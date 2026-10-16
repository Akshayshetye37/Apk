package com.example.aurelia_pms

import android.net.Uri
import android.os.Bundle
import java.io.File
import kotlin.math.abs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions

class MainActivity : FlutterFragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Screenshot capture is allowed by product requirement.
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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
                val recognizer = TextRecognition.getClient(
                    DevanagariTextRecognizerOptions.Builder().build()
                )
                try {
                    val image = InputImage.fromFilePath(this, Uri.fromFile(File(path)))
                    recognizer.process(image)
                        .addOnSuccessListener { recognized ->
                            val lines = recognized.textBlocks
                                .flatMap { it.lines }
                                .map { line ->
                                    val box = line.boundingBox
                                    Triple(box?.top ?: 0, box?.left ?: 0, line.text.trim())
                                }
                                .filter { it.third.isNotEmpty() }
                                .sortedWith(Comparator { a, b ->
                                    val verticalDelta = a.first - b.first
                                    if (abs(verticalDelta) > 12) verticalDelta
                                    else a.second - b.second
                                })
                            val text = if (lines.isEmpty()) recognized.text.trim()
                                else lines.joinToString("\n") { it.third }
                            result.success(text)
                        }
                        .addOnFailureListener { error ->
                            result.error("OCR_FAILED", error.message ?: "Devanagari OCR failed", null)
                        }
                        .addOnCompleteListener { recognizer.close() }
                } catch (error: Exception) {
                    recognizer.close()
                    result.error("OCR_FAILED", error.message ?: "Devanagari OCR failed", null)
                }
            }
    }
}
