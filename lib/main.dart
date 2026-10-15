import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:local_auth/local_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:share_plus/share_plus.dart';


/// Keystore-backed storage for native secrets such as future API tokens or
/// integration credentials. Do not put PMS records in ordinary preferences.
class AureliaSecureVault {
  AureliaSecureVault._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: false,
    ),
  );

  static Future<void> writeSecret(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<String?> readSecret(String key) =>
      _storage.read(key: key);

  static Future<void> deleteSecret(String key) =>
      _storage.delete(key: key);
}


/// Encrypted, app-private storage for the authoritative PMS database.
/// AES-256-GCM encrypts each snapshot with a random nonce. The key is kept in
/// Android Keystore-backed secure storage; ciphertext files are never plaintext.
class AureliaEncryptedPmsStore {
  AureliaEncryptedPmsStore._();

  static const String _keyName = 'aurelia_pms_database_key_v1';
  static const String _aad = 'aurelia-pms-database-v1';
  static final AesGcm _algorithm = AesGcm.with256bits();
  static Future<void> _pendingWrite = Future<void>.value();

  static Future<Directory> _directory() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return directory;
  }

  static Future<File> _file(String name) async =>
      File('${(await _directory()).path}/$name');

  static Future<SecretKey> _key({required bool createIfMissing}) async {
    final stored = await AureliaSecureVault.readSecret(_keyName);
    if (stored != null) {
      final bytes = base64Decode(stored);
      if (bytes.length != 32) {
        throw StateError('The saved PMS encryption key is invalid. Data was not changed.');
      }
      return SecretKey(bytes);
    }
    if (!createIfMissing) {
      throw StateError('The PMS encryption key is missing. Data was not changed.');
    }
    final bytes = List<int>.generate(32, (_) => math.Random.secure().nextInt(256));
    await AureliaSecureVault.writeSecret(_keyName, base64Encode(bytes));
    return SecretKey(bytes);
  }

  static Future<String?> read() async {
    final primary = await _file('aurelia-pms-primary.enc');
    final recovery = await _file('aurelia-pms-recovery.enc');
    if (!await primary.exists() && !await recovery.exists()) return null;

    final key = await _key(createIfMissing: false);
    Object? primaryError;
    for (final file in <File>[primary, recovery]) {
      if (!await file.exists()) continue;
      try {
        final envelope = jsonDecode(await file.readAsString());
        if (envelope is! Map<String, dynamic> || envelope['version'] != 1 ||
            envelope['algorithm'] != 'AES-256-GCM') {
          throw const FormatException('Unsupported encrypted PMS data format.');
        }
        final box = SecretBox(
          base64Decode(envelope['ciphertext'] as String),
          nonce: base64Decode(envelope['nonce'] as String),
          mac: Mac(base64Decode(envelope['tag'] as String)),
        );
        final clear = await _algorithm.decrypt(
          box,
          secretKey: key,
          aad: utf8.encode(_aad),
        );
        final text = utf8.decode(clear);
        if (jsonDecode(text) is! Map<String, dynamic>) {
          throw const FormatException('Encrypted PMS data has an invalid root structure.');
        }
        return text;
      } catch (error) {
        primaryError ??= error;
      }
    }
    throw StateError('Encrypted PMS data could not be opened. The original files were preserved. Details: $primaryError');
  }

  static Future<void> write(String json) {
    final next = _pendingWrite.then((_) => _writeNow(json));
    _pendingWrite = next.catchError((Object _) {});
    return next;
  }

  static Future<void> _writeNow(String json) async {
    if (json.length > 20 * 1024 * 1024) {
      throw const FormatException('PMS database exceeds the 20 MB storage limit.');
    }
    if (jsonDecode(json) is! Map<String, dynamic>) {
      throw const FormatException('PMS database must be a JSON object.');
    }
    final key = await _key(createIfMissing: true);
    final box = await _algorithm.encrypt(
      utf8.encode(json),
      secretKey: key,
      aad: utf8.encode(_aad),
    );
    final envelope = jsonEncode({
      'version': 1,
      'algorithm': 'AES-256-GCM',
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
    await _writeEnvelope('aurelia-pms-primary.enc', envelope);
    await _writeEnvelope('aurelia-pms-recovery.enc', envelope);
  }

  static const int _backupIterations = 310000;
  static const String _backupAad = 'aurelia-pms-portable-backup-v1';
  static final Pbkdf2 _backupKdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: _backupIterations,
    bits: 256,
  );

  static void _validateTree(Object? value, int depth, List<int> count) {
    if (depth > 40) throw const FormatException('Backup data is nested too deeply.');
    count[0]++;
    if (count[0] > 250000) throw const FormatException('Backup contains too many data items.');
    if (value == null || value is String || value is bool) return;
    if (value is num) {
      if (!value.isFinite) throw const FormatException('Backup contains an invalid number.');
      return;
    }
    if (value is List) {
      for (final item in value) {
        _validateTree(item, depth + 1, count);
      }
      return;
    }
    if (value is Map<String, dynamic>) {
      for (final entry in value.entries) {
        if (const {'__proto__', 'prototype', 'constructor'}.contains(entry.key)) {
          throw const FormatException('Backup contains an unsafe property name.');
        }
        _validateTree(entry.value, depth + 1, count);
      }
      return;
    }
    throw const FormatException('Backup contains an unsupported data value.');
  }

  static Map<String, dynamic> _validateBackupPayload(String json) {
    if (json.length > 20 * 1024 * 1024) {
      throw const FormatException('Backup exceeds the 20 MB limit.');
    }
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, dynamic> || decoded['app'] != 'AURELIA PMS' ||
        decoded['formatVersion'] != 1 || decoded['data'] is! Map<String, dynamic>) {
      throw const FormatException('Unsupported or invalid Aurelia backup.');
    }
    final data = decoded['data'] as Map<String, dynamic>;
    if (data['guests'] is! List || data['rooms'] is! List ||
        (data['bookings'] is! List && data['reservations'] is! List)) {
      throw const FormatException('Backup is missing required guest, room, or booking lists.');
    }
    for (final key in const ['guests','rooms','bookings','reservations','inventory','expenses','payments']) {
      if (data.containsKey(key) && data[key] is! List) {
        throw FormatException('The "$key" section must be a list.');
      }
    }
    _validateTree(data, 0, [0]);
    return data;
  }

  static Future<String> encryptPortableBackup(String payload, String passphrase) async {
    if (passphrase.length < 12 || passphrase.length > 1024) {
      throw const FormatException('Use a backup passphrase between 12 and 1024 characters.');
    }
    if (payload.length > 20 * 1024 * 1024) {
      throw const FormatException('Backup exceeds the 20 MB limit.');
    }
    _validateBackupPayload(payload);
    final salt = List<int>.generate(16, (_) => math.Random.secure().nextInt(256));
    final key = await _backupKdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final box = await _algorithm.encrypt(
      utf8.encode(payload),
      secretKey: key,
      aad: utf8.encode(_backupAad),
    );
    return jsonEncode({
      'app': 'AURELIA PMS ENCRYPTED BACKUP',
      'formatVersion': 1,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _backupIterations,
      'algorithm': 'AES-256-GCM',
      'salt': base64Encode(salt),
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes),
    });
  }

  static Future<String> decryptPortableBackup(String envelopeJson, String passphrase) async {
    if (passphrase.length < 1 || passphrase.length > 1024 ||
        envelopeJson.length > 30 * 1024 * 1024) {
      throw const FormatException('Invalid encrypted backup size or passphrase.');
    }
    final envelope = jsonDecode(envelopeJson);
    if (envelope is! Map<String, dynamic> ||
        envelope['app'] != 'AURELIA PMS ENCRYPTED BACKUP' ||
        envelope['formatVersion'] != 1 ||
        envelope['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        envelope['iterations'] != _backupIterations ||
        envelope['algorithm'] != 'AES-256-GCM') {
      throw const FormatException('Unsupported encrypted backup format.');
    }
    final salt = base64Decode(envelope['salt'] as String);
    final nonce = base64Decode(envelope['nonce'] as String);
    final ciphertext = base64Decode(envelope['ciphertext'] as String);
    final tag = base64Decode(envelope['tag'] as String);
    if (salt.length != 16 || nonce.length != 12 || tag.length != 16 ||
        ciphertext.length > 20 * 1024 * 1024) {
      throw const FormatException('Encrypted backup envelope is invalid or too large.');
    }
    final key = await _backupKdf.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
    final clear = await _algorithm.decrypt(
      SecretBox(ciphertext, nonce: nonce, mac: Mac(tag)),
      secretKey: key,
      aad: utf8.encode(_backupAad),
    );
    final payload = utf8.decode(clear);
    final data = _validateBackupPayload(payload);
    return jsonEncode(data);
  }

  static Future<void> _writeEnvelope(String name, String envelope) async {
    final target = await _file(name);
    final temporary = await _file('$name.tmp');
    await temporary.writeAsString(envelope, flush: true);
    await temporary.rename(target.path);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AureliaPmsApp());
}

