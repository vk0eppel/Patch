import 'package:patch/src/rust/api.dart' as rust;
import 'package:patch/src/rust/state/config.dart' as rust_config;

import 'channel.dart';

/// A manually-configured peer at a known fixed address (see CONTEXT.md: Static
/// Peer). Mirrors the `static_peers` entries inside `AppConfig`.
class StaticPeerInfo {
  final String address;
  final int port;
  final String? label;

  const StaticPeerInfo({
    required this.address,
    required this.port,
    this.label,
  });

  factory StaticPeerInfo.fromJson(Map<String, dynamic> j) => StaticPeerInfo(
        address: j['address'] as String,
        port: (j['port'] as num).toInt(),
        label: j['label'] as String?,
      );

  factory StaticPeerInfo.fromRust(rust_config.StaticPeer s) => StaticPeerInfo(
        address: s.address,
        port: s.port,
        label: s.label,
      );
}

/// Typed view of the engine's runtime-mutable config (Rust `ConfigSnapshot`,
/// `bridge_client.dart::getConfig()`'s `'config'` event). Both `home_screen.dart`
/// and `settings_screen.dart` parse the same event through this one factory
/// instead of each hand-unpacking the raw map — see ERRORS.md for the bug that
/// caused (a field missing from one of the two screens' independent unpacking
/// silently resets that screen's state to a default).
class AppConfig {
  final String clientName;
  final String? role;
  final int oscPort;
  final String? networkInterface;
  final List<StaticPeerInfo> staticPeers;
  final bool flashOnCritical;
  final bool flashOnMessage;
  final int flashCount;
  final int macrosColumns;
  final bool hideKeyboard;
  final bool audibleAlert;
  final bool flashWholeScreen;
  final List<MacroMessage> globalMacros;
  final int heartbeatIntervalSecs;
  final bool nameIsDefault;

  const AppConfig({
    required this.clientName,
    this.role,
    required this.oscPort,
    this.networkInterface,
    this.staticPeers = const [],
    required this.flashOnCritical,
    required this.flashOnMessage,
    required this.flashCount,
    required this.macrosColumns,
    required this.hideKeyboard,
    required this.audibleAlert,
    this.flashWholeScreen = false,
    this.globalMacros = const [],
    required this.heartbeatIntervalSecs,
    required this.nameIsDefault,
  });

  factory AppConfig.fromRust(rust.ConfigSnapshot cfg) => AppConfig(
        clientName: cfg.clientName,
        role: cfg.role,
        oscPort: cfg.oscPort,
        networkInterface: cfg.networkInterface,
        staticPeers: cfg.staticPeers.map(StaticPeerInfo.fromRust).toList(),
        flashOnCritical: cfg.flashOnCritical,
        flashOnMessage: cfg.flashOnMessage,
        flashCount: cfg.flashCount,
        macrosColumns: cfg.macrosColumns,
        hideKeyboard: cfg.hideKeyboard,
        audibleAlert: cfg.audibleAlert,
        flashWholeScreen: cfg.flashWholeScreen,
        globalMacros: cfg.globalMacros.map(MacroMessage.fromRust).toList(),
        heartbeatIntervalSecs: cfg.heartbeatIntervalSecs,
        nameIsDefault: cfg.nameIsDefault,
      );
}
