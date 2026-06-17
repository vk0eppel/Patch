// Widget tests for PulsingPeersButton — the peers toggle that pulses once on a
// new unread DM. Verifies the timer-based accent pulse on a pulseNotify bump and
// the persistent unread dot.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/theme/patch_theme.dart';
import 'package:patch/widgets/pulsing_peers_button.dart';

Widget _host({required int notify, bool hasUnread = false}) => MaterialApp(
      home: Scaffold(
        body: PulsingPeersButton(
          pulseNotify: notify,
          hasUnread: hasUnread,
          onPressed: () {},
        ),
      ),
    );

Color _iconColour(WidgetTester tester) =>
    tester.widget<Icon>(find.byIcon(Icons.people)).color!;

void main() {
  testWidgets('idle icon is muted', (tester) async {
    await tester.pumpWidget(_host(notify: 0));
    expect(_iconColour(tester), PatchTheme.textMuted);
  });

  testWidgets('a pulseNotify bump lights the icon accent, then it settles back',
      (tester) async {
    await tester.pumpWidget(_host(notify: 0));
    expect(_iconColour(tester), PatchTheme.textMuted);

    // Simulate a DM arriving (the parent increments the counter).
    await tester.pumpWidget(_host(notify: 1));
    await tester.pump(); // run didUpdateWidget → _pulse() first setState
    expect(_iconColour(tester), PatchTheme.accent); // lit

    await tester.pump(const Duration(milliseconds: 400)); // pulse window elapses
    expect(_iconColour(tester), PatchTheme.textMuted); // settled
  });

  testWidgets('each successive DM re-pulses', (tester) async {
    await tester.pumpWidget(_host(notify: 1));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_iconColour(tester), PatchTheme.textMuted);

    await tester.pumpWidget(_host(notify: 2));
    await tester.pump();
    expect(_iconColour(tester), PatchTheme.accent); // lit again
    await tester.pump(const Duration(milliseconds: 400));
  });

  testWidgets('the unread dot shows when hasUnread', (tester) async {
    await tester.pumpWidget(_host(notify: 0, hasUnread: true));
    final dots = find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).color == PatchTheme.critical);
    expect(dots, findsOneWidget);
  });
}
