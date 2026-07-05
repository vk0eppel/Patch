import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/config.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/flash_model.dart' show ChannelFlashEvent;
import 'package:patch/models/message.dart';
import 'package:patch/models/selection_controller.dart';
import 'package:patch/presenters/home_presenter.dart';
import 'package:patch/store/app_store.dart';

// ── Fakes (same pattern as flash_applicator_test) ─────────────────────────────

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

// Push helper — sync controller so events are delivered immediately in tests.
StreamController<PatchEvent> _pushes() =>
    StreamController<PatchEvent>(sync: true);

// Config helper — sync controller so config is applied immediately in tests.
StreamController<AppConfig?> _configs() =>
    StreamController<AppConfig?>(sync: true);

AppConfig _cfg({
  bool audibleAlert = false,
  bool flashWholeScreen = false,
  bool nameIsDefault = false,
}) =>
    AppConfig(
      clientName: 'Test',
      oscPort: 8000,
      flashOnCritical: true,
      flashOnMessage: false,
      flashCount: 4,
      macrosColumns: 2,
      hideKeyboard: false,
      audibleAlert: audibleAlert,
      flashWholeScreen: flashWholeScreen,
      heartbeatIntervalSecs: 5,
      nameIsDefault: nameIsDefault,
    );

const _failedStatus = MessageDeliveryStatus(
  delivered: 0,
  total: 1,
  failed: true,
  failedPeers: ['Stage Manager'],
);

const _successStatus = MessageDeliveryStatus(
  delivered: 1,
  total: 1,
  failed: false,
);

