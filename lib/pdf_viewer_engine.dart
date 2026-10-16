import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Native PdfRenderer-backed viewer. Native calls are serialized by the Android
/// engine; request IDs prevent stale zoom/page renders from replacing newer ones.
class ProductionPdfViewerRoute extends StatefulWidget {
  const ProductionPdfViewerRoute({
    super.key,
    required this.filePath,
    required this.documentTitle,
  });

  final String filePath;
  final String documentTitle;

  @override
  State<ProductionPdfViewerRoute> createState() => _ProductionPdfViewerRouteState();
}

class _ProductionPdfViewerRouteState extends State<ProductionPdfViewerRoute> {
  static const _channel = MethodChannel('com.aurelia.pms/pdf_engine');
  int _pageCount = 0;
  int _page = 0;
  int _request = 0;
  bool _loading = true;
  String? _error;
  Uint8List? _bytes;
  double _zoom = 1;
  final TransformationController _transformController = TransformationController();
  Timer? _debounce;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final count = await _channel.invokeMethod<int>('loadPdf', {'path': widget.filePath});
      if (!mounted) return;
      if (count == null || count < 1) throw StateError('The PDF contains no readable pages.');
      setState(() { _pageCount = count; _loading = false; });
      _render(0, 1);
    } on PlatformException catch (e) {
      if (mounted) setState(() { _error = e.message ?? 'Could not open PDF.'; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  void _render(int page, double scale, {bool debounce = false}) {
    if (_pageCount == 0 || _closing) return;
    final id = ++_request;
    _debounce?.cancel();
    Future<void> run() async {
      if (!mounted || id != _request) return;
      setState(() { _loading = true; _error = null; });
      try {
        final bytes = await _channel.invokeMethod<Uint8List>('renderPage', {
          'index': page, 'width': 1400, 'height': 1980,
          'scale': scale.clamp(1.0, 2.5),
        });
        if (!mounted || id != _request) return;
        if (bytes == null || bytes.isEmpty) throw StateError('The PDF page could not be rendered.');
        setState(() { _page = page; _bytes = bytes; _loading = false; });
      } on PlatformException catch (e) {
        if (mounted && id == _request) setState(() { _error = e.message ?? 'PDF rendering failed.'; _loading = false; });
      } catch (e) {
        if (mounted && id == _request) setState(() { _error = e.toString(); _loading = false; });
      }
    }
    if (debounce) {
      _debounce = Timer(const Duration(milliseconds: 220), () { unawaited(run()); });
    } else {
      unawaited(run());
    }
  }

  void _zoomChanged(ScaleEndDetails details) {
    _zoom = _transformController.value.getMaxScaleOnAxis().clamp(1.0, 2.5).toDouble();
    _render(_page, _zoom, debounce: true);
  }

  @override
  void dispose() {
    _closing = true;
    _request++;
    _debounce?.cancel();
    _transformController.dispose();
    unawaited(_channel.invokeMethod<void>('closePdf').catchError((_) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF1C3029),
    appBar: AppBar(
      title: Text(widget.documentTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      backgroundColor: const Color(0xFF17483B),
      foregroundColor: Colors.white,
    ),
    body: _error != null
      ? Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.picture_as_pdf_outlined, color: Colors.white70, size: 48),
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.white), textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: () { setState(() { _error = null; _loading = true; }); _load(); }, child: const Text('Retry')),
          ]),
        ))
      : Stack(children: [
          Positioned.fill(child: _bytes == null
            ? const SizedBox.shrink()
            : Center(child: InteractiveViewer(
                transformationController: _transformController,
                minScale: 1, maxScale: 3, panEnabled: true, scaleEnabled: true,
                onInteractionEnd: _zoomChanged,
                child: Image.memory(_bytes!, fit: BoxFit.contain, gaplessPlayback: true),
              ))),
          if (_loading) const Positioned(top: 12, right: 12,
            child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
        ]),
    bottomNavigationBar: _pageCount > 1 ? SafeArea(
      child: ColoredBox(color: const Color(0xFF172F27), child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(onPressed: _page > 0 && !_loading ? () { _zoom = 1; _transformController.value = Matrix4.identity(); _render(_page - 1, 1); } : null,
            icon: const Icon(Icons.chevron_left, color: Colors.white)),
          Text('Page ${_page + 1} of $_pageCount', style: const TextStyle(color: Colors.white)),
          IconButton(onPressed: _page + 1 < _pageCount && !_loading ? () { _zoom = 1; _transformController.value = Matrix4.identity(); _render(_page + 1, 1); } : null,
            icon: const Icon(Icons.chevron_right, color: Colors.white)),
        ],
      )),
    ) : null,
  );
}
