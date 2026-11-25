# Daily Discipline: your personal Islamic growth companion

*Build better habits. Strengthen your connection with Allah. Improve yourself, one day at a time.* The app encourages consistency, not perfection: a missed day is a day to begin again, and the coach suggests a lighter next step instead of guilt.

A Flutter mobile app (Android and iOS) for waking early, the five prayers and any habit you want to build, plus tasks planned with AI. Everything is stored on the phone; the only network call is to OpenRouter, and only if you add your own key.

- **☀️ Wake up early.** Set a target time and a grace period. A loud full-screen alarm keeps ringing until you tap **I'm up**. An optional **wake challenge** (read a sentence aloud, or solve two maths problems) must be passed before the tap counts.
- **🌙 Sleep.** A sleep goal gives you a bedtime (wake time minus sleep goal) and a wind-down reminder with a **Going to bed** button. The wake card shows how long you slept.
- **🕌 Five daily prayers.** Times are calculated offline from your location, with a choice of calculation method and Hanafi/standard Asr, or entered by hand. Each prayer is marked **On time**, **Late** or **Qada** (tap picks it from the clock, long-press to choose). Today shows the Hijri date. On Fridays Dhuhr becomes **Jumu'ah** with its own time and early reminder. **Ramadan mode** (automatic by Hijri month, or a toggle) adds a suhoor alarm, Iftar and optional Taraweeh. Duha and Witr are optional and never count against the streak.
- **🧩 Agent-built habits.** Tell the coach what you need (*"I mumble in meetings"*, *"drink 2L of water"*, *"read Quran after Fajr"*) and it creates a habit with its own logging or practice screen: counters, timers, read-aloud drills that measure pace and filler words, ratings and trend charts. The chat shows a preview before you add it. Without an AI key you can add the same kind of habit from templates (Articulation practice, Read Quran, Drink water, Exercise).
- **🎯 Goals.** Describe something bigger in Chat (*"memorise Juz Amma in 6 months"*). The AI turns it into a goal with milestones across the timeline and the first weeks of tasks, links habits to it, and looks back with you weekly, monthly or quarterly depending on the goal's length, suggesting adjustments you can apply with a tap.
- **📝 Tasks.** Add them by hand or ask the coach in plain language (*"Gym Monday, Wednesday and Friday at 6pm"*). Every change the coach makes has an **Undo** button. Repeating tasks count as habits in the stats.

## Screens

- **Today.** Cards ordered by what is due next; finished ones collapse under **Done**. In the morning a **Yesterday** card lists what was left unfinished, with one-tap fixes.
- **Plan.** The coach, your habits (add, edit, archive) and your tasks.
- **Progress.** Streak tiles with "N of last 30", a 30-day grid (tap any cell to edit that day), a weekly review computed on the phone (best and worst item, weekday miss pattern, one suggestion) with **Ask coach**, and per-habit charts of minutes and session metrics.
- **Settings** (gear icon). Wake, sleep, prayer times, Ramadan and Jumu'ah, streak rules, reminders, AI key, backup and diagnostics.

First start walks through location, notification permissions, a battery tip, wake time, starter habits and the optional AI key.

Other features:

- **Forgiving streaks.** A habit can use "never miss twice", and perfect-day streaks get a few freezes each month.
- **Android home-screen widget.** Shows the next prayer and today's score, with a **Done** button that marks the prayer without opening the app.
- **Backup.** Export to a file through the share sheet, import from a file, and an automatic daily backup on the phone (last 7 kept, plus a copy before every restore). Android system backup includes the data but not the API key.
- **Diagnostics.** Off by default. When on, the app counts reminders and notification actions and keeps the last 50 errors on the phone; nothing is sent unless you share the report.

## How agent-built habits work (A2UI)