void main() {
  PeerInfo peer(String id, String name, PeerStatus status) => PeerInfo(
        peerId: id,
        peerName: name,
        channels: const [],
        address: '10.0.0.2',
        oscPort: 9000,
        lastSeen: DateTime.parse('2026-07-04T12:00:00Z'),
        discoveryMode: 'mdns',
        status: status,
      );

  group('dmOfflineWarning', () {
    test('phrases the warning for an offline Peer, null for a live one', () {
      final pushes = _pushes();
      final peers = StreamController<List<PeerInfo>>(sync: true);
      final presenter =
          HomePresenter(pushes: pushes.stream, peersStream: peers.stream);
      peers.add([
        peer('p-off', 'Stage Manager', PeerStatus.offline),
        peer('p-on', 'FOH', PeerStatus.online),
        peer('p-stale', 'MON', PeerStatus.stale),
      ]);

      expect(presenter.dmOfflineWarning('p-off'),
          'Stage Manager appears offline — they may not receive this DM');
      expect(presenter.dmOfflineWarning('p-on'), isNull);
      // Stale = still remembered, best-effort delivery plausible: no warning.
      expect(presenter.dmOfflineWarning('p-stale'), isNull);
      // Unknown peer can't receive anything.
      expect(presenter.dmOfflineWarning('ghost'),
          'Unknown appears offline — they may not receive this DM');

      presenter.dispose();
    });
  });

  // ── #106 — imperative commands ────────────────────────────────────────────

  group('ShowDeliveryFailure', () {
    test('emitted when DeliveryUpdated arrives with failed=true', () async {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      ctrl.add(const DeliveryUpdated('msg-1', _failedStatus));

      expect(commands, hasLength(1));
      final cmd = commands.first as ShowDeliveryFailure;
      expect(cmd.messageId, 'msg-1');
      expect(cmd.status.failed, isTrue);
      expect(cmd.status.failedPeers, ['Stage Manager']);

      presenter.dispose();
    });

    test('summary phrases the failure by (total, failedPeers)', () {
      ShowDeliveryFailure cmd(int total, List<String> peers) =>
          ShowDeliveryFailure(
            messageId: 'm',
            status: MessageDeliveryStatus(
              delivered: 0,
              total: total,
              failed: true,
              failedPeers: peers,
            ),
          );
      expect(cmd(0, const []).summary,
          'Critical message no peers were online');
      expect(cmd(2, const ['Stage Manager', 'FOH']).summary,
          'Critical message not received by Stage Manager, FOH');
      expect(cmd(2, const []).summary,
          'Critical message not received by all peers');
    });

    test('not emitted when DeliveryUpdated arrives with failed=false', () async {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      ctrl.add(const DeliveryUpdated('msg-2', _successStatus));

      expect(commands, isEmpty);

      presenter.dispose();
    });
  });

  group('ShowPermissionDenied', () {
    test('emitted when PermissionDenied event arrives', () async {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      ctrl.add(const PermissionDenied('Local Network'));

      expect(commands, hasLength(1));
      final cmd = commands.first as ShowPermissionDenied;
      expect(cmd.context, 'Local Network');

      presenter.dispose();
    });

    test('emitted with empty context string when that is what the engine sends',
        () async {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      ctrl.add(const PermissionDenied(''));

      expect(commands, hasLength(1));
      expect((commands.first as ShowPermissionDenied).context, isEmpty);

      presenter.dispose();
    });
  });

  group('other events', () {
    test('produce no commands', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      ctrl.add(const PeersChanged());
      ctrl.add(const ChannelsChanged());
      ctrl.add(const ClientNameChanged('Alice'));

      expect(commands, isEmpty);

      presenter.dispose();
    });
  });

  // ── #107 — FlashState ownership ───────────────────────────────────────────

  group('Flashed event — channel flash', () {
    test('selected channel bumps flashCounts, flashNotify, and sets color/pulseCount', () {
      final ctrl = _pushes();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      ctrl.add(const Flashed(channelId: 'rf', senderId: 'p1', senderName: 'Alice'));

      expect(presenter.flashCounts['rf'], 1);
      expect(presenter.flashNotify, 1);

      presenter.dispose();
    });

    test('unselected channel bumps flashCounts only — flashNotify unchanged', () {
      final ctrl = _pushes();
      final sel = _sel()..selectTab('audio');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      ctrl.add(const Flashed(channelId: 'rf', senderId: 'p1', senderName: 'Alice'));

      expect(presenter.flashCounts['rf'], 1);
      expect(presenter.flashNotify, 0);

      presenter.dispose();
    });
  });

  group('Flashed event — DM flash', () {
    test('selected DM bumps flashNotify, adds peer to openDms', () {
      final ctrl = _pushes();
      final sel = _sel()..openDm('p1');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      ctrl.add(const Flashed(channelId: 'dm:p1', senderId: 'p1', senderName: 'Alice'));

      expect(presenter.flashNotify, 1);
      expect(presenter.openDms, contains('p1'));
      expect(presenter.unreadDms, isEmpty);

      presenter.dispose();
    });

    test('unselected DM adds to unreadDms and bumps dmPulseNotify', () {
      final ctrl = _pushes();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      ctrl.add(const Flashed(channelId: 'dm:p1', senderId: 'p1', senderName: 'Alice'));

      expect(presenter.flashNotify, 0);
      expect(presenter.unreadDms, contains('dm:p1'));
      expect(presenter.dmPulseNotify, 1);

      presenter.dispose();
    });
  });

  group('MessageReceived — DM unread', () {
    test('DM message for unselected thread marks it unread', () {
      final ctrl = _pushes();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      ctrl.add(MessageReceived(
        PatchMessage(
          messageId: 'mid',
          senderId: 'p1',
          senderName: 'Alice',
          channelId: 'dm:p1',
          priority: 1,
          payload: 'hey',
          timestamp: DateTime.now(),
        ),
      ));

      expect(presenter.unreadDms, contains('dm:p1'));

      presenter.dispose();
    });
  });

  group('apply — direct FlashEvent', () {
    test('ChannelFlashEvent on selected channel bumps flashNotify', () {
      final ctrl = _pushes();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
      );

      presenter.apply(
          const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(presenter.flashNotify, 1);
      expect(presenter.flashColor, Colors.red);
      expect(presenter.flashPulseCount, 3);

      presenter.dispose();
    });
  });

  group('PlayAlert command', () {
    test('emitted when audibleAlert=true and selected channel is flashed', () {
      final ctrl = _pushes();
      final cfgCtrl = _configs();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        configStream: cfgCtrl.stream,
        selectionController: sel,
      );
      cfgCtrl.add(_cfg(audibleAlert: true));
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      presenter.apply(
          const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(commands.whereType<PlayAlert>(), hasLength(1));

      presenter.dispose();
    });

    test('not emitted when audibleAlert=false', () {
      final ctrl = _pushes();
      final cfgCtrl = _configs();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        configStream: cfgCtrl.stream,
        selectionController: sel,
      );
      cfgCtrl.add(_cfg(audibleAlert: false));
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      presenter.apply(
          const ChannelFlashEvent(channelId: 'rf', color: Colors.red, pulseCount: 3));

      expect(commands.whereType<PlayAlert>(), isEmpty);

      presenter.dispose();
    });
  });

  group('PulseOverlay command', () {
    test('emitted with color+count when flashWholeScreen=true and selected channel flashes', () {
      final ctrl = _pushes();
      final cfgCtrl = _configs();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        configStream: cfgCtrl.stream,
        supportsFlashOverlay: true,
        selectionController: sel,
      );
      cfgCtrl.add(_cfg(flashWholeScreen: true));
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      presenter.apply(
          const ChannelFlashEvent(channelId: 'rf', color: Colors.green, pulseCount: 5));

      final overlays = commands.whereType<PulseOverlay>().toList();
      expect(overlays, hasLength(1));
      expect(overlays.first.color, Colors.green);
      expect(overlays.first.pulseCount, 5);

      presenter.dispose();
    });

    test('not emitted when flashWholeScreen=false', () {
      final ctrl = _pushes();
      final cfgCtrl = _configs();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        configStream: cfgCtrl.stream,
        selectionController: sel,
      );
      cfgCtrl.add(_cfg(flashWholeScreen: false));
      final commands = <HomeCommand>[];
      presenter.commands.listen(commands.add);

      presenter.apply(
          const ChannelFlashEvent(channelId: 'rf', color: Colors.green, pulseCount: 5));

      expect(commands.whereType<PulseOverlay>(), isEmpty);

      presenter.dispose();
    });
  });

  // ── #160 — HomeController folded in: store→presenter reduction ───────────

  group('HomePresenter.onStoreChanged', () {
    test('applies config and peers immediately — no stream round-trip', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);

      presenter.onStoreChanged(
        config: _cfg(),
        peers: [peer('p1', 'Alice', PeerStatus.online)],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );

      expect(presenter.flashCount, 4);
      expect(presenter.dmPeerName('p1'), 'Alice');
      presenter.dispose();
    });

    test('name prompt fires once for a default name, never again', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final first = presenter.onStoreChanged(
        config: _cfg(nameIsDefault: true),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      final second = presenter.onStoreChanged(
        config: _cfg(nameIsDefault: true),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      expect(first.showNamePrompt, isTrue);
      expect(second.showNamePrompt, isFalse);
      presenter.dispose();
    });

    test('no name prompt when the Operator already set a name', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final fx = presenter.onStoreChanged(
        config: _cfg(nameIsDefault: false),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      expect(fx.showNamePrompt, isFalse);
      presenter.dispose();
    });

    test(
        'macros panel default derives from configured macros only while '
        'no explicit preference exists', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final fx = presenter.onStoreChanged(
        config: _cfg(),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: false,
        anyMacrosConfigured: true,
      );
      expect(fx.defaultMacrosPanel, isTrue);

      final afterPreference = presenter.onStoreChanged(
        config: _cfg(),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: true,
      );
      expect(afterPreference.defaultMacrosPanel, isNull);
      presenter.dispose();
    });

    test('no macros panel default before the first config load', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      final fx = presenter.onStoreChanged(
        config: null,
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: false,
        anyMacrosConfigured: false,
      );
      expect(fx.defaultMacrosPanel, isNull);
      presenter.dispose();
    });

    test('selection reconciles only when the Channel id list changes', () {
      final ctrl = _pushes();
      final presenter = HomePresenter(pushes: ctrl.stream);
      HomeStoreEffects fire(List<String> ids) => presenter.onStoreChanged(
            config: _cfg(),
            peers: const [],
            channelIds: ids,
            macrosPanelPreferenceSet: true,
            anyMacrosConfigured: false,
          );

      expect(fire(['rf']).reconcileSelection, isTrue);
      expect(fire(['rf']).reconcileSelection, isFalse);
      expect(fire(['rf', 'audio']).reconcileSelection, isTrue);
      expect(fire(['rf', 'audio']).reconcileSelection, isFalse);
      presenter.dispose();
    });
  });

  // ── #113 — channelGetter called at flash time, not captured at init ───────

  group('channelGetter', () {
    test('channels added after construction are visible at flash time', () {
      final channels = <PatchChannel>[];
      final ctrl = _pushes();
      final sel = _sel()..selectTab('rf');
      final presenter = HomePresenter(
        pushes: ctrl.stream,
        selectionController: sel,
        channelGetter: () => channels,
      );

      const ch = PatchChannel(
          id: 'rf', displayName: 'RF', color: Color(0xFFFF0000), flashCount: 2);
      channels.add(ch);

      ctrl.add(MessageReceived(
        PatchMessage(
          messageId: 'm',
          senderId: 's',
          senderName: 'S',
          channelId: 'rf',
          priority: 3,
          payload: 'hi',
          timestamp: DateTime.now(),
        ),
      ));

      expect(presenter.flashColor, const Color(0xFFFF0000));
      expect(presenter.flashPulseCount, 2);

      presenter.dispose();
    });
  });
}
