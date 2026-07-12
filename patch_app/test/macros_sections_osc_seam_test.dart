// Widget test for the macro edit dialog's Save path (#165): OSC-target
// validity must be decided in exactly one place — validateMacroOscTarget,
// reached via MacrosSectionPresenter's validateThenSave seam — not by a
// second, looser check inline in the dialog.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/macros_section_presenter.dart';
import 'package:patch/store/app_store.dart';
import 'package:patch/widgets/settings/macros_sections.dart';

Widget _host(MacrosSectionPresenter presenter) => MaterialApp(
  home: AppStoreScope(
    store: AppStore(BridgeClient()),
    child: Scaffold(
      body: GlobalMacrosSection(
        bridge: BridgeClient(),
        presenter: presenter,
        globalMacros: const [],
        onImportFromPeer: () {},
        onReset: () {},
      ),
    ),
  ),
);

Future<void> _openDialogAndFillOsc(
  WidgetTester tester, {
  required String address,
}) async {
  await tester.tap(find.widgetWithText(TextButton, 'Add'));
  await tester.pumpAndSettle();

  await tester.enterText(find.widgetWithText(TextField, 'Button label'), 'GO');
  await tester.enterText(
    find.widgetWithText(TextField, 'Message text'),
    'GO GO GO',
  );

  // Enable the OSC dual-action switch.
  await tester.tap(find.text('Also send OSC'));
  await tester.pumpAndSettle();

  await tester.enterText(find.widgetWithText(TextField, 'IP'), address);
  await tester.enterText(find.widgetWithText(TextField, 'Port'), '53000');
  await tester.enterText(
    find.widgetWithText(TextField, 'OSC path'),
    '/cue/1/start',
  );

  await tester.tap(find.widgetWithText(ElevatedButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a target the validator rejects (non-IP address) is not saved, '
      'and the dialog does not gate it with its own looser check', (
    tester,
  ) async {
    var saveCalled = false;
    final presenter = MacrosSectionPresenter(
      upsertMacro: ({channelId, originalLabel, required macro}) async {
        saveCalled = true;
      },
    );

    await tester.pumpWidget(_host(presenter));

    // "localhost" is non-empty and would have passed the dialog's old
    // ad-hoc inline gate (addr.isEmpty || port==null || ...) — it must
    // still be rejected, but only by validateMacroOscTarget via the
    // presenter's validateThenSave seam.
    await _openDialogAndFillOsc(tester, address: 'localhost');

    expect(saveCalled, isFalse);
    expect(
      find.text('OSC address must be an IP address (e.g. 10.0.0.9)'),
      findsOneWidget,
    );
  });

  testWidgets('a well-formed OSC target saves through the presenter seam', (
    tester,
  ) async {
    MacroOsc? savedOsc;
    final presenter = MacrosSectionPresenter(
      upsertMacro: ({channelId, originalLabel, required macro}) async {
        savedOsc = macro.osc;
      },
    );

    await tester.pumpWidget(_host(presenter));
    await _openDialogAndFillOsc(tester, address: '10.0.0.9');

    expect(savedOsc, isNotNull);
    expect(savedOsc!.address, '10.0.0.9');
  });
}
