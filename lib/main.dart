import 'dart:async';
import 'image_viewer_engine.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'pms_access_gate.dart';
import 'pdf_viewer_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr/qr.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:local_auth/local_auth.dart';
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
    // One stable filename only: each successful save overwrites the previous
    // local snapshot instead of accumulating timestamped backup files.
    final destination = File('${dir.path}/aurelia-pms-latest.enc');
    final temporary = File('${dir.path}/aurelia-pms-latest.enc.tmp');
    await primary.copy(temporary.path);
    if (await destination.exists()) await destination.delete();
    await temporary.rename(destination.path);
    // Clean up legacy timestamped snapshots from older builds.
    await for (final entry in dir.list()) {
      if (entry is File && entry.path.endsWith('.enc') &&
          entry.path != destination.path) {
        try { await entry.delete(); } catch (_) {}
      }
    }
  }

  static Future<Uint8List> latestEncryptedSnapshotBytes() async {
    final file = await _file('aurelia-pms-primary.enc');
    if (!await file.exists()) {
      throw StateError('There is no saved PMS database to back up yet.');
    }
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty || bytes.length > 30 * 1024 * 1024) {
      throw StateError('Encrypted PMS backup is empty or exceeds 30 MB.');
    }
    return Uint8List.fromList(bytes);
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
        if (text.isNotEmpty) {
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(top: 8, bottom: 5),
            child: pw.Text(text, style: pw.TextStyle(fontSize: tag == 'h1' ? 18 : (tag == 'h2' ? 14 : 11), fontWeight: pw.FontWeight.bold)),
          ));
        }
        return;
      }
      if (tag == 'p') {
        final text = node.text.trim();
        if (text.isNotEmpty) {
          widgets.add(pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.Text(text, style: const pw.TextStyle(fontSize: 9)),
          ));
        }
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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF38251D), secondary: const Color(0xFFD8B45C)),
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
    _controller = WebViewController();
    if (kDebugMode && _controller.platform is AndroidWebViewController) {
      AndroidWebViewController.enableDebugging(true);
    }
    _controller
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
            unawaited(_installAureliaAssistant());
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
            // WebView's capture attribute must open a camera that writes to
            // app cache, not a public DCIM/Pictures destination. This avoids
            // leaving duplicate guest-ID photos in the user's gallery.
            if (imageOnly && params.isCaptureEnabled) {
              final capture = await ImagePicker().pickImage(
                source: ImageSource.camera,
                imageQuality: 92,
                maxWidth: 2200,
                maxHeight: 3000,
              );
              if (capture == null) return <String>[];
              final captured = File(capture.path);
              if (!await captured.exists() || await captured.length() == 0) {
                return <String>[];
              }
              return <String>[captured.path];
            }
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
      final loaded = await _loadLocalPms();
      if (mounted) setState(() => _pmsLoaded = loaded);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && _unlocked && mounted) {
      setState(() => _unlocked = false);
    }
  }

  Future<void> _installAureliaAssistant() async {
    const script = r"""
(function(){
 if(window.__aureliaAssistantInstalled)return;window.__aureliaAssistantInstalled=true;
 const s=document.createElement('style');s.textContent='#aurelia-ai-launch{position:fixed;z-index:2147483000;right:18px;bottom:22px;border:1px solid #d7bd80;border-radius:999px;padding:13px 17px;background:linear-gradient(135deg,#153d35,#245f53);color:#fff8e8;font:600 14px system-ui;box-shadow:0 10px 30px #102a3150;cursor:pointer}#aurelia-ai-panel{position:fixed;z-index:2147483000;right:14px;bottom:82px;width:min(370px,calc(100vw - 28px));height:min(520px,calc(100vh - 120px));display:none;flex-direction:column;overflow:hidden;border:1px solid #c7a86a;border-radius:20px;background:#fffdf8;color:#1c302b;box-shadow:0 22px 65px #102a3150;font:14px system-ui}#aurelia-ai-head{padding:16px;background:linear-gradient(135deg,#153d35,#102a31);color:#fff8e8;display:flex;justify-content:space-between;align-items:center}#aurelia-ai-head small{display:block;color:#d9d0b8;margin-top:4px;font-weight:400}#aurelia-ai-log{flex:1;overflow:auto;padding:13px;display:flex;flex-direction:column;gap:10px}.aurelia-ai-msg{max-width:92%;padding:10px 12px;border-radius:13px;white-space:pre-wrap;line-height:1.45;overflow-wrap:anywhere}.aurelia-ai-msg.bot{align-self:flex-start;background:#edf1e8;border:1px solid #dce5d7}.aurelia-ai-msg.user{align-self:flex-end;background:#173f36;color:#fff8e8}#aurelia-ai-form{display:flex;gap:8px;padding:11px;border-top:1px solid #e3d8c3}#aurelia-ai-input{flex:1;min-width:0;border:1px solid #d9cdb6;border-radius:10px;padding:10px;background:#fff;color:#172e28;font:14px system-ui}#aurelia-ai-send{border:0;border-radius:10px;background:#153d35;color:white;padding:0 14px;font-weight:600}#aurelia-ai-note{padding:0 13px 10px;color:#7a8076;font-size:11px}';document.head.appendChild(s);
 const b=document.createElement('button');b.id='aurelia-ai-launch';b.type='button';b.textContent='✦ Aurelia Assist';
 const p=document.createElement('section');p.id='aurelia-ai-panel';p.setAttribute('aria-label','Aurelia Assist');
 p.innerHTML='<div id="aurelia-ai-head"><div><strong>Aurelia Assist</strong><small>Offline help · no cloud AI connected</small></div><button id="aurelia-ai-close" aria-label="Close assistant" style="background:transparent;border:0;color:#fff;font-size:22px">×</button></div><div id="aurelia-ai-log" aria-live="polite"></div><div id="aurelia-ai-note">Advice only. Verify amounts and confirm billing actions yourself.</div><form id="aurelia-ai-form"><input id="aurelia-ai-input" autocomplete="off" placeholder="Ask about hotel, POS, reports…" maxlength="500" aria-label="Ask Aurelia Assist"><button id="aurelia-ai-send" type="submit">Ask</button></form>';
 document.body.appendChild(b);document.body.appendChild(p);const log=p.querySelector('#aurelia-ai-log'),input=p.querySelector('#aurelia-ai-input');
 function msg(t,w){const e=document.createElement('div');e.className='aurelia-ai-msg '+w;e.textContent=t;log.appendChild(e);log.scrollTop=log.scrollHeight;return e;}
 msg('Hello. I can guide you through hotel room and guest management, restaurant POS, food-only room billing, reports, and local backup. I work offline using built-in guidance; this is not a generative cloud AI model.','bot');
 b.addEventListener('click',()=>{p.style.display=p.style.display==='flex'?'none':'flex';if(p.style.display==='flex')input.focus()});p.querySelector('#aurelia-ai-close').addEventListener('click',()=>p.style.display='none');
 p.querySelector('#aurelia-ai-form').addEventListener('submit',e=>{e.preventDefault();const q=input.value.trim();if(!q)return;input.value='';msg(q,'user');const id='ai_'+Date.now().toString(36)+'_'+Math.random().toString(36).slice(2,8);const pending=msg('Checking local guidance…','bot');pending.dataset.request=id;try{if(!window.AureliaNative||typeof window.AureliaNative.postMessage!=='function')throw Error('Unavailable');window.AureliaNative.postMessage(JSON.stringify({type:'aureliaAiQuery',requestId:id,question:q,config:window.__AURELIA_AI_CONFIG||{}}));}catch(_){pending.textContent='Assistant unavailable in this view. You can continue using the PMS normally.';}});
 window.aureliaAiResult=function(id,answer,error){const safe=String(id).replace(/[^A-Za-z0-9_-]/g,'');const el=log.querySelector('[data-request="'+safe+'"]');if(el)el.textContent=error||answer||'No guidance available.';};
})();
""";
    try { await _controller.runJavaScript(script); }
    catch (error) { debugPrint('Aurelia Assist UI could not be installed: $error'); }
  }

  String _answerAureliaAssistant(String question) {
    final q = question.toLowerCase();
    if (q.contains('drive') || q.contains('cloud') || q.contains('sync') || q.contains('backup') || q.contains('restore')) {
      return 'BACKUP GUIDANCE\\nThe encrypted local PMS store is the source of truth. Use Settings > Backup & Restore to create a local encrypted snapshot or export a protected archive. Cloud sync must remain “Not Configured / Local-Only Mode” until OAuth, encrypted upload, remote verification, and restore tests are implemented. A folder ID alone does not prove Drive sync is active.';
    }
    if (q.contains('room bill') || q.contains('food only') || q.contains('guest food') || q.contains('restaurant bill to room')) {
      return 'ROOM BILLING GUIDANCE\\nSelect an existing hotel guest/room, add food items from the restaurant menu, verify quantities and the food total, then post to the guest room bill. Only food items should be posted through this flow; do not merge restaurant table bills, inventory, or non-food charges. Verify the final amount before confirming.';
    }
    if (q.contains('restaurant') || q.contains('pos') || q.contains('kot') || q.contains('order')) {
      return 'RESTAURANT POS GUIDANCE\\nUse Restaurant (POS) for menu items, table/takeaway/delivery orders, kitchen tickets, restaurant payments, and inventory. Keep restaurant sales and bills in the restaurant entity. Use Room Billing (Guest Food) only when food is charged to an existing hotel guest.';
    }
    if (q.contains('check in') || q.contains('check-in') || q.contains('guest') || q.contains('room') || q.contains('checkout') || q.contains('check out')) {
      return 'HOTEL PMS GUIDANCE\\nUse Hotel (Rooms & Guests) to maintain room status and guest records, then use the dedicated check-in/check-out actions. Confirm room availability, dates, guest identity details, and rates before saving. Guest ID OCR is assistive only: compare extracted fields with the document before storing or using them.';
    }
    if (q.contains('report') || q.contains('revenue') || q.contains('occupancy') || q.contains('sales')) {
      return 'REPORTING GUIDANCE\\nOpen Reports & Export and choose the report period and entity. Check hotel occupancy/room revenue separately from restaurant sales; guest-room food charges should not be counted twice as independent restaurant revenue. Reconcile totals against bills and payments before accounting use.';
    }
    if (q.contains('security') || q.contains('privacy') || q.contains('id photo') || q.contains('identity') || q.contains('ocr')) {
      return 'SECURITY GUIDANCE\\nTreat guest identity images and extracted ID fields as sensitive. Restrict access, verify OCR manually, avoid sharing guest data, and keep a tested encrypted backup. This assistant does not transmit questions or PMS records to a cloud AI service.';
    }
    if (q.contains('inventory') || q.contains('stock') || q.contains('menu')) {
      return 'MENU & INVENTORY GUIDANCE\\nMaintain food menu items and stock inside Restaurant (POS) / Inventory. Check item price, availability, and stock before accepting orders. Keep hotel room charges and restaurant inventory as separate records.';
    }
    return 'AURELIA ASSIST (OFFLINE)\\nI can provide built-in operational guidance for Hotel PMS, Restaurant POS, food-only room billing, reports, guest ID/OCR safety, and encrypted local backup. Try “How do I bill food to a room?”, “How should I back up data?”, or “How do I separate restaurant sales from hotel revenue?”.\\n\\nThis is an offline rules-based assistant, not a connected generative AI model. It will not change bills or records on your behalf.';
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
      if (value['type'] == 'aureliaAiQuery') {
        final question = value['question'];
        if (requestId == null || question is! String || question.trim().isEmpty || question.length > 500) {
          throw const FormatException('Ask a question of 1–500 characters.');
        }
        final answer = _answerAureliaAssistant(question.trim());
        await _controller.runJavaScript(
          'window.aureliaAiResult?.(${jsonEncode(requestId)},${jsonEncode(answer)},null);',
        );
        return;
      }
      if (value['type'] == 'saveAiGatewayConfig') {
        final endpointValue = value['endpoint'];
        final tokenValue = value['token'];
        if (requestId == null || endpointValue is! String || tokenValue is! String ||
            endpointValue.length > 2048 || tokenValue.length > 4096) {
          throw const FormatException('Invalid AI gateway configuration.');
        }
        final endpoint = endpointValue.trim();
        if (endpoint.isNotEmpty) {
          final uri = Uri.tryParse(endpoint);
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
              uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
            throw const FormatException('AI gateway must be a valid HTTPS URL without embedded credentials or fragments.');
          }
        }
        if (tokenValue.trim().isEmpty || endpoint.isEmpty) {
          await AureliaSecureVault.deleteSecret('aurelia_ai_gateway_token_v1');
        } else {
          await AureliaSecureVault.writeSecret('aurelia_ai_gateway_token_v1', tokenValue.trim());
        }
        await _controller.runJavaScript(
          'window.aureliaAiGatewaySaveResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'aureliaAiQuery') {
        final question = value['question'];
        final configValue = value['config'];
        if (requestId == null || question is! String || question.trim().isEmpty || question.length > 500) {
          throw const FormatException('Ask a question of 1–500 characters.');
        }
        final config = configValue is Map ? configValue : const <String, dynamic>{};
        final internetEnabled = config['internetEnabled'] != false;
        final aiEnabled = config['aiEnabled'] != false;
        final endpointValue = config['aiGatewayUrl'];
        String answer;
        if (!aiEnabled) {
          answer = 'AI automation is disabled in Settings. Enable it to use Aurelia Assist.';
        } else if (!internetEnabled || endpointValue is! String || endpointValue.trim().isEmpty) {
          answer = _answerAureliaAssistant(question.trim());
          if (!internetEnabled) {
            answer += '\n\nInternet access for online features is disabled. No external request was made.';
          } else {
            answer += '\n\nOnline AI is not configured. Add your own authenticated HTTPS gateway in Settings to enable model-based responses.';
          }
        } else {
          final uri = Uri.tryParse(endpointValue.trim());
          if (uri == null || uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
            answer = '${_answerAureliaAssistant(question.trim())}\n\nThe AI gateway URL is invalid or not HTTPS. No external request was made.';
          } else {
            HttpClient? client;
            try {
              client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
              final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
              request.headers.contentType = ContentType.json;
              request.headers.set(HttpHeaders.acceptHeader, 'application/json');
              final token = await AureliaSecureVault.readSecret('aurelia_ai_gateway_token_v1');
              if (token != null && token.isNotEmpty) request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
              // Privacy by design: send only the user's explicit question, never guest records or billing data.
              request.write(jsonEncode({
                'question': question.trim(),
                'message': question.trim(),
                'app': 'Aurelia PMS',
                'mode': 'hotel_restaurant_operations',
              }));
              final response = await request.close().timeout(const Duration(seconds: 15));
              final body = await response.transform(utf8.decoder).join().timeout(const Duration(seconds: 10));
              if (body.length > 256 * 1024) throw const FormatException('AI response exceeded the size limit.');
              if (response.statusCode < 200 || response.statusCode >= 300) {
                throw HttpException('AI gateway returned HTTP ${response.statusCode}.');
              }
              final decoded = jsonDecode(body);
              String? remoteAnswer;
              if (decoded is Map<String, dynamic>) {
                final direct = decoded['answer'] ?? decoded['response'] ?? decoded['output_text'];
                if (direct is String) remoteAnswer = direct;
                if (remoteAnswer == null && decoded['choices'] is List && (decoded['choices'] as List).isNotEmpty) {
                  final first = (decoded['choices'] as List).first;
                  if (first is Map && first['message'] is Map && (first['message'] as Map)['content'] is String) {
                    remoteAnswer = (first['message'] as Map)['content'] as String;
                  } else if (first is Map && first['text'] is String) {
                    remoteAnswer = first['text'] as String;
                  }
                }
              }
              if (remoteAnswer == null || remoteAnswer.trim().isEmpty) {
                throw const FormatException('AI gateway response did not contain an answer field.');
              }
              answer = 'Online AI guidance — verify before applying:\n\n${remoteAnswer.trim()}';
            } catch (error) {
              debugPrint('Aurelia online AI request failed: $error');
              answer = '${_answerAureliaAssistant(question.trim())}' +
                  '\n\nOnline AI is unavailable right now. Showing offline guidance instead; no PMS data was uploaded.';
            } finally {
              client?.close(force: true);
            }
          }
        }
        await _controller.runJavaScript(
          'window.aureliaAiResult?.(${jsonEncode(requestId)},${jsonEncode(answer)},null);',
        );
        return;
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
        final savedPath = await FilePicker.platform.saveFile(
          dialogTitle: 'Save local encrypted Aurelia PMS archive',
          fileName: 'aurelia-pms-encrypted-backup.aurelia',
          type: FileType.custom,
          allowedExtensions: const ['aurelia'],
          bytes: Uint8List.fromList(utf8.encode(envelope)),
        );
        if (savedPath == null || savedPath.isEmpty) {
          await _controller.runJavaScript(
            'window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},false,${jsonEncode('Backup save cancelled.')});',
          );
          return;
        }
        try { await file.delete(); } catch (_) {}
        await _controller.runJavaScript(
          'window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},true,null);',
        );
        return;
      }
      if (value['type'] == 'reloadSecurePms') {
        if (requestId == null) throw const FormatException('Missing secure reload request id');
        // Reload from the encrypted native store, never via WebView location.reload().
        final loaded = await _loadLocalPms();
        if (mounted) setState(() { _pmsLoaded = loaded; _loading = false; });
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
        // Re-bootstrap the local page from the encrypted store before reporting
        // success. A JavaScript reload would bypass secure bootstrap.
        await Future<void>.delayed(const Duration(milliseconds: 120));
        final loaded = await _loadLocalPms();
        if (!loaded) {
          throw StateError('Backup data was encrypted and saved, but the PMS could not reopen it. Keep the app installed and recover access before trying again.');
        }
        if (mounted) setState(() { _pmsLoaded = true; _loading = false; });
        await _controller.runJavaScript(
          'window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},true,null);',
        );
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
        // Run several bounded preprocessing passes: original colour, grayscale,
        // and stronger contrast. OCR cannot guarantee exact recovery from a blurry
        // or unreadable image, so return the strongest result for the user to verify.
        final targetWidth = decoded.width < 1200 ? 1200 : (decoded.width > 2400 ? 2400 : decoded.width);
        final resized = decoded.width == targetWidth ? decoded : img.copyResize(decoded, width: targetWidth);
        final gray = img.grayscale(resized);
        final variants = <img.Image>[
          resized,
          gray,
          img.adjustColor(gray, contrast: 1.45, brightness: 0.03),
          img.adjustColor(gray, contrast: 1.9, brightness: -0.03),
        ];
        final temp = await getTemporaryDirectory();
        final tempFiles = <File>[];
        final recognizers = <TextRecognizer>[
          TextRecognizer(script: TextRecognitionScript.latin),
          TextRecognizer(script: TextRecognitionScript.devanagiri),
        ];
        var bestText = '';
        var bestScore = -1;
        try {
          for (var variantIndex = 0; variantIndex < variants.length; variantIndex++) {
            final ocrFile = File('${temp.path}/aurelia_ocr_${DateTime.now().microsecondsSinceEpoch}_$variantIndex.jpg');
            tempFiles.add(ocrFile);
            await ocrFile.writeAsBytes(img.encodeJpg(variants[variantIndex], quality: 96), flush: true);
            final inputImage = InputImage.fromFilePath(ocrFile.path);
            final recognized = <({double top, double left, String text})>[];
            for (final recognizer in recognizers) {
              final result = await recognizer.processImage(inputImage);
              for (final block in result.blocks) {
                for (final line in block.lines) {
                  final lineText = line.text.trim();
                  if (lineText.isEmpty) continue;
                  recognized.add((top: line.boundingBox.top.toDouble(),
                    left: line.boundingBox.left.toDouble(), text: lineText));
                }
              }
            }
            recognized.sort((a, b) {
              final vertical = a.top.compareTo(b.top);
              return vertical != 0 ? vertical : a.left.compareTo(b.left);
            });
            final lines = <String>[];
            final seen = <String>{};
            for (final line in recognized) {
              final key = line.text.toUpperCase().replaceAll(RegExp(r'\s+'), '');
              if (key.isNotEmpty && seen.add(key)) lines.add(line.text);
            }
            final candidate = lines.join('\n').trim();
            final alphanumericCount = RegExp(r'[A-Za-z0-9]').allMatches(candidate).length;
            final score = lines.length * 20 + alphanumericCount;
            if (score > bestScore) {
              bestScore = score;
              bestText = candidate;
            }
          }
          await _controller.runJavaScript('window.aureliaNativeOcrResult?.(${jsonEncode(requestId)},${jsonEncode(bestText)},null);');
        } finally {
          for (final recognizer in recognizers) {
            await recognizer.close();
          }
          for (final ocrFile in tempFiles) {
            try { await ocrFile.delete(); } catch (_) {}
          }
        }
        return;
      }
      if (value['type'] == 'getAuthPreferences') {
        if (requestId == null) throw const FormatException('Missing authentication preference request id');
        final pin = await AureliaSecureVault.readSecret('aurelia_pms_pin_entry_enabled_v1') == 'true';
        final biometric = await AureliaSecureVault.readSecret('aurelia_pms_biometric_enabled_v1') == 'true';
        await _controller.runJavaScript(
          'window.aureliaNativeAuthPreferencesResult?.(${jsonEncode(requestId)},$pin,$biometric,null);',
        );
        return;
      }
      if (value['type'] == 'setBiometricEnabled') {
        final enabled = value['enabled'];
        if (requestId == null || enabled is! bool) throw const FormatException('Biometric preference must be true or false.');
        final deviceSupported = await LocalAuthentication().isDeviceSupported();
        if (enabled && !deviceSupported) {
          throw const FormatException('This device does not support Android device authentication.');
        }
        await AureliaSecureVault.writeSecret('aurelia_pms_biometric_enabled_v1', enabled ? 'true' : 'false');
        // PIN and biometric preferences are independent user choices. Disabling
        // biometrics must not silently turn PIN entry on or alter its setting.
        await _controller.runJavaScript('window.aureliaNativeBiometricSettingResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      if (value['type'] == 'setPinEntryEnabled') {
        final enabled = value['enabled'];
        if (requestId == null || enabled is! bool) throw const FormatException('PIN entry preference must be true or false.');
        // PIN entry is independently optional. The access gate bypasses
        // authentication only when both preferences are disabled.
        await AureliaSecureVault.writeSecret('aurelia_pms_pin_entry_enabled_v1', enabled ? 'true' : 'false');
        await _controller.runJavaScript('window.aureliaNativePinEntrySettingResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      if (value['type'] == 'setAppProtection') {
        final enabled = value['enabled'];
        if (enabled is! bool) throw const FormatException('Protection setting must be true or false.');
        if (!enabled) {
          // App protection itself stays fail-closed in secure builds. The
          // PIN and biometric methods remain independent optional preferences.
          await AureliaSecureVault.writeSecret('aurelia_pms_auth_enabled_v1', 'true');
          await _controller.runJavaScript('window.aureliaNativeProtectionResult?.(${jsonEncode(requestId)},false,${jsonEncode('App protection cannot be disabled in this secure build.')});');
          return;
        }
        await AureliaSecureVault.writeSecret('aurelia_pms_auth_enabled_v1', 'true');
        await _controller.runJavaScript('window.aureliaNativeProtectionResult?.(${jsonEncode(requestId)},true,null);');
        return;
      }
      if (value['type'] == 'chooseDeviceBackupFolder') {
        if (requestId == null) throw const FormatException('Missing backup-folder request id');
        const channel = MethodChannel('aurelia/backup_folder');
        final folder = await channel.invokeMethod<String>('chooseFolder');
        await _controller.runJavaScript(
          'window.aureliaNativeBackupFolderResult?.(${jsonEncode(requestId)},${folder != null},${jsonEncode(folder == null ? 'Folder selection cancelled.' : 'Device backup folder selected.')});',
        );
        return;
      }
      if (value['type'] == 'backupDeviceNow') {
        if (requestId == null) throw const FormatException('Missing device-backup request id');
        await AureliaEncryptedPmsStore.createLocalSnapshot();
        final bytes = await AureliaEncryptedPmsStore.latestEncryptedSnapshotBytes();
        const channel = MethodChannel('aurelia/backup_folder');
        final written = await channel.invokeMethod<bool>('writeBackup', {
          'name': 'aurelia-pms-latest.enc',
          'bytes': bytes,
        });
        if (written != true) {
          throw StateError('Choose a device backup folder first. The app-private encrypted backup remains saved.');
        }
        await _controller.runJavaScript(
          'window.aureliaNativeDeviceBackupResult?.(${jsonEncode(requestId)},true,null);',
        );
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
        // Back up only after a successful database save. The encrypted primary,
        // recovery copy, and one stable latest snapshot are overwritten in place;
        // no timestamped duplicate files are created.
        try {
          await AureliaEncryptedPmsStore.createLocalSnapshot();
          // If the user selected a document-tree folder, overwrite the same
          // encrypted archive after each successful changed-data save.
          final bytes = await AureliaEncryptedPmsStore.latestEncryptedSnapshotBytes();
          final written = await const MethodChannel('aurelia/backup_folder').invokeMethod<bool>(
            'writeBackup',
            {'name': 'aurelia-pms-latest.enc', 'bytes': bytes},
          );
          if (written == true) debugPrint('Updated the selected device backup folder.');
        } catch (error) {
          debugPrint('Automatic encrypted local snapshot / folder backup failed: $error');
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
        final mime = mimeByExtension[ext] ?? 'application/octet-stream';
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
          await _controller.runJavaScript('window.aureliaNativeQrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeOcrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeFileResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativePmsSaveResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupExportResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupRestoreResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativePinEntrySettingResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBiometricSettingResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeBackupFolderResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaNativeDeviceBackupResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaAiGatewaySaveResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});window.aureliaAiResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});');
        } catch (_) {}
      }
    }
  }

  Future<bool> _loadLocalPms() async {
    try {
      final saved = await AureliaEncryptedPmsStore.read();
      final html = await rootBundle.loadString('assets/index.html');
      // Apply the Aurelia Royal Coast design layer at runtime so the base HTML's
      // business logic remains untouched and preview/browser behavior stays stable.
      const royalCoastTheme = r"""<style id="aurelia-royal-coast-theme">
:root{--brand:#153d35;--brand2:#245f53;--ink:#1c302b;--muted:#75847b;--bg:#f4f0e7;--card:#fffdf8;--line:#e3d8c3;--soft:#e8eee6;--danger:#a8443d;--warn:#a67b35;--ok:#2e7152;--gold:#c7a86a;--gold-light:#e9d8a8;--shadow:0 16px 42px rgba(21,61,53,.09);--radius:20px}
html,body{background:radial-gradient(ellipse at 95% 0%,rgba(199,168,106,.12),transparent 35%),var(--bg)!important;color:var(--ink)!important}
h1,h2,h3,.serif,.brand strong{font-family:"Iowan Old Style","Palatino Linotype",Georgia,serif!important;font-style:normal!important;letter-spacing:-.025em}
.sidebar{background:linear-gradient(165deg,#173f36 0%,#102a31 72%,#0c2228 100%)!important;color:#f9f2e3!important;border-right:1px solid #b99a60!important;box-shadow:10px 0 35px rgba(8,33,30,.12)}
.sidebar .brand{border-bottom:1px solid rgba(201,177,123,.28);margin-bottom:18px}.sidebar .brand strong{color:#f7edda!important;font-size:23px;letter-spacing:.025em}.sidebar .brand .muted{color:#c6d1c5!important}
.sidebar .logo{border-radius:50%;border:1px solid var(--gold)!important;background:#203e32;box-shadow:0 4px 18px #0002}
.nav button{color:#e5e9df!important;border-radius:12px;transition:background .18s,color .18s,transform .18s}.nav button:hover{background:rgba(226,213,176,.12)!important;color:#fff!important;transform:translateX(2px)}.nav button.active{background:linear-gradient(120deg,#b99a60,#ead9ab)!important;color:#18352d!important;box-shadow:0 6px 18px #0002}
.main{background:radial-gradient(ellipse at top right,rgba(196,171,116,.09),transparent 35%),var(--bg)!important}.top{background:rgba(250,247,239,.94)!important;border-bottom:1px solid #ded4bf!important;backdrop-filter:blur(18px)}
.search input{background:#fffdf8!important;border-color:#ded4bf!important}.search input:focus{border-color:var(--gold)!important;box-shadow:0 0 0 3px #b99a601c}.iconbtn{background:#fffdf8!important;border-color:#ded4bf!important;color:#234536!important}
.hero h1{font-size:clamp(31px,3vw,43px);font-weight:600;color:#183f35}.hero h1:after{content:"";display:block;width:58px;height:2px;background:linear-gradient(90deg,var(--gold),transparent);margin-top:12px}.hero p{line-height:1.65}
.card,.item{background:rgba(255,253,248,.97)!important;border-color:#e3d8c3!important;box-shadow:var(--shadow)!important;border-radius:20px}.card{padding:22px}.item{transition:transform .18s,box-shadow .18s,border-color .18s}.item:hover{transform:translateY(-1px);box-shadow:0 15px 34px rgba(39,56,43,.10)!important;border-color:#d1bf98!important}
.kpi .value{color:#204b3a;font-variant-numeric:tabular-nums}.kpi .label{letter-spacing:.13em}.btn{border-color:#ded4bf!important;background:#fffdf8!important;color:#294738!important;border-radius:12px;transition:transform .16s,box-shadow .16s}.btn:hover{transform:translateY(-1px);box-shadow:0 5px 14px #203b2c12}
.btn.primary{background:linear-gradient(135deg,#153d35,#286451)!important;color:#fffaf0!important;border:1px solid var(--gold)!important;box-shadow:0 8px 18px rgba(23,72,59,.18)}.btn.primary:hover{background:linear-gradient(135deg,#102f29,#1e5546)!important}.btn.danger{color:#a8443d!important}
.available{background:#e7f1e8!important;color:#2b6a49!important}.occupied{background:#e1ece6!important;color:#285744!important}.reserved{background:#f3ead8!important;color:#8b692d!important}.cleaning{background:#f8eedb!important;color:#936719!important}.maintenance{background:#f7e5e2!important;color:#a8443d!important}
.table-wrap{border-color:#e3d8c3!important;border-radius:16px}.table th{background:#eee7d7!important;color:#6d705f!important}.table td{background:#fffdf8!important}.table tr:hover td{background:#faf6eb!important}
.modal{background:#fffdf8!important;border-color:#c7b17f!important;box-shadow:0 35px 100px rgba(16,36,27,.32)!important;border-radius:22px}.modal-back{background:rgba(13,34,26,.64)!important;backdrop-filter:blur(5px)}
.field label{color:#69776b!important;letter-spacing:.02em}.field input,.field select,.field textarea{background:#fffefb!important;border-color:#ded7c7!important;border-radius:12px}.field input:focus,.field select:focus,.field textarea:focus{border-color:var(--gold)!important;box-shadow:0 0 0 3px #b99a6018}
.subcard,.restaurant-customer,.import-drop{background:#faf7ef!important;border-color:#d9caa8!important}.feature-parent{border-color:#e3d8c3!important;background:#fffdf8!important}.child-feature,.feature-row{background:#faf7ef!important;border-color:#e3d8c3!important}.feature-parent-head .master-toggle input:checked{background:#1e5942!important;border-color:var(--gold)!important}
.restaurant-tab.active,.pos-subtabs .btn.active{background:#153d35!important;color:#fff8e8!important;border-color:var(--gold)!important}.food-line,.open-bill-card{background:#fffdf8!important;border-color:#e3d8c3!important}.toast{background:#17382c!important;border:1px solid var(--gold)!important}
.bottom{background:rgba(250,247,239,.97)!important;border-top-color:#d9caa8!important}.bottom button.active{background:#e7ebdf!important;color:#153d35!important}.more-menu{background:#fffdf8!important;border-color:#d9caa8!important}.more-menu button{background:#f4f0e5!important;color:#294738!important}.qr-box{background:#faf7ef!important;border-color:#d4c39e!important}.audit-chip{background:#e8efe5!important;color:#24583f!important}.top-alert{animation:none;box-shadow:0 2px 8px #00000008}
button:focus-visible,a:focus-visible,input:focus-visible,select:focus-visible,textarea:focus-visible{outline:2px solid var(--gold)!important;outline-offset:2px}
@media(max-width:760px){.content{padding:17px 13px}.card{padding:17px}.sidebar{display:none}}@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
</style>""";
      final htmlWithLuxuryTheme = html.replaceFirst('</head>', '$royalCoastTheme</head>');
      final headEnd = htmlWithLuxuryTheme.toLowerCase().indexOf('</head>');
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
      final page = htmlWithLuxuryTheme.substring(0, headEnd) + bootstrap + htmlWithLuxuryTheme.substring(headEnd);
      await _controller.loadHtmlString(
        page,
        baseUrl: 'file:///android_asset/flutter_assets/assets/index.html',
      );
      return true;
    } catch (error) {
      debugPrint('Could not safely open Aurelia PMS data: $error');
      if (mounted) setState(() => _loading = false);
      await _controller.loadHtmlString(
        '<!doctype html><html><meta name="viewport" content="width=device-width">'
        '<body style="font:16px sans-serif;padding:24px"><h2>Aurelia PMS data could not be opened</h2>'
        '<p>Your saved data has not been deleted or replaced. Do not uninstall the app or clear its data. '
        'Restore access to the device encryption key or recover from a trusted backup before continuing.</p></body></html>',
      );
      return false;
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
