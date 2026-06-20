// Unit tests for the pure UI-model parsing — the JSON shapes the bridge façade
// emits and the screens consume. No engine/FFI needed.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/config.dart';
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
  });

  group('ShowFileMeta', () {
    test('fromJson parses count and date', () {
      final s = ShowFileMeta.fromJson({
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

  group('AppConfig', () {
    test('fromJson parses every field — both screens read this, not the raw map', () {
      final cfg = AppConfig.fromJson({
        'client_name': 'FOH',
        'role': 'Audio',
        'osc_port': 9001,
        'network_interface': 'en0',
        'static_peers': [
          {'address': '192.168.1.50', 'port': 9000, 'label': 'Monitor World'},
        ],
        'flash_on_critical': false,
        'flash_on_message': true,
        'flash_count': 6,
        'macros_columns': 2,
        'hide_keyboard': false,
        'audible_alert': true,
        'global_macros': [
          {'label': 'CLEAR', 'payload': 'Channel clear', 'priority': 1},
        ],
        'heartbeat_interval_secs': 10,
        'name_is_default': true,
      });

      expect(cfg.clientName, 'FOH');
      expect(cfg.role, 'Audio');
      expect(cfg.oscPort, 9001);
      expect(cfg.networkInterface, 'en0');
      expect(cfg.staticPeers, hasLength(1));
      expect(cfg.staticPeers[0].address, '192.168.1.50');
      expect(cfg.staticPeers[0].port, 9000);
      expect(cfg.staticPeers[0].label, 'Monitor World');
      expect(cfg.flashOnCritical, isFalse);
      expect(cfg.flashOnMessage, isTrue);
      expect(cfg.flashCount, 6);
      expect(cfg.macrosColumns, 2);
      expect(cfg.hideKeyboard, isFalse);
      expect(cfg.audibleAlert, isTrue);
      expect(cfg.globalMacros, hasLength(1));
      expect(cfg.globalMacros[0].label, 'CLEAR');
      expect(cfg.heartbeatIntervalSecs, 10);
      expect(cfg.nameIsDefault, isTrue);
    });

    test('fromJson defaults a missing role, network_interface, and empty lists', () {
      final cfg = AppConfig.fromJson({
        'client_name': 'FOH',
        'osc_port': 9000,
        'flash_on_critical': true,
        'flash_on_message': false,
        'flash_count': 4,
        'macros_columns': 1,
        'hide_keyboard': true,
        'audible_alert': false,
        'heartbeat_interval_secs': 7,
        'name_is_default': false,
      });
      expect(cfg.role, isNull);
      expect(cfg.networkInterface, isNull);
      expect(cfg.staticPeers, isEmpty);
      expect(cfg.globalMacros, isEmpty);
    });
  });
}
