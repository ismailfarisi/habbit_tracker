package com.ismailfarisi.habit_tracker

import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import java.util.Calendar

/**
 * Pauses the apps the user chose once their daily limit is used up, or during sleep time.
 *
 * Only window-change events are read (which app is in front); the service cannot see screen
 * content. Time is counted while a chosen app is in front and the screen is on, and checked
 * every [TICK_MS] so a limit reached mid-scroll pauses the app.
 */
class FocusGuardService : AccessibilityService() {
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var store: FocusStore

    /** The chosen app in front, and since when (elapsed realtime). */
    private var current: String? = null
    private var since = 0L

    /** The last app in front, chosen or not, so unlocking the phone resumes counting. */
    private var lastPkg: String? = null

    /** The app just paused or locked, so going back to it (e.g. after "5 more minutes") isn't a new open. */
    private var pausedPkg: String? = null

    /** The chosen app that last left the front, and when; a quick return isn't a new open. */
    private var leftPkg: String? = null
    private var leftAt = 0L

    private val tick = object : Runnable {
        override fun run() {
            val pkg = current ?: return
            flush()
            check(pkg)
            if (current != null) handler.postDelayed(this, TICK_MS)
        }
    }

    private val screen = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) {
            when (i.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    current?.let { pausedPkg = it }
                    leave()
                }
                Intent.ACTION_USER_PRESENT -> lastPkg?.let { enter(it, countOpen = false) }
            }
        }
    }

    override fun onServiceConnected() {
        store = FocusStore(this)
        registerReceiver(screen, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        })
    }

    override fun onDestroy() {
        leave()
        runCatching { unregisterReceiver(screen) }
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(e: AccessibilityEvent?) {
        if (e?.eventType != AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED || !::store.isInitialized) return
        val pkg = e.packageName?.toString() ?: return
        if (pkg in IGNORED || pkg == keyboardPackage()) return
        lastPkg = pkg
        if (pkg == packageName) {
            leave()
            return
        }
        val resumed = pkg == pausedPkg
        pausedPkg = null
        if (pkg != current) enter(pkg, countOpen = !resumed)
    }

    private fun enter(pkg: String, countOpen: Boolean) {
        if (pkg == current) return
        leave()
        val cfg = store.config()
        if (!cfg.enabled || !cfg.apps.containsKey(pkg)) return
        val now = SystemClock.elapsedRealtime()
        if (countOpen && !(pkg == leftPkg && now - leftAt < REOPEN_MS)) store.addOpen(pkg)
        current = pkg
        since = now
        if (check(pkg)) handler.postDelayed(tick, TICK_MS)
    }

    private fun flush() {
        val pkg = current ?: return
        val now = SystemClock.elapsedRealtime()
        store.addTime(pkg, now - since)
        since = now
    }

    private fun leave() {
        flush()
        current?.let {
            leftPkg = it
            leftAt = SystemClock.elapsedRealtime()
        }
        current = null
        handler.removeCallbacks(tick)
    }

    /** Pauses [pkg] if it should be; returns true while it may stay open. */
    private fun check(pkg: String): Boolean {
        val cfg = store.config()
        val c = Calendar.getInstance()
        val minute = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE)
        val reason = FocusRules.reason(cfg, pkg, minute, store.usedMs(pkg), store.isExtended(pkg)) ?: return true
        leave()
        val app = cfg.apps[pkg] ?: return false
        pausedPkg = pkg
        startActivity(
            Intent(this, PauseActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(PauseActivity.PKG, pkg)
                .putExtra(PauseActivity.NAME, app.name)
                .putExtra(PauseActivity.REASON, reason.name)
                .putExtra(PauseActivity.LIMIT, app.limitMin)
                .putExtra(PauseActivity.WAKE, cfg.wakeLabel)
                .putExtra(PauseActivity.CAN_EXTEND, !cfg.strict && store.canExtend(pkg)),
        )
        return false
    }

    private fun keyboardPackage(): String? =
        Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.let { ComponentName.unflattenFromString(it)?.packageName }

    companion object {
        const val TICK_MS = 10_000L
        const val REOPEN_MS = 3_000L
        private val IGNORED = setOf("com.android.systemui")

        fun isEnabled(context: Context): Boolean {
            val me = ComponentName(context, FocusGuardService::class.java)
            val list = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            return list.split(':').any { ComponentName.unflattenFromString(it) == me }
        }
    }
}
