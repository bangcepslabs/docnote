package com.bangceps.docnote

import android.app.Activity
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val backupChannel = "docnote/backup_picker"
    private val pickBackupRequest = 7401
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, backupChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "pickBackup") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (pendingResult != null) {
                    result.error("busy", "파일 선택이 이미 진행 중입니다.", null)
                    return@setMethodCallHandler
                }
                pendingResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                }
                startActivityForResult(intent, pickBackupRequest)
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != pickBackupRequest) return
        val result = pendingResult ?: return
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val source = data.data!!
            val target = File(cacheDir, "docnote_backup_${System.currentTimeMillis()}.docnote")
            contentResolver.openInputStream(source).use { input ->
                requireNotNull(input) { "백업 파일을 읽을 수 없습니다." }
                target.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var count: Int
                    while (input.read(buffer).also { count = it } >= 0) {
                        if (count == 0) continue
                        output.write(buffer, 0, count)
                    }
                }
            }
            result.success(target.absolutePath)
        } catch (error: Exception) {
            result.error("read_failed", error.message, null)
        }
    }
}
