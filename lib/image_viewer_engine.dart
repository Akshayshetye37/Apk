import 'dart:io';
import 'package:flutter/material.dart';

/// Memory-conscious image viewer for guest IDs, receipts and property images.
class AdvancedImageViewerRoute extends StatefulWidget {
  final String filePath;
  final String documentTitle;

  const AdvancedImageViewerRoute({
    super.key,
    required this.filePath,
    required this.documentTitle,
  });

  @override
  State<AdvancedImageViewerRoute> createState() => _AdvancedImageViewerRouteState();
}

class _AdvancedImageViewerRouteState extends State<AdvancedImageViewerRoute> {
  final TransformationController _transform = TransformationController();
  bool _loading = true;
  String? _error;
  late final File _file;

  @override
  void initState() {
    super.initState();
    _file = File(widget.filePath);
    _verify();
  }

  Future<void> _verify() async {
    try {
      final exists = await _file.exists();
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (!exists) _error = 'Image file could not be found.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = 'Could not access image: $e'; });
    }
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF1C3029),
    appBar: AppBar(
      title: Text(widget.documentTitle),
      backgroundColor: const Color(0xFF17483B),
      foregroundColor: Colors.white,
      actions: [
        IconButton(
          tooltip: 'Reset zoom',
          icon: const Icon(Icons.center_focus_strong),
          onPressed: () => _transform.value = Matrix4.identity(),
        ),
      ],
    ),
    body: _loading
      ? const Center(child: CircularProgressIndicator(color: Color(0xFFB99A60)))
      : _error != null
        ? Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
          ))
        : Center(
            child: InteractiveViewer(
              transformationController: _transform,
              minScale: 1,
              maxScale: 6,
              boundaryMargin: const EdgeInsets.all(24),
              child: Image.file(
                _file,
                fit: BoxFit.contain,
                // Decode to a bounded width instead of allocating a full 12–48MP bitmap.
                cacheWidth: 1600,
                errorBuilder: (context, error, stack) => Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('Image could not be decoded. $error',
                    style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                ),
              ),
            ),
          ),
  );
}
