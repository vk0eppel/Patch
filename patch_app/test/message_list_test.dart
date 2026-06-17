// Widget test for MessageList — a pure widget (no bridge/engine), so it runs
// under `flutter test` without any native library.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/theme/patch_theme.dart';
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

Widget _host(
  List<PatchMessage> messages, {
  Map<String, MessageDeliveryStatus>? delivery,
}) =>
    MaterialApp(
      home: Scaffold(
        body: MessageList(messages: messages, delivery: delivery),
      ),
    );

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

  testWidgets('delivery badge: in-progress shows N/M, complete shows a check', (tester) async {
    final m = _msg('HOLD', priority: 3);
    await tester.pumpWidget(_host([m], delivery: {
      m.messageId: const MessageDeliveryStatus(delivered: 1, total: 3, failed: false),
    }));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    expect(find.byIcon(Icons.done_all), findsNothing);

    await tester.pumpWidget(_host([m], delivery: {
      m.messageId: const MessageDeliveryStatus(delivered: 3, total: 3, failed: false),
    }));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsNothing);
    expect(find.byIcon(Icons.done_all), findsOneWidget); // delivered to all
  });

  testWidgets('delivery badge: failure shows the alert icon', (tester) async {
    final m = _msg('HOLD', priority: 3);
    await tester.pumpWidget(_host([m], delivery: {
      m.messageId: const MessageDeliveryStatus(
        delivered: 1,
        total: 2,
        failed: true,
        failedPeers: ['RF Tech'],
      ),
    }));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('no delivery badge when the message has no status', (tester) async {
    await tester.pumpWidget(_host([_msg('Channel clear', priority: 1)]));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.done_all), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('broadcast (__all__) messages show the 📢 marker', (tester) async {
    final broadcast = PatchMessage(
      messageId: 'b1',
      senderId: 's',
      senderName: 'PM',
      channelId: kAllChannelId,
      timestamp: DateTime(2026, 6, 6, 9, 30),
      priority: 1,
      payload: 'LUNCH BREAK',
    );
    await tester.pumpWidget(_host([broadcast, _msg('normal')]));
    await tester.pumpAndSettle();
    // Exactly one 📢 — on the broadcast row, not the normal one.
    expect(find.text('📢'), findsOneWidget);
    expect(find.text('LUNCH BREAK'), findsOneWidget);
  });

  testWidgets('sender name colour encodes priority', (tester) async {
    Color senderColour() => tester.widget<Text>(find.text('FOH')).style!.color!;

    await tester.pumpWidget(_host([_msg('info', priority: 1)]));
    await tester.pumpAndSettle();
    expect(senderColour(), PatchTheme.accent); // info → blue

    await tester.pumpWidget(_host([_msg('warn', priority: 2)]));
    await tester.pumpAndSettle();
    expect(senderColour(), PatchTheme.warning); // warning → amber

    await tester.pumpWidget(_host([_msg('crit', priority: 3)]));
    await tester.pumpAndSettle();
    expect(senderColour(), PatchTheme.critical); // critical → red
  });
}
