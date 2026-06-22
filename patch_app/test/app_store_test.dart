import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter/widgets.dart' show Color;

import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/config.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/message.dart';
import 'package:patch/store/app_store.dart';

/// A fake bridge that overrides only what [AppStore] touches — the typed
/// `pushes` stream and `getPeers()`. `BridgeClient()`'s constructor just makes
/// stream controllers (no engine), so subclassing is safe in a unit test.
class _FakeBridge extends BridgeClient {
  _FakeBridge(this._pushController);

  final StreamController<PatchEvent> _pushController;
  List<PeerInfo> peersToReturn = const [];
  AppConfig configToReturn = _cfg();
  List<PatchChannel> channelsToReturn = const [];
  Map<String, List<PatchMessage>> messagesToReturn = {};
  int getPeersCalls = 0;
  int getConfigCalls = 0;
  int getChannelsCalls = 0;
  int getMessagesCalls = 0;

  @override
  Stream<PatchEvent> get pushes => _pushController.stream;

  @override
  Future<List<PeerInfo>> getPeers() async {
    getPeersCalls++;
    return peersToReturn;
  }

  @override
  Future<AppConfig> getConfig() async {
    getConfigCalls++;
    return configToReturn;
  }

  @override
  Future<List<PatchChannel>> getChannels() async {
    getChannelsCalls++;
    return channelsToReturn;
  }

  @override
  Future<List<PatchMessage>> getMessages(String channelId, {int limit = 500}) async {
    getMessagesCalls++;
    return messagesToReturn[channelId] ?? const [];
  }
}

PatchChannel _chan(String id) =>
    PatchChannel(id: id, displayName: id.toUpperCase(), color: const Color(0xFF1E88E5));

PatchMessage _msg(String channelId, String id) => PatchMessage(
      messageId: id,
      senderId: 's',
      senderName: 'S',
      channelId: channelId,
      timestamp: DateTime.utc(2026, 6, 22),
      priority: 1,
      payload: 'hi',
    );

AppConfig _cfg({String clientName = 'Me', bool nameIsDefault = false}) =>
    AppConfig(
      clientName: clientName,
      oscPort: 9000,
      flashOnCritical: true,
      flashOnMessage: false,
      flashCount: 4,
      macrosColumns: 1,
      hideKeyboard: true,
      audibleAlert: false,
      heartbeatIntervalSecs: 7,
      nameIsDefault: nameIsDefault,
    );

PeerInfo _peer(String id) => PeerInfo(
      peerId: id,
      peerName: 'peer-$id',
      channels: const [],
      address: '10.0.0.1',
      oscPort: 9000,
      lastSeen: DateTime.utc(2026, 6, 22),
      discoveryMode: 'osc_beacon',
      status: PeerStatus.online,
    );

