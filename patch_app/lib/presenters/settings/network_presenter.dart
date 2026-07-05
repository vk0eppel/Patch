/// Owns the Network section's validate → bridge call → refetch loops (#140):
/// discovery-interface selection, heartbeat interval, and OSC port, with the
/// operator-facing bounds enforced before any bridge call. Presentation
/// (applied ticks, pickers) stays in the section widget per ADR-0005.
class NetworkPresenter {
  NetworkPresenter({
    required this.setInterface,
    required this.setHeartbeatInterval,
    required this.setOscPort,
    required this.refreshConfig,
    required this.getInterfaces,
  });

  final Future<void> Function(String name) setInterface;
  final Future<void> Function(int secs) setHeartbeatInterval;
  final Future<void> Function(int port) setOscPort;
  final Future<void> Function() refreshConfig;
  final Future<List<({String name, String ip})>> Function() getInterfaces;

  /// Heartbeat bounds shown in the UI copy ("Applies live, 1–60").
  static const heartbeatMin = 1, heartbeatMax = 60;

  /// Non-privileged UDP port range ("Applies live, 1024–65535").
  static const oscPortMin = 1024, oscPortMax = 65535;

  /// Scope the discovery beacon to one interface. Pinning is mandatory —
  /// there is no "Auto" to select back to.
  Future<void> selectInterface(String name) async {
    await setInterface(name);
    await refreshConfig();
  }

  /// Save the heartbeat interval; out-of-bounds is rejected before any
  /// bridge call.
  Future<bool> saveHeartbeatInterval(int secs) async {
    if (secs < heartbeatMin || secs > heartbeatMax) return false;
    await setHeartbeatInterval(secs);
    await refreshConfig();
    return true;
  }

  /// Save the OSC port; out-of-bounds is rejected before any bridge call.
  Future<bool> saveOscPort(int port) async {
    if (port < oscPortMin || port > oscPortMax) return false;
    await setOscPort(port);
    await refreshConfig();
    return true;
  }

  /// Available NICs for the picker. A load failure degrades to an empty
  /// picker — non-critical.
  Future<List<Map<String, String>>> loadInterfaces() async {
    try {
      final ifaces = await getInterfaces();
      return ifaces.map((i) => {'name': i.name, 'ip': i.ip}).toList();
    } catch (_) {
      return const [];
    }
  }
}
