import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/peer_request_gate.dart';

PatchChannel ch(String id) =>
    PatchChannel(id: id, displayName: id, color: Colors.red);

void main() {
  late List<String> calls;
  late PeerRequestGate gate;

  setUp(() {
    calls = [];
    gate = PeerRequestGate(
      sendRequest: (peerId) async => calls.add('request:$peerId'),
    );
  });

  group('PeerRequestGate (#182: the one request/offer race, both import flows)',
      () {
    test('request sends and arms the gate', () async {
      await gate.request('peer-1');
      expect(calls, ['request:peer-1']);
      expect(gate.admitOffer(() => 'offer'), 'offer');
    });

    test('an unsolicited offer is refused (never requested)', () {
      expect(gate.admitOffer(() => 'offer'), isNull);
    });

    test('an admitted offer disarms the gate — a second offer is refused',
        () async {
      await gate.request('peer-1');
      expect(gate.admitOffer(() => 1), 1);
      expect(gate.admitOffer(() => 2), isNull);
    });

    test('timeout disarms and reports it fired, if still awaiting', () async {
      await gate.request('peer-1');
      expect(gate.timeout(), isTrue);
      expect(gate.admitOffer(() => 'stale'), isNull);
    });

    test('timeout is a no-op if an offer already arrived', () async {
      await gate.request('peer-1');
      gate.admitOffer(() => 'offer');
      expect(gate.timeout(), isFalse);
    });

    test('two gates cannot cross-trigger — each flow owns its own', () async {
      final other = PeerRequestGate(sendRequest: (_) async {});
      await gate.request('peer-1');
      expect(other.admitOffer(() => 'offer'), isNull);
      expect(gate.admitOffer(() => 'offer'), 'offer');
    });
  });

  group('freshChannels', () {
    test('returns only offered channels not already held', () {
      final fresh = freshChannels(
        offered: [ch('a'), ch('b'), ch('c')],
        existing: [ch('b')],
      );
      expect(fresh.map((c) => c.id), ['a', 'c']);
    });
  });
}
