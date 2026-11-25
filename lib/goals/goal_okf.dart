import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../habits/habit.dart';
import '../logic/stats.dart';
import '../logic/tasks.dart';
import '../models.dart';
import '../quran/quran.dart';
import 'goal.dart';
import 'goal_outcomes.dart';

/// One thing a goal has planned on a day.
class GoalDayItem {
  final String title;
  final String detail;
  final bool done;
  final HabitDef? habit;
  final Task? task;
  final Milestone? milestone;
  const GoalDayItem(this.title, {this.detail = '', this.done = false, this.habit, this.task, this.milestone});
}

const _allPlanned = "All planned sessions covered; plan more in the goal's chat";

String _sessionLabel((int, int, String)? s) => s == null ? '' : 'Session ${s.$1}/${s.$2}: ${s.$3}';

/// What [g] has planned on [day], as of today: future days assume every
/// day before them is done, so they shift when one is missed.
List<GoalDayItem> goalPlanFor(AppState s, Goal g, DateTime day, {DateTime? today}) {
  final d = dateOnly(day);
  final items = <GoalDayItem>[];
  for (final h in s.habits.where((h) => g.habitIds.contains(h.id))) {
    if (h.archived || !h.isScheduledOn(d)) continue;
    final q = s.quranFor(h, d, today: today);
    items.add(
      GoalDayItem(
        h.title,
        detail: [
          if (q != null) passageLabel(q.surah, q.from, q.to),
          _sessionLabel(s.sessionForHabit(h, d, today: today)),
          if ((h.guide?.sessions ?? const []).isNotEmpty && s.sessionForHabit(h, d, today: today) == null) _allPlanned,
        ].where((e) => e.isNotEmpty).join(' · '),
        done: habitDone(s.habitEntry(d, h.id), h),
        habit: h,
      ),
    );
  }
  final tasks = s.tasks.where((t) => g.taskIds.contains(t.id)).toList();
  for (final t in tasksForDay(tasks, d, today: today ?? dateOnly(DateTime.now()))) {
    final q = s.quranForTask(t, d, today: today);
    items.add(
      GoalDayItem(
        t.title,
        detail: [
          if (q != null) passageLabel(q.surah, q.from, q.to),
          _sessionLabel(s.sessionForTask(t, d, today: today)),
          if (t.isRepeating && (t.guide?.sessions ?? const []).isNotEmpty && s.sessionForTask(t, d, today: today) == null) _allPlanned,
        ].where((e) => e.isNotEmpty).join(' · '),
        done: t.isDoneOn(d),
        task: t,
      ),
    );
  }
  for (final m in g.milestones.where((m) => m.due == dayKey(d))) {
    items.add(GoalDayItem('Milestone: ${m.title}', done: m.done, milestone: m));
  }
  return items;
}

/// A file-name-safe slug for [g].
String okfSlug(Goal g) {
  final s = g.title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
  return s.isEmpty ? g.id : s;
}

String _q(String s) => '"${s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', ' ')}"';

String _box(bool done) => done ? '[x]' : '[ ]';

