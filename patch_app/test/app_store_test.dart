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

  /// When set, [getMessages] waits on it before returning — lets a test
  /// interleave a push while a fetch is in flight.
  Completer<void>? gateMessages;

  @override
  Future<List<PatchMessage>> getMessages(String channelId, {int limit = 500}) async {
    getMessagesCalls++;
    if (gateMessages != null) await gateMessages!.future;
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

  test('PeerExpired push coalesces a burst into one debounced refetch',
      () async {
    // "Clear inactive peers" emits one PeerExpired per removed peer — N
    // stale peers must not mean N full refetches.
    bridge.peersToReturn = [_peer('a')];
    var notified = 0;
    store.addListener(() => notified++);

    pushes
      ..add(const PeerExpired('gone-1'))
      ..add(const PeerExpired('gone-2'))
      ..add(const PeerExpired('gone-3'));
    await pumpEventQueue();
    expect(bridge.getPeersCalls, 0, reason: 'still within the debounce window');

    await Future<void>.delayed(const Duration(milliseconds: 850));

    expect(bridge.getPeersCalls, 1, reason: 'one refetch for the whole burst');
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

  test('MessageReceived push stamps each message with an increasing '
      'localSeq, in arrival order, regardless of channel', () async {
    pushes.add(MessageReceived(_msg('rf', 'm1')));
    await pumpEventQueue();
    pushes.add(MessageReceived(_msg('audio', 'm2')));
    await pumpEventQueue();
    pushes.add(MessageReceived(_msg('rf', 'm3')));
    await pumpEventQueue();

    final rfSeqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    final audioSeq = store.messages['audio']!.single.localSeq;
    expect(rfSeqs[0], lessThan(audioSeq));
    expect(audioSeq, lessThan(rfSeqs[1]));
  });

  test('ensureMessages fetches a channel once', () async {
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a'), _msg('rf', 'b')];

    await store.ensureMessages('rf');
    expect(store.messages['rf']?.length, 2);
    expect(bridge.getMessagesCalls, 1);

    await store.ensureMessages('rf'); // already loaded — no refetch
    expect(bridge.getMessagesCalls, 1);
  });

  test('ensureMessages stamps fetched history with increasing localSeq, '
      'preserving the order the bridge returned', () async {
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a'), _msg('rf', 'b')];

    await store.ensureMessages('rf');

    final seqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    expect(seqs[0], lessThan(seqs[1]));
  });

  test('a message pushed while ensureMessages is fetching survives the merge',
      () async {
    // The fetch snapshot can predate the pushed message's engine-side store —
    // overwriting the buffer with the snapshot would lose it from the UI
    // until restart, since nothing ever refetches message history.
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a')];
    bridge.gateMessages = Completer<void>();

    final fetch = store.ensureMessages('rf');
    pushes.add(MessageReceived(_msg('rf', 'live'))); // arrives mid-fetch
    await pumpEventQueue();
    bridge.gateMessages!.complete();
    await fetch;

    final rf = store.messages['rf']!;
    expect(rf.map((m) => m.messageId), ['a', 'live']);
    expect(rf[0].localSeq, lessThan(rf[1].localSeq),
        reason: 'history sorts before the just-arrived tail');
  });

  test('a message pushed mid-fetch that the snapshot already includes is '
      'not duplicated', () async {
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a'), _msg('rf', 'live')];
    bridge.gateMessages = Completer<void>();

    final fetch = store.ensureMessages('rf');
    pushes.add(MessageReceived(_msg('rf', 'live')));
    await pumpEventQueue();
    bridge.gateMessages!.complete();
    await fetch;

    expect(store.messages['rf']!.map((m) => m.messageId), ['a', 'live']);
  });

  test('trimming the 500-message cap drops the trimmed delivery entries too',
      () async {
    pushes.add(MessageReceived(_msg('rf', 'm0')));
    pushes.add(const DeliveryUpdated(
      'm0',
      MessageDeliveryStatus(delivered: 1, total: 1, failed: false),
    ));
    // 500 more on the same channel pushes m0 out of the ring.
    for (var i = 1; i <= 500; i++) {
      pushes.add(MessageReceived(_msg('rf', 'm$i')));
    }
    await pumpEventQueue();

    expect(store.messages['rf']!.length, 500);
    expect(store.messages['rf']!.first.messageId, 'm1');
    expect(store.delivery.containsKey('m0'), isFalse,
        reason: 'trimmed message must not leak its delivery entry');
  });

  test('Resynced push refetches loaded message buffers, recovering a '
      'message the event stream dropped', () async {
    // The engine sends Desynced when this subscriber's event stream lagged —
    // a dropped MessageReceived would otherwise never render, since buffers
    // are push-fed and never refetched after their first load.
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a')];
    await store.ensureMessages('rf');
    expect(store.messages['rf']!.map((m) => m.messageId), ['a']);

    // 'b' arrived engine-side but its push was dropped by the lag.
    bridge.messagesToReturn['rf'] = [_msg('rf', 'a'), _msg('rf', 'b')];
    pushes.add(const Resynced());
    await pumpEventQueue();

    expect(store.messages['rf']!.map((m) => m.messageId), ['a', 'b']);
    final seqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    expect(seqs[0], lessThan(seqs[1]), reason: 'buffer order is preserved');
  });

  test('Resynced push refetches peers, config, and channels, and keeps '
      'delivery entries', () async {
    pushes.add(const DeliveryUpdated(
      'm1',
      MessageDeliveryStatus(delivered: 1, total: 2, failed: false),
    ));
    await pumpEventQueue();
    bridge.peersToReturn = [_peer('a')];
    bridge.configToReturn = _cfg(clientName: 'After');
    bridge.channelsToReturn = [_chan('rf')];

    pushes.add(const Resynced());
    await pumpEventQueue();

    expect(store.peers.single.peerId, 'a');
    expect(store.config?.clientName, 'After');
    expect(store.channels.single.id, 'rf');
    expect(store.delivery.containsKey('m1'), isTrue,
        reason: 'a resync must not discard in-flight delivery status');
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

    // Next fetch throws — the store should swallow and keep the old list,
    // and listeners must not be notified for a failed refresh (#185).
    var notified2 = 0;
    final throwingBridge = _ThrowingBridge(pushes);
    final store2 = AppStore(throwingBridge)..addListener(() => notified2++);
    await store2.refreshPeers();
    expect(store2.peers, isEmpty); // unchanged from its initial empty state
    expect(notified2, 0);
    store2.dispose();
  });
}

class _ThrowingBridge extends _FakeBridge {
  _ThrowingBridge(super.pushController);
  @override
  Future<List<PeerInfo>> getPeers() async => throw StateError('boom');
}
