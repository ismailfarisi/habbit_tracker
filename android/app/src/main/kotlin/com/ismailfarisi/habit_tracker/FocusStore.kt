package com.ismailfarisi.habit_tracker

import android.content.Context
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

/**
 * The focus config and per-day usage of the chosen apps, kept in their own SharedPreferences
 * file. Usage is stored as `usage_yyyy-MM-dd` → `{package: {"ms": foreground ms, "o": opens}}`.
 */
class FocusStore(context: Context) {
    private val p = context.getSharedPreferences("focus_guard", Context.MODE_PRIVATE)

    fun clear(): Boolean = p.edit().clear().commit()

    fun config(): FocusConfig = parse(p.getString("config", null))

    fun setConfig(json: String) {
        p.edit().putString("config", json).apply()
        prune()
    }

    fun usage(day: String = today()): JSONObject =
        runCatching { JSONObject(p.getString("usage_$day", null) ?: "{}") }.getOrDefault(JSONObject())

    fun usedMs(pkg: String): Long = usage().optJSONObject(pkg)?.optLong("ms") ?: 0L

    fun addTime(pkg: String, ms: Long) = update(pkg) { it.put("ms", it.optLong("ms") + ms) }

    fun addOpen(pkg: String) = update(pkg) { it.put("o", it.optInt("o") + 1) }

    fun isExtended(pkg: String) = p.getLong("ext_until_$pkg", 0L) > System.currentTimeMillis()

    /** One "5 more minutes" per app per day. */
    fun canExtend(pkg: String) = p.getString("ext_day_$pkg", null) != today()

    fun extend(pkg: String, minutes: Int) {
        p.edit()
            .putLong("ext_until_$pkg", System.currentTimeMillis() + minutes * 60_000L)
            .putString("ext_day_$pkg", today())
            .apply()
    }

    private fun update(pkg: String, change: (JSONObject) -> Unit) {
        val day = today()
        val u = usage(day)
        val e = u.optJSONObject(pkg) ?: JSONObject()
        change(e)
        u.put(pkg, e)
        p.edit().putString("usage_$day", u.toString()).apply()
    }

    private fun prune() {
        val cal = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -35) }
        val oldest = "usage_" + fmt(cal.time)
        val e = p.edit()
        for (k in p.all.keys) if (k.startsWith("usage_") && k < oldest) e.remove(k)
        e.apply()
    }

    companion object {
        fun today(): String = fmt(Date())

        private fun fmt(d: Date) = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(d)

        fun parse(json: String?): FocusConfig {
            if (json == null) return FocusConfig()
            return runCatching {
                val j = JSONObject(json)
                val apps = mutableMapOf<String, FocusApp>()
                val a = j.optJSONObject("apps") ?: JSONObject()
                for (k in a.keys()) {
                    val e = a.getJSONObject(k)
                    apps[k] = FocusApp(e.optString("name", k), e.optInt("limit", 0))
                }
                FocusConfig(
                    enabled = j.optBoolean("enabled"),
                    apps = apps,
                    sleepBlock = j.optBoolean("sleep"),
                    bedMin = j.optInt("bedMin"),
                    wakeMin = j.optInt("wakeMin"),
                    strict = j.optBoolean("strict"),
                    wakeLabel = j.optString("wakeLabel"),
                )
            }.getOrDefault(FocusConfig())
        }
    }
}
