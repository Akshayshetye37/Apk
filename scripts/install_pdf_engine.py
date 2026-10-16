#!/usr/bin/env python3
"""Install the bounded, serialized Android PdfRenderer channel into generated Flutter Android sources."""
from pathlib import Path
import re
import sys

if len(sys.argv) != 2:
    raise SystemExit("Usage: install_pdf_engine.py <flutter-project-directory>")
root = Path(sys.argv[1]).resolve()
main = root / "android/app/src/main/kotlin/com/aurelia/pms/MainActivity.kt"
if not main.is_file():
    candidates = list((root / "android/app/src/main/kotlin").rglob("MainActivity.kt"))
    if len(candidates) != 1:
        raise SystemExit("Could not uniquely locate generated MainActivity.kt")
    main = candidates[0]
source = main.read_text(encoding="utf-8")
package_match = re.search(r"(?m)^package\s+([\w.]+)", source)
if not package_match:
    raise SystemExit("MainActivity.kt has no package declaration")
package_name = package_match.group(1)
plugin_dir = main.parent
plugin_dir.mkdir(parents=True, exist_ok=True)
plugin = r'''package __PACKAGE__

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.LruCache
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** All PdfRenderer operations are serialized on one worker to avoid close/render races. */
object PdfEnginePlugin {
    private const val CHANNEL = "com.aurelia.pms/pdf_engine"
    private const val MAX_PDF_BYTES = 100L * 1024L * 1024L
    private const val MAX_RENDER_EDGE = 4096
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var descriptor: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private val cache = object : LruCache<String, ByteArray>(15 * 1024 * 1024) {
        override fun sizeOf(key: String, value: ByteArray): Int = value.size
    }

    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "loadPdf" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) { result.error("INVALID_PATH", "PDF path is required", null); return@setMethodCallHandler }
                    worker.execute {
                        try {
                            val file = File(path)
                            require(file.isFile && file.canRead()) { "PDF file is not readable." }
                            require(file.length() in 1..MAX_PDF_BYTES) { "PDF must be between 1 byte and 100 MiB." }
                            closeInternal()
                            val fd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                            try {
                                val opened = PdfRenderer(fd)
                                descriptor = fd
                                renderer = opened
                                cache.evictAll()
                                main.post { result.success(opened.pageCount) }
                            } catch (error: Throwable) {
                                fd.close()
                                throw error
                            }
                        } catch (error: Throwable) {
                            main.post { result.error("PDF_LOAD_ERROR", error.message ?: "Could not open PDF.", null) }
                        }
                    }
                }
                "renderPage" -> {
                    val index = call.argument<Int>("index") ?: 0
                    val width = call.argument<Int>("width") ?: 1400
                    val height = call.argument<Int>("height") ?: 1980
                    val scale = (call.argument<Double>("scale") ?: 1.0).coerceIn(1.0, 2.5)
                    worker.execute {
                        try {
                            val pdf = renderer ?: error("No PDF is open.")
                            require(index in 0 until pdf.pageCount) { "Page index is out of range." }
                            val baseW = (width * scale).toInt().coerceIn(300, MAX_RENDER_EDGE)
                            val baseH = (height * scale).toInt().coerceIn(300, MAX_RENDER_EDGE)
                            val pageInfo = pdf.openPage(index)
                            val aspect = pageInfo.width.toDouble() / pageInfo.height.toDouble()
                            pageInfo.close()
                            val w = minOf(baseW.toDouble(), baseH * aspect).toInt().coerceIn(300, MAX_RENDER_EDGE)
                            val h = (w / aspect).toInt().coerceIn(300, MAX_RENDER_EDGE)
                            val key = "$index:$w:$h"
                            val bytes = cache.get(key) ?: pdf.openPage(index).use { page ->
                                val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                try {
                                    bitmap.eraseColor(Color.WHITE)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    ByteArrayOutputStream().use { stream ->
                                        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, stream)
                                        stream.toByteArray()
                                    }
                                } finally {
                                    bitmap.recycle()
                                }
                            }.also { cache.put(key, it) }
                            main.post { result.success(bytes) }
                        } catch (error: Throwable) {
                            main.post { result.error("PDF_RENDER_ERROR", error.message ?: "Could not render PDF page.", null) }
                        }
                    }
                }
                "closePdf" -> worker.execute {
                    closeInternal()
                    main.post { result.success(true) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun closeInternal() {
        cache.evictAll()
        try { renderer?.close() } finally {
            renderer = null
            try { descriptor?.close() } finally { descriptor = null }
        }
    }
}
'''.replace("__PACKAGE__", package_name)
(plugin_dir / "PdfEnginePlugin.kt").write_text(plugin, encoding="utf-8")
if "PdfEnginePlugin.register(flutterEngine)" not in source:
    # The Flutter template has changed its Kotlin formatting across releases.
    # Only replace a generated, empty MainActivity; fail closed on custom methods.
    lines = source.splitlines()
    class_index = next((i for i, line in enumerate(lines)
                        if re.search(r"\bclass\s+MainActivity\b", line)
                        and re.search(r"Flutter(?:Fragment)?Activity", line)), None)
    if class_index is None:
        raise SystemExit("Could not find a MainActivity extending FlutterActivity. Found declarations: " +
                         repr([line for line in lines if "MainActivity" in line or "FlutterActivity" in line]))
    declaration = lines[class_index].strip()
    if not re.match(r"^class\s+MainActivity\s*:\s*Flutter(?:Fragment)?Activity\b", declaration):
        raise SystemExit("Unexpected MainActivity declaration: " + repr(declaration))
    # Permit an empty class body (including a separate closing-brace line).
    remainder = lines[class_index + 1:]
    if declaration.endswith("{"):
        while remainder and not remainder[0].strip():
            remainder.pop(0)
        if remainder and remainder[0].strip() == "}":
            remainder.pop(0)
        else:
            raise SystemExit("MainActivity contains custom code; refusing automatic patch.")
    elif declaration.endswith("{}") or re.fullmatch(r"class\s+MainActivity\s*:\s*Flutter(?:Fragment)?Activity\s*(?:\(\s*\))?\s*", declaration):
        pass
    else:
        raise SystemExit("MainActivity contains custom code; refusing automatic patch: " + repr(declaration))
    if any(line.strip() for line in remainder):
        raise SystemExit("MainActivity contains custom code; refusing automatic patch.")
    lines = lines[:class_index] + [
        "class MainActivity : FlutterActivity() {",
        "    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {",
        "        super.configureFlutterEngine(flutterEngine)",
        "        PdfEnginePlugin.register(flutterEngine)",
        "    }",
        "}",
    ]
    source = "\n".join(lines)
    if "import io.flutter.embedding.engine.FlutterEngine" not in source:
        package_line = re.search(r"(?m)^package\\s+[^\\n]+", source)
        if package_line:
            source = source[:package_line.end()] + "\\n\\nimport io.flutter.embedding.engine.FlutterEngine" + source[package_line.end():]
        else:
            raise SystemExit("Could not safely add FlutterEngine import.")
    main.write_text(source.rstrip() + "\n", encoding="utf-8")
print("Installed serialized PdfRenderer method channel and registered it with FlutterEngine.")
