import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/flash_model.dart';
import 'package:patch/models/message.dart';
import 'package:patch/models/selection.dart';

const _ch = PatchChannel(id: 'rf', displayName: 'RF', color: Colors.red, flashCount: 3);

const _defaultSettings = FlashSettings(
  flashCount: 4,
  flashOnCritical: true,
  flashOnMessage: false,
  broadcastColor: Colors.white,
  dmColor: Colors.blue,
  showPeers: false,
  audibleAlert: false,
  flashWholeScreen: false,
);

PatchMessage _msg({required String channelId, int priority = 1}) => PatchMessage(
      messageId: 'm1',
      senderId: 's1',
      senderName: 'Sender',
      channelId: channelId,
      timestamp: DateTime(2026),
      priority: priority,
      payload: 'hi',
    );

void main() {
  group('FlashState.empty', () {
    test('zero counts, empty sets', () {
      expect(FlashState.empty.flashCounts, isEmpty);
      expect(FlashState.empty.flashNotify, 0);
      expect(FlashState.empty.openDms, isEmpty);
      expect(FlashState.empty.unreadDms, isEmpty);
      expect(FlashState.empty.dmPulseNotify, 0);
    });
  });

  group('reduceEvent — MessageReceived', () {
    test('flash-eligible message on selected channel bumps flashCounts and flashNotify', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 3)),
        sel,
        const [_ch],
        _defaultSettings,
      );

      expect(s.flashCounts['rf'], 1);
      expect(s.flashNotify, 1);
      expect(s.flashColor, Colors.red);
      expect(s.flashPulseCount, 3);
    });

    test('flash-eligible message on unselected channel bumps flashCounts only', () {
      final sel = ChannelSelection({'audio'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 3)),
        sel,
        const [_ch],
        _defaultSettings,
      );

      expect(s.flashCounts['rf'], 1);
      expect(s.flashNotify, 0);
    });

    test('non-flash message (flags off) produces no state change', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf')),
        sel,
        const [_ch],
        _defaultSettings.copyWith(flashOnCritical: false, flashOnMessage: false),
      );

      expect(s.flashCounts, isEmpty);
      expect(s.flashNotify, 0);
    });

    test('non-critical DM not selected marks unread and bumps dmPulseNotify when panel closed', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'dm:p1')),
        sel,
        const [],
        _defaultSettings,
      );

      expect(s.unreadDms, contains('dm:p1'));
      expect(s.dmPulseNotify, 1);
      expect(s.flashNotify, 0);
    });

    test('non-critical DM not selected, peers panel open — marks unread, dmPulseNotify unchanged', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'dm:p1')),
        sel,
        const [],
        _defaultSettings.copyWith(showPeers: true),
      );

      expect(s.unreadDms, contains('dm:p1'));
      expect(s.dmPulseNotify, 0);
    });

    test('critical DM not selected adds to openDms + unreadDms, bumps dmPulseNotify', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'dm:p1', priority: 3)),
        sel,
        const [],
        _defaultSettings,
      );

      expect(s.openDms, contains('p1'));
      expect(s.unreadDms, contains('dm:p1'));
      expect(s.dmPulseNotify, 1);
      expect(s.flashNotify, 0);
    });
  });

  group('reduceEvent — Flashed', () {
    test('selected channel flash bumps flashCounts, flashNotify, uses channel color and flashCount', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        const Flashed(channelId: 'rf', senderId: 's', senderName: 'S'),
        sel,
        const [_ch],
        _defaultSettings,
      );

      expect(s.flashCounts['rf'], 1);
      expect(s.flashNotify, 1);
      expect(s.flashColor, Colors.red);
      expect(s.flashPulseCount, 3);
    });

    test('unselected channel flash bumps flashCounts only', () {
      final sel = ChannelSelection({'audio'});
      final s = reduceEvent(
        FlashState.empty,
        const Flashed(channelId: 'rf', senderId: 's', senderName: 'S'),
        sel,
        const [_ch],
        _defaultSettings,
      );

      expect(s.flashCounts['rf'], 1);
      expect(s.flashNotify, 0);
    });

    test('__all__ flash always bumps flashNotify and uses broadcastColor', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        const Flashed(channelId: '__all__', senderId: 's', senderName: 'S'),
        sel,
        const [],
        _defaultSettings,
      );

      expect(s.flashCounts['__all__'], 1);
      expect(s.flashNotify, 1);
      expect(s.flashColor, Colors.white);
    });

    test('DM flash, peer selected — bumps flashNotify, adds to openDms, no unread', () {
      final sel = DmSelection('p1');
      final s = reduceEvent(
        FlashState.empty,
        const Flashed(channelId: 'dm:p1', senderId: 'p1', senderName: 'P'),
        sel,
        const [],
        _defaultSettings,
      );

      expect(s.flashNotify, 1);
      expect(s.openDms, contains('p1'));
      expect(s.unreadDms, isEmpty);
      expect(s.dmPulseNotify, 0);
    });

    test('DM flash, peer not selected — adds to openDms and unreadDms, bumps dmPulseNotify', () {
      final sel = ChannelSelection({'rf'});
      final s = reduceEvent(
        FlashState.empty,
        const Flashed(channelId: 'dm:p1', senderId: 'p1', senderName: 'P'),
        sel,
        const [],
        _defaultSettings,
      );

      expect(s.flashNotify, 0);
      expect(s.openDms, contains('p1'));
      expect(s.unreadDms, contains('dm:p1'));
      expect(s.dmPulseNotify, 1);
    });

    test('flash counts accumulate across multiple reductions', () {
      final sel = ChannelSelection({'rf'});
      var s = reduceEvent(FlashState.empty,
          const Flashed(channelId: 'rf', senderId: 's', senderName: 'S'), sel, const [_ch], _defaultSettings);
      s = reduceEvent(s,
          const Flashed(channelId: 'rf', senderId: 's', senderName: 'S'), sel, const [_ch], _defaultSettings);

      expect(s.flashCounts['rf'], 2);
      expect(s.flashNotify, 2);
    });
  });

  group('clearUnread', () {
    test('removes the given id from unreadDms', () {
      final seeded = FlashState.empty.copyWith(unreadDms: {'dm:p1', 'dm:p2'});
      final s = clearUnread(seeded, 'dm:p1');

      expect(s.unreadDms, {'dm:p2'});
    });
  });

  group('openDmThread', () {
    test('adds peerId to openDms and removes dm:peerId from unreadDms', () {
      final seeded = FlashState.empty.copyWith(unreadDms: {'dm:p1'});
      final s = openDmThread(seeded, 'p1');

      expect(s.openDms, contains('p1'));
      expect(s.unreadDms, isEmpty);
    });
  });

  group('clearDmThread', () {
    test('removes dm:peerId from unreadDms', () {
      final seeded = FlashState.empty.copyWith(unreadDms: {'dm:p1', 'dm:p2'});
      final s = clearDmThread(seeded, 'p1');

      expect(s.unreadDms, {'dm:p2'});
    });
  });

  group('flashOutput', () {
    final prev = FlashState.empty;
    final next = FlashState.empty.copyWith(
      flashNotify: 1,
      flashColor: Colors.green,
      flashPulseCount: 3,
    );

    test('no flashNotify change → playAlert=false, pulse=null', () {
      final out = flashOutput(prev, prev, _defaultSettings.copyWith(
        audibleAlert: true,
        flashWholeScreen: true,
      ));
      expect(out.playAlert, isFalse);
      expect(out.pulse, isNull);
    });

    test('audibleAlert=true + flashNotify changed → playAlert=true', () {
      final out = flashOutput(prev, next,
          _defaultSettings.copyWith(audibleAlert: true));
      expect(out.playAlert, isTrue);
    });

    test('audibleAlert=false + flashNotify changed → playAlert=false', () {
      final out = flashOutput(prev, next,
          _defaultSettings.copyWith(audibleAlert: false));
      expect(out.playAlert, isFalse);
    });

    test('flashWholeScreen=true + flashNotify changed → pulse carries color and count', () {
      final out = flashOutput(prev, next,
          _defaultSettings.copyWith(flashWholeScreen: true));
      expect(out.pulse, isNotNull);
      expect(out.pulse!.color, Colors.green);
      expect(out.pulse!.count, 3);
    });

    test('flashWholeScreen=false + flashNotify changed → pulse=null', () {
      final out = flashOutput(prev, next,
          _defaultSettings.copyWith(flashWholeScreen: false));
      expect(out.pulse, isNull);
    });
  });

  group('decideFlashCommand — push-event → command, end to end', () {
    test('a critical message on the selected channel pulses the overlay', () {
      final sel = ChannelSelection({'rf'});
      final settings = _defaultSettings.copyWith(flashWholeScreen: true);

      final decision = decideFlashCommand(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 3)),
        sel,
        const [_ch],
        settings,
      );

      expect(decision.pulse, isNotNull);
      expect(decision.pulse!.color, Colors.red);
      expect(decision.pulse!.count, 3);
      expect(decision.state.flashNotify, 1);
    });

    test('a non-critical message with flashOnMessage off produces no command', () {
      final sel = ChannelSelection({'rf'});
      final settings = _defaultSettings.copyWith(flashWholeScreen: true);

      final decision = decideFlashCommand(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 1)),
        sel,
        const [_ch],
        settings,
      );

      expect(decision.pulse, isNull);
      expect(decision.playAlert, isFalse);
      expect(decision.state.flashNotify, 0);
    });

    test('a non-critical message with flashOnMessage on produces a command', () {
      final sel = ChannelSelection({'rf'});
      final settings = _defaultSettings.copyWith(
        flashOnMessage: true,
        flashWholeScreen: true,
      );

      final decision = decideFlashCommand(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 1)),
        sel,
        const [_ch],
        settings,
      );

      expect(decision.pulse, isNotNull);
      expect(decision.state.flashNotify, 1);
    });

    test('a critical message on a non-selected channel updates counts but fires no command', () {
      final sel = ChannelSelection({'audio'});
      final settings = _defaultSettings.copyWith(flashWholeScreen: true);

      final decision = decideFlashCommand(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 3)),
        sel,
        const [_ch],
        settings,
      );

      expect(decision.state.flashCounts['rf'], 1);
      expect(decision.pulse, isNull);
      expect(decision.playAlert, isFalse);
    });

    test('audibleAlert plays alongside the pulse when both are enabled', () {
      final sel = ChannelSelection({'rf'});
      final settings = _defaultSettings.copyWith(
        flashWholeScreen: true,
        audibleAlert: true,
      );

      final decision = decideFlashCommand(
        FlashState.empty,
        MessageReceived(_msg(channelId: 'rf', priority: 3)),
        sel,
        const [_ch],
        settings,
      );

      expect(decision.playAlert, isTrue);
      expect(decision.pulse, isNotNull);
    });
  });
}