class AureliaPmsApp extends StatelessWidget {
  const AureliaPmsApp({super.key});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _lockoutTimer?.cancel();
    _pinController.dispose();
    _confirmPinController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aurelia PMS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF17365D)),
        useMaterial3: true,
      ),
      home: const PmsWebViewPage(),
    );
  }
}

class PmsWebViewPage extends StatefulWidget {
  const PmsWebViewPage({super.key});

  @override
  State<PmsWebViewPage> createState() => _PmsWebViewPageState();
}

class _PmsWebViewPageState extends State<PmsWebViewPage> with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;
  bool _gateLoading = true;
  bool _pinConfigured = false;
  bool _unlocked = false;
  bool _pmsLoaded = false;
  bool _isAuthenticating = false;
  bool _deviceAuthAvailable = false;
  String? _gateError;
  int _failedAttempts = 0;
  DateTime? _lockoutUntil;
  Timer? _lockoutTimer;
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _confirmPinController = TextEditingController();
  final LocalAuthentication _localAuth = LocalAuthentication();
  static const String _pinSaltKey = 'aurelia_pms_pin_salt_v1';
  static const String _pinHashKey = 'aurelia_pms_pin_hash_v1';
  static const String _pinAttemptsKey = 'aurelia_pms_pin_attempts_v1';
  static const String _pinLockUntilKey = 'aurelia_pms_pin_lock_until_v1';
  static final Pbkdf2 _pinKdf = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 310000, bits: 256);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('AureliaNative', onMessageReceived: (message) { unawaited(_handleNativeMessage(message.message)); })
      ..setBackgroundColor(const Color(0xFFFFFCF6))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            debugPrint('Aurelia PMS WebView error: ${error.description}');
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            // The JavaScript bridge is intended only for our bundled local PMS.
            // Never let a remote page become top-level while the bridge is installed.
            if (uri != null && uri.scheme == 'file' && uri.path.startsWith('/android_asset/flutter_assets/')) {
              return NavigationDecision.navigate;
            }
            if (uri != null && (uri.scheme == 'tel' || uri.scheme == 'mailto')) {
              return NavigationDecision.navigate;
            }
            if (uri != null && uri.scheme == 'about' && uri.path == 'blank') {
              return NavigationDecision.navigate;
            }
            debugPrint('Blocked non-local top-level navigation: ${request.url}');
            return NavigationDecision.prevent;
          },
        ),
      );

    final platformController = _controller.platform;
    if (platformController is AndroidWebViewController) {
      // Handle HTML <input type="file"> controls, including Settings > Upload
      // payment QR, hotel logo, guest ID images, and data import files.
      unawaited(
        platformController.setOnShowFileSelector((params) async {
          try {
            final imageOnly = params.acceptTypes.isNotEmpty &&
                params.acceptTypes.every(
                  (type) => type.toLowerCase().startsWith('image/'),
                );
            final picked = await FilePicker.platform.pickFiles(
              type: imageOnly ? FileType.image : FileType.any,
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
            );
            if (picked == null) return <String>[];
            return picked.files
                .where((file) => file.path != null)
                .map((file) => file.path!)
                .toList();
          } catch (error) {
            debugPrint('Aurelia PMS file selection failed: $error');
            return <String>[];
          }
        }),
      );
    }

    unawaited(_initializeAccessGate());
  }


  Future<void> _initializeAccessGate() async {
    try {
      final salt = await AureliaSecureVault.readSecret(_pinSaltKey);
      final hash = await AureliaSecureVault.readSecret(_pinHashKey);
      if ((salt == null) != (hash == null)) {
        throw StateError('PIN configuration is incomplete. Existing encrypted PMS data has not been changed.');
      }
      final attempts = await AureliaSecureVault.readSecret(_pinAttemptsKey);
      final lockUntil = await AureliaSecureVault.readSecret(_pinLockUntilKey);
      var deviceAuth = false;
      try { deviceAuth = await _localAuth.isDeviceSupported(); } catch (_) {}
      if (!mounted) return;
      setState(() {
        _pinConfigured = salt != null && hash != null;
        _failedAttempts = int.tryParse(attempts ?? '') ?? 0;
        _lockoutUntil = lockUntil == null ? null : DateTime.tryParse(lockUntil);
        _deviceAuthAvailable = deviceAuth;
        _gateLoading = false;
      });
      _startLockoutTicker();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _gateLoading = false;
        _gateError = 'Secure authentication could not be loaded. Do not clear app data or reinstall. Details: ' + error.toString();
      });
    }
  }

  Future<String> _derivePinHash(String pin, List<int> salt) async {
    final key = await _pinKdf.deriveKey(secretKey: SecretKey(utf8.encode(pin)), nonce: salt);
    return base64Encode(await key.extractBytes());
  }

  bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var difference = 0;
    for (var i = 0; i < a.length; i++) { difference |= a[i] ^ b[i]; }
    return difference == 0;
  }

  Future<void> _configurePin() async {
    final pin = _pinController.text;
    final confirm = _confirmPinController.text;
    if (!RegExp(r'^\d{6,12}
    String? requestId;
    try {
      if (raw.length > 45 * 1024 * 1024) throw const FormatException('Request too large');
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid request');
      final rawId = value['requestId'];
      if (rawId is String) {
        final cleaned = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        requestId = cleaned.substring(0, cleaned.length.clamp(0, 64).toInt());
      }
      if (value['type'] == 'exportEncryptedBackup') {
        final dataValue = value['data'];
        final passphrase = value['passphrase'];
        if (requestId == null || dataValue is! String || passphrase is! String) {
          throw const FormatException('Missing encrypted backup fields');
        }
        final payload = jsonEncode({
          'app': 'AURELIA PMS',
          'formatVersion': 1,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'data': jsonDecode(dataValue),
        });
        final envelope = await AureliaEncryptedPmsStore.encryptPortableBackup(payload, passphrase);
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/aurelia-pms-backup-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.aurelia');
        await file.writeAsString(envelope, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: 'aurelia-pms-encrypted-backup.aurelia')],
          subject: 'Encrypted Aurelia PMS backup',
        );
        await _controller.runJavaScript(
          'window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'restoreEncryptedBackup') {
        final envelopeValue = value['envelope'];
        final passphrase = value['passphrase'];
        if (requestId == null || envelopeValue is! Map<String, dynamic> || passphrase is! String) {
          throw const FormatException('Missing encrypted restore fields');
        }
        final restored = await AureliaEncryptedPmsStore.decryptPortableBackup(
          jsonEncode(envelopeValue),
          passphrase,
        );
        await AureliaEncryptedPmsStore.write(restored);
        await _controller.runJavaScript(
          'window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'savePmsData') {
        final dataValue = value['data'];
        if (requestId == null || dataValue is! String || dataValue.length > 20 * 1024 * 1024) {
          throw const FormatException('Missing or oversized secure database fields');
        }
        await AureliaEncryptedPmsStore.write(dataValue);
        await _controller.runJavaScript(
          'window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'generateQr') {
        final text = value['text'];
        if (text is! String || text.isEmpty || text.length > 2048) throw const FormatException('Invalid QR content');
        final code = QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M);
        final qrImage = QrImage(code);
        const quiet = 4;
        final side = qrImage.moduleCount + quiet * 2;
        final squares = <String>[];
        for (var y = 0; y < qrImage.moduleCount; y++) {
          for (var x = 0; x < qrImage.moduleCount; x++) {
            if (qrImage.isDark(y, x)) squares.add('M${x + quiet} ${y + quiet}h1v1h-1z');
          }
        }
        final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $side $side" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="${squares.join()}" fill="#000"/></svg>';
        final data = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
        await _controller.runJavaScript('window.aureliaNativeQrResult(${jsonEncode(requestId)},${jsonEncode(data)},null);');
        return;
      }
      if (value['type'] == 'shareFile') {
        final nameValue = value['name'], mimeValue = value['mime'], dataValue = value['data'];
        if (nameValue is! String || mimeValue is! String || dataValue is! String) throw const FormatException('Missing file fields');
        if (dataValue.length > 20 * 1024 * 1024) throw const FormatException('File too large');
        final safeName = nameValue.split(RegExp(r'[/\\\\]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (safeName.isEmpty || safeName == '.' || safeName == '..') throw const FormatException('Invalid file name');
        const allowed = <String>{'text/csv','application/json','application/pdf','text/plain','text/html','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/png','image/jpeg','application/octet-stream'};
        final mime = allowed.contains(mimeValue) ? mimeValue : 'application/octet-stream';
        final bytes = base64Decode(dataValue);
        if (bytes.length > 15 * 1024 * 1024) throw const FormatException('File too large');
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/$safeName');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([XFile(file.path, mimeType: mime, name: safeName)], subject: safeName);
        await _controller.runJavaScript('window.aureliaNativeFileResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      throw const FormatException('Unsupported native action');
    } catch (error) {
      debugPrint('Aurelia native bridge rejected request: $error');
      if (requestId != null) {
        try {
          await _controller.runJavaScript('window.aureliaNativeQrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeFileResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});');
        } catch (_) {}
      }
    }
  }

  Future<void> _loadLocalPms() async {
    try {
      // Decrypt before app JavaScript executes so legacy localStorage is never
      // authoritative in the native app. If decryption fails, fail closed.
      final saved = await AureliaEncryptedPmsStore.read();
      final html = await rootBundle.loadString('assets/index.html');
      final headEnd = html.toLowerCase().indexOf('</head>');
      if (headEnd < 0) throw const FormatException('Bundled PMS HTML has no head element.');
      final bootstrap = '<script id="aurelia-secure-db-bootstrap">'
          'window.__AURELIA_SECURE_DB_READY=true;'
          'window.__AURELIA_SECURE_DB_EXISTS=${saved != null};'
          'window.__AURELIA_SECURE_DB_BOOTSTRAP=${saved == null ? 'null' : jsonEncode(jsonDecode(saved))};'
          '</script>';
      final page = html.substring(0, headEnd) + bootstrap + html.substring(headEnd);
      await _controller.loadHtmlString(
        page,
        baseUrl: 'file:///android_asset/flutter_assets/assets/index.html',
      );
    } catch (e) {
      debugPrint('Could not safely open Aurelia PMS data: $e');
      if (mounted) setState(() => _loading = false);
      // Never fall back to seed data when encrypted records exist but cannot be
      // decrypted. This avoids a false empty state and accidental overwrites.
      await _controller.loadHtmlString(
        '<!doctype html><html><meta name="viewport" content="width=device-width">'
        '<body style="font:16px sans-serif;padding:24px"><h2>Aurelia PMS data could not be opened</h2>'
        '<p>Your saved data has not been deleted or replaced. Do not uninstall the app or clear its data. '
        'Restore access to the device encryption key or recover from a trusted backup before continuing.</p></body></html>',
      );
    }
  }

  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(
                    value: _progress == 100 ? null : _progress / 100,
                  ),
                ),
              if (!_unlocked)
                Positioned.fill(child: _buildAccessGate()),
            ],
          ),
        ),
      ),
    );
  }
}
).hasMatch(pin)) {
      setState(() => _gateError = 'Choose a PIN with 6 to 12 digits.');
      return;
    }
    if (pin != confirm) {
      setState(() => _gateError = 'The PINs do not match.');
      return;
    }
    setState(() { _isAuthenticating = true; _gateError = null; });
    try {
      final salt = List<int>.generate(16, (_) => math.Random.secure().nextInt(256));
      final hash = await _derivePinHash(pin, salt);
      await AureliaSecureVault.writeSecret(_pinSaltKey, base64Encode(salt));
      await AureliaSecureVault.writeSecret(_pinHashKey, hash);
      await AureliaSecureVault.writeSecret(_pinAttemptsKey, '0');
      await AureliaSecureVault.deleteSecret(_pinLockUntilKey);
      if (!mounted) return;
      setState(() {
        _pinConfigured = true;
        _failedAttempts = 0;
        _lockoutUntil = null;
        _isAuthenticating = false;
      });
      _pinController.clear();
      _confirmPinController.clear();
      await _unlockAndLoad();
    } catch (error) {
      await AureliaSecureVault.deleteSecret(_pinSaltKey);
      await AureliaSecureVault.deleteSecret(_pinHashKey);
      if (mounted) setState(() { _isAuthenticating = false; _gateError = 'Could not securely save the PIN. Try again. ' + error.toString(); });
    }
  }

  Future<void> _verifyPin() async {
    final now = DateTime.now();
    if (_lockoutUntil != null && now.isBefore(_lockoutUntil!)) {
      setState(() => _gateError = 'Too many attempts. Try again after ' + _lockoutUntil!.toLocal().toString() + '.');
      return;
    }
    if (_lockoutUntil != null && !now.isBefore(_lockoutUntil!)) {
      _failedAttempts = 0;
      _lockoutUntil = null;
      await AureliaSecureVault.writeSecret(_pinAttemptsKey, '0');
      await AureliaSecureVault.deleteSecret(_pinLockUntilKey);
    }
    final pin = _pinController.text;
    if (!RegExp(r'^\d{6,12}
    String? requestId;
    try {
      if (raw.length > 45 * 1024 * 1024) throw const FormatException('Request too large');
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid request');
      final rawId = value['requestId'];
      if (rawId is String) {
        final cleaned = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        requestId = cleaned.substring(0, cleaned.length.clamp(0, 64).toInt());
      }
      if (value['type'] == 'exportEncryptedBackup') {
        final dataValue = value['data'];
        final passphrase = value['passphrase'];
        if (requestId == null || dataValue is! String || passphrase is! String) {
          throw const FormatException('Missing encrypted backup fields');
        }
        final payload = jsonEncode({
          'app': 'AURELIA PMS',
          'formatVersion': 1,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'data': jsonDecode(dataValue),
        });
        final envelope = await AureliaEncryptedPmsStore.encryptPortableBackup(payload, passphrase);
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/aurelia-pms-backup-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.aurelia');
        await file.writeAsString(envelope, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: 'aurelia-pms-encrypted-backup.aurelia')],
          subject: 'Encrypted Aurelia PMS backup',
        );
        await _controller.runJavaScript(
          'window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'restoreEncryptedBackup') {
        final envelopeValue = value['envelope'];
        final passphrase = value['passphrase'];
        if (requestId == null || envelopeValue is! Map<String, dynamic> || passphrase is! String) {
          throw const FormatException('Missing encrypted restore fields');
        }
        final restored = await AureliaEncryptedPmsStore.decryptPortableBackup(
          jsonEncode(envelopeValue),
          passphrase,
        );
        await AureliaEncryptedPmsStore.write(restored);
        await _controller.runJavaScript(
          'window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'savePmsData') {
        final dataValue = value['data'];
        if (requestId == null || dataValue is! String || dataValue.length > 20 * 1024 * 1024) {
          throw const FormatException('Missing or oversized secure database fields');
        }
        await AureliaEncryptedPmsStore.write(dataValue);
        await _controller.runJavaScript(
          'window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'generateQr') {
        final text = value['text'];
        if (text is! String || text.isEmpty || text.length > 2048) throw const FormatException('Invalid QR content');
        final code = QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M);
        final qrImage = QrImage(code);
        const quiet = 4;
        final side = qrImage.moduleCount + quiet * 2;
        final squares = <String>[];
        for (var y = 0; y < qrImage.moduleCount; y++) {
          for (var x = 0; x < qrImage.moduleCount; x++) {
            if (qrImage.isDark(y, x)) squares.add('M${x + quiet} ${y + quiet}h1v1h-1z');
          }
        }
        final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $side $side" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="${squares.join()}" fill="#000"/></svg>';
        final data = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
        await _controller.runJavaScript('window.aureliaNativeQrResult(${jsonEncode(requestId)},${jsonEncode(data)},null);');
        return;
      }
      if (value['type'] == 'shareFile') {
        final nameValue = value['name'], mimeValue = value['mime'], dataValue = value['data'];
        if (nameValue is! String || mimeValue is! String || dataValue is! String) throw const FormatException('Missing file fields');
        if (dataValue.length > 20 * 1024 * 1024) throw const FormatException('File too large');
        final safeName = nameValue.split(RegExp(r'[/\\\\]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (safeName.isEmpty || safeName == '.' || safeName == '..') throw const FormatException('Invalid file name');
        const allowed = <String>{'text/csv','application/json','application/pdf','text/plain','text/html','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/png','image/jpeg','application/octet-stream'};
        final mime = allowed.contains(mimeValue) ? mimeValue : 'application/octet-stream';
        final bytes = base64Decode(dataValue);
        if (bytes.length > 15 * 1024 * 1024) throw const FormatException('File too large');
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/$safeName');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([XFile(file.path, mimeType: mime, name: safeName)], subject: safeName);
        await _controller.runJavaScript('window.aureliaNativeFileResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      throw const FormatException('Unsupported native action');
    } catch (error) {
      debugPrint('Aurelia native bridge rejected request: $error');
      if (requestId != null) {
        try {
          await _controller.runJavaScript('window.aureliaNativeQrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeFileResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});');
        } catch (_) {}
      }
    }
  }

  Future<void> _loadLocalPms() async {
    try {
      // Decrypt before app JavaScript executes so legacy localStorage is never
      // authoritative in the native app. If decryption fails, fail closed.
      final saved = await AureliaEncryptedPmsStore.read();
      final html = await rootBundle.loadString('assets/index.html');
      final headEnd = html.toLowerCase().indexOf('</head>');
      if (headEnd < 0) throw const FormatException('Bundled PMS HTML has no head element.');
      final bootstrap = '<script id="aurelia-secure-db-bootstrap">'
          'window.__AURELIA_SECURE_DB_READY=true;'
          'window.__AURELIA_SECURE_DB_EXISTS=${saved != null};'
          'window.__AURELIA_SECURE_DB_BOOTSTRAP=${saved == null ? 'null' : jsonEncode(jsonDecode(saved))};'
          '</script>';
      final page = html.substring(0, headEnd) + bootstrap + html.substring(headEnd);
      await _controller.loadHtmlString(
        page,
        baseUrl: 'file:///android_asset/flutter_assets/assets/index.html',
      );
    } catch (e) {
      debugPrint('Could not safely open Aurelia PMS data: $e');
      if (mounted) setState(() => _loading = false);
      // Never fall back to seed data when encrypted records exist but cannot be
      // decrypted. This avoids a false empty state and accidental overwrites.
      await _controller.loadHtmlString(
        '<!doctype html><html><meta name="viewport" content="width=device-width">'
        '<body style="font:16px sans-serif;padding:24px"><h2>Aurelia PMS data could not be opened</h2>'
        '<p>Your saved data has not been deleted or replaced. Do not uninstall the app or clear its data. '
        'Restore access to the device encryption key or recover from a trusted backup before continuing.</p></body></html>',
      );
    }
  }

  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(
                    value: _progress == 100 ? null : _progress / 100,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
).hasMatch(pin)) {
      setState(() => _gateError = 'Enter your 6 to 12 digit PIN.');
      return;
    }
    setState(() { _isAuthenticating = true; _gateError = null; });
    try {
      final saltValue = await AureliaSecureVault.readSecret(_pinSaltKey);
      final hashValue = await AureliaSecureVault.readSecret(_pinHashKey);
      if (saltValue == null || hashValue == null) throw StateError('PIN configuration is missing.');
      final candidate = base64Decode(await _derivePinHash(pin, base64Decode(saltValue)));
      final expected = base64Decode(hashValue);
      if (_constantTimeEquals(candidate, expected)) {
        await AureliaSecureVault.writeSecret(_pinAttemptsKey, '0');
        await AureliaSecureVault.deleteSecret(_pinLockUntilKey);
        _failedAttempts = 0;
        _lockoutUntil = null;
        _pinController.clear();
        if (mounted) setState(() => _isAuthenticating = false);
        await _unlockAndLoad();
        return;
      }
      _failedAttempts += 1;
      await AureliaSecureVault.writeSecret(_pinAttemptsKey, _failedAttempts.toString());
      if (_failedAttempts >= 5) {
        _lockoutUntil = DateTime.now().add(const Duration(minutes: 5));
        await AureliaSecureVault.writeSecret(_pinLockUntilKey, _lockoutUntil!.toIso8601String());
        _startLockoutTicker();
      }
      if (mounted) {
        setState(() {
          _isAuthenticating = false;
          _gateError = _lockoutUntil == null
              ? 'Incorrect PIN. ' + (5 - _failedAttempts).toString() + ' attempts remain before a 5-minute lockout.'
              : 'Too many attempts. Access is locked for 5 minutes.';
        });
      }
      _pinController.clear();
    } catch (error) {
      if (mounted) setState(() { _isAuthenticating = false; _gateError = 'Could not verify PIN securely. ' + error.toString(); });
    }
  }

  void _startLockoutTicker() {
    _lockoutTimer?.cancel();
    if (_lockoutUntil == null) return;
    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) { timer.cancel(); return; }
      if (_lockoutUntil == null || !DateTime.now().isBefore(_lockoutUntil!)) {
        timer.cancel();
        setState(() {
          _lockoutUntil = null;
          _failedAttempts = 0;
          _gateError = null;
        });
        unawaited(AureliaSecureVault.writeSecret(_pinAttemptsKey, '0'));
        unawaited(AureliaSecureVault.deleteSecret(_pinLockUntilKey));
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _tryDeviceAuthentication() async {
    setState(() { _isAuthenticating = true; _gateError = null; });
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Unlock Aurelia PMS',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (!mounted) return;
      setState(() => _isAuthenticating = false);
      if (authenticated) {
        await AureliaSecureVault.writeSecret(_pinAttemptsKey, '0');
        await AureliaSecureVault.deleteSecret(_pinLockUntilKey);
        _failedAttempts = 0;
        _lockoutUntil = null;
        await _unlockAndLoad();
      } else {
        setState(() => _gateError = 'Device authentication was cancelled or not accepted.');
      }
    } catch (error) {
      if (mounted) setState(() { _isAuthenticating = false; _gateError = 'Device authentication is unavailable. Use your PIN. ' + error.toString(); });
    }
  }

  Future<void> _unlockAndLoad() async {
    if (!mounted) return;
    setState(() { _unlocked = true; _gateError = null; });
    if (!_pmsLoaded) {
      await _loadLocalPms();
      if (mounted) setState(() => _pmsLoaded = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _unlocked && mounted) {
      setState(() {
        _unlocked = false;
        _pinController.clear();
        _confirmPinController.clear();
        _gateError = null;
      });
    }
  }

  Widget _buildAccessGate() {
    final locked = _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);
    final remaining = locked ? _lockoutUntil!.difference(DateTime.now()).inSeconds + 1 : 0;
    return Container(
      color: const Color(0xFFF3F7FA),
      alignment: Alignment.center,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    _gateLoading ? 'Securing Aurelia PMS' : (_pinConfigured ? 'Unlock Aurelia PMS' : 'Create your PMS PIN'),
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your PMS data is encrypted on this device. Keep your PIN private and keep an encrypted backup somewhere safe.',
                    textAlign: TextAlign.center,
                  ),
                  if (_gateLoading) const Padding(
                    padding: EdgeInsets.all(18),
                    child: CircularProgressIndicator(),
                  ),
                  if (!_gateLoading && _gateError != null) Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_gateError!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
                  ),
                  if (!_gateLoading && !_pinConfigured && _gateError == null) const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Choose 6–12 digits. This PIN is not recoverable by the developer; store it safely.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (!_gateLoading && _gateError == null) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: _pinController,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 12,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      enabled: !_isAuthenticating && !locked,
                      decoration: const InputDecoration(labelText: 'PIN', border: OutlineInputBorder()),
                      onSubmitted: (_) => _pinConfigured ? _verifyPin() : _configurePin(),
                    ),
                    if (!_pinConfigured) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _confirmPinController,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 12,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        enabled: !_isAuthenticating,
                        decoration: const InputDecoration(labelText: 'Confirm PIN', border: OutlineInputBorder()),
                        onSubmitted: (_) => _configurePin(),
                      ),
                    ],
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _isAuthenticating || locked ? null : (_pinConfigured ? _verifyPin : _configurePin),
                        child: Text(
                          _isAuthenticating ? 'Please wait…' : (locked ? 'Try again in ' + remaining.toString() + 's' : (_pinConfigured ? 'Unlock' : 'Save PIN and continue')),
                        ),
                      ),
                    ),
                    if (_pinConfigured && _deviceAuthAvailable) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _isAuthenticating ? null : _tryDeviceAuthentication,
                          icon: const Icon(Icons.fingerprint),
                          label: const Text('Use device authentication'),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleNativeMessage(String raw) async {
    String? requestId;
    try {
      if (raw.length > 45 * 1024 * 1024) throw const FormatException('Request too large');
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid request');
      final rawId = value['requestId'];
      if (rawId is String) {
        final cleaned = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        requestId = cleaned.substring(0, cleaned.length.clamp(0, 64).toInt());
      }
      if (value['type'] == 'exportEncryptedBackup') {
        final dataValue = value['data'];
        final passphrase = value['passphrase'];
        if (requestId == null || dataValue is! String || passphrase is! String) {
          throw const FormatException('Missing encrypted backup fields');
        }
        final payload = jsonEncode({
          'app': 'AURELIA PMS',
          'formatVersion': 1,
          'exportedAt': DateTime.now().toUtc().toIso8601String(),
          'data': jsonDecode(dataValue),
        });
        final envelope = await AureliaEncryptedPmsStore.encryptPortableBackup(payload, passphrase);
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/aurelia-pms-backup-${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}.aurelia');
        await file.writeAsString(envelope, flush: true);
        await Share.shareXFiles(
          [XFile(file.path, mimeType: 'application/octet-stream', name: 'aurelia-pms-encrypted-backup.aurelia')],
          subject: 'Encrypted Aurelia PMS backup',
        );
        await _controller.runJavaScript(
          'window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'restoreEncryptedBackup') {
        final envelopeValue = value['envelope'];
        final passphrase = value['passphrase'];
        if (requestId == null || envelopeValue is! Map<String, dynamic> || passphrase is! String) {
          throw const FormatException('Missing encrypted restore fields');
        }
        final restored = await AureliaEncryptedPmsStore.decryptPortableBackup(
          jsonEncode(envelopeValue),
          passphrase,
        );
        await AureliaEncryptedPmsStore.write(restored);
        await _controller.runJavaScript(
          'window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'savePmsData') {
        final dataValue = value['data'];
        if (requestId == null || dataValue is! String || dataValue.length > 20 * 1024 * 1024) {
          throw const FormatException('Missing or oversized secure database fields');
        }
        await AureliaEncryptedPmsStore.write(dataValue);
        await _controller.runJavaScript(
          'window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'generateQr') {
        final text = value['text'];
        if (text is! String || text.isEmpty || text.length > 2048) throw const FormatException('Invalid QR content');
        final code = QrCode.fromData(data: text, errorCorrectLevel: QrErrorCorrectLevel.M);
        final qrImage = QrImage(code);
        const quiet = 4;
        final side = qrImage.moduleCount + quiet * 2;
        final squares = <String>[];
        for (var y = 0; y < qrImage.moduleCount; y++) {
          for (var x = 0; x < qrImage.moduleCount; x++) {
            if (qrImage.isDark(y, x)) squares.add('M${x + quiet} ${y + quiet}h1v1h-1z');
          }
        }
        final svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $side $side" shape-rendering="crispEdges"><rect width="100%" height="100%" fill="#fff"/><path d="${squares.join()}" fill="#000"/></svg>';
        final data = 'data:image/svg+xml;base64,${base64Encode(utf8.encode(svg))}';
        await _controller.runJavaScript('window.aureliaNativeQrResult(${jsonEncode(requestId)},${jsonEncode(data)},null);');
        return;
      }
      if (value['type'] == 'shareFile') {
        final nameValue = value['name'], mimeValue = value['mime'], dataValue = value['data'];
        if (nameValue is! String || mimeValue is! String || dataValue is! String) throw const FormatException('Missing file fields');
        if (dataValue.length > 20 * 1024 * 1024) throw const FormatException('File too large');
        final safeName = nameValue.split(RegExp(r'[/\\\\]')).last.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (safeName.isEmpty || safeName == '.' || safeName == '..') throw const FormatException('Invalid file name');
        const allowed = <String>{'text/csv','application/json','application/pdf','text/plain','text/html','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/png','image/jpeg','application/octet-stream'};
        final mime = allowed.contains(mimeValue) ? mimeValue : 'application/octet-stream';
        final bytes = base64Decode(dataValue);
        if (bytes.length > 15 * 1024 * 1024) throw const FormatException('File too large');
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/$safeName');
        await file.writeAsBytes(bytes, flush: true);
        await Share.shareXFiles([XFile(file.path, mimeType: mime, name: safeName)], subject: safeName);
        await _controller.runJavaScript('window.aureliaNativeFileResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      throw const FormatException('Unsupported native action');
    } catch (error) {
      debugPrint('Aurelia native bridge rejected request: $error');
      if (requestId != null) {
        try {
          await _controller.runJavaScript('window.aureliaNativeQrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeFileResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});');
        } catch (_) {}
      }
    }
  }

  Future<void> _loadLocalPms() async {
    try {
      // Decrypt before app JavaScript executes so legacy localStorage is never
      // authoritative in the native app. If decryption fails, fail closed.
      final saved = await AureliaEncryptedPmsStore.read();
      final html = await rootBundle.loadString('assets/index.html');
      final headEnd = html.toLowerCase().indexOf('</head>');
      if (headEnd < 0) throw const FormatException('Bundled PMS HTML has no head element.');
      final bootstrap = '<script id="aurelia-secure-db-bootstrap">'
          'window.__AURELIA_SECURE_DB_READY=true;'
          'window.__AURELIA_SECURE_DB_EXISTS=${saved != null};'
          'window.__AURELIA_SECURE_DB_BOOTSTRAP=${saved == null ? 'null' : jsonEncode(jsonDecode(saved))};'
          '</script>';
      final page = html.substring(0, headEnd) + bootstrap + html.substring(headEnd);
      await _controller.loadHtmlString(
        page,
        baseUrl: 'file:///android_asset/flutter_assets/assets/index.html',
      );
    } catch (e) {
      debugPrint('Could not safely open Aurelia PMS data: $e');
      if (mounted) setState(() => _loading = false);
      // Never fall back to seed data when encrypted records exist but cannot be
      // decrypted. This avoids a false empty state and accidental overwrites.
      await _controller.loadHtmlString(
        '<!doctype html><html><meta name="viewport" content="width=device-width">'
        '<body style="font:16px sans-serif;padding:24px"><h2>Aurelia PMS data could not be opened</h2>'
        '<p>Your saved data has not been deleted or replaced. Do not uninstall the app or clear its data. '
        'Restore access to the device encryption key or recover from a trusted backup before continuing.</p></body></html>',
      );
    }
  }

  Future<bool> _handleBack() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldExit = await _handleBack();
        if (shouldExit && mounted) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(
                    value: _progress == 100 ? null : _progress / 100,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
