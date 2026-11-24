package com.ismailfarisi.habit_tracker

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FocusRulesTest {
    private val yt = "com.google.android.youtube"
    private val cfg = FocusConfig(
        enabled = true,
        apps = mapOf(yt to FocusApp("YouTube", 30), "sleep.only" to FocusApp("Reels", 0)),
        sleepBlock = true,
        bedMin = 22 * 60 + 30,
        wakeMin = 5 * 60,
    )

    @Test
    fun sleepWindowCrossesMidnight() {
        assertTrue(FocusRules.inSleep(23 * 60, 22 * 60 + 30, 5 * 60))
        assertTrue(FocusRules.inSleep(2 * 60, 22 * 60 + 30, 5 * 60))
        assertFalse(FocusRules.inSleep(5 * 60, 22 * 60 + 30, 5 * 60))
        assertFalse(FocusRules.inSleep(12 * 60, 22 * 60 + 30, 5 * 60))
        assertTrue(FocusRules.inSleep(60, 30, 5 * 60))
        assertFalse(FocusRules.inSleep(20, 30, 5 * 60))
    }

    @Test
    fun pausesAfterTheLimitAndDuringSleep() {
        val noon = 12 * 60
        assertNull(FocusRules.reason(cfg, yt, noon, 29 * 60_000L, false))
        assertEquals(PauseReason.LIMIT, FocusRules.reason(cfg, yt, noon, 30 * 60_000L, false))
        assertEquals(PauseReason.SLEEP, FocusRules.reason(cfg, yt, 23 * 60, 0, false))
        assertNull(FocusRules.reason(cfg, "sleep.only", noon, 600 * 60_000L, false))
        assertEquals(PauseReason.SLEEP, FocusRules.reason(cfg, "sleep.only", 23 * 60, 0, false))
    }

    @Test
    fun extraMinutesOtherAppsAndOffAreNeverPaused() {
        assertNull(FocusRules.reason(cfg, yt, 23 * 60, 90 * 60_000L, true))
        assertNull(FocusRules.reason(cfg, "com.other", 23 * 60, 90 * 60_000L, false))
        assertNull(FocusRules.reason(cfg.copy(enabled = false), yt, 23 * 60, 90 * 60_000L, false))
        assertNull(FocusRules.reason(cfg.copy(sleepBlock = false), yt, 23 * 60, 0, false))
    }
}
