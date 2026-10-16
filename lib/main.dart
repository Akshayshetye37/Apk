import 'dart:async';
import 'image_viewer_engine.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'pms_access_gate.dart';
import 'pdf_viewer_engine.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
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
    // The primary snapshot is authoritative. A recovery-copy failure must not
    // report the already-durable primary write as a total failure.
    await _writeEnvelope('aurelia-pms-primary.enc', envelope);
    try {
      await _writeEnvelope('aurelia-pms-recovery.enc', envelope);
    } catch (error) {
      debugPrint('Aurelia encrypted recovery snapshot update failed: $error');
    }
  }

  /// Retains a bounded history of encrypted snapshots inside app-private storage.
  /// These files are ciphertext using the same device-held key; they are not cloud backups.
  static Future<void> createLocalSnapshot() async {
    final primary = await _file('aurelia-pms-primary.enc');
    if (!await primary.exists()) throw StateError('There is no saved PMS database to back up yet.');
    final dir = Directory('${(await _directory()).path}/backups');
    await dir.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final destination = File('${dir.path}/aurelia-pms-$stamp.enc');
    await primary.copy(destination.path);
    final snapshots = await dir.list().where((entry) => entry is File && entry.path.endsWith('.enc')).cast<File>().toList();
    snapshots.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    for (final old in snapshots.skip(14)) {
      try { await old.delete(); } catch (_) {}
    }
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
    for (final key in const [
      'guests','rooms','bookings','reservations','inventory','expenses','payments',
      'audit','invoices','inventoryLedger','restaurantSales','paymentSignals',
    ]) {
      if (data.containsKey(key) && data[key] is! List) {
        throw FormatException('The "$key" section must be a list.');
      }
    }
    // Every record section must contain objects, not strings/numbers, and IDs
    // must be unique within that section when present.
    for (final entry in data.entries) {
      if (entry.value is! List) continue;
      final seenIds = <String>{};
      for (final record in entry.value as List) {
        if (record is! Map<String, dynamic>) {
          throw FormatException('The "${entry.key}" section contains a non-object record.');
        }
        if (record.containsKey('id') && record['id'] != null) {
          final id = record['id'];
          if (id is! String && id is! num) {
            throw FormatException('A record in "${entry.key}" has an invalid ID.');
          }
          final normalizedId = id.toString().trim();
          if (normalizedId.isEmpty || !seenIds.add(normalizedId)) {
            throw FormatException('The "${entry.key}" section contains an empty or duplicate ID.');
          }
        }
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
    if (passphrase.isEmpty || passphrase.length > 1024 ||
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

Future<Uint8List> _renderHtmlPdf(String source) async {
  final parsed = html_parser.parse(source);
  final title = (parsed.querySelector('title')?.text ?? 'Aurelia PMS document').trim();
  final widgets = <pw.Widget>[];
  void visit(dom.Node node) {
    if (node is dom.Element) {
      final tag = (node.localName ?? '').toLowerCase();
      if (const {'script','style','head','meta','link','noscript'}.contains(tag)) return;
      if (tag == 'table') {
        final rows = node.querySelectorAll('tr')
            .map((row) => row.children.map((cell) => cell.text.trim()).toList())
            .where((row) => row.isNotEmpty)
            .toList();
        if (rows.isNotEmpty) {
          final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
          final normalized = rows.map((r) => <String>[...r, ...List<String>.filled(width - r.length, '')]).toList();
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 10),
            child: pw.Table(
              border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
              children: normalized.asMap().entries.map((entry) => pw.TableRow(
                decoration: entry.key == 0 ? const pw.BoxDecoration(color: PdfColors.grey300) : null,
                children: entry.value.map((cell) => pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Text(
                    cell,
                    style: pw.TextStyle(
                      fontSize: 7,
                      fontWeight: entry.key == 0 ? pw.FontWeight.bold : pw.FontWeight.normal,
                    ),
                  ),
                )).toList(),
              )).toList(),
            ),
          ));
        }
        return;
      }
      if (tag == 'img') {
        widgets.add(pw.Text('[Image attachment omitted from generated PDF]', style: const pw.TextStyle(fontSize: 8)));
        return;
      }
      if (const {'h1','h2','h3','h4'}.contains(tag)) {
        final text = node.text.trim();
        if (text.isNotEmpty) widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(top: 8, bottom: 5),
          child: pw.Text(text, style: pw.TextStyle(fontSize: tag == 'h1' ? 18 : (tag == 'h2' ? 14 : 11), fontWeight: pw.FontWeight.bold)),
        ));
        return;
      }
      if (tag == 'p') {
        final text = node.text.trim();
        if (text.isNotEmpty) widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
        ));
        return;
      }
      for (final child in node.nodes) {
        visit(child);
      }
    } else if (node is dom.Text) {
      final text = node.text.trim();
      if (text.isNotEmpty && text.length <= 500) {
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
        ));
      }
    }
  }
  final body = parsed.body;
  if (body != null) visit(body);
  if (widgets.isEmpty) widgets.add(pw.Text(title, style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)));
  final document = pw.Document();
  document.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(32),
    header: (_) => pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 8),
      child: pw.Text(title, style: pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
    ),
    build: (_) => widgets,
  ));
  return document.save();
}

