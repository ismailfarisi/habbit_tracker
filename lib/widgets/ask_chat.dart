import 'package:flutter/widgets.dart';

import '../app_state.dart';
import '../screens/home_screen.dart';

/// Opens the Chat tab and sends [text] there, showing [display] as the
/// user's message when given. With [context], pages and sheets on top of
/// the tabs are closed first.
void askChat(AppState state, String text, {String? display, BuildContext? context, String? goalId}) {
  if (context != null) Navigator.of(context).popUntil((r) => r.isFirst);
  state.chatPrompt.value = ChatRequest(text, display: display, goalId: goalId);
  state.requestedTab.value = HomeScreen.chatTab;
}
