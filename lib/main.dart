import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'core/security/pin_kdf_service.dart';
import 'core/security/security_interfaces.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'native_migration_store.dart';
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
      resetOnError: true,
    ),
  );

  static Future<void> writeSecret(String key, String value) =>
      _storage.write(key: key, value: value);

  static Future<String?> readSecret(String key) =>
      _storage.read(key: key);

  static Future<void> deleteSecret(String key) =>
      _storage.delete(key: key);
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
      home: const AureliaSecurityGate(child: PmsWebViewPage()),
    );
  }
}

class PmsWebViewPage extends StatefulWidget {
  const PmsWebViewPage({super.key});

  @override
  State<PmsWebViewPage> createState() => _PmsWebViewPageState();
}

class _PmsWebViewPageState extends State<PmsWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;
  bool _migrationBusy = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('AureliaNative', onMessageReceived: (message) { unawaited(_handleNativeMessage(message.message)); })
      ..addJavaScriptChannel('MigrationChannel', onMessageReceived: (message) { unawaited(_handleMigrationPayload(message.message)); })
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
            // The bundled HTML exposes a non-destructive migration payload
            // sender. Repeat loads are safe because the native snapshot is upserted.
            unawaited(_controller.runJavaScript('window.aureliaSendMigrationPayload?.();').catchError((Object error) {
              debugPrint('Aurelia migration sender unavailable: $error');
            }));
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

    _loadLocalPms();
  }


  Future<void> _handleMigrationPayload(String raw) async {
    if (_migrationBusy) {
      debugPrint('Aurelia migration request ignored: another migration is active');
      return;
    }
    _migrationBusy = true;
    try {
      final result = await AureliaMigrationStore.instance.ingest(raw);
      // The JS callback intentionally retains localStorage. Deletion is not
      // enabled until a separately tested reconciliation/restore flow exists.
      await _controller.runJavaScript(
        'window.aureliaMigrationResult?.(${jsonEncode(result)});',
      );
      debugPrint('Aurelia encrypted snapshot verified: ${jsonEncode(result['counts'])}');
    } catch (error, stack) {
      debugPrint('Aurelia migration failed; source browser storage retained: $error');
      debugPrintStack(stackTrace: stack);
      try {
        await _controller.runJavaScript(
          'window.aureliaMigrationResult?.(${jsonEncode({'verified': false, 'error': 'Native migration failed'})});',
        );
      } catch (_) {}
    } finally {
      _migrationBusy = false;
    }
  }

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


/// PIN provisioning, legacy migration, biometric unlock, and lifecycle locking.
class AureliaSecurityGate extends StatefulWidget {
  final Widget child;
  final SecureStorageProvider? storage;
  final BiometricAuthProvider? auth;
  final PinKdfService? pinService;

  const AureliaSecurityGate({
    super.key,
    required this.child,
    this.storage,
    this.auth,
    this.pinService,
  });

  @override
  State<AureliaSecurityGate> createState() => _AureliaSecurityGateState();
}

