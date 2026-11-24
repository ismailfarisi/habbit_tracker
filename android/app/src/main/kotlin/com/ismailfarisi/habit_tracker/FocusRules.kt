package com.ismailfarisi.habit_tracker

/** An app the user chose to pause; [limitMin] 0 means no daily limit (sleep time only). */
data class FocusApp(val name: String, val limitMin: Int)

/** What the Flutter side writes through `daily_discipline/focus` → `configure`. */
data class FocusConfig(
    val enabled: Boolean = false,
    val apps: Map<String, FocusApp> = emptyMap(),
    val sleepBlock: Boolean = false,
    val bedMin: Int = 0,
    val wakeMin: Int = 0,
    val strict: Boolean = false,
    val wakeLabel: String = "",
)

enum class PauseReason { LIMIT, SLEEP }

/** When a chosen app is paused. Pure, so it can be unit tested on the JVM. */
object FocusRules {
    /** [minute] (minute of the day) falls in the sleep window, which may cross midnight. */
    fun inSleep(minute: Int, bedMin: Int, wakeMin: Int): Boolean = when {
        bedMin == wakeMin -> false
        bedMin < wakeMin -> minute in bedMin until wakeMin
        else -> minute >= bedMin || minute < wakeMin
    }

    fun reason(cfg: FocusConfig, pkg: String, minute: Int, usedMs: Long, extended: Boolean): PauseReason? {
        if (!cfg.enabled || extended) return null
        val app = cfg.apps[pkg] ?: return null
        if (cfg.sleepBlock && inSleep(minute, cfg.bedMin, cfg.wakeMin)) return PauseReason.SLEEP
        if (app.limitMin > 0 && usedMs >= app.limitMin * 60_000L) return PauseReason.LIMIT
        return null
    }
}
