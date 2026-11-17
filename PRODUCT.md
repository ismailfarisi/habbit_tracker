# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users
People building daily habits who want structure without friction: waking early, sticking to routines, and planning small tasks. Muslim users can turn on prayer tracking (five prayers, Jumu'ah, Ramadan), but it is optional and the app must read as a general habit app without it. Typical moments are short and frequent: a check-off at the alarm, a glance between tasks, a review before bed.

## Product Purpose
Daily Discipline (package `habit_tracker`) helps someone show up every day. Success is that the user opens it briefly several times a day, logs honestly (including past days), and sees real progress over weeks, not a brittle streak that breaks on one miss.

## Positioning
Habits are composed for the user instead of picked from a fixed list: the coach turns a need ("I mumble in meetings") into a habit with its own practice UI, rendered from an app-owned A2UI component catalog. It works fully offline with templates and on-device voice input (Whisper), with AI optional through the user's own OpenRouter key.

## Operating Context
- One-handed phone use, often half-awake (wake alarm, Fajr) or between activities.
- Tabs: Today (cards ordered by what is due next, a Yesterday card for unfinished items), Plan (coach, habits, tasks), Progress (streaks, 30-day grid, weekly review, per-habit charts). Settings sits behind a gear icon.
- Voice: dictation into text fields and "Speak a task"; platform TTS for confirmations and optional coach replies.
- Reminders are local notifications; a full-screen wake alarm and an Android home-screen widget.

## Capabilities and Constraints
- Flutter 3.44.9 (A2UI packages need Dart 3.10+; Flutter 3.47+ breaks `flutter analyze`).
- All data stays on the phone (SharedPreferences, file backups). The only network calls are OpenRouter (with the user's key), the OpenRouter model list, and the one-time Whisper model download.
- Agent-built UI is limited to the app-owned catalog; the model never writes code.
- Ships to Android and iOS. iOS builds are not produced or verified in the current environment.
- Theme: deep teal seed with light and dark schemes; Inter is bundled. Both are earlier user decisions.

## Brand Commitments
- Name: Daily Discipline.
- Deep teal (`#0F766E` seed) with a first-class dark mode, chosen by the user.
- Calm, focused, modern; not loud, not "religious app" in tone.

## Evidence on Hand
No testimonials, user counts, or store ratings exist; none may be invented.

## Product Principles
1. Logging takes one tap; fixing a past day takes two.
2. Forgiving over brittle: streak rules and copy never shame a miss.
3. Works offline and without AI; AI and voice add speed, not access.
4. Each platform feels native: Material 3 on Android, iOS conventions on iPhone, one brand across both.
5. Quiet by default: the next due thing is prominent, everything else steps back.

## Accessibility & Inclusion
- Arabic and English content (Hijri dates, Arabic prayer names, Arabic dictation); layouts must tolerate RTL text and long labels.
- Respect system font scale and dark mode; touch targets 48dp (Android) / 44pt (iOS).
