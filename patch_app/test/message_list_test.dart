// Widget test for MessageList — a pure widget (no bridge/engine), so it runs
// under `flutter test` without any native library.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/widgets/message_list.dart';

PatchMessage _msg(String payload, {int priority = 1}) => PatchMessage(
      messageId: payload,
      senderId: 's',
      senderName: 'FOH',
      channelId: 'rf',
      timestamp: DateTime(2026, 6, 4, 9, 30),
      priority: priority,
      payload: payload,
    );

Widget _host(List<PatchMessage> messages) =>
    MaterialApp(home: Scaffold(body: MessageList(messages: messages)));

void main() {
  testWidgets('shows the empty-state hint when there are no messages', (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(find.text('No messages yet'), findsOneWidget);
  });

  testWidgets('renders a message payload and sender', (tester) async {
    await tester.pumpWidget(_host([_msg('Battery low', priority: 3)]));
    await tester.pumpAndSettle();
    expect(find.text('Battery low'), findsOneWidget);
    expect(find.text('FOH'), findsOneWidget);
    expect(find.text('No messages yet'), findsNothing);
  });
}
