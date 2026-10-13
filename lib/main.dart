import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';


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
      home: const PmsWebViewPage(),
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

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
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
            return NavigationDecision.navigate;
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
