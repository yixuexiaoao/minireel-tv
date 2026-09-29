package app.minireel.minireel

import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "minireel/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> result.success(true)  // TV flavor 始终走 TV 界面
                    "getAbi" -> {
                        val abis = Build.SUPPORTED_ABIS
                        result.success(if (abis.isNotEmpty()) abis[0] else "armeabi-v7a")
                    }
                    "installApk" -> {
                        val path = call.argument<String>("filePath")
                        if (path == null) {
                            result.error("ARG_NULL", "filePath is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "File not found: $path", null)
                                return@setMethodCallHandler
                            }
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                                FileProvider.getUriForFile(
                                    this,
                                    "${applicationContext.packageName}.fileProvider",
                                    file
                                )
                            } else {
                                Uri.fromFile(file)
                            }
                            intent.setDataAndType(uri, "application/vnd.android.package-archive")
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.localizedMessage, e.message)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isTvDevice(): Boolean {
        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK_ONLY)) return true
        val uiMode = resources.configuration.uiMode and Configuration.UI_MODE_TYPE_MASK
        return uiMode == Configuration.UI_MODE_TYPE_TELEVISION
    }
}
