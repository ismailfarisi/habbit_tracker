# Daily Discipline: habit tracker

A Flutter mobile app (Android and iOS) for three daily habits, plus tasks planned with AI:

- **☀️ Wake up early.** Set a target time and a grace period. A loud full-screen alarm keeps ringing until you tap **I'm up**, and that tap is logged.
- **🕌 Five daily prayers.** Fajr, Dhuhr, Asr, Maghrib and Isha times are calculated offline from your location, with a choice of calculation method and Hanafi/standard Asr. You can also enter manual times to match your mosque. Each prayer gets a reminder, and you can mark it **Prayed** straight from the notification.
- **🗣️ Articulation training with an AI coach (OpenRouter).** The coach generates tongue twisters, read-aloud passages, minimal pairs, impromptu topics or interview questions. You speak, the app transcribes you, and it measures your pace (words/min), filler words, and how many of the target words were recognized. The AI then scores you and gives targeted drills. You can also chat with the coach. A session timer logs your minutes against a daily goal.
- **📝 Tasks the AI creates for you.** Type what you want in plain language on the **Tasks** tab, e.g. *"Read Quran 20 minutes after Fajr every day"*, *"Remind me to call my mother tomorrow at 8pm"* or *"Gym Monday, Wednesday and Friday at 6pm"*. The AI creates the tasks with reminder times. It knows today's date, your wake time and your prayer times, so "after Fajr" turns into a real time. It can also list, reschedule, complete and delete tasks. Every change it makes shows in the chat with an **Undo** button. The speech coach can create tasks too, e.g. *"schedule a 10-minute drill every evening at 9pm"*. You can also add and edit tasks by hand: one-off, daily or weekly, with or without a reminder.

The app also has streaks (current and best), a 30-day history grid, and backup export/import.

## Reminders

Reminders are scheduled as local notifications, so they fire even when the app is closed and after a reboot:

| Reminder | When | Action button |
|---|---|---|
| Wake-up alarm | Your target time (exact alarm clock, full-screen, rings until answered) | I'm up |
| Each prayer | At prayer time, or N minutes before | Prayed |
| Training | Your chosen time, skipped once the goal is met | Open coach |
| Tasks | The task's time, if it has one | Done |

The schedule covers up to 8 days ahead (the 60 soonest reminders, because iOS allows at most 64 pending) and refreshes every time you open the app or log something. Reminders for things you've already done are skipped.

> **Android tip:** some phones (Xiaomi, Samsung, Oppo…) kill background apps aggressively. If reminders don't fire, set the app's battery usage to **Unrestricted** and allow **Alarms & reminders** in system settings.

## Setup

1. Install Flutter 3.35 or newer.
2. Run:
   ```sh
   flutter pub get
   flutter run          # with a phone connected or an emulator running
   ```
3. In the app, open **Settings** and:
   - tap **Use my current location** (for prayer times),
   - tap **Grant permissions** (for notifications and exact alarms),
   - paste your OpenRouter API key from <https://openrouter.ai/keys> and tap **Save & test**.

The model defaults to `openai/gpt-4o-mini`, which is cheap and good enough. You can enter any model ID from <https://openrouter.ai/models>. Creating tasks needs a model that supports **tool calling**; most do, but some free models don't, and the app tells you if so. The API key is stored encrypted on the device and sent only to `openrouter.ai`.

### Get the APK without installing Flutter

Every push builds the app with GitHub Actions and publishes it to the **Latest build** release:

<https://github.com/ismailfarisi/habbit_tracker/releases/tag/latest-build>

Open that page on your phone, download `daily-discipline.apk`, and open it to install. Android asks you to allow installs from your browser the first time.

## Project layout

```
lib/
  main.dart                     app start, notification tap handling
  app_state.dart                state + persistence + rescheduling
  models.dart                   Settings, DayLog
  logic/stats.dart              scoring, streaks
  logic/speech_metrics.dart     pace, fillers, recognition accuracy
  logic/tasks.dart              task scheduling (one-off / daily / weekly)
  services/prayer_service.dart  offline prayer times (adhan)
  services/reminders.dart       pure reminder planning
  services/notification_service.dart  scheduling, alarm channel, background actions
  services/openrouter.dart      streaming OpenRouter client with tool calling + agent loop
  services/task_tools.dart      AI tools: create/list/update/complete/delete tasks
  services/coach_prompts.dart   coach system prompt, exercise and feedback prompts
  widgets/assistant_chat.dart   AI chat with task actions and undo
  screens/                      Today, Tasks, Train, Stats, Settings
test/                           unit and widget tests
```

Run the tests with `flutter test`.