void main() {
  late StreamController<PatchEvent> pushes;
  late _FakeBridge bridge;
  late AppStore store;

  setUp(() {
    pushes = StreamController<PatchEvent>.broadcast();
    bridge = _FakeBridge(pushes);
    store = AppStore(bridge);
  });

  tearDown(() async {
    store.dispose();
    await pushes.close();
  });

  test('start() loads peers, config, and channels and notifies for each',
      () async {
    bridge.peersToReturn = [_peer('a'), _peer('b')];
    bridge.configToReturn = _cfg(clientName: 'FOH');
    bridge.channelsToReturn = [_chan('rf')];
    var notified = 0;
    store.addListener(() => notified++);

    await store.start();

    expect(store.peers.map((p) => p.peerId), ['a', 'b']);
    expect(store.config?.clientName, 'FOH');
    expect(store.channels.single.id, 'rf');
    expect(notified, 3); // peers + config + channels
  });

  test('ChannelsChanged push refetches channels and notifies', () async {
    bridge.channelsToReturn = [_chan('rf')];
    await store.refreshChannels();
    expect(store.channels.single.id, 'rf');

    bridge.channelsToReturn = [_chan('rf'), _chan('audio')];
    var notified = 0;
    store.addListener(() => notified++);

    pushes.add(const ChannelsChanged());
    await pumpEventQueue();

    expect(store.channels.map((c) => c.id), ['rf', 'audio']);
    expect(notified, 1);
  });

  test('ClientNameChanged push refetches config and notifies', () async {
    bridge.configToReturn = _cfg(clientName: 'Old');
    await store.refreshConfig();
    expect(store.config?.clientName, 'Old');

    bridge.configToReturn = _cfg(clientName: 'New');
    var notified = 0;
    store.addListener(() => notified++);

    pushes.add(const ClientNameChanged('New'));
    await pumpEventQueue();

    expect(store.config?.clientName, 'New');
    expect(notified, 1);
  });

  test('PeerExpired push refetches peers and notifies (no debounce)', () async {
    bridge.peersToReturn = [_peer('a')];
    var notified = 0;
    store.addListener(() => notified++);

    pushes.add(const PeerExpired('gone'));
    await pumpEventQueue();

    expect(bridge.getPeersCalls, 1);
    expect(store.peers.single.peerId, 'a');
    expect(notified, 1);
  });

  test('PeersChanged push coalesces a burst into one debounced refetch',
      () async {
    bridge.peersToReturn = [_peer('a')];
    var notified = 0;
    store.addListener(() => notified++);

    // A burst of PeersChanged (one per received packet).
    pushes
      ..add(const PeersChanged())
      ..add(const PeersChanged())
      ..add(const PeersChanged());
    await pumpEventQueue();
    expect(bridge.getPeersCalls, 0, reason: 'still within the debounce window');

    await Future<void>.delayed(const Duration(milliseconds: 850));

    expect(bridge.getPeersCalls, 1, reason: 'one refetch for the whole burst');
    expect(store.peers.single.peerId, 'a');
    expect(notified, 1);
  });

  test('MessageReceived push appends to the channel buffer and notifies',
      () async {
    var notified = 0;
    store.addListener(() => notified++);

    pushes.add(MessageReceived(_msg('rf', 'm1')));
    await pumpEventQueue();

    expect(store.messages['rf']?.map((m) => m.messageId), ['m1']);
    expect(notified, 1);
  });

  test('ensureMessages fetches a channel once', () async {
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a'), _msg('rf', 'b')];

    await store.ensureMessages('rf');
    expect(store.messages['rf']?.length, 2);
    expect(bridge.getMessagesCalls, 1);

    await store.ensureMessages('rf'); // already loaded — no refetch
    expect(bridge.getMessagesCalls, 1);
  });

  test('dropMessages clears a channel buffer and notifies', () async {
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a')];
    await store.ensureMessages('rf');
    var notified = 0;
    store.addListener(() => notified++);

    store.dropMessages('rf');

    expect(store.messages.containsKey('rf'), isFalse);
    expect(notified, 1);
  });

  test('DeliveryUpdated push tracks status and notifies', () async {
    var notified = 0;
    store.addListener(() => notified++);

    pushes.add(const DeliveryUpdated(
      'm1',
      MessageDeliveryStatus(delivered: 1, total: 2, failed: false),
    ));
    await pumpEventQueue();

    expect(store.delivery['m1']?.delivered, 1);
    expect(notified, 1);
  });

  test('a fetch failure keeps the current list and does not throw', () async {
    bridge.peersToReturn = [_peer('a')];
    await store.refreshPeers();
    expect(store.peers.single.peerId, 'a');

    // Next fetch throws — the store should swallow and keep the old list.
    final throwingBridge = _ThrowingBridge(pushes);
    final store2 = AppStore(throwingBridge)..addListener(() {});
    await store2.refreshPeers();
    expect(store2.peers, isEmpty); // unchanged from its initial empty state
    store2.dispose();
  });
}

class _ThrowingBridge extends _FakeBridge {
  _ThrowingBridge(super.pushController);
  @override
  Future<List<PeerInfo>> getPeers() async => throw StateError('boom');
}
