package com.ismailfarisi.habit_tracker

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.Uri
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_discipline/focus").setMethodCallHandler { call, result ->
            val store = FocusStore(this)
            when (call.method) {
                "isEnabled" -> result.success(FocusGuardService.isEnabled(this))
                "openAccessibilitySettings" -> {
                    startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "openAppInfo" -> {
                    startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                    result.success(null)
                }
                "apps" -> Thread {
                    val apps = launchableApps()
                    runOnUiThread { result.success(apps) }
                }.start()
                "configure" -> {
                    store.setConfig(call.arguments as String)
                    result.success(null)
                }
                "usage" -> result.success(store.usage(call.arguments as? String ?: FocusStore.today()).toString())
                else -> result.notImplemented()
            }
        }
    }

    /** Apps with a launcher icon: package, label and a 96 px PNG icon. */
    private fun launchableApps(): List<Map<String, Any>> {
        val pm = packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, 0)
            .map { it.activityInfo }
            .filter { it.packageName != packageName }
            .distinctBy { it.packageName }
            .map { info ->
                val icon = runCatching {
                    val d = info.loadIcon(pm)
                    val b = Bitmap.createBitmap(96, 96, Bitmap.Config.ARGB_8888)
                    d.setBounds(0, 0, 96, 96)
                    d.draw(Canvas(b))
                    ByteArrayOutputStream().also { b.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
                }.getOrNull()
                buildMap<String, Any> {
                    put("package", info.packageName)
                    put("name", info.applicationInfo.loadLabel(pm).toString())
                    if (icon != null) put("icon", icon)
                }
            }
            .sortedBy { (it["name"] as String).lowercase() }
    }
}
