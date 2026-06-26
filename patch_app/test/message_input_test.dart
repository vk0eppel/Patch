import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/message_input.dart';

void main() {
  // The test host isn't iOS/Android, so home_screen's `_hideKeyboard` getter
  // (gated to mobile in #78) always resolves to `false` here — exercising the
  // desktop branch directly, with no platform faking needed.
  Widget host({required ValueChanged<String> onSend}) => MaterialApp(
        home: Scaffold(
          body: MessageInput(onSend: onSend, hideKeyboard: false),
        ),
      );

  testWidgets('autofocuses on initial view when hideKeyboard is false',
      (tester) async {
    await tester.pumpWidget(host(onSend: (_) {}));
    final focusNode = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('field regains focus immediately after a send (send button)',
      (tester) async {
    String? sent;
    await tester.pumpWidget(host(onSend: (text) => sent = text));

    await tester.enterText(find.byType(TextField), 'standby');
    // Drop focus first (e.g. as a channel switch would) so the assertion
    // below actually proves the post-send refocus, not just autofocus.
    final focusNode = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    focusNode.unfocus();
    await tester.pump();
    expect(focusNode.hasFocus, isFalse);

    await tester.tap(find.byTooltip('Send (Enter)'));
    await tester.pump();

    expect(sent, 'standby');
    expect(focusNode.hasFocus, isTrue);
  });

  testWidgets('field regains focus immediately after a send (Enter key)',
      (tester) async {
    String? sent;
    await tester.pumpWidget(host(onSend: (text) => sent = text));

    await tester.enterText(find.byType(TextField), 'go standby');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();

    expect(sent, 'go standby');
    final focusNode = tester.widget<TextField>(find.byType(TextField)).focusNode!;
    expect(focusNode.hasFocus, isTrue);
  });
}
