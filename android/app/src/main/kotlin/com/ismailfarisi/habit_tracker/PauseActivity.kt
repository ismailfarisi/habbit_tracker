package com.ismailfarisi.habit_tracker

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Full-screen pause shown over a chosen app when its daily limit is used up or during sleep
 * time. "Close" goes to the home screen; "5 more minutes" (once per app per day, not in strict
 * mode) unlocks after a short wait. Verses are the Tanzil Uthmani text bundled with the app and
 * the Saheeh International translation.
 */
class PauseActivity : Activity() {
    private val handler = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val pkg = intent.getStringExtra(PKG) ?: return finish()
        val name = intent.getStringExtra(NAME) ?: pkg
        val sleep = intent.getStringExtra(REASON) == PauseReason.SLEEP.name
        val limit = intent.getIntExtra(LIMIT, 0)
        val wake = intent.getStringExtra(WAKE).orEmpty()

        val col = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(28), dp(72), dp(28), dp(40))
        }
        col.addView(text(if (sleep) "Time to rest" else "Time to pause", 30f, FG, bold = true))
        col.addView(
            text(
                if (sleep) "It's your sleep time. $name opens again at $wake."
                else "You've used your $limit min of $name for today.",
                17f, MUTED, top = 12,
            ),
        )
        val (arabic, english, ref) = if (sleep) VERSE_SLEEP else VERSE_LIMIT
        col.addView(text(arabic, 26f, FG, top = 40).apply { textDirection = View.TEXT_DIRECTION_RTL })
        col.addView(text("“$english”", 16f, MUTED, top = 12).apply { setTypeface(typeface, Typeface.ITALIC) })
        col.addView(text(ref, 13f, ACCENT, top = 6))
        col.addView(
            text(
                if (sleep) "Put the phone down, read the last two ayat of Al-Baqarah and rest well."
                else "Take a minute for dhikr instead: SubḥānAllāh, Alḥamdulillāh, Allāhu akbar.",
                15f, MUTED, top = 28,
            ),
        )
        col.addView(button("Close $name", filled = true, top = 40) { goHome() })
        col.addView(button("Open Daily Discipline", filled = false, top = 12) {
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            finish()
        })
        if (intent.getBooleanExtra(CAN_EXTEND, false)) {
            val more = button("", filled = false, top = 4) {
                FocusStore(this).extend(pkg, EXTRA_MINUTES)
                packageManager.getLaunchIntentForPackage(pkg)?.let {
                    startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }
                finish()
            }.apply { isEnabled = false }
            col.addView(more)
            var left = WAIT_SECONDS
            val countdown = object : Runnable {
                override fun run() {
                    more.text = if (left > 0) "$EXTRA_MINUTES more minutes ($left)" else "$EXTRA_MINUTES more minutes"
                    more.isEnabled = left <= 0
                    more.alpha = if (left > 0) 0.5f else 1f
                    if (left-- > 0) handler.postDelayed(this, 1000)
                }
            }
            countdown.run()
        }
        setContentView(ScrollView(this).apply {
            setBackgroundColor(BG)
            isFillViewport = true
            addView(col)
        })
        window.statusBarColor = BG
        window.navigationBarColor = BG
    }

    override fun onDestroy() {
        handler.removeCallbacksAndMessages(null)
        super.onDestroy()
    }

    @Deprecated("Back goes home rather than into the paused app.")
    override fun onBackPressed() = goHome()

    private fun goHome() {
        startActivity(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        finish()
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun text(s: String, sp: Float, color: Int, top: Int = 0, bold: Boolean = false) = TextView(this).apply {
        text = s
        setTextSize(TypedValue.COMPLEX_UNIT_SP, sp)
        setTextColor(color)
        gravity = Gravity.CENTER
        if (bold) setTypeface(typeface, Typeface.BOLD)
        setLineSpacing(0f, 1.25f)
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    }

    private fun button(label: String, filled: Boolean, top: Int, onClick: () -> Unit) = Button(this).apply {
        text = label
        isAllCaps = false
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
        setTextColor(if (filled) ON_ACCENT else ACCENT)
        background = if (filled) GradientDrawable().apply {
            cornerRadius = dp(999).toFloat()
            setColor(ACCENT)
        } else null
        stateListAnimator = null
        minHeight = dp(52)
        setOnClickListener { onClick() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) }
    }

    companion object {
        const val PKG = "pkg"
        const val NAME = "name"
        const val REASON = "reason"
        const val LIMIT = "limit"
        const val WAKE = "wake"
        const val CAN_EXTEND = "canExtend"
        const val EXTRA_MINUTES = 5
        const val WAIT_SECONDS = 10

        private val BG = Color.parseColor("#0B0F0E")
        private val FG = Color.parseColor("#E9F0EE")
        private val MUTED = Color.parseColor("#A9B8B5")
        private val ACCENT = Color.parseColor("#80D5CB")
        private val ON_ACCENT = Color.parseColor("#003733")

        private val VERSE_LIMIT = Triple(
            "ٱلَّذِينَ ءَامَنُوا۟ وَتَطْمَئِنُّ قُلُوبُهُم بِذِكْرِ ٱللَّهِ أَلَا بِذِكْرِ ٱللَّهِ تَطْمَئِنُّ ٱلْقُلُوبُ",
            "Those who have believed and whose hearts are assured by the remembrance of Allah. Unquestionably, by the remembrance of Allah hearts are assured.",
            "Ar-Ra'd 13:28",
        )
        private val VERSE_SLEEP = Triple("وَجَعَلْنَا نَوْمَكُمْ سُبَاتًا", "And made your sleep [a means for] rest", "An-Naba 78:9")
    }
}
