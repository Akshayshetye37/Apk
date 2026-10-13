import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
      // Never silently reset encrypted preferences: doing so can orphan keys
      // and make existing encrypted data unrecoverable. Surface errors instead.
    ),
  );

  static Future<void> writeSecret(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<String?> readSecret(String key) =>
      _storage.read(key: key);

  static Future<void> deleteSecret(String key) =>
      _storage.delete(key: key);
}

/// Allow only the bundled PMS asset and explicit external-app schemes.
/// Remote web content must never receive access to the native JavaScript bridge.
bool isAllowedTopLevelNavigation(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.pathSegments.contains('..')) return false;
  if (uri.scheme == 'file' &&
      uri.host.isEmpty &&
      uri.path.startsWith('/android_asset/flutter_assets/')) {
    return true;
  }
  if (uri.scheme == 'tel' || uri.scheme == 'mailto') return true;
  return uri.scheme == 'about' && uri.path == 'blank';
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AureliaPmsApp());
}

class AureliaPmsApp extends StatelessWidget {
  const AureliaPmsApp({super.key});

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
  static const MethodChannel _securityChannel = MethodChannel('com.example.aurelia_pms/security');
  static const Duration _inactivityLimit = Duration(minutes: 5);
  final TextEditingController _pinInput = TextEditingController();
  final TextEditingController _confirmPinInput = TextEditingController();
  Timer? _inactivityTimer;
  bool _locked = true, _settingPin = true, _securityBusy = false;
  String _lockMessage = 'Set a PIN to protect this device.';
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initializeSecurity());
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
            if (isAllowedTopLevelNavigation(request.url)) {
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

    _loadLocalPms();
  }


  Future<void> _initializeSecurity() async {
    try {
      final hash = await AureliaSecureVault.readSecret('app_pin_hash_v1');
      if (!mounted) return;
      setState(() { _settingPin = hash == null || hash.isEmpty; _locked = true; _lockMessage = _settingPin ? 'Set a 4–8 digit PIN to protect this device.' : 'Unlock Aurelia PMS to continue.'; });
    } catch (_) { if (mounted) setState(() { _settingPin = true; _locked = true; _lockMessage = 'Secure storage unavailable. App remains locked.'; }); }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached || state == AppLifecycleState.resumed) { _inactivityTimer?.cancel(); if (mounted) setState(() => _locked = true); }
  }
  void _recordActivity() { if (_locked) return; _inactivityTimer?.cancel(); _inactivityTimer = Timer(_inactivityLimit, () { if (mounted) setState(() { _locked = true; _lockMessage = 'Locked after five minutes of inactivity.'; }); }); }
  String _newSalt() => base64UrlEncode(List<int>.generate(16, (_) => Random.secure().nextInt(256)));
  Future<String> _pinHash(String pin, String salt) async {
    final hash = await _securityChannel.invokeMethod<String>('derivePinHash', {'pin': pin, 'salt': salt, 'iterations': 120000});
    if (hash == null || hash.length != 64) throw StateError('PIN derivation failed');
    return hash;
  }
  Future<void> _setPin() async {
    final pin = _pinInput.text;
    if (pin.length < 4 || pin.length > 8 || !pin.runes.every((digit) => digit >= 48 && digit <= 57)) { setState(() => _lockMessage = 'PIN must contain 4–8 digits.'); return; }
    if (pin != _confirmPinInput.text) { setState(() => _lockMessage = 'PINs do not match.'); return; }
    setState(() => _securityBusy = true);
    try {
      final salt = _newSalt(); final hash = await _pinHash(pin, salt);
      await AureliaSecureVault.writeSecret('app_pin_salt_v1', salt); await AureliaSecureVault.writeSecret('app_pin_hash_v1', hash);
      await AureliaSecureVault.writeSecret('app_pin_attempts_v1', '0'); await AureliaSecureVault.deleteSecret('app_pin_lock_until_v1');
      if (!mounted) return; _pinInput.clear(); _confirmPinInput.clear();
      setState(() { _settingPin = false; _locked = false; _lockMessage = 'App unlocked.'; }); _recordActivity();
    } catch (_) { if (mounted) setState(() => _lockMessage = 'Could not store PIN securely. App remains locked.'); }
    finally { if (mounted) setState(() => _securityBusy = false); }
  }
  Future<void> _unlockPin() async {
    if (_securityBusy) return; setState(() => _securityBusy = true);
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final until = int.tryParse(await AureliaSecureVault.readSecret('app_pin_lock_until_v1') ?? '');
      if (until != null && now < until) { setState(() => _lockMessage = 'Too many attempts. Wait ' + ((until - now) ~/ 1000).toString() + ' seconds.'); return; }
      final salt = await AureliaSecureVault.readSecret('app_pin_salt_v1'); final expected = await AureliaSecureVault.readSecret('app_pin_hash_v1');
      if (salt == null || expected == null) { setState(() { _settingPin = true; _lockMessage = 'PIN configuration missing. Set a new PIN.'; }); return; }
      final actual = await _pinHash(_pinInput.text, salt); _pinInput.clear();
      if (actual == expected) { await AureliaSecureVault.writeSecret('app_pin_attempts_v1', '0'); await AureliaSecureVault.deleteSecret('app_pin_lock_until_v1'); if (!mounted) return; setState(() { _locked = false; _lockMessage = 'App unlocked.'; }); _recordActivity(); }
      else {
        final attempts = (int.tryParse(await AureliaSecureVault.readSecret('app_pin_attempts_v1') ?? '0') ?? 0) + 1;
        await AureliaSecureVault.writeSecret('app_pin_attempts_v1', attempts.toString());
        if (attempts >= 5) { final delay = min(900, 60 * (1 << min(4, attempts - 5))); await AureliaSecureVault.writeSecret('app_pin_lock_until_v1', (now + delay * 1000).toString()); setState(() => _lockMessage = 'Too many failures. Locked for ' + delay.toString() + ' seconds.'); }
        else { setState(() => _lockMessage = 'Incorrect PIN. ' + (5 - attempts).toString() + ' attempts remain before lockout.'); }
      }
    } catch (_) { if (mounted) setState(() => _lockMessage = 'Secure verification failed. App remains locked.'); }
    finally { if (mounted) setState(() => _securityBusy = false); }
  }
  Future<void> _authenticateDevice() async {
    if (_securityBusy) return; setState(() => _securityBusy = true);
    try { final ok = await _securityChannel.invokeMethod<bool>('authenticateDevice') ?? false; if (ok && mounted) { await AureliaSecureVault.writeSecret('app_pin_attempts_v1', '0'); await AureliaSecureVault.deleteSecret('app_pin_lock_until_v1'); setState(() { _locked = false; _lockMessage = 'Device authentication successful.'; }); _recordActivity(); } else if (mounted) { setState(() => _lockMessage = 'Device authentication cancelled or unavailable. Use PIN.'); } }
    catch (_) { if (mounted) setState(() => _lockMessage = 'Device authentication unavailable. Use PIN.'); }
    finally { if (mounted) setState(() => _securityBusy = false); }
  }
  Widget _lockOverlay() => Positioned.fill(child: Material(color: const Color(0xFF102C36), child: SafeArea(child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 380), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Icon(Icons.lock_rounded, size: 52, color: Colors.white), const SizedBox(height: 16), const Text('Aurelia PMS', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)), const SizedBox(height: 12),
    Text(_lockMessage, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)), const SizedBox(height: 20),
    TextField(controller: _pinInput, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, enabled: !_securityBusy, decoration: const InputDecoration(filled: true, fillColor: Colors.white, labelText: 'PIN', counterText: '', border: OutlineInputBorder())),
    if (_settingPin) TextField(controller: _confirmPinInput, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, enabled: !_securityBusy, decoration: const InputDecoration(filled: true, fillColor: Colors.white, labelText: 'Confirm PIN', counterText: '', border: OutlineInputBorder())),
    const SizedBox(height: 12), FilledButton(onPressed: _securityBusy ? null : (_settingPin ? _setPin : _unlockPin), child: Text(_securityBusy ? 'Please wait…' : (_settingPin ? 'Set PIN securely' : 'Unlock'))),
    if (!_settingPin) OutlinedButton.icon(onPressed: _securityBusy ? null : _authenticateDevice, icon: const Icon(Icons.fingerprint), label: const Text('Use device screen lock'), style: OutlinedButton.styleFrom(foregroundColor: Colors.white)),
    const SizedBox(height: 12), const Text('Locks when backgrounded and after five minutes without interaction.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 12)),
  ])))))));

  Future<void> _handleNativeMessage(String raw) async {
    String? requestId;
    try {
      if (raw.length > 22 * 1024 * 1024) throw const FormatException('Request too large');
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic>) throw const FormatException('Invalid request');
      final rawId = value['requestId'];
      if (rawId is String) {
        final cleaned = rawId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');
        requestId = cleaned.substring(0, cleaned.length.clamp(0, 64).toInt());
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
        // Use a unique temporary path to avoid collisions between exports.
        final file = File('${temp.path}/aurelia_${DateTime.now().microsecondsSinceEpoch}_$safeName');
        try {
          await file.writeAsBytes(bytes, flush: true);
          await Share.shareXFiles(
            [XFile(file.path, mimeType: mime, name: safeName)],
            subject: safeName,
          );
          await _controller.runJavaScript(
            'window.aureliaNativeFileResult?.(${jsonEncode(requestId)},true,null);',
          );
        } finally {
          // Share targets may read asynchronously; cleanup is best-effort and
          // should not turn a successful share into a bridge failure.
          try {
            if (await file.exists()) await file.delete();
          } catch (cleanupError) {
            debugPrint('Aurelia temporary export cleanup failed: $cleanupError');
          }
        }
        return;
      }
      throw const FormatException('Unsupported native action');
    } catch (error) {
      debugPrint('Aurelia native bridge rejected request: $error');
      if (requestId != null) {
        try {
          await _controller.runJavaScript('window.aureliaNativeQrResult?.(${jsonEncode(requestId)},null,${jsonEncode(error.toString())});window.aureliaNativeFileResult?.(${jsonEncode(requestId)},false,${jsonEncode(error.toString())});');
        } catch (_) {}
      }
    }
  }

  Future<void> _loadLocalPms() async {
    try {
      await _controller.loadFlutterAsset('assets/index.html');
    } catch (e) {
      debugPrint('Could not load Aurelia PMS asset: $e');
      if (mounted) setState(() => _loading = false);
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
          child: Listener(behavior: HitTestBehavior.translucent, onPointerDown: (_) => _recordActivity(), child: Stack(
            children: [
              WebViewWidget(controller: _controller),
              if (_loading)
                Align(
                  alignment: Alignment.topCenter,
                  child: LinearProgressIndicator(
                    value: _progress == 100 ? null : _progress / 100,
                  ),
                ),
              if (_locked) _lockOverlay(),
            ],
          )),
        ),
      ),
    );
  }
}
