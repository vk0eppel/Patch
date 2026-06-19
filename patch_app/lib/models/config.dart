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
    this.globalMacros = const [],
    required this.heartbeatIntervalSecs,
    required this.nameIsDefault,
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        clientName: j['client_name'] as String? ?? '',
        role: j['role'] as String?,
        oscPort: (j['osc_port'] as num?)?.toInt() ?? 9000,
        networkInterface: j['network_interface'] as String?,
        staticPeers: ((j['static_peers'] as List<dynamic>?) ?? const [])
            .map((p) => StaticPeerInfo.fromJson(p as Map<String, dynamic>))
            .toList(),
        flashOnCritical: (j['flash_on_critical'] as bool?) ?? true,
        flashOnMessage: (j['flash_on_message'] as bool?) ?? false,
        flashCount: (j['flash_count'] as num?)?.toInt() ?? 4,
        macrosColumns: (j['macros_columns'] as num?)?.toInt() ?? 1,
        hideKeyboard: (j['hide_keyboard'] as bool?) ?? true,
        audibleAlert: (j['audible_alert'] as bool?) ?? false,
        globalMacros: ((j['global_macros'] as List<dynamic>?) ?? const [])
            .map((m) => MacroMessage.fromJson(m as Map<String, dynamic>))
            .toList(),
        heartbeatIntervalSecs:
            (j['heartbeat_interval_secs'] as num?)?.toInt() ?? 7,
        nameIsDefault: (j['name_is_default'] as bool?) ?? false,
      );
}
