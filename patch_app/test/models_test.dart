// Unit tests for the pure UI-model logic. Models are typed `fromRust` views
// over the FRB structs (#187) — the FRB types are plain data classes, so the
// live conversion path is testable without the engine.

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart';
import 'package:patch/src/rust/state/channel.dart' as rust_channel;

void main() {
  group('PatchMessage', () {
    PatchMessage make(int priority) => PatchMessage(
          messageId: 'm',
          senderId: 's',
          senderName: 'n',
          channelId: 'rf',
          timestamp: DateTime.utc(2026, 6, 4, 12),
          priority: priority,
          payload: 'x',
        );

    test('priority getters match the wire contract (0=debug…3=critical)', () {
      expect(make(0).isCritical, isFalse); // debug
      expect(make(1).isCritical, isFalse); // info
      expect(make(2).isWarning, isTrue); // warning
      expect(make(2).isCritical, isFalse);
      expect(make(3).isCritical, isTrue); // critical
      expect(make(3).isWarning, isFalse);
    });

    test('withLocalSeq stamps only the local sequence', () {
      final stamped = make(2).withLocalSeq(7);
      expect(stamped.localSeq, 7);
      expect(stamped.messageId, 'm');
      expect(stamped.priority, 2);
    });
  });

  group('PeerInfo', () {
    // PeerInfo is constructed directly from the bridge (bridge_client.dart's
    // _peerFromRust), not parsed from a raw map — these just pin down the
    // constructor's defaults.
    test('departed defaults to false', () {
      final p = PeerInfo(
        peerId: 'p1',
        peerName: 'MON',
        channels: const [],
        address: '',
        oscPort: 9000,
        lastSeen: DateTime.parse('2026-06-04T12:00:00Z'),
        discoveryMode: 'mdns',
        status: PeerStatus.online,
      );
      expect(p.departed, isFalse);
    });

    test('isManual is true only for a Static Peer (manual_ip)', () {
      PeerInfo peer(String mode) => PeerInfo(
            peerId: 'p1',
            peerName: 'MON',
            channels: const [],
            address: '',
            oscPort: 9000,
            lastSeen: DateTime.parse('2026-06-04T12:00:00Z'),
            discoveryMode: mode,
            status: PeerStatus.online,
          );
      // 'manual_ip' is the only spelling the model ever emits (fromRust) —
      // the classification gates the DM affordance, so no other string may
      // classify as manual.
      expect(peer('manual_ip').isManual, isTrue);
      expect(peer('mdns').isManual, isFalse);
      expect(peer('osc_beacon').isManual, isFalse);
      expect(peer('ManualIp').isManual, isFalse);
    });
  });

  group('PatchChannel.fromRust — the one inbound construction path', () {
    rust_channel.Channel wire(String color,
            [List<rust_channel.MacroMessage> macros = const []]) =>
        rust_channel.Channel(
          id: 'rf',
          displayName: 'RF',
          color: color,
          macros: macros,
          flashOnCritical: true,
          flashOnMessage: false,
        );

    test('parses colour hex with and without a leading #', () {
      expect(PatchChannel.fromRust(wire('#1E88E5')).color.toARGB32(),
          0xFF1E88E5);
      expect(
          PatchChannel.fromRust(wire('1E88E5')).color.toARGB32(), 0xFF1E88E5);
    });

    test('maps the macro list field-for-field', () {
      final c = PatchChannel.fromRust(wire('#1E88E5', const [
        rust_channel.MacroMessage(
            label: 'CLEAR',
            payload: 'Channel clear',
            keyBinding: 'F1',
            priority: 1),
        rust_channel.MacroMessage(label: 'HOLD', payload: 'HOLD', priority: 2),
      ]));
      expect(c.macros, hasLength(2));
      expect(c.macros[0].label, 'CLEAR');
      expect(c.macros[0].keyBinding, 'F1');
      expect(c.macros[1].keyBinding, isNull);
      expect(c.macros[1].priority, 2);
    });

    test('constructor flag defaults (flash flags, empty macros)', () {
      const c = PatchChannel(
          id: 'x', displayName: 'X', color: Color(0xFF607D8B));
      expect(c.flashOnCritical, isTrue);
      expect(c.flashOnMessage, isFalse);
      expect(c.flashCount, isNull);
      expect(c.macros, isEmpty);
    });
  });
}
