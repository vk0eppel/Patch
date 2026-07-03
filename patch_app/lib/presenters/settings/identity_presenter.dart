import '../../models/config.dart';

/// Owns the Identity section's validate → bridge call → refetch loops (#140):
/// name/role saves, the seed-once rule that stops a later config notify from
/// clobbering the Operator's in-progress edits, and the identity reset.
/// Presentation (saved ticks, controllers, dialogs) stays in the section
/// widget per ADR-0005. Bridge/store dependencies are injected as functions
/// so the loops are unit-testable without FFI.
class IdentityPresenter {
  IdentityPresenter({
    required this.setClientName,
    required this.setRole,
    required this.refreshConfig,
  });

  final Future<void> Function(String name) setClientName;
  final Future<void> Function(String? role) setRole;
  final Future<void> Function() refreshConfig;

  bool _seeded = false;

  /// Save the display name. Blank input is rejected before any bridge call.
  /// The engine echoes a ClientNameChanged push, so no refetch here.
  Future<bool> saveName(String raw) async {
    final name = raw.trim();
    if (name.isEmpty) return false;
    await setClientName(name);
    return true;
  }

  /// Save the Role (empty clears it engine-side). No push echoes back, so
  /// refetch the config to keep the store truthful.
  Future<void> saveRole(String raw) async {
    await setRole(raw);
    await refreshConfig();
  }

  /// The initial text-field values, yielded exactly once when config first
  /// loads — null before the first load and forever after the seed, so a
  /// later config notify never clobbers the Operator's edits.
  ({String name, String role})? seedOnce(AppConfig? config) {
    if (_seeded || config == null) return null;
    _seeded = true;
    return (name: config.clientName, role: config.role ?? '');
  }

  /// Reset to the OS default name and no Role. Returns the name so the
  /// widget can reseed its controller.
  Future<String> resetIdentity({required String defaultName}) async {
    await setClientName(defaultName);
    await setRole(null);
    await refreshConfig();
    return defaultName;
  }
}
