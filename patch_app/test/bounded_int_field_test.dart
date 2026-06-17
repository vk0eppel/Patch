// Widget tests for BoundedIntField — the Settings → Network numeric inputs
// (heartbeat interval 1–60, OSC port 1024–65535). Validation is the contract:
// only an in-range value reaches onSubmit; an out-of-range or non-numeric entry
// shows the range as an inline error and calls nothing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/bounded_int_field.dart';

Widget _host({
  required int value,
  required int min,
  required int max,
  String? suffix,
  required void Function(int) onSubmit,
}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: BoundedIntField(
            value: value,
            min: min,
            max: max,
            suffix: suffix,
            onSubmit: onSubmit,
          ),
        ),
      ),
    );

void main() {
  testWidgets('seeds the field with the current value', (tester) async {
    await tester.pumpWidget(_host(value: 7, min: 1, max: 60, onSubmit: (_) {}));
    expect(find.text('7'), findsOneWidget);
  });

  testWidgets('a valid value is submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(_host(value: 7, min: 1, max: 60, onSubmit: (v) => submitted = v));
    await tester.enterText(find.byType(TextField), '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, 12);
    expect(find.text('1–60'), findsNothing); // no error
  });

  testWidgets('boundaries are accepted', (tester) async {
    final got = <int>[];
    await tester.pumpWidget(_host(value: 5000, min: 1024, max: 65535, onSubmit: got.add));
    await tester.enterText(find.byType(TextField), '1024');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.enterText(find.byType(TextField), '65535');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(got, [1024, 65535]);
  });

  testWidgets('an out-of-range value shows the range error and is not submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(
      _host(value: 9000, min: 1024, max: 65535, onSubmit: (v) => submitted = v),
    );
    await tester.enterText(find.byType(TextField), '80'); // privileged port
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isNull); // engine never called
    expect(find.text('1024–65535'), findsOneWidget); // range shown inline
  });

  testWidgets('a non-numeric value shows an error and is not submitted', (tester) async {
    int? submitted;
    await tester.pumpWidget(_host(value: 7, min: 1, max: 60, onSubmit: (v) => submitted = v));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(submitted, isNull);
    expect(find.text('1–60'), findsOneWidget);
  });
}
