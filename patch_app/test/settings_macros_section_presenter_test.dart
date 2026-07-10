import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/macros_section_presenter.dart';
import 'package:patch/presenters/settings/save_result.dart';

void main() {
  late List<String> calls;
  late MacrosSectionPresenter p;

  setUp(() {
    calls = [];
    p = MacrosSectionPresenter(
      upsertMacro: ({channelId, originalLabel, required macro}) async {
        calls.add('upsertMacro:${channelId ?? '<global>'}:${macro.label}');
      },
    );
  });

  const validOsc = MacroOsc(
    address: '10.0.0.9',
    port: 53000,
    path: '/cue/1/start',
    argType: MacroOscArgType.string,
  );

  group('MacrosSectionPresenter (#186: one save path keyed on channelId)', () {
    test('a Channel Macro save carries its channel id', () async {
      final result = await p.saveMacro(
        channelId: 'rf',
        macro: const MacroMessage(label: 'GO', payload: 'go', osc: validOsc),
      );
      expect(result, isA<SaveOk>());
      expect(calls, ['upsertMacro:rf:GO']);
    });

    test('a Global Macro save carries no channel id', () async {
      final result = await p.saveMacro(
          macro: const MacroMessage(label: 'Standby', payload: 'standby'));
      expect(result, isA<SaveOk>());
      expect(calls, ['upsertMacro:<global>:Standby']);
    });

    test('an invalid OSC target rejects before any bridge call — both homes',
        () async {
      const badOsc = MacroOsc(
        address: 'not-an-ip',
        port: 53000,
        path: '/cue/1/start',
        argType: MacroOscArgType.string,
      );
      expect(
        await p.saveMacro(
            channelId: 'rf',
            macro: const MacroMessage(label: 'GO', payload: 'go', osc: badOsc)),
        isA<SaveError>(),
      );
      expect(
        await p.saveMacro(
            macro:
                const MacroMessage(label: 'Standby', payload: 's', osc: badOsc)),
        isA<SaveError>(),
      );
      expect(calls, isEmpty);
    });

    test('no OSC target skips the guard', () async {
      final result = await p.saveMacro(
          channelId: 'rf', macro: const MacroMessage(label: 'GO', payload: 'go'));
      expect(result, isA<SaveOk>());
      expect(calls, ['upsertMacro:rf:GO']);
    });
  });
}
