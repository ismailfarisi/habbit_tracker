package com.ismailfarisi.habit_tracker

import android.app.NotificationManager
import android.app.PendingIntent
import android.os.Build
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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_discipline/reminders").setMethodCallHandler { call, result ->
            val manager = getSystemService(NotificationManager::class.java)
            when (call.method) {
                "fullScreenAllowed" -> result.success(Build.VERSION.SDK_INT < 34 || manager.canUseFullScreenIntent())
                "blockedChannels" -> result.success(if (Build.VERSION.SDK_INT >= 26) {
                    manager.notificationChannels.filter { it.importance == NotificationManager.IMPORTANCE_NONE }
                        .associate { it.id to it.name.toString() }
                } else emptyMap<String, String>())
                "pendingIds" -> {
                    val intent = Intent().setClassName(this, "com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver")
                    val flags = PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
                    val ids = (call.arguments as? List<*>)?.filterIsInstance<Int>().orEmpty()
                    result.success(ids.filter { PendingIntent.getBroadcast(this, it, intent, flags) != null })
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "daily_discipline/focus").setMethodCallHandler { call, result ->
            val store = FocusStore(this)
            when (call.method) {
                "readiness" -> {
                    val cfg = store.config()
                    val safe = FocusSafety.excluded(this)
                    result.success(mapOf(
                        "permission" to FocusGuardService.isEnabled(this),
                        "running" to (FocusGuardService.connected != null),
                        "protected" to cfg.apps.filter { (pkg, app) ->
                            cfg.enabled && pkg !in safe && (cfg.sleepBlock || app.limitMin > 0)
                                && packageManager.getLaunchIntentForPackage(pkg) != null
                        }.keys.toList(),
                    ))
                }
                "testPause" -> {
                    val pkg = call.arguments as String
                    val launch = packageManager.getLaunchIntentForPackage(pkg)
                    val ready = launch != null && FocusGuardService.isEnabled(this) && FocusGuardService.connected?.armTest(pkg) == true
                    result.success(ready && runCatching { startActivity(launch); true }.getOrDefault(false))
                }
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
                "clearDeviceData" -> {
                    if (FocusGuardService.clearDeviceData(this)) result.success(null)
                    else result.error("focus_clear", "Could not clear focus data", null)
                }
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
        val excluded = FocusSafety.excluded(this)
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        return pm.queryIntentActivities(intent, 0)
            .map { it.activityInfo }
            .filter { it.packageName !in excluded }
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