The app uses the [A2UI](https://a2ui.org/) packages `a2ui_core`, `a2ui_flutter` and `a2ui_agent` (the replacements for the deprecated `genui` package), protocol v1.0.

1. The app owns a component catalog (`lib/agent/habit_catalog.dart`): `HabitCheck`, `Counter`, `PracticeTimer`, `ReadAloudDrill`, `PromptCard`, `RatingInput`, `MetricTrend`, `ChoiceChips`, next to the basic A2UI catalog.
2. The coach (`lib/agent/habit_agent.dart`) gets the catalog description in its prompt and has tools such as `create_habit`, `set_habit_ui` and `log_habit`. The model never writes code: it sends A2UI JSON that picks components from the catalog. The JSON is validated before it is saved, and invalid surfaces are rejected.
3. The surface is stored with the habit (`HabitDef.uiSurface`). `HabitSurface` renders it offline on Today, in the day editor and on the habit page, with the day's `HabitEntry` as its data model. Whatever the components write (done, value, minutes, metrics, sessions) is saved for that day and charted in Progress.
4. If a stored surface cannot be rendered, the habit falls back to a plain check, count or timer control.

## Reminders

Reminders are scheduled as local notifications, so they fire even when the app is closed and after a reboot:

| Reminder | When | Action button |
|---|---|---|
| Wake-up alarm | Your target time (exact alarm clock, full-screen, rings until answered) | I'm up (opens the challenge when it is on) |
| Each prayer | At prayer time, or N minutes before | Prayed (counts as on time) |
| Suhoor (Ramadan) | N minutes before Fajr | |
| Jumu'ah (Friday) | N minutes before Jumu'ah | Prayed |
| Bedtime | Wind-down time before bed | Going to bed |
| Habits | The habit's reminder time, skipped once it is done | Open |
| Tasks | The task's time, if it has one | Done |

The schedule covers up to 8 days ahead (the 60 soonest reminders, because iOS allows at most 64 pending) and refreshes every time you open the app or log something. Reminders for things you've already done are skipped. **Settings › Upcoming reminders** lists what is planned.

> **Android tip:** some phones (Xiaomi, Samsung, Oppo…) kill background apps aggressively. If reminders don't fire, set the app's battery usage to **Unrestricted** and allow **Alarms & reminders** in system settings.

## Setup

1. Install Flutter 3.44.9.
2. Run:
   ```sh
   flutter pub get
   flutter run          # with a phone connected or an emulator running
   ```
3. Follow the first-run steps in the app (location, permissions, wake time). The OpenRouter API key from <https://openrouter.ai/keys> is optional; you can add it later in **Settings**.

The model defaults to `openai/gpt-4o-mini`, which is cheap and good enough. You can enter any model ID from <https://openrouter.ai/models>. Creating tasks needs a model that supports **tool calling**; most do, but some free models don't, and the app tells you if so. The API key is stored encrypted on the device and sent only to `openrouter.ai`.

### Get the APK without installing Flutter

Every push builds the app with GitHub Actions and publishes it to the **Latest build** release:

<https://github.com/ismailfarisi/habbit_tracker/releases/tag/latest-build>

Open that page on your phone, download `daily-discipline.apk`, and open it to install. Android asks you to allow installs from your browser the first time.

## Project layout

```
lib/
  main.dart                     app start, onboarding or home, notification routing
  app_state.dart                state + persistence + rescheduling
  models.dart                   Settings, DayLog
  habits/habit.dart             HabitDef, HabitEntry (generic habit model)
  agent/habit_catalog.dart      A2UI catalog of habit components + surface validation
  agent/habit_components.dart   the catalog's widgets (Counter, PracticeTimer, ReadAloudDrill…)
  agent/habit_surface.dart      HabitSurface: renders a habit's stored A2UI surface, saves its entry
  agent/habit_agent.dart        AI coach tools: create/update/log habits, set their UI
  agent/habit_templates.dart    offline seed habits as A2UI JSON
  logic/stats.dart              habit completion, streak rules, consistency, daily score
  logic/weekly_review.dart      weekly review computed on the phone
  logic/prayer_status.dart      on time / late / qada, Jumu'ah, Ramadan, optional prayers
  logic/hijri.dart              Hijri date
  logic/sleep.dart              bedtime, wind-down, sleep duration
  logic/wake_challenge.dart     wake phrases, fuzzy match, maths problems
  logic/speech_metrics.dart     pace, fillers, recognition accuracy
  logic/tasks.dart              task scheduling (one-off / daily / weekly)
  services/prayer_service.dart  offline prayer times (adhan)
  services/reminders.dart       pure reminder planning
  services/notification_service.dart  scheduling, alarm channel, background actions
  services/home_widget_service.dart   data and Done action for the Android widget
  services/backup_service.dart  file export/import, automatic daily backups
  services/diagnostics.dart     opt-in local counters and error log
  services/storage.dart         SharedPreferences storage, backup JSON v2 (reads v1)
  services/openrouter.dart      streaming OpenRouter client with tool calling + agent loop
  services/task_tools.dart      AI tools: create/list/update/complete/delete tasks
  services/coach_prompts.dart   coach system prompt and feedback prompts
  widgets/assistant_chat.dart   AI chat with task/habit actions, undo and inline habit previews
  widgets/cards/                Today cards (wake, prayer, habit, tasks)
  widgets/day_editor.dart       edit any past day
  widgets/yesterday_prompt.dart morning card for yesterday's unfinished items
  widgets/charts.dart           line and bar charts
  screens/                      onboarding, Today, Plan, Progress, Settings, reminders,
                                diagnostics, wake challenge, habit detail
android/.../PrayerWidgetProvider.kt   the home-screen widget
test/                           unit and widget tests
```

Run the checks with `flutter analyze` and `flutter test`. The tests use fakes and never call the network.
