import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/macros_section_presenter.dart';

void main() {
  late List<String> calls;
  late MacrosSectionPresenter p;

  setUp(() {
    calls = [];
    p = MacrosSectionPresenter(
      upsertChannelMacro: ({
        required channelId,
        originalLabel,
        required label,
        required payload,
        keyBinding,
        priority = 1,
        midiNote,
        midiCc,
        osc,
      }) async {
        calls.add('upsertChannelMacro:$channelId:$label');
      },
      upsertGlobalMacro: ({
        originalLabel,
        required label,
        required payload,
        keyBinding,
        priority = 1,
        midiNote,
        midiCc,
        osc,
      }) async {
        calls.add('upsertGlobalMacro:$label');
      },
    );
  });

  group('MacrosSectionPresenter', () {
    test('saveChannelMacro calls the bridge with a valid OSC target',
        () async {
      await p.saveChannelMacro(
        channelId: 'rf',
        label: 'GO',
        payload: 'go',
        osc: const MacroOsc(
          address: '10.0.0.9',
          port: 53000,
          path: '/cue/1/start',
          argType: MacroOscArgType.string,
        ),
      );
      expect(calls, ['upsertChannelMacro:rf:GO']);
    });

    test('saveChannelMacro rejects an invalid OSC target before any bridge call',
        () async {
      await expectLater(
        () => p.saveChannelMacro(
          channelId: 'rf',
          label: 'GO',
          payload: 'go',
          osc: const MacroOsc(
            address: 'not-an-ip',
            port: 53000,
            path: '/cue/1/start',
            argType: MacroOscArgType.string,
          ),
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
    });

    test('saveChannelMacro with no OSC target skips the guard', () async {
      await p.saveChannelMacro(channelId: 'rf', label: 'GO', payload: 'go');
      expect(calls, ['upsertChannelMacro:rf:GO']);
    });

    test('saveGlobalMacro calls the bridge with a valid OSC target',
        () async {
      await p.saveGlobalMacro(label: 'Standby', payload: 'standby');
      expect(calls, ['upsertGlobalMacro:Standby']);
    });

    test('saveGlobalMacro rejects an invalid OSC target before any bridge call',
        () async {
      await expectLater(
        () => p.saveGlobalMacro(
          label: 'Standby',
          payload: 'standby',
          osc: const MacroOsc(
            address: '10.0.0.9',
            port: 0,
            path: '/cue/1/start',
            argType: MacroOscArgType.string,
          ),
        ),
        throwsFormatException,
      );
      expect(calls, isEmpty);
    });
  });
}
