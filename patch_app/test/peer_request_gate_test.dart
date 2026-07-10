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
      expect(gate.admitOffer(), isTrue);
    });

    test('an unsolicited offer is refused (never requested)', () {
      expect(gate.admitOffer(), isFalse);
    });

    test('an admitted offer disarms the gate — a second offer is refused',
        () async {
      await gate.request('peer-1');
      expect(gate.admitOffer(), isTrue);
      expect(gate.admitOffer(), isFalse);
    });

    test('timeout disarms and reports it fired, if still awaiting', () async {
      await gate.request('peer-1');
      expect(gate.timeout(), isTrue);
      expect(gate.admitOffer(), isFalse);
    });

    test('timeout is a no-op if an offer already arrived', () async {
      await gate.request('peer-1');
      gate.admitOffer();
      expect(gate.timeout(), isFalse);
    });

    test('two gates cannot cross-trigger — each flow owns its own', () async {
      final other = PeerRequestGate(sendRequest: (_) async {});
      await gate.request('peer-1');
      expect(other.admitOffer(), isFalse);
      expect(gate.admitOffer(), isTrue);
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
