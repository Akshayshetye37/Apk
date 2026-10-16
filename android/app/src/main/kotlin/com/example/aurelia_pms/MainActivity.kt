package com.example.aurelia_pms

import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Bundle
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions

class MainActivity : FlutterFragmentActivity() {
    private var pdfFile: RandomAccessFile? = null
    private var pdfRenderer: PdfRenderer? = null
    private val pdfLock = Any()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.aurelia.pms/pdf_engine")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "loadPdf" -> {
                            val path = call.argument<String>("path")
                            if (path.isNullOrBlank()) result.error("PDF_INPUT", "Missing PDF file path", null)
                            else synchronized(pdfLock) {
                                closePdfLocked()
                                val file = File(path)
                                if (!file.isFile || !file.canRead()) result.error("PDF_FILE", "PDF file cannot be read.", null)
                                else {
                                    val raf = RandomAccessFile(file, "r")
                                    try {
                                        val renderer = PdfRenderer(raf.fd)
                                        pdfFile = raf
                                        pdfRenderer = renderer
                                        result.success(renderer.pageCount)
                                    } catch (e: Exception) {
                                        raf.close()
                                        throw e
                                    }
                                }
                            }
                        }
                        "renderPage" -> {
                            val index = call.argument<Int>("index") ?: 0
                            val width = (call.argument<Int>("width") ?: 1400).coerceIn(320, 2400)
                            val height = (call.argument<Int>("height") ?: 1980).coerceIn(320, 3200)
                            synchronized(pdfLock) {
                                val renderer = pdfRenderer
                                if (renderer == null) result.error("PDF_NOT_LOADED", "Open the PDF again to render this page.", null)
                                else if (index !in 0 until renderer.pageCount) result.error("PDF_PAGE", "Requested PDF page is out of range.", null)
                                else renderer.openPage(index).use { page ->
                                    val scale = minOf(width.toFloat() / page.width, height.toFloat() / page.height)
                                    val bitmap = Bitmap.createBitmap((page.width * scale).toInt().coerceAtLeast(1), (page.height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888)
                                    bitmap.eraseColor(android.graphics.Color.WHITE)
                                    page.render(bitmap, Rect(0, 0, bitmap.width, bitmap.height), null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    val output = ByteArrayOutputStream()
                                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                                    bitmap.recycle()
                                    result.success(output.toByteArray())
                                }
                            }
                        }
                        "closePdf" -> {
                            synchronized(pdfLock) { closePdfLocked() }
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("PDF_FAILED", error.message ?: "Could not process PDF.", null)
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurelia/native_ocr")
            .setMethodCallHandler { call, result ->
                if (call.method != "recognizeDevanagari") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("OCR_INPUT", "Missing OCR image path", null)
                    return@setMethodCallHandler
                }
                val recognizer = TextRecognition.getClient(DevanagariTextRecognizerOptions.Builder().build())
                try {
                    recognizer.process(InputImage.fromFilePath(this, Uri.fromFile(File(path))))
                        .addOnSuccessListener { recognized ->
                            val lines = recognized.textBlocks.flatMap { it.lines }.map { line ->
                                val box = line.boundingBox
                                Triple(box?.top ?: 0, box?.left ?: 0, line.text.trim())
                            }.filter { it.third.isNotEmpty() }.sortedWith(Comparator { a, b ->
                                val dy = a.first - b.first
                                if (abs(dy) > 12) dy else a.second - b.second
                            })
                            result.success(if (lines.isEmpty()) recognized.text.trim() else lines.joinToString("\n") { it.third })
                        }
                        .addOnFailureListener { error -> result.error("OCR_FAILED", error.message ?: "Devanagari OCR failed", null) }
                        .addOnCompleteListener { recognizer.close() }
                } catch (error: Exception) {
                    recognizer.close()
                    result.error("OCR_FAILED", error.message ?: "Devanagari OCR failed", null)
                }
            }
    }

    private fun closePdfLocked() {
        try { pdfRenderer?.close() } catch (_: Exception) {}
        try { pdfFile?.close() } catch (_: Exception) {}
        pdfRenderer = null
        pdfFile = null
    }

    override fun onDestroy() {
        synchronized(pdfLock) { closePdfLocked() }
        super.onDestroy()
    }
}
