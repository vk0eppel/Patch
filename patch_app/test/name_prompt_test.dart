// Tests for the first-run name prompt — the decision helper and the dialog.
// Both are bridge-free seams: shouldShowNamePrompt is pure, and showNamePrompt
// reports the chosen name through an onSave callback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/name_prompt.dart';

void main() {
  group('shouldShowNamePrompt', () {
    test('shows when the name is default and not yet shown', () {
      expect(
        shouldShowNamePrompt(nameIsDefault: true, alreadyShown: false),
        isTrue,
      );
    });

    test('hidden when the name is custom', () {
      expect(
        shouldShowNamePrompt(nameIsDefault: false, alreadyShown: false),
        isFalse,
      );
    });

    test('suppressed once already shown this session', () {
      expect(
        shouldShowNamePrompt(nameIsDefault: true, alreadyShown: true),
        isFalse,
      );
    });
  });

  group('showNamePrompt dialog', () {
    Widget host(void Function(String) onSave) => MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () =>
                    showNamePrompt(context, currentName: 'vincent', onSave: onSave),
                child: const Text('open'),
              ),
            ),
          ),
        );

    testWidgets('pre-fills the current name', (tester) async {
      await tester.pumpWidget(host((_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Set your name'), findsOneWidget);
      expect(find.text('vincent'), findsOneWidget); // seeded in the field
    });

    testWidgets('Save reports the entered name and closes', (tester) async {
      String? saved;
      await tester.pumpWidget(host((n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'FOH Sam');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, 'FOH Sam');
      expect(find.text('Set your name'), findsNothing); // dialog closed
    });

    testWidgets('Skip closes without saving', (tester) async {
      String? saved;
      await tester.pumpWidget(host((n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Set your name'), findsNothing);
    });

    testWidgets('an empty name does not save', (tester) async {
      String? saved;
      await tester.pumpWidget(host((n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(saved, isNull); // blank rejected, dialog stays open
      expect(find.text('Set your name'), findsOneWidget);
    });
  });
}