final GlobalKey<NavigatorState> aureliaNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AureliaPmsApp());
}

class AureliaPmsApp extends StatelessWidget {
  const AureliaPmsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: aureliaNavigatorKey,
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
  bool _unlocked = false;
  bool _pmsLoaded = false;

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
            final backupFile = params.acceptTypes.any((type) {
              final lower = type.toLowerCase();
              return lower.contains('json') || lower.contains('aurelia');
            });
            final picked = await FilePicker.platform.pickFiles(
              type: imageOnly ? FileType.image : FileType.any,
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
              withData: true,
            );
            if (picked == null) return <String>[];
            const blockedExtensions = <String>{
              'apk','exe','bat','cmd','sh','js','html','htm','jar','dex','so','dll','msi'
            };
            final maxBytes = backupFile ? 30 * 1024 * 1024 : 15 * 1024 * 1024;
            final selectedPaths = <String>[];
            final cache = await getTemporaryDirectory();
            for (final file in picked.files) {
              final extension = (file.extension ?? '').toLowerCase();
              if (file.size > maxBytes || blockedExtensions.contains(extension)) continue;
              // Some Android document providers expose bytes but no stable filesystem path.
              // Materialize a bounded cache copy so WebView can read the selected file.
              var path = file.path;
              final bytes = file.bytes;
              if (bytes != null) {
                final safeName = file.name.split(RegExp(r'[/\\\\]')).last
                    .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
                if (safeName.isEmpty || safeName == '.' || safeName == '..') continue;
                final target = File('${cache.path}/upload_${DateTime.now().microsecondsSinceEpoch}_$safeName');
                await target.writeAsBytes(bytes, flush: true);
                path = target.path;
              }
              if (path != null) selectedPaths.add(path);
            }
            return selectedPaths;
          } catch (error) {
            debugPrint('Aurelia PMS file selection failed: $error');
            return <String>[];
          }
        }),
      );
    }

  }

  Future<void> _unlockAndLoad() async {
    if (!mounted) return;
    setState(() => _unlocked = true);
    if (!_pmsLoaded) {
      await _loadLocalPms();
      if (mounted) setState(() => _pmsLoaded = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _unlocked && mounted) {
      setState(() => _unlocked = false);
    }
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
        // Re-bootstrap the local page from the encrypted store. A JavaScript reload
        // would bypass this secure bootstrap and revert to legacy localStorage.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await _loadLocalPms();
        if (mounted) setState(() { _pmsLoaded = true; _loading = false; });
        return;
      }
      if (value['type'] == 'recognizeIdImage') {
        final encoded = value['imageBase64'];
        if (requestId == null || encoded is! String || encoded.isEmpty || encoded.length > 12 * 1024 * 1024) {
          throw const FormatException('ID image is missing or exceeds the size limit.');
        }
        final raw = base64Decode(encoded);
        if (raw.isEmpty || raw.length > 8 * 1024 * 1024) throw const FormatException('ID image exceeds the 8 MiB limit.');
        final decoded = img.decodeImage(raw);
        if (decoded == null) throw const FormatException('Could not decode this ID image.');
        // Improve low-contrast scans before OCR. Keep dimensions bounded to avoid
        // excessive memory use on older phones; never overwrite the original image.
        final resized = decoded.width > 2400
            ? img.copyResize(decoded, width: 2400)
            : decoded;
        final gray = img.grayscale(resized);
        final enhanced = img.adjustColor(gray, contrast: 1.35, brightness: 0.04);
        final temp = await getTemporaryDirectory();
        final ocrFile = File('${temp.path}/aurelia_ocr_${DateTime.now().microsecondsSinceEpoch}.jpg');
        await ocrFile.writeAsBytes(img.encodeJpg(enhanced, quality: 94), flush: true);
        final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        try {
          final result = await recognizer.processImage(InputImage.fromFilePath(ocrFile.path));
          final text = result.text.trim();
          await _controller.runJavaScript('window.aureliaNativeOcrResult?.(${jsonEncode(requestId)},${jsonEncode(text)},null);');
        } finally {
          await recognizer.close();
          try { await ocrFile.delete(); } catch (_) {}
        }
        return;
      }
      if (value['type'] == 'setAppProtection') {
        final enabled = value['enabled'];
        if (enabled is! bool) throw const FormatException('Protection setting must be true or false.');
        await AureliaSecureVault.writeSecret('aurelia_pms_auth_enabled_v1', enabled ? 'true' : 'false');
        await _controller.runJavaScript('window.aureliaNativeProtectionResult?.(${jsonEncode(requestId)},true,null);');
        if (!enabled && mounted) setState(() => _unlocked = true);
        return;
      }
      if (value['type'] == 'createLocalBackup') {
        await AureliaEncryptedPmsStore.createLocalSnapshot();
        await _controller.runJavaScript('window.aureliaNativeLocalBackupResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      if (value['type'] == 'savePmsData') {
        final dataValue = value['data'];
        if (requestId == null || dataValue is! String || dataValue.length > 20 * 1024 * 1024) {
          throw const FormatException('Missing or oversized secure database fields');
        }
        await AureliaEncryptedPmsStore.write(dataValue);
        // If auto-backup is enabled in the saved PMS settings, keep a bounded
        // encrypted on-device snapshot after each committed database change.
        try {
          final decoded = jsonDecode(dataValue);
          final settings = decoded is Map ? decoded['settings'] : null;
          if (settings is Map && settings['autoBackupEnabled'] == true) {
            await AureliaEncryptedPmsStore.createLocalSnapshot();
          }
        } catch (error) {
          debugPrint('Automatic encrypted local snapshot failed: $error');
        }
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
      if (value['type'] == 'exportHtmlPdf') {
        final htmlValue = value['html'];
        final nameValue = value['name'];
        final actionValue = value['action'];
        if (requestId == null || htmlValue is! String || nameValue is! String ||
            (actionValue != 'open' && actionValue != 'save')) {
          throw const FormatException('Missing printable document fields');
        }
        if (htmlValue.isEmpty || htmlValue.length > 2 * 1024 * 1024) {
          throw const FormatException('Printable document exceeds the 2 MiB HTML limit');
        }
        final pdfBytes = await _renderHtmlPdf(htmlValue);
        if (pdfBytes.isEmpty || pdfBytes.length > 15 * 1024 * 1024) {
          throw const FormatException('Generated PDF exceeds the 15 MiB limit');
        }
        var pdfName = nameValue.split(RegExp(r'[/\\\\]')).last
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (pdfName.isEmpty || pdfName == '.' || pdfName == '..' || pdfName.startsWith('.')) {
          pdfName = 'aurelia-document.pdf';
        }
        if (!pdfName.toLowerCase().endsWith('.pdf')) pdfName = '$pdfName.pdf';
        if (actionValue == 'save') {
          final savedPath = await FilePicker.platform.saveFile(
            dialogTitle: 'Save PDF export',
            fileName: pdfName,
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
            bytes: pdfBytes,
          );
          if (savedPath == null) throw const FormatException('PDF save cancelled');
        } else {
          final temp = await getTemporaryDirectory();
          final file = File('${temp.path}/$pdfName');
          await file.writeAsBytes(pdfBytes, flush: true);
          final navigator = aureliaNavigatorKey.currentState;
          if (navigator == null) throw StateError('The in-app PDF viewer is not available.');
          // Resolve the WebView request as soon as the viewer is launched;
          // do not keep the JavaScript bridge waiting until the user closes the PDF.
          unawaited(navigator.push(MaterialPageRoute<void>(
            builder: (_) => ProductionPdfViewerRoute(filePath: file.path, documentTitle: pdfName),
          )));
        }
        await _controller.runJavaScript('window.aureliaNativeFileResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      if (value['type'] == 'shareFile' || value['type'] == 'saveFile' || value['type'] == 'openFile') {
        final nameValue = value['name'], mimeValue = value['mime'], dataValue = value['data'];
        if (requestId == null || nameValue is! String || mimeValue is! String || dataValue is! String) {
          throw const FormatException('Missing file fields');
        }
        // Bound encoded data before base64Decode allocates the decoded buffer.
        const maxBytes = 15 * 1024 * 1024;
        const maxBase64Chars = (maxBytes * 4 + 2) ~/ 3;
        if (dataValue.isEmpty || dataValue.length > maxBase64Chars) {
          throw const FormatException('File exceeds the 15 MiB export limit');
        }
        final safeName = nameValue.split(RegExp(r'[/\\\\]')).last
            .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        if (safeName.isEmpty || safeName == '.' || safeName == '..' ||
            safeName.length > 120 || safeName.startsWith('.')) {
          throw const FormatException('Invalid file name');
        }
        final bytes = base64Decode(dataValue);
        if (bytes.isEmpty || bytes.length > maxBytes) throw const FormatException('File size is invalid');
        final ext = safeName.contains('.') ? safeName.split('.').last.toLowerCase() : '';
        const mimeByExtension = <String, String>{
          'pdf':'application/pdf','png':'image/png','jpg':'image/jpeg','jpeg':'image/jpeg',
          'webp':'image/webp','gif':'image/gif','bmp':'image/bmp','csv':'text/csv',
          'json':'application/json','txt':'text/plain','xml':'application/xml',
          'html':'text/html','htm':'text/html','xls':'application/vnd.ms-excel',
          'xlsx':'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          'doc':'application/msword','docx':'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
          'ppt':'application/vnd.ms-powerpoint','pptx':'application/vnd.openxmlformats-officedocument.presentationml.presentation',
          'zip':'application/zip','rtf':'application/rtf',
        };
        final mime = mimeByExtension[ext] ?? (mimeValue == 'application/octet-stream' ? mimeValue : mimeValue);
        final temp = await getTemporaryDirectory();
        final file = File('${temp.path}/$safeName');
        await file.writeAsBytes(bytes, flush: true);
        if (value['type'] == 'saveFile') {
          final savedPath = await FilePicker.platform.saveFile(
            dialogTitle: 'Save Aurelia export',
            fileName: safeName,
            type: FileType.any,
            bytes: bytes,
          );
          if (savedPath == null) throw const FormatException('Save cancelled');
        } else if (value['type'] == 'openFile') {
          if (mime == 'image/jpeg' || mime == 'image/png' || mime == 'image/webp' ||
              mime == 'image/gif' || mime == 'image/bmp') {
            final navigator = aureliaNavigatorKey.currentState;
            if (navigator == null) throw StateError('The in-app image viewer is not available.');
            unawaited(navigator.push(MaterialPageRoute<void>(
              builder: (_) => AdvancedImageViewerRoute(filePath: file.path, documentTitle: safeName),
            )));
          } else {
            final result = await OpenFilex.open(file.path, type: mime);
            if (result.type != ResultType.done) {
              throw StateError('No compatible external app could open this file: ${result.message}');
            }
          }
        } else {
          await Share.shareXFiles([XFile(file.path, mimeType: mime, name: safeName)], subject: safeName);
        }
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
      final saved = await AureliaEncryptedPmsStore.read();
      final html = await rootBundle.loadString('assets/index.html');
      final headEnd = html.toLowerCase().indexOf('</head>');
      if (headEnd < 0) throw const FormatException('Bundled PMS HTML has no head element.');
      final bootstrapData = saved == null
          ? 'null'
          : jsonEncode(jsonDecode(saved))
              .replaceAll('<', r'\u003c')
              .replaceAll('>', r'\u003e')
              .replaceAll('&', r'\u0026')
              .replaceAll('\u2028', r'\u2028')
              .replaceAll('\u2029', r'\u2029');
      final bootstrap = '<script id="aurelia-secure-db-bootstrap">'
          'window.__AURELIA_SECURE_DB_READY=true;'
          'window.__AURELIA_SECURE_DB_EXISTS=${saved != null};'
          'window.__AURELIA_SECURE_DB_BOOTSTRAP=$bootstrapData;'
          '</script>';
      final page = html.substring(0, headEnd) + bootstrap + html.substring(headEnd);
      await _controller.loadHtmlString(
        page,
        baseUrl: 'file:///android_asset/flutter_assets/assets/index.html',
      );
    } catch (error) {
      debugPrint('Could not safely open Aurelia PMS data: $error');
      if (mounted) setState(() => _loading = false);
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
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
                Positioned.fill(
                  child: PmsAccessGate(
                    readSecret: AureliaSecureVault.readSecret,
                    writeSecret: AureliaSecureVault.writeSecret,
                    deleteSecret: AureliaSecureVault.deleteSecret,
                    onUnlocked: _unlockAndLoad,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
