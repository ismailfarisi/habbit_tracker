import '../logic/speech_metrics.dart';

const coachSystemPrompt = '''
You are a warm, expert speech and articulation coach. You help the user speak
more clearly: crisp consonants, open vowels, steady pace, good breath support,
fewer filler words, and confident delivery.

Guidelines:
- Be concise and practical. Use short paragraphs and bullet points.
- Give concrete drills the user can do right now (e.g. "Say 'red lorry,
  yellow lorry' 5 times slowly, exaggerating the R and L").
- When reviewing a transcript produced by speech recognition, remember that
  misrecognized words often mean the word was not articulated clearly. Point
  out the specific sounds involved.
- Encourage the user, but be honest about what to improve.
''';

const coachTaskPrompt = '''
You can also manage the user's tasks with tools (create_task, list_tasks,
update_task, complete_task, delete_task). When the user asks you to schedule
practice, build a plan, or remind them of something, create the tasks with
sensible times, so they get reminders. Avoid clashing with prayer times.
Call list_tasks before changing or deleting a task.
''';

enum ExerciseType {
  twister('Tongue twisters', readAloud: true),
  reading('Reading passage', readAloud: true),
  minimal('Minimal pairs', readAloud: true),
  impromptu('Impromptu speech', readAloud: false),
  interview('Interview practice', readAloud: false);

  final String label;

  /// Whether the user reads the exercise text verbatim (so we can measure
  /// how much of it the recognizer heard).
  final bool readAloud;
  const ExerciseType(this.label, {required this.readAloud});
}

String exercisePrompt(ExerciseType type, String level, String focus) {
  final f = focus.trim().isEmpty ? '' : ' Focus especially on these sounds: $focus.';
  final body = switch (type) {
    ExerciseType.twister =>
      'Write 4 tongue twisters for $level articulation practice.$f Number them. Put each twister on its own line with no commentary, then add one line at the end with a tip on how to practise them.',
    ExerciseType.reading =>
      'Write a short passage (80-120 words) for $level read-aloud articulation practice, rich in varied consonant clusters.$f Output only the passage, then one line starting with "Tip:".',
    ExerciseType.minimal =>
      'Write 8 minimal-pair sentences for $level practice that contrast commonly confused sounds.$f Put each sentence on its own line. Output only the sentences.',
    ExerciseType.impromptu =>
      'Give me one interesting impromptu speaking topic suitable for a 60-90 second talk at $level level. Include the topic on the first line, then 3 short bullet points I could cover. Keep it brief.',
    ExerciseType.interview =>
      'Ask me one realistic interview or conversation question to answer out loud for about a minute ($level level). Output only the question and one line of advice on structuring the answer.',
  };
  return body;
}

String feedbackPrompt({
  required ExerciseType type,
  required String exercise,
  required String transcript,
  required SpeechMetrics metrics,
}) =>
    '''
Please review my articulation practice.

Exercise type: ${type.label}
${exercise.trim().isEmpty ? '' : 'Exercise text:\n"""\n${exercise.trim()}\n"""\n'}
What the speech recognizer heard me say:
"""
${transcript.trim()}
"""

Measured: ${metrics.describe()}

Give me:
1. A score out of 10 for clarity and one for pace.
2. The 2-3 most important things to improve, naming the specific sounds or words.
3. One targeted drill for each, which I can do right now.
4. One thing I did well.
''';
