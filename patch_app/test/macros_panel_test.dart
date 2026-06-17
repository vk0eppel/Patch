// Widget test for MacrosPanel ordering — global macros render above
// per-channel macros (matching the Settings section order).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/widgets/macros_panel.dart';

ChannelMacro _macro(String label, {String channelId = 'rf'}) => ChannelMacro(
      channelId: channelId,
      channelColor: const Color(0xFF1E88E5),
      macro: MacroMessage(label: label, payload: label),
    );

Widget _host({
  required List<ChannelMacro> macros,
  required List<ChannelMacro> globalMacros,
}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 600,
          child: MacrosPanel(
            macros: macros,
            globalMacros: globalMacros,
            isMulti: false,
            columns: 1,
            onMacro: (_) {},
          ),
        ),
      ),
    );

void main() {
  testWidgets('global macros render above per-channel macros', (tester) async {
    await tester.pumpWidget(_host(
      macros: [_macro('CHAN_MAC')],
      globalMacros: [_macro('GLOBAL_MAC', channelId: '')],
    ));
    await tester.pumpAndSettle();

    // Both present, plus the GLOBAL group header.
    expect(find.text('GLOBAL'), findsOneWidget);
    expect(find.text('GLOBAL_MAC'), findsOneWidget);
    expect(find.text('CHAN_MAC'), findsOneWidget);

    // The global macro button sits above the per-channel one.
    final globalY = tester.getTopLeft(find.text('GLOBAL_MAC')).dy;
    final chanY = tester.getTopLeft(find.text('CHAN_MAC')).dy;
    expect(globalY, lessThan(chanY));
  });

  testWidgets('with no per-channel macros, only the global group renders', (tester) async {
    await tester.pumpWidget(_host(
      macros: const [],
      globalMacros: [_macro('GLOBAL_MAC', channelId: '')],
    ));
    await tester.pumpAndSettle();
    expect(find.text('GLOBAL_MAC'), findsOneWidget);
    expect(find.text('No macros'), findsNothing);
  });
}