/// The goal's context as an Open Knowledge Format concept document:
/// Markdown with a YAML frontmatter block (https://okf.md/spec/). It is what
/// the goal's chat loads, and what the user can read or export.
String goalOkf(AppState s, Goal g, DateTime now) {
  final today = dateOnly(now);
  final f = DateFormat('EEE d MMM y');
  final habits = s.habits.where((h) => g.habitIds.contains(h.id)).toList();
  final tasks = s.tasks.where((t) => g.taskIds.contains(t.id)).toList();
  final outcomes = goalOutcomes(s, g, now);
  final b = StringBuffer()
    ..writeln('---')
    ..writeln('type: Goal')
    ..writeln('title: ${_q(g.title)}');
  if (g.why.trim().isNotEmpty) b.writeln('description: ${_q(g.why.trim())}');
  b
    ..writeln('tags: [goal, ${_q(g.horizon)}]')
    ..writeln('timestamp: ${now.toUtc().toIso8601String()}')
    ..writeln('id: ${g.id}')
    ..writeln('status: ${g.archived ? 'archived' : 'active'}')
    ..writeln('start: ${g.start}')
    ..writeln('end: ${g.end}')
    ..writeln('review: ${g.cadence.name}')
    ..writeln('outcomes: ${_q(outcomes.map((o) => o.label).join('; '))}')
    ..writeln('time_passed: ${(g.elapsed(now) * 100).round()}%')
    ..writeln('---')
    ..writeln()
    ..writeln('# ${g.emoji} ${g.title}')
    ..writeln();
  if (g.why.trim().isNotEmpty) {
    b
      ..writeln('## Why')
      ..writeln()
      ..writeln(g.why.trim())
      ..writeln();
  }
  b
    ..writeln('## Timeline')
    ..writeln()
    ..writeln('${f.format(g.startDate)} → ${f.format(g.endDate)} (${g.horizon}). '
        '${(g.elapsed(now) * 100).round()}% of the time passed.')
    ..writeln()
    ..writeAll(outcomes.map((o) => '- ${o.label}\n'))
    ..writeln()
    ..writeln('## Milestones')
    ..writeln();
  if (g.milestones.isEmpty) b.writeln('None yet.');
  for (final m in g.milestones) {
    b.writeln('- ${_box(m.done)} ${m.title}${m.due == null ? '' : ' (by ${m.due})'}');
  }
  b.writeln();
  if (habits.isNotEmpty) {
    b
      ..writeln('## Daily practice')
      ..writeln();
    for (final h in habits) {
      final gd = h.guide;
      final done = s.habitDaysDoneBefore(h, today.add(const Duration(days: 1)));
      b
        ..writeln('### ${h.title}')
        ..writeln()
        ..writeln('- Schedule: ${h.describeSchedule()}${gd?.minutes == null ? '' : ', about ${gd!.minutes} min'}')
        ..writeln('- Days done: $done');
      final q = s.quranFor(h, today);
      if (q != null) b.writeln("- Today's portion: ${passageLabel(q.surah, q.from, q.to)} (${q.mode})");
      if (gd != null && gd.doneWhen.isNotEmpty) b.writeln('- Done when: ${gd.doneWhen}');
      if (gd != null && gd.steps.isNotEmpty) {
        b
          ..writeln()
          ..writeln('Steps:')
          ..writeln();
        for (final (i, x) in gd.steps.indexed) {
          b.writeln('${i + 1}. $x');
        }
      }
      if (gd != null && gd.sessions.isNotEmpty) {
        final cur = s.habitSessionsBefore(h, today) - gd.sessionStart;
        b
          ..writeln()
          ..writeln('Sessions:')
          ..writeln();
        for (final (i, x) in gd.sessions.indexed) {
          b.writeln('- ${_box(i < done - gd.sessionStart)} ${i + 1}. $x${i == cur ? ' ← today' : ''}');
        }
      }
      b.writeln();
    }
  }
  b
    ..writeln('## Tasks')
    ..writeln();
  if (tasks.isEmpty) b.writeln('None linked.');
  for (final t in tasks) {
    final when = t.isRepeating ? '${t.repeat.name}, done ${t.doneDates.length} times' : (t.date == null ? 'no date' : 'on ${t.date}');
    b.writeln('- ${_box(t.isDoneOn(today))} ${t.title} ($when)');
    final gd = t.guide;
    if (gd != null && gd.doneWhen.isNotEmpty) b.writeln('  - Done when: ${gd.doneWhen}');
  }
  b
    ..writeln()
    ..writeln('## Plan for the next 7 days')
    ..writeln()
    ..writeln('As planned today; later days move when one is missed.')
    ..writeln();
  for (var i = 0; i < 7; i++) {
    final d = today.add(Duration(days: i));
    final items = goalPlanFor(s, g, d, today: today);
    if (items.isEmpty) continue;
    b.writeln('- **${i == 0 ? 'Today' : f.format(d)}**');
    for (final it in items) {
      b.writeln('  - ${_box(it.done)} ${it.title}${it.detail.isEmpty ? '' : ' — ${it.detail}'}');
    }
  }
  b
    ..writeln()
    ..writeln('## Last 7 days')
    ..writeln();
  for (var i = 7; i >= 1; i--) {
    final d = today.subtract(Duration(days: i));
    final items = goalPlanFor(s, g, d, today: today);
    if (items.isEmpty) continue;
    b.writeln('- ${dayKey(d)}: ${items.where((x) => x.done).length}/${items.length} done'
        '${items.any((x) => !x.done) ? ' (missed: ${items.where((x) => !x.done).map((x) => x.title).join(', ')})' : ''}');
  }
  if (g.reviews.isNotEmpty) {
    b
      ..writeln()
      ..writeln('## Reviews')
      ..writeln();
    for (final r in g.reviews) {
      b.writeln('### ${dayKey(r.at)}');
      b
        ..writeln()
        ..writeln(r.summary)
        ..writeln();
      for (final (i, x) in r.suggestions.indexed) {
        final milestone = g.milestones.where((m) => m.id == r.milestoneLinks[i]).firstOrNull;
        b.writeln('- ${_box(milestone != null)} $x${milestone == null ? '' : ' → ${milestone.title}'}');
      }
      b.writeln();
    }
  }
  final shared = g.noteEntries.where((n) => n.shared);
  final dated = shared.where((n) => n.changedOn != null).toList()
    ..sort((a, b) => b.changedOn!.compareTo(a.changedOn!));
  b
    ..writeln()
    ..writeln('## Notes')
    ..writeln();
  if (shared.isEmpty) b.writeln('None shared.');
  for (final n in shared.where((n) => n.changedOn == null)) {
    b..writeln(n.text)..writeln();
  }
  if (dated.isNotEmpty) {
    b..writeln('### Latest assumption updates')..writeln();
    for (final n in dated) {
      b..writeln('${n.changedOn} · ${n.text}')..writeln();
    }
  }
  return b.toString();
}