class _AureliaSecurityGateState extends State<AureliaSecurityGate>
    with WidgetsBindingObserver {
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
  );

  late final SecureStorageProvider _storage;
  late final BiometricAuthProvider _auth;
  late final PinKdfService _pinService;
  final _pin = TextEditingController();
  final _confirm = TextEditingController();

  bool _ready = false;
  bool _provisioning = false;
  bool _locked = true;
  bool _busy = false;
  bool _showPin = false;
  int _failed = 0;
  DateTime? _lockoutUntil;
  String? _error;

  @override
  void initState() {
    super.initState();
    _storage = widget.storage ?? FlutterSecureStorageProvider(_secureStorage);
    _auth = widget.auth ?? LocalBiometricAuthProvider(LocalAuthentication());
    _pinService = widget.pinService ?? PinKdfService(_storage);
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final state = await _pinService.checkProvisioningState();
      final failures = int.tryParse(
            await _storage.read(PinKdfService.failedKey) ?? '',
          ) ??
          0;
      final untilRaw = await _storage.read(PinKdfService.untilKey);
      final untilMillis = int.tryParse(untilRaw ?? '');
      if (!mounted) return;
      setState(() {
        _provisioning = state == PinProvisioningState.notProvisioned;
        _failed = failures.clamp(0, 1000000);
        _lockoutUntil = untilMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(untilMillis);
        _ready = true;
        if (state == PinProvisioningState.lockedOut) {
          _error = 'Too many attempts. Please wait before trying again.';
        }
      });
      if (state == PinProvisioningState.provisioned ||
          state == PinProvisioningState.requiresMigration) {
        unawaited(_tryBiometric());
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _ready = true;
          _error = 'Secure storage or PIN data is invalid. App remains locked.';
        });
      }
    }
  }

  Future<void> _provision() async {
    if (_busy) return;
    if (!RegExp(r'^\d{6,12}$').hasMatch(_pin.text)) {
      setState(() => _error = 'Choose a PIN of 6–12 digits.');
      return;
    }
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'PINs do not match.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      await _pinService.provisionPin(_pin.text);
      if (mounted) {
        setState(() {
          _provisioning = false;
          _locked = false;
          _pin.clear();
          _confirm.clear();
          _failed = 0;
          _lockoutUntil = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not securely save PIN.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyPin() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    try {
      final result = await _pinService.verifyPin(_pin.text);
      final failed = int.tryParse(
            await _storage.read(PinKdfService.failedKey) ?? '',
          ) ??
          0;
      final untilMillis = int.tryParse(
        await _storage.read(PinKdfService.untilKey) ?? '',
      );
      if (!mounted) return;
      setState(() {
        _failed = failed.clamp(0, 1000000);
        _lockoutUntil = untilMillis == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(untilMillis);
      });
      switch (result) {
        case PinVerificationResult.success:
          setState(() { _locked = false; _pin.clear(); _error = null; });
          break;
        case PinVerificationResult.incorrect:
          setState(() => _error = 'Incorrect PIN. Attempt $_failed of 3.');
          break;
        case PinVerificationResult.lockedOut:
          setState(() => _error = 'Locked out. Try again after the lockout expires.');
          break;
        case PinVerificationResult.notProvisioned:
          setState(() {
            _provisioning = true;
            _error = 'PIN setup is required.';
          });
          break;
        case PinVerificationResult.invalidPayload:
          setState(() => _error = 'PIN data is invalid. App remains locked.');
          break;
      }
      _pin.clear();
    } catch (_) {
      if (mounted) setState(() => _error = 'PIN verification failed. App remains locked.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _tryBiometric() async {
    if (_busy || _provisioning || !_locked || !mounted) return;
    setState(() { _busy = true; _error = null; });
    try {
      if (await _auth.isDeviceSupported() && await _auth.authenticate()) {
        if (mounted) setState(() { _locked = false; _pin.clear(); });
      }
    } catch (_) {
      // PIN remains available as fallback.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      if (mounted) setState(() => _locked = true);
    } else if (state == AppLifecycleState.resumed && _locked && !_provisioning) {
      unawaited(_tryBiometric());
    }
  }

  Widget _lockScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF172F27),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.lock_outline, color: Color(0xFFB99A60), size: 56),
                  const SizedBox(height: 16),
                  Text(
                    _provisioning ? 'Create your Aurelia PIN' : 'Unlock Aurelia PMS',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _pin,
                    keyboardType: TextInputType.number,
                    obscureText: !_showPin,
                    maxLength: 12,
                    enabled: !_busy && !(_lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!)),
                    decoration: InputDecoration(
                      labelText: _provisioning ? 'New PIN (6–12 digits)' : 'PIN',
                      counterText: '',
                      filled: true,
                      fillColor: Colors.white,
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => _showPin = !_showPin),
                        icon: Icon(_showPin ? Icons.visibility_off : Icons.visibility),
                      ),
                    ),
                  ),
                  if (_provisioning) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 12,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        labelText: 'Confirm PIN',
                        counterText: '',
                        filled: true,
                        fillColor: Colors.white,
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: Color(0xFFFFC4B8)), textAlign: TextAlign.center),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _busy ? null : (_provisioning ? _provision : _verifyPin),
                    child: Text(_busy ? 'Please wait…' : (_provisioning ? 'Save PIN' : 'Unlock with PIN')),
                  ),
                  if (!_provisioning) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _busy ? null : _tryBiometric,
                      child: const Text('Use device authentication', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final obscured = _locked || _provisioning;
    return Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: obscured,
          child: IgnorePointer(ignoring: obscured, child: widget.child),
        ),
        if (obscured) _lockScreen(),
      ],
    );
  }
}
