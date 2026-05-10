package com.beatzlock.otp

import android.app.Activity
import android.content.ContentValues
import android.content.Intent
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.activity.result.contract.ActivityResultContracts
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterFragmentActivity() {
    private var pendingDocumentPickerResult: MethodChannel.Result? = null

    private val documentPickerLauncher =
        registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { activityResult ->
            val result = pendingDocumentPickerResult
            pendingDocumentPickerResult = null

            if (result == null) {
                return@registerForActivityResult
            }

            if (activityResult.resultCode != Activity.RESULT_OK) {
                result.success(null)
                return@registerForActivityResult
            }

            val uri = activityResult.data?.data
            if (uri == null) {
                result.success(null)
                return@registerForActivityResult
            }

            try {
                val payload = readPickedDocument(uri)
                result.success(payload)
            } catch (error: Exception) {
                result.error(
                    "DOCUMENT_PICK_FAILED",
                    error.message ?: "Unable to read the selected file.",
                    null
                )
            }
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.beatzlock.otp/storage"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "savePdfToDownloads" -> {
                    val fileName = call.argument<String>("fileName")
                    val bytes = call.argument<ByteArray>("bytes")

                    if (fileName.isNullOrBlank() || bytes == null) {
                        result.error(
                            "INVALID_ARGUMENTS",
                            "A file name and PDF bytes are required.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        result.success(savePdfToDownloads(fileName, bytes))
                    } catch (error: Exception) {
                        result.error(
                            "DOWNLOAD_SAVE_FAILED",
                            error.message ?: "Unable to save PDF to Downloads.",
                            null
                        )
                    }
                }
                "saveFileToDownloads" -> {
                    val fileName = call.argument<String>("fileName")
                    val mimeType = call.argument<String>("mimeType")
                    val bytes = call.argument<ByteArray>("bytes")

                    if (fileName.isNullOrBlank() || mimeType.isNullOrBlank() || bytes == null) {
                        result.error(
                            "INVALID_ARGUMENTS",
                            "A file name, MIME type, and file bytes are required.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        result.success(saveFileToDownloads(fileName, mimeType, bytes))
                    } catch (error: Exception) {
                        result.error(
                            "DOWNLOAD_SAVE_FAILED",
                            error.message ?: "Unable to save file to Downloads.",
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.beatzlock.otp/file_picker"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImportFile",
                "pickPasswordImportFile" -> {
                    if (pendingDocumentPickerResult != null) {
                        result.error(
                            "PICKER_BUSY",
                            "A file picker is already open.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    pendingDocumentPickerResult = result
                    try {
                        openDocumentPicker()
                    } catch (error: Exception) {
                        pendingDocumentPickerResult = null
                        result.error(
                            "DOCUMENT_PICK_FAILED",
                            error.message ?: "Unable to open the document picker.",
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.beatzlock.otp/device_identity"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStableDeviceId" -> {
                    try {
                        val androidId = Settings.Secure.getString(
                            contentResolver,
                            Settings.Secure.ANDROID_ID
                        )
                        result.success(androidId ?: "")
                    } catch (error: Exception) {
                        result.error(
                            "DEVICE_IDENTITY_FAILED",
                            error.message ?: "Unable to read Android device identity.",
                            null
                        )
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun savePdfToDownloads(fileName: String, bytes: ByteArray): String {
        return saveFileToDownloads(fileName, "application/pdf", bytes)
    }

    private fun saveFileToDownloads(
        fileName: String,
        mimeType: String,
        bytes: ByteArray
    ): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveToMediaStoreDownloads(fileName, mimeType, bytes)
        } else {
            saveToLegacyDownloads(fileName, bytes)
        }
    }

    private fun saveToMediaStoreDownloads(
        fileName: String,
        mimeType: String,
        bytes: ByteArray
    ): String {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, mimeType)
            put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
            put(MediaStore.Downloads.IS_PENDING, 1)
        }

        val resolver = applicationContext.contentResolver
        val collection = MediaStore.Downloads.getContentUri(
            MediaStore.VOLUME_EXTERNAL_PRIMARY
        )
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Could not create Downloads entry.")

        resolver.openOutputStream(uri)?.use { output ->
            output.write(bytes)
        } ?: throw IllegalStateException("Could not open Downloads entry.")

        val finishedValues = ContentValues().apply {
            put(MediaStore.Downloads.IS_PENDING, 0)
        }
        resolver.update(uri, finishedValues, null, null)

        return "${Environment.DIRECTORY_DOWNLOADS}/$fileName"
    }

    private fun saveToLegacyDownloads(fileName: String, bytes: ByteArray): String {
        val downloadsDir = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_DOWNLOADS
        )
        if (!downloadsDir.exists() && !downloadsDir.mkdirs()) {
            throw IllegalStateException("Could not create Downloads directory.")
        }

        val file = File(downloadsDir, fileName)
        FileOutputStream(file).use { output ->
            output.write(bytes)
        }
        return file.absolutePath
    }

    private fun openDocumentPicker() {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        documentPickerLauncher.launch(intent)
    }

    private fun readPickedDocument(uri: android.net.Uri): Map<String, Any> {
        val fileName = queryDisplayName(uri) ?: "password-import"
        val mimeType = contentResolver.getType(uri) ?: ""
        val bytes = contentResolver.openInputStream(uri)?.use { input ->
            input.readBytes()
        } ?: throw IllegalStateException("Could not read the selected file.")

        return mapOf(
            "fileName" to fileName,
            "mimeType" to mimeType,
            "bytes" to bytes
        )
    }

    private fun queryDisplayName(uri: android.net.Uri): String? {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) {
                    return cursor.getString(index)
                }
            }
        }
        return null
    }
}
