import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/flash.dart';
import 'package:patch/models/flash_applicator.dart';
import 'package:patch/models/message.dart' show kAllChannelId;
import 'package:patch/models/selection_controller.dart';
import 'package:patch/store/app_store.dart';

// Minimal no-op fakes — this test suite only needs SelectionController for its
// .selection getter; ensureMessages / syncSelection calls are not exercised here.
class _FakeBridge extends BridgeClient {
  @override
  Future<void> setSelectedChannels(List<String> ids) async {}
  @override
  Future<void> setDmTarget(String? peerId) async {}
}

class _FakeStore extends AppStore {
  _FakeStore() : super(_FakeBridge());
  @override
  Future<void> ensureMessages(String channelId) async {}
}

SelectionController _sel() => SelectionController(_FakeStore(), _FakeBridge());

// Tests drive apply() directly. Each call produces a fresh stream so multiple
// FlashApplicator instances in the same test suite don't fight over one listener.
FlashApplicator _app(SelectionController sel, {
  bool showPeers = false,
  Future<void> Function()? onAlert,
  Future<void> Function(Color, int)? onPulseOverlay,
}) => FlashApplicator(
      selectionController: sel,
      pushes: StreamController<PatchEvent>(sync: true).stream,
      showPeers: showPeers,
      onAlert: onAlert,
      onPulseOverlay: onPulseOverlay,
    );

void main() {
  group('ChannelFlashEvent', () {
    test('selected channel bumps flashCounts, flashNotify, and sets color/pulseCount', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(app.flashCounts['rf'], 1);
      expect(app.flashNotify, 1);
      expect(app.flashColor, Colors.red);
      expect(app.flashPulseCount, 3);
    });

    test('unselected channel bumps flashCounts only — flashNotify unchanged', () {
      final sel = _sel()..selectTab('audio');
      final app = _app(sel);
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(app.flashCounts['rf'], 1);
      expect(app.flashNotify, 0);
    });

    test('flash counts accumulate across multiple applies', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(app.flashCounts['rf'], 2);
      expect(app.flashNotify, 2);
    });
  });

  group('BroadcastFlashEvent', () {
    test('always bumps flashCounts[kAllChannelId] and flashNotify regardless of selection', () {
      final sel = _sel()..selectTab('rf'); // not in ALL mode
      final app = _app(sel);
      app.apply(const BroadcastFlashEvent(pulseCount: 2));

      expect(app.flashCounts[kAllChannelId], 1);
      expect(app.flashNotify, 1);
      expect(app.flashPulseCount, 2);
    });
  });

  group('DmFlashEvent', () {
    test('selected DM thread bumps flashNotify and adds peer to openDms', () {
      final sel = _sel()..openDm('p1');
      final app = _app(sel);
      app.apply(const DmFlashEvent(peerId: 'p1'));

      expect(app.flashNotify, 1);
      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, isEmpty);
      expect(app.dmPulseNotify, 0);
    });

    test('unselected DM, peers panel closed — adds to openDms + unreadDms, bumps dmPulseNotify', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      app.apply(const DmFlashEvent(peerId: 'p1'));

      expect(app.flashNotify, 0);
      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 1);
    });

    test('unselected DM, peers panel open — adds to openDms + unreadDms, dmPulseNotify unchanged', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel, showPeers: true);
      app.apply(const DmFlashEvent(peerId: 'p1'));

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 0);
    });
  });

  group('clearUnread', () {
    test('removes the id from unreadDms', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      app.apply(const DmFlashEvent(peerId: 'p1'));
      app.clearUnread('dm:p1');

      expect(app.unreadDms, isEmpty);
    });
  });

  group('clearDmThread', () {
    test('removes the dm:peerId entry from unreadDms', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      app.apply(const DmFlashEvent(peerId: 'p1'));
      app.clearDmThread('p1');

      expect(app.unreadDms, isEmpty);
    });
  });

  group('markDmUnread', () {
    test('panel closed — adds to unreadDms and bumps dmPulseNotify', () {
      final sel = _sel();
      final app = _app(sel);
      app.markDmUnread('dm:p1');

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 1);
    });

    test('panel open — adds to unreadDms, dmPulseNotify unchanged', () {
      final sel = _sel();
      final app = _app(sel, showPeers: true);
      app.markDmUnread('dm:p1');

      expect(app.unreadDms, contains('dm:p1'));
      expect(app.dmPulseNotify, 0);
    });
  });

  group('onAlert callback', () {
    test('fired when audibleAlert is true and a flash is applied', () {
      int calls = 0;
      final sel = _sel()..selectTab('rf');
      final app = _app(sel, onAlert: () async => calls++)
        ..audibleAlert = true;
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(calls, 1);
    });

    test('not fired when audibleAlert is false', () {
      int calls = 0;
      final sel = _sel()..selectTab('rf');
      final app = _app(sel, onAlert: () async => calls++)
        ..audibleAlert = false;
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(calls, 0);
    });
  });

  group('openDmThread', () {
    test('adds peer to openDms and removes it from unreadDms', () {
      final sel = _sel()..selectTab('rf');
      final app = _app(sel);
      // Flash arrives while DM is not selected → unread
      app.apply(const DmFlashEvent(peerId: 'p1'));
      expect(app.unreadDms, contains('dm:p1'));

      // Operator taps the peer row → thread opens, unread clears
      app.openDmThread('p1');

      expect(app.openDms, contains('p1'));
      expect(app.unreadDms, isEmpty);
    });
  });

  group('onPulseOverlay callback', () {
    test('fired on selected channel flash when flashWholeScreen is true', () {
      int calls = 0;
      final sel = _sel()..selectTab('rf');
      final app = _app(sel, onPulseOverlay: (c, n) async => calls++)
        ..flashWholeScreen = true;
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(calls, 1);
    });

    test('not fired when channel is not selected', () {
      int calls = 0;
      final sel = _sel()..selectTab('audio');
      final app = _app(sel, onPulseOverlay: (c, n) async => calls++)
        ..flashWholeScreen = true;
      app.apply(const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(calls, 0);
    });
  });
}
