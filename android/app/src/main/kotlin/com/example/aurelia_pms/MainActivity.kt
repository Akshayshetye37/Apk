package com.example.aurelia_pms

import android.graphics.Bitmap
import android.graphics.Rect
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.content.Intent
import android.database.Cursor
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.os.Bundle
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.RandomAccessFile
import kotlin.math.abs
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodCall
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions

class MainActivity : FlutterFragmentActivity() {
    private var pdfFile: RandomAccessFile? = null
    private var pdfRenderer: PdfRenderer? = null
    private val pdfLock = Any()
    private var pendingBackupFolderResult: MethodChannel.Result? = null
    private val backupFolderRequestCode = 7319

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
                                        val renderer = PdfRenderer(android.os.ParcelFileDescriptor.dup(raf.fd))
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "aurelia/backup_folder")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasFolder" -> {
                        val folder = getSharedPreferences("aurelia_backup", MODE_PRIVATE).getString("tree_uri", null)
                        result.success(!folder.isNullOrBlank())
                    }
                    "chooseFolder" -> {
                        if (pendingBackupFolderResult != null) {
                            result.error("BACKUP_PICKER_BUSY", "A folder picker is already open.", null)
                        } else {
                            pendingBackupFolderResult = result
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
                            }
                            try { startActivityForResult(intent, backupFolderRequestCode) }
                            catch (error: Exception) {
                                pendingBackupFolderResult = null
                                result.error("BACKUP_PICKER", error.message ?: "Could not open folder picker.", null)
                            }
                        }
                    }
                    "writeBackup" -> {
                        try {
                            val bytes = call.argument<ByteArray>("bytes")
                            val name = call.argument<String>("name") ?: "aurelia-pms-latest.enc"
                            val folder = getSharedPreferences("aurelia_backup", MODE_PRIVATE).getString("tree_uri", null)
                            if (folder.isNullOrBlank()) {
                                result.success(false)
                            } else if (bytes == null || bytes.isEmpty() || bytes.size > 30 * 1024 * 1024) {
                                result.error("BACKUP_SIZE", "Encrypted backup is empty or exceeds 30 MB.", null)
                            } else {
                                val treeUri = Uri.parse(folder)
                                val treeId = DocumentsContract.getTreeDocumentId(treeUri)
                                val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, treeId)
                                var existing: Uri? = null
                                contentResolver.query(childrenUri, arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { cursor ->
                                    val idCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                                    val nameCol = cursor.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                                    while (cursor.moveToNext()) {
                                        if (cursor.getString(nameCol) == name) {
                                            existing = DocumentsContract.buildDocumentUriUsingTree(treeUri, cursor.getString(idCol))
                                            break
                                        }
                                    }
                                }
                                val target = existing ?: DocumentsContract.createDocument(contentResolver, DocumentsContract.buildDocumentUriUsingTree(treeUri, treeId), "application/octet-stream", name)
                                    ?: throw IllegalStateException("Could not create backup file in the selected folder.")
                                contentResolver.openOutputStream(target, "wt")?.use { it.write(bytes) }
                                    ?: throw IllegalStateException("Could not write the encrypted backup file.")
                                result.success(true)
                            }
                        } catch (error: Exception) {
                            result.error("BACKUP_WRITE", error.message ?: "Could not write backup.", null)
                        }
                    }
                    else -> result.notImplemented()
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

    @Deprecated("Deprecated in Android API; retained for the document-tree picker callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != backupFolderRequestCode) return
        val pending = pendingBackupFolderResult
        pendingBackupFolderResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            pending?.success(null)
            return
        }
        val uri = data.data!!
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, flags)
            getSharedPreferences("aurelia_backup", MODE_PRIVATE).edit().putString("tree_uri", uri.toString()).apply()
            pending?.success(uri.toString())
        } catch (error: Exception) {
            pending?.error("BACKUP_FOLDER_PERMISSION", error.message ?: "Could not keep access to the selected folder.", null)
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
