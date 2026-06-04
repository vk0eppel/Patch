// Unit tests for the pure UI-model parsing — the JSON shapes the bridge façade
// emits and the screens consume. No engine/FFI needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart';

void main() {
  group('PatchMessage', () {
    PatchMessage make(int priority) => PatchMessage.fromJson({
          'message_id': 'm',
          'sender_id': 's',
          'sender_name': 'n',
          'channel_id': 'rf',
          'timestamp': '2026-06-04T12:00:00.000Z',
          'priority': priority,
          'payload': 'x',
        });

    test('fromJson parses every field', () {
      final m = PatchMessage.fromJson({
        'message_id': 'm1',
        'sender_id': 's1',
        'sender_name': 'FOH',
        'channel_id': 'rf',
        'timestamp': '2026-06-04T12:00:00.000Z',
        'priority': 2,
        'payload': 'hello',
      });
      expect(m.messageId, 'm1');
      expect(m.senderId, 's1');
      expect(m.senderName, 'FOH');
      expect(m.channelId, 'rf');
      expect(m.priority, 2);
      expect(m.payload, 'hello');
      expect(m.timestamp.toUtc(), DateTime.utc(2026, 6, 4, 12));
    });

    test('priority getters match the wire contract (0=debug…3=critical)', () {
      expect(make(0).isCritical, isFalse); // debug
      expect(make(1).isCritical, isFalse); // info
      expect(make(2).isWarning, isTrue); // warning
      expect(make(2).isCritical, isFalse);
      expect(make(3).isCritical, isTrue); // critical
      expect(make(3).isWarning, isFalse);
    });

    test('priority tolerates a num (double) from JSON', () {
      final m = PatchMessage.fromJson({
        'message_id': 'm',
        'sender_id': 's',
        'sender_name': 'n',
        'channel_id': 'rf',
        'timestamp': '2026-06-04T12:00:00Z',
        'priority': 3.0,
        'payload': 'x',
      });
      expect(m.priority, 3);
      expect(m.isCritical, isTrue);
    });
  });

  group('PeerInfo', () {
    test('fromJson maps fields including discovery mode', () {
      final p = PeerInfo.fromJson({
        'peer_id': 'p1',
        'peer_name': 'MON',
        'channels': ['rf', 'audio'],
        'address': '192.168.1.5',
        'osc_port': 9000,
        'last_seen': '2026-06-04T12:00:00Z',
        'discovery_mode': 'mdns',
      });
      expect(p.peerName, 'MON');
      expect(p.channels, ['rf', 'audio']);
      expect(p.address, '192.168.1.5');
      expect(p.oscPort, 9000);
      expect(p.discoveryMode, 'mdns');
    });

    test('fromJson defaults a missing address and discovery mode', () {
      final p = PeerInfo.fromJson({
        'peer_id': 'p1',
        'peer_name': 'MON',
        'channels': <String>[],
        'osc_port': 9000,
        'last_seen': '2026-06-04T12:00:00Z',
      });
      expect(p.address, '');
      expect(p.discoveryMode, 'unknown');
    });
  });

  group('SessionMeta', () {
    test('fromJson parses count and date', () {
      final s = SessionMeta.fromJson({
        'slug': 'festival-day-1',
        'name': 'Festival Day 1',
        'created_at': '2026-06-04T12:00:00Z',
        'channel_count': 5,
      });
      expect(s.slug, 'festival-day-1');
      expect(s.name, 'Festival Day 1');
      expect(s.channelCount, 5);
    });
  });

  group('PatchChannel', () {
    test('fromJson parses colour hex with and without a leading #', () {
      final withHash =
          PatchChannel.fromJson({'id': 'rf', 'display_name': 'RF', 'color': '#1E88E5'});
      final without =
          PatchChannel.fromJson({'id': 'rf', 'display_name': 'RF', 'color': '1E88E5'});
      expect(withHash.color.toARGB32(), 0xFF1E88E5);
      expect(without.color.toARGB32(), 0xFF1E88E5);
    });

    test('fromJson falls back to the default colour and flag defaults', () {
      final c = PatchChannel.fromJson({'id': 'x', 'display_name': 'X'});
      expect(c.color.toARGB32(), 0xFF607D8B);
      expect(c.flashOnCritical, isTrue);
      expect(c.flashOnMessage, isFalse);
      expect(c.flashCount, isNull);
      expect(c.macros, isEmpty);
    });

    test('fromJson parses the macro list', () {
      final c = PatchChannel.fromJson({
        'id': 'rf',
        'display_name': 'RF',
        'color': '#1E88E5',
        'macros': [
          {'label': 'CLEAR', 'payload': 'Channel clear', 'key_binding': 'F1', 'priority': 1},
          {'label': 'HOLD', 'payload': 'HOLD', 'key_binding': null, 'priority': 2},
        ],
      });
      expect(c.macros, hasLength(2));
      expect(c.macros[0].label, 'CLEAR');
      expect(c.macros[0].keyBinding, 'F1');
      expect(c.macros[1].keyBinding, isNull);
      expect(c.macros[1].priority, 2);
    });
  });
}
