// Widget tests for HeartbeatField — the Settings → Network heartbeat input.
// Validation is the contract: only an in-range (1–60) value reaches onSubmit;
// an out-of-range or non-numeric entry shows an inline error and calls nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/heartbeat_field.dart';

Widget _host(int value, void Function(int) onSubmit) => MaterialApp(
      home: Scaffold(body: Center(child: HeartbeatField(value: value, onSubmit: onSubmit))),
    );

void main() {
  testWidgets('seeds the field with the current value', (tester) async {
    await tester.pumpWidget(_host(7, (_) {}));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('a valid value (1–60) is submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(_host(7, (v) => submitted = v));
    await tester.enterText(find.byType(TextField), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 12);
    expect(find.text('1–60'), findsNothing); // no error
  });

  testWidgets('boundaries 1 and 60 are accepted', (tester) async {
    final got = <int>[];
    await tester.pumpWidget(_host(7, got.add));
    await tester.enterText(find.byType(TextField), '1');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(find.byType(TextField), '60');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(got, [1, 60]);
  });

  testWidgets('an out-of-range value shows an error and is not submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(_host(7, (v) => submitted = v));
    await tester.enterText(find.byType(TextField), '90');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isNull); // engine never called
    expect(find.text('1–60'), findsOneWidget); // inline error shown
  });

  testWidgets('a non-numeric value shows an error and is not submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(_host(7, (v) => submitted = v));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isNull);
    expect(find.text('1–60'), findsOneWidget);
  });
}
