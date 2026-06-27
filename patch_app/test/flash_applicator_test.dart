import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/flash.dart';
import 'package:patch/models/flash_applicator.dart';
import 'package:patch/models/message.dart' show kAllChannelId;
import 'package:patch/models/selection.dart';

void main() {
  group('ChannelFlashEvent', () {
    test('selected channel bumps flashCounts, flashNotify, and sets color/pulseCount', () {
      final app = FlashApplicator();
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashCounts['rf'], 1);
      expect(app.flashNotify, 1);
      expect(app.flashColor, Colors.red);
      expect(app.flashPulseCount, 3);
    });
    test('unselected channel bumps flashCounts only — flashNotify unchanged', () {
      final app = FlashApplicator();
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'audio'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashCounts['rf'], 1);
      expect(app.flashNotify, 0);
    });

    test('flash counts accumulate across multiple applies', () {
      final app = FlashApplicator();
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashCounts['rf'], 2);
      expect(app.flashNotify, 2);
    });
  });

  group('BroadcastFlashEvent', () {
    test('always bumps flashCounts[kAllChannelId] and flashNotify regardless of selection', () {
      final app = FlashApplicator();
      app.apply(
        const BroadcastFlashEvent(pulseCount: 2),
        const ChannelSelection({'rf'}), // not in ALL mode
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashCounts[kAllChannelId], 1);
      expect(app.flashNotify, 1);
      expect(app.flashPulseCount, 2);
    });
  });

  group('DmFlashEvent', () {
    test('selected DM thread bumps flashNotify and adds peer to openDms', () {
      final app = FlashApplicator();
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const DmSelection('p1'),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashNotify, 1);
      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, isEmpty);
      expect(app.dmPulseNotify, 0);
    });

    test('unselected DM, peers panel closed — adds to openDms + unreadDms, bumps dmPulseNotify', () {
      final app = FlashApplicator();
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(app.flashNotify, 0);
      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 1);
    });

    test('unselected DM, peers panel open — adds to openDms + unreadDms, dmPulseNotify unchanged', () {
      final app = FlashApplicator();
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: true,
      );

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 0);
    });
  });

  group('clearUnread', () {
    test('removes the id from unreadDms', () {
      final app = FlashApplicator();
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );
      app.clearUnread('dm:p1');

      expect(app.unreadDms, isEmpty);
    });
  });

  group('clearDmThread', () {
    test('removes the dm:peerId entry from unreadDms', () {
      final app = FlashApplicator();
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );
      app.clearDmThread('p1');

      expect(app.unreadDms, isEmpty);
    });
  });

  group('markDmUnread', () {
    test('panel closed — adds to unreadDms and bumps dmPulseNotify', () {
      final app = FlashApplicator();
      app.markDmUnread('dm:p1', showPeers: false);

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 1);
    });

    test('panel open — adds to unreadDms, dmPulseNotify unchanged', () {
      final app = FlashApplicator();
      app.markDmUnread('dm:p1', showPeers: true);

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 0);
    });
  });

  group('onAlert callback', () {
    test('fired when audibleAlert is true and a flash is applied', () {
      int calls = 0;
      final app = FlashApplicator(onAlert: () async => calls++)
        ..audibleAlert = true;
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(calls, 1);
    });

    test('not fired when audibleAlert is false', () {
      int calls = 0;
      final app = FlashApplicator(onAlert: () async => calls++)
        ..audibleAlert = false;
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(calls, 0);
    });
  });

  group('openDmThread', () {
    test('adds peer to openDms and removes it from unreadDms', () {
      final app = FlashApplicator();
      // First: a flash arrives while the DM is not selected → unread
      app.apply(
        const DmFlashEvent(peerId: 'p1'),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );
      expect(app.unreadDms, contains('dm:p1'));

      // Then: Operator taps the peer row → thread opens, unread clears
      app.openDmThread('p1');

      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, isEmpty);
    });
  });

  group('onPulseOverlay callback', () {
    test('fired on selected channel flash when flashWholeScreen is true', () {
      int calls = 0;
      final app = FlashApplicator(onPulseOverlay: (_, _) async => calls++)
        ..flashWholeScreen = true;
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'rf'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(calls, 1);
    });

    test('not fired when channel is not selected', () {
      int calls = 0;
      final app = FlashApplicator(onPulseOverlay: (_, _) async => calls++)
        ..flashWholeScreen = true;
      app.apply(
        const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3),
        const ChannelSelection({'audio'}),
        globalFlashCount: 4,
        showPeers: false,
      );

      expect(calls, 0);
    });
  });
}
