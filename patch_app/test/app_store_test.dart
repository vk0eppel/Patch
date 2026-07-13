import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:patch/models/events.dart';
import 'package:patch/models/message.dart';
import 'package:patch/store/app_store.dart';

import 'support/fake_bridge.dart';

void main() {
  late FakeBridge bridge;
  late AppStore store;

  setUp(() {
    bridge = FakeBridge();
    store = AppStore(bridge);
  });

  tearDown(() {
    store.dispose();
  });

  test(
    'start() loads peers, config, and channels and notifies for each',
    () async {
      bridge.peersToReturn = [peerInfo('a'), peerInfo('b')];
      bridge.configToReturn = cfg(clientName: 'FOH');
      bridge.channelsToReturn = [chan('rf')];
      var notified = 0;
      store.addListener(() => notified++);

      await store.start();

      expect(store.peers.map((p) => p.peerId), ['a', 'b']);
      expect(store.config?.clientName, 'FOH');
      expect(store.channels.single.id, 'rf');
      expect(notified, 3); // peers + config + channels
    },
  );

  test('ChannelsChanged push refetches channels and notifies', () async {
    bridge.channelsToReturn = [chan('rf')];
    await store.refreshChannels();
    expect(store.channels.single.id, 'rf');

    bridge.channelsToReturn = [chan('rf'), chan('audio')];
    var notified = 0;
    store.addListener(() => notified++);

    bridge.push(const ChannelsChanged());
    await pumpEventQueue();

    expect(store.channels.map((c) => c.id), ['rf', 'audio']);
    expect(notified, 1);
  });

  test('ClientNameChanged push refetches config and notifies', () async {
    bridge.configToReturn = cfg(clientName: 'Old');
    await store.refreshConfig();
    expect(store.config?.clientName, 'Old');

    bridge.configToReturn = cfg(clientName: 'New');
    var notified = 0;
    store.addListener(() => notified++);

    bridge.push(const ClientNameChanged('New'));
    await pumpEventQueue();

    expect(store.config?.clientName, 'New');
    expect(notified, 1);
  });

  test(
    'PeerExpired push coalesces a burst into one debounced refetch',
    () async {
      // "Clear inactive peers" emits one PeerExpired per removed peer — N
      // stale peers must not mean N full refetches.
      bridge.peersToReturn = [peerInfo('a')];
      var notified = 0;
      store.addListener(() => notified++);

      bridge
        ..push(const PeerExpired('gone-1'))
        ..push(const PeerExpired('gone-2'))
        ..push(const PeerExpired('gone-3'));
      await pumpEventQueue();
      expect(
        bridge.getPeersCalls,
        0,
        reason: 'still within the debounce window',
      );

      await Future<void>.delayed(const Duration(milliseconds: 850));

      expect(
        bridge.getPeersCalls,
        1,
        reason: 'one refetch for the whole burst',
      );
      expect(store.peers.single.peerId, 'a');
      expect(notified, 1);
    },
  );

  test(
    'PeersChanged push coalesces a burst into one debounced refetch',
    () async {
      bridge.peersToReturn = [peerInfo('a')];
      var notified = 0;
      store.addListener(() => notified++);

      // A burst of PeersChanged (one per received packet).
      bridge
        ..push(const PeersChanged())
        ..push(const PeersChanged())
        ..push(const PeersChanged());
      await pumpEventQueue();
      expect(
        bridge.getPeersCalls,
        0,
        reason: 'still within the debounce window',
      );

      await Future<void>.delayed(const Duration(milliseconds: 850));

      expect(
        bridge.getPeersCalls,
        1,
        reason: 'one refetch for the whole burst',
      );
      expect(store.peers.single.peerId, 'a');
      expect(notified, 1);
    },
  );

  test(
    'MessageReceived push appends to the channel buffer and notifies',
    () async {
      var notified = 0;
      store.addListener(() => notified++);

      bridge.push(MessageReceived(msg('rf', 'm1')));
      await pumpEventQueue();

      expect(store.messages['rf']?.map((m) => m.messageId), ['m1']);
      expect(notified, 1);
    },
  );

  test('MessageReceived push stamps each message with an increasing '
      'localSeq, in arrival order, regardless of channel', () async {
    bridge.push(MessageReceived(msg('rf', 'm1')));
    await pumpEventQueue();
    bridge.push(MessageReceived(msg('audio', 'm2')));
    await pumpEventQueue();
    bridge.push(MessageReceived(msg('rf', 'm3')));
    await pumpEventQueue();

    final rfSeqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    final audioSeq = store.messages['audio']!.single.localSeq;
    expect(rfSeqs[0], lessThan(audioSeq));
    expect(audioSeq, lessThan(rfSeqs[1]));
  });

  test('ensureMessages fetches a channel once', () async {
    bridge.messagesToReturn['rf'] = [msg('rf', 'a'), msg('rf', 'b')];

    await store.ensureMessages('rf');
    expect(store.messages['rf']?.length, 2);
    expect(bridge.getMessagesCalls, 1);

    await store.ensureMessages('rf'); // already loaded — no refetch
    expect(bridge.getMessagesCalls, 1);
  });

  test('ensureMessages stamps fetched history with increasing localSeq, '
      'preserving the order the bridge returned', () async {
    bridge.messagesToReturn['rf'] = [msg('rf', 'a'), msg('rf', 'b')];

    await store.ensureMessages('rf');

    final seqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    expect(seqs[0], lessThan(seqs[1]));
  });

  test(
    'a message pushed while ensureMessages is fetching survives the merge',
    () async {
      // The fetch snapshot can predate the pushed message's engine-side store —
      // overwriting the buffer with the snapshot would lose it from the UI
      // until restart, since nothing ever refetches message history.
      bridge.messagesToReturn['rf'] = [msg('rf', 'a')];
      bridge.gateMessages = Completer<void>();

      final fetch = store.ensureMessages('rf');
      bridge.push(MessageReceived(msg('rf', 'live'))); // arrives mid-fetch
      await pumpEventQueue();
      bridge.gateMessages!.complete();
      await fetch;

      final rf = store.messages['rf']!;
      expect(rf.map((m) => m.messageId), ['a', 'live']);
      expect(
        rf[0].localSeq,
        lessThan(rf[1].localSeq),
        reason: 'history sorts before the just-arrived tail',
      );
    },
  );

  test('a message pushed mid-fetch that the snapshot already includes is '
      'not duplicated', () async {
    bridge.messagesToReturn['rf'] = [msg('rf', 'a'), msg('rf', 'live')];
    bridge.gateMessages = Completer<void>();

    final fetch = store.ensureMessages('rf');
    bridge.push(MessageReceived(msg('rf', 'live')));
    await pumpEventQueue();
    bridge.gateMessages!.complete();
    await fetch;

    expect(store.messages['rf']!.map((m) => m.messageId), ['a', 'live']);
  });

  test(
    'trimming the 500-message cap drops the trimmed delivery entries too',
    () async {
      bridge.push(MessageReceived(msg('rf', 'm0')));
      bridge.push(
        const DeliveryUpdated(
          'm0',
          MessageDeliveryStatus(delivered: 1, total: 1, failed: false),
        ),
      );
      // 500 more on the same channel pushes m0 out of the ring.
      for (var i = 1; i <= 500; i++) {
        bridge.push(MessageReceived(msg('rf', 'm$i')));
      }
      await pumpEventQueue();

      expect(store.messages['rf']!.length, 500);
      expect(store.messages['rf']!.first.messageId, 'm1');
      expect(
        store.delivery.containsKey('m0'),
        isFalse,
        reason: 'trimmed message must not leak its delivery entry',
      );
    },
  );

  test('Resynced push refetches loaded message buffers, recovering a '
      'message the event stream dropped', () async {
    // The engine sends Desynced when this subscriber's event stream lagged —
    // a dropped MessageReceived would otherwise never render, since buffers
    // are push-fed and never refetched after their first load.
    bridge.messagesToReturn['rf'] = [msg('rf', 'a')];
    await store.ensureMessages('rf');
    expect(store.messages['rf']!.map((m) => m.messageId), ['a']);

    // 'b' arrived engine-side but its push was dropped by the lag.
    bridge.messagesToReturn['rf'] = [msg('rf', 'a'), msg('rf', 'b')];
    bridge.push(const Resynced());
    await pumpEventQueue();

    expect(store.messages['rf']!.map((m) => m.messageId), ['a', 'b']);
    final seqs = store.messages['rf']!.map((m) => m.localSeq).toList();
    expect(seqs[0], lessThan(seqs[1]), reason: 'buffer order is preserved');
  });

  test('Resynced push refetches peers, config, and channels, and keeps '
      'delivery entries', () async {
    bridge.push(
      const DeliveryUpdated(
        'm1',
        MessageDeliveryStatus(delivered: 1, total: 2, failed: false),
      ),
    );
    await pumpEventQueue();
    bridge.peersToReturn = [peerInfo('a')];
    bridge.configToReturn = cfg(clientName: 'After');
    bridge.channelsToReturn = [chan('rf')];

    bridge.push(const Resynced());
    await pumpEventQueue();

    expect(store.peers.single.peerId, 'a');
    expect(store.config?.clientName, 'After');
    expect(store.channels.single.id, 'rf');
    expect(
      store.delivery.containsKey('m1'),
      isTrue,
      reason: 'a resync must not discard in-flight delivery status',
    );
  });

  test('dropMessages clears a channel buffer and notifies', () async {
    bridge.messagesToReturn['rf'] = [msg('rf', 'a')];
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

    bridge.push(
      const DeliveryUpdated(
        'm1',
        MessageDeliveryStatus(delivered: 1, total: 2, failed: false),
      ),
    );
    await pumpEventQueue();

    expect(store.delivery['m1']?.delivered, 1);
    expect(notified, 1);
  });

  test('a fetch failure keeps the current list and does not throw', () async {
    bridge.peersToReturn = [peerInfo('a')];
    await store.refreshPeers();
    expect(store.peers.single.peerId, 'a');

    // Next fetch throws — the store should swallow and keep the old list,
    // and listeners must not be notified for a failed refresh (#185).
    var notified2 = 0;
    final throwingBridge = _ThrowingBridge();
    final store2 = AppStore(throwingBridge)..addListener(() => notified2++);
    await store2.refreshPeers();
    expect(store2.peers, isEmpty); // unchanged from its initial empty state
    expect(notified2, 0);
    store2.dispose();
  });
}

class _ThrowingBridge extends FakeBridge {
  @override
  Future<List<PeerInfo>> getPeers() async => throw StateError('boom');
}
