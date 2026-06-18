// Tests for the first-run identity prompt — the decision helper and the dialog.
// Both are bridge-free seams: shouldShowNamePrompt is pure, and showNamePrompt
// reports the chosen name/role through onSaveName/onSaveRole callbacks.

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
    Widget host({
      required void Function(String) onSaveName,
      void Function(String)? onSaveRole,
    }) =>
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showNamePrompt(
                  context,
                  currentName: 'vincent',
                  onSaveName: onSaveName,
                  onSaveRole: onSaveRole ?? (_) {},
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );

    testWidgets('pre-fills the current name', (tester) async {
      await tester.pumpWidget(host(onSaveName: (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Set your identity'), findsOneWidget);
      expect(find.text('vincent'), findsOneWidget);
    });

    testWidgets('Use this name saves name and closes', (tester) async {
      String? saved;
      await tester.pumpWidget(host(onSaveName: (n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'FOH Sam');
      await tester.tap(find.text('Use this name'));
      await tester.pumpAndSettle();
      expect(saved, 'FOH Sam');
      expect(find.text('Set your identity'), findsNothing);
    });

    testWidgets('saving with name-only (empty role) is allowed', (tester) async {
      String? savedName;
      String? savedRole;
      await tester.pumpWidget(host(
        onSaveName: (n) => savedName = n,
        onSaveRole: (r) => savedRole = r,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Sam');
      await tester.tap(find.text('Use this name'));
      await tester.pumpAndSettle();
      expect(savedName, 'Sam');
      expect(savedRole, '');
      expect(find.text('Set your identity'), findsNothing);
    });

    testWidgets('tapping a role suggestion populates the role field',
        (tester) async {
      await tester.pumpWidget(host(onSaveName: (_) {}));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('FOH'));
      await tester.pumpAndSettle();
      // Role TextField (second one) should now contain 'FOH'
      final roleField = find.byType(TextField).at(1);
      expect(tester.widget<TextField>(roleField).controller?.text, 'FOH');
    });

    testWidgets('Skip closes without saving', (tester) async {
      String? saved;
      await tester.pumpWidget(host(onSaveName: (n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Set your identity'), findsNothing);
    });

    testWidgets('an empty name does not save', (tester) async {
      String? saved;
      await tester.pumpWidget(host(onSaveName: (n) => saved = n));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '   ');
      await tester.tap(find.text('Use this name'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.text('Set your identity'), findsOneWidget);
    });
  });
}
