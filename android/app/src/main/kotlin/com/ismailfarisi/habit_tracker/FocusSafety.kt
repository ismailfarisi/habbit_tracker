package com.ismailfarisi.habit_tracker

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.provider.Settings
import android.provider.Telephony
import android.telecom.TelecomManager

/** Also enforced on restored app lists, which may predate the picker filter. */
object FocusSafety {
    fun excluded(context: Context): Set<String> = buildSet {
        add(context.packageName)
        add("android")
        add("com.android.systemui")
        add("com.android.phone")
        val pm = context.packageManager
        val telecom = context.getSystemService(TelecomManager::class.java)
        telecom?.defaultDialerPackage?.let(::add)
        telecom?.systemDialerPackage?.let(::add)
        Telephony.Sms.getDefaultSmsPackage(context)?.let(::add)
        Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
            ?.let { ComponentName.unflattenFromString(it)?.packageName }?.let(::add)
        val intents = listOf(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME),
            Intent(Intent.ACTION_DIAL),
            Intent("android.intent.action.DIAL_EMERGENCY"),
            Intent("android.content.pm.action.REQUEST_PERMISSIONS"),
            Intent(Settings.ACTION_SETTINGS),
            Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS),
            Intent("android.telephony.action.EMERGENCY_ASSISTANCE"),
        )
        for (intent in intents) {
            pm.queryIntentActivities(intent, 0).forEach { add(it.activityInfo.packageName) }
        }
        pm.queryIntentServices(Intent("android.telecom.InCallService"), 0).forEach { add(it.serviceInfo.packageName) }
    }
}
