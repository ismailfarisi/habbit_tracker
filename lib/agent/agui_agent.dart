import 'dart:async';
import 'dart:convert';

import 'package:ag_ui/ag_ui.dart' as agui;

import '../app_state.dart';
import '../services/openrouter.dart';
import '../services/task_tools.dart';
import 'habit_agent.dart';
import 'coach_access.dart';

/// The on-device agent exposed as an AG-UI event stream. The chat screen
/// only consumes standard AG-UI events (run, text message and tool call
/// events), so a remote AG-UI server could stand in for it later.
class LocalAgUiAgent {
  final AppState state;
  final OpenRouterClient Function()? client;

  /// Things the events refer to by tool call id: undo actions and habit
  /// proposals (rendered as A2UI previews).
  final activities = <String, List<ToolActivity>>{};
  final proposals = <String, List<HabitProposal>>{};

  LocalAgUiAgent(this.state, {this.client});

  Stream<agui.BaseEvent> run({
    required String threadId,
    required List<ChatMessage> history,
    required String system,
    CoachAccess? access,
    ReviewChanges? review,
    bool replyOnly = false,
    void Function()? checkActive,
  }) {
    final out = StreamController<agui.BaseEvent>();
    final runId = 'run-${DateTime.now().microsecondsSinceEpoch}';
    var n = 0;
    String? open;
    String? call;
    void closeText() {
      if (open != null) out.add(agui.TextMessageEndEvent(messageId: open!));
      open = null;
    }

    activities.clear();
    proposals.clear();
    final agent = HabitAgent(
      state,
      client: client,
      access: access ?? CoachAccess(state),
      onActivity: (a) => call == null ? null : (activities[call!] ??= []).add(a),
      onProposal: (p) => call == null ? null : (proposals[call!] ??= []).add(p),
    );
    Future<void> go() async {
      out.add(agui.RunStartedEvent(threadId: threadId, runId: runId));
      try {
        await agent.run(
          history,
          system: system,
          review: review,
          replyOnly: replyOnly,
          checkActive: checkActive,
          onText: (delta) {
            if (delta.isEmpty) return;
            if (open == null) {
              open = '$runId-m${n++}';
              out.add(agui.TextMessageStartEvent(messageId: open!));
            }
            out.add(agui.TextMessageContentEvent(messageId: open!, delta: delta));
          },
          onToolStart: (c) {
            closeText();
            call = c.id;
            activities.remove(c.id);
            proposals.remove(c.id);
            out
              ..add(agui.ToolCallStartEvent(toolCallId: c.id, toolCallName: c.name))
              ..add(agui.ToolCallArgsEvent(toolCallId: c.id, delta: c.arguments.isEmpty ? '{}' : c.arguments))
              ..add(agui.ToolCallEndEvent(toolCallId: c.id));
          },
          onToolResult: (c, result) =>
              out.add(agui.ToolCallResultEvent(messageId: '$runId-t${n++}', toolCallId: c.id, content: result)),
        );
        closeText();
        out.add(agui.RunFinishedEvent(threadId: threadId, runId: runId));
      } catch (e) {
        closeText();
        out.add(agui.RunErrorEvent(message: e.toString()));
      } finally {
        await out.close();
      }
    }

    unawaited(go());
    return out.stream;
  }

  /// Short readable result for a tool card, e.g. the error a tool returned.
  static String? errorOf(String result) {
    try {
      final j = jsonDecode(result);
      return j is Map && j['error'] != null ? '${j['error']}' : null;
    } catch (_) {
      return null;
    }
  }
}
