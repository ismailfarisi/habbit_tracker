package com.ismailfarisi.habit_tracker

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONException
import org.json.JSONObject

/**
 * Home-screen widget: the prayer to pray now (or the next one), its time, today's score and a
 * "Done" button. The app writes a timeline of slots (lib/services/home_widget_service.dart); this
 * draws the slot for the current time.
 */
class PrayerWidgetProvider : HomeWidgetProvider() {
  override fun onUpdate(
      context: Context,
      appWidgetManager: AppWidgetManager,
      appWidgetIds: IntArray,
      widgetData: SharedPreferences,
  ) {
    val slot = currentSlot(widgetData.getString(DATA_KEY, null), System.currentTimeMillis())
    for (id in appWidgetIds) {
      val views = RemoteViews(context.packageName, R.layout.prayer_widget)
      views.setOnClickPendingIntent(
          R.id.widget_root,
          HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java),
      )
      if (slot == null) {
        views.setTextViewText(R.id.widget_label, context.getString(R.string.prayer_widget_name))
        views.setTextViewText(R.id.widget_prayer, context.getString(R.string.prayer_widget_open_app))
        views.setTextViewText(R.id.widget_time, "")
        views.setTextViewText(R.id.widget_score, "")
        views.setViewVisibility(R.id.widget_done, View.GONE)
      } else {
        views.setTextViewText(R.id.widget_label, slot.optString("label"))
        views.setTextViewText(R.id.widget_prayer, slot.optString("prayer"))
        views.setTextViewText(R.id.widget_time, slot.optString("time"))
        views.setTextViewText(R.id.widget_score, slot.optString("score"))
        val payload = slot.optString("payload")
        if (payload.isEmpty()) {
          views.setViewVisibility(R.id.widget_done, View.GONE)
        } else {
          val uri =
              Uri.Builder()
                  .scheme("dailydiscipline")
                  .authority("done")
                  .appendQueryParameter("payload", payload)
                  .build()
          views.setViewVisibility(R.id.widget_done, View.VISIBLE)
          views.setOnClickPendingIntent(
              R.id.widget_done,
              HomeWidgetBackgroundIntent.getBroadcast(context, uri),
          )
        }
      }
      appWidgetManager.updateAppWidget(id, views)
    }
  }

  companion object {
    const val DATA_KEY = "prayer_widget"

    /** The last slot that started at or before [now], or null if there is none or they ran out. */
    fun currentSlot(json: String?, now: Long): JSONObject? {
      if (json == null) return null
      return try {
        val data = JSONObject(json)
        if (now >= data.optLong("until", Long.MAX_VALUE)) return null
        val slots = data.getJSONArray("slots")
        var current: JSONObject? = null
        for (i in 0 until slots.length()) {
          val slot = slots.getJSONObject(i)
          if (slot.getLong("from") <= now) current = slot
        }
        current ?: if (slots.length() > 0) slots.getJSONObject(0) else null
      } catch (e: JSONException) {
        null
      }
    }
  }
}