/// The bundle's `index.md`: one entry per goal.
String okfIndex(AppState s, DateTime now) {
  final b = StringBuffer()
    ..writeln('# Goals')
    ..writeln()
    ..writeln('Exported ${now.toUtc().toIso8601String()} from Daily Discipline.')
    ..writeln();
  for (final g in s.goals) {
    b.writeln('- [${g.title}](goals/${okfSlug(g)}.md)${g.why.isEmpty ? '' : ' — ${g.why}'}${g.archived ? ' (archived)' : ''}');
  }
  return b.toString();
}

/// The bundle's `log.md`: goal starts and reviews, newest first.
String okfLog(AppState s) {
  final entries = <(String, String)>[
    for (final g in s.goals) ...[
      (g.start, 'Started [${g.title}](goals/${okfSlug(g)}.md)'),
      for (final r in g.reviews) (dayKey(r.at), 'Reviewed [${g.title}](goals/${okfSlug(g)}.md): ${r.summary}'),
    ],
  ]..sort((a, b) => b.$1.compareTo(a.$1));
  return '# Log\n\n${entries.map((e) => '## ${e.$1}\n\n${e.$2}\n').join('\n')}';
}

/// All goals as an OKF bundle: `index.md`, `log.md` and `goals/<slug>.md`.
Map<String, String> okfBundle(AppState s, DateTime now) {
  final out = {'index.md': okfIndex(s, now), 'log.md': okfLog(s)};
  for (final g in s.goals) {
    var name = 'goals/${okfSlug(g)}.md';
    if (out.containsKey(name)) name = 'goals/${okfSlug(g)}-${g.id}.md';
    out[name] = goalOkf(s, g, now);
  }
  return out;
}

/// Zips the bundle and opens the share sheet.
Future<void> shareOkfBundle(AppState s) async {
  final archive = Archive();
  for (final e in okfBundle(s, DateTime.now()).entries) {
    archive.addFile(ArchiveFile.string('goals-okf/${e.key}', e.value));
  }
  final dir = await getTemporaryDirectory();
  final f = File('${dir.path}/goals-okf.zip');
  await f.writeAsBytes(Uint8List.fromList(ZipEncoder().encode(archive)));
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path, mimeType: 'application/zip')], subject: 'Goals (Open Knowledge Format)'));
}
