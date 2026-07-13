import 'package:flutter_test/flutter_test.dart';

import 'package:patch/models/config.dart';
import 'package:patch/src/rust/api.dart' as rust;
import 'package:patch/src/rust/osc/types.dart' as rust_osc;
import 'package:patch/src/rust/state/channel.dart' as rust_channel;
import 'package:patch/src/rust/state/config.dart' as rust_config;

// When adding a field to ConfigSnapshot: add a sentinel value here, add the
// field to AppConfig, wire it in AppConfig.fromRust().
//
// The ConfigSnapshot data classes need no RustLib.init() — they are pure Dart.
void main() {
  test(
    'AppConfig.fromRust maps every field from a non-default sentinel snapshot',
    () {
      final snapshot = rust.ConfigSnapshot(
        clientName: 'FOH',
        role: 'Monitors',
        oscPort: 9001,
        networkInterface: 'en0',
        staticPeers: [
          rust_config.StaticPeer(
            address: '10.0.0.1',
            port: 9000,
            label: 'Stage',
          ),
        ],
        flashOnCritical: false,
        flashOnMessage: true,
        flashCount: 6,
        macrosColumns: 2,
        hideKeyboard: false,
        audibleAlert: true,
        flashWholeScreen: true,
        globalMacros: [
          rust_channel.MacroMessage(
            label: 'GO',
            payload: 'GO crew',
            priority: 2,
            keyBinding: 'F1',
            osc: rust_channel.OscTarget(
              address: '192.168.1.10',
              port: 53000,
              path: '/cue/1/start',
              argType: rust_osc.OscArgKind.string,
            ),
          ),
        ],
        heartbeatIntervalSecs: 10,
        nameIsDefault: true,
      );

      final cfg = AppConfig.fromRust(snapshot);

      expect(cfg.clientName, 'FOH');
      expect(cfg.role, 'Monitors');
      expect(cfg.oscPort, 9001);
      expect(cfg.networkInterface, 'en0');
      expect(cfg.staticPeers, hasLength(1));
      expect(cfg.staticPeers[0].address, '10.0.0.1');
      expect(cfg.staticPeers[0].port, 9000);
      expect(cfg.staticPeers[0].label, 'Stage');
      expect(cfg.flashOnCritical, isFalse);
      expect(cfg.flashOnMessage, isTrue);
      expect(cfg.flashCount, 6);
      expect(cfg.macrosColumns, 2);
      expect(cfg.hideKeyboard, isFalse);
      expect(cfg.audibleAlert, isTrue);
      expect(cfg.flashWholeScreen, isTrue);
      expect(cfg.globalMacros, hasLength(1));
      expect(cfg.globalMacros[0].label, 'GO');
      expect(cfg.globalMacros[0].payload, 'GO crew');
      expect(cfg.globalMacros[0].priority, 2);
      expect(cfg.globalMacros[0].keyBinding, 'F1');
      expect(cfg.heartbeatIntervalSecs, 10);
      expect(cfg.nameIsDefault, isTrue);
    },
  );
}
