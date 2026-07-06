import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/events.dart';
import 'package:patch/src/rust/api.dart' as rust;
import 'package:patch/src/rust/osc/types.dart' as rust_osc;
import 'package:patch/src/rust/state/channel.dart' as rust_channel;

/// Unit tests for `patchEventFromRust` — the pure wire→model mapper at the FFI
/// event seam (slice 1.1, ADR-0004). The FRB event values are plain data
/// classes, so this needs no `RustLib.init()`. The tests cover the field
/// conversions the compiler cannot see (UuidValue→String, Priority→index, hex
/// colour) and pin the two intentional drops.
void main() {
  final msgId = UuidValue.fromString('11111111-1111-1111-1111-111111111111');
  final senderId = UuidValue.fromString('22222222-2222-2222-2222-222222222222');
  final ts = DateTime.utc(2026, 6, 21, 12, 0, 0);

  rust_osc.PatchMessage msg() => rust_osc.PatchMessage(
        messageId: msgId,
        senderId: senderId,
        senderName: 'FOH',
        channelId: 'rf',
        timestamp: ts,
        priority: rust_osc.Priority.critical,
        payload: 'standby',
        isFlash: false,
      );

  group('data-carrying variants', () {
    test('Message → MessageReceived with converted fields', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.message(msg()));
      expect(ev, isA<MessageReceived>());
      final m = (ev as MessageReceived).message;
      expect(m.messageId, msgId.toString()); // UuidValue → String
      expect(m.senderId, senderId.toString());
      expect(m.senderName, 'FOH');
      expect(m.channelId, 'rf');
      expect(m.priority, 3); // Priority.critical → index
      expect(m.payload, 'standby');
      expect(m.timestamp, ts);
    });

    test('MessageDelivery → DeliveryUpdated carrying a MessageDeliveryStatus', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.messageDelivery(
        messageId: 'abc',
        delivered: 2,
        total: 3,
        failed: false,
        failedPeers: const ['Lighting'],
      ));
      expect(ev, isA<DeliveryUpdated>());
      final d = ev as DeliveryUpdated;
      expect(d.messageId, 'abc');
      expect(d.status.delivered, 2);
      expect(d.status.total, 3);
      expect(d.status.failed, isFalse);
      expect(d.status.failedPeers, const ['Lighting']);
    });

    test('ChannelFlash → Flashed with senderId stringified', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.channelFlash(
        rust_osc.ChannelFlash(
          channelId: 'rf',
          senderId: senderId,
          senderName: 'FOH',
        ),
      ));
      expect(ev, isA<Flashed>());
      final f = ev as Flashed;
      expect(f.channelId, 'rf');
      expect(f.senderId, senderId.toString());
      expect(f.senderName, 'FOH');
    });

    test('Desynced → Resynced (lagged subscriber must refetch)', () {
      final ev = patchEventFromRust(const rust.PatchAppEvent.desynced());
      expect(ev, isA<Resynced>());
    });

    test('PeerExpired → PeerExpired carrying the peer id', () {
      final ev =
          patchEventFromRust(rust.PatchAppEvent.peerExpired(peerId: 'peer-9'));
      expect(ev, isA<PeerExpired>());
      expect((ev as PeerExpired).peerId, 'peer-9');
    });

    test('ChannelsOffered → ChannelsOffered with converted channels', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.channelsOffered(
        fromPeerId: 'peer-1',
        fromName: 'Booth',
        channels: [
          const rust_channel.Channel(
            id: 'rf',
            displayName: 'RF',
            color: '#1E88E5',
            macros: [],
            flashOnCritical: true,
            flashOnMessage: false,
          ),
        ],
      ));
      expect(ev, isA<ChannelsOffered>());
      final o = ev as ChannelsOffered;
      expect(o.fromPeerId, 'peer-1');
      expect(o.fromName, 'Booth');
      expect(o.channels, hasLength(1));
      expect(o.channels.single.id, 'rf');
      expect(o.channels.single.displayName, 'RF'); // hex colour parsed by converter
    });

    test('GlobalMacrosOffered → GlobalMacrosOffered with converted macros',
        () {
      final ev = patchEventFromRust(rust.PatchAppEvent.globalMacrosOffered(
        fromPeerId: 'peer-1',
        fromName: 'Booth',
        globalMacros: [
          const rust_channel.MacroMessage(
            label: 'GO',
            payload: 'Go',
            priority: 1,
          ),
        ],
      ));
      expect(ev, isA<GlobalMacrosOffered>());
      final o = ev as GlobalMacrosOffered;
      expect(o.fromPeerId, 'peer-1');
      expect(o.fromName, 'Booth');
      expect(o.globalMacros, hasLength(1));
      expect(o.globalMacros.single.label, 'GO');
    });

    test('ClientNameChanged → ClientNameChanged', () {
      final ev = patchEventFromRust(
          rust.PatchAppEvent.clientNameChanged(name: 'Stage Manager'));
      expect((ev as ClientNameChanged).name, 'Stage Manager');
    });

    test('PermissionDenied → PermissionDenied', () {
      final ev = patchEventFromRust(
          rust.PatchAppEvent.permissionDenied(context: 'Local Network blocked'));
      expect((ev as PermissionDenied).context, 'Local Network blocked');
    });
  });

  group('refetch signals (payload-free)', () {
    test('PeerUpdated → PeersChanged, dropping the presence payload', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.peerUpdated(
        rust_osc.PeerPresence(
          peerId: senderId,
          peerName: 'someone',
          channels: const [],
          role: null,
          timestamp: ts,
        ),
      ));
      expect(ev, isA<PeersChanged>());
    });

    test('ChannelListUpdated → ChannelsChanged', () {
      final ev = patchEventFromRust(rust.PatchAppEvent.channelListUpdated());
      expect(ev, isA<ChannelsChanged>());
    });
  });

  group('intentional drops', () {
    test('MessageAcked is not surfaced (maps to null)', () {
      final ev = patchEventFromRust(
          rust.PatchAppEvent.messageAcked(messageId: 'x', peerId: 'y'));
      expect(ev, isNull);
    });
  });
}
