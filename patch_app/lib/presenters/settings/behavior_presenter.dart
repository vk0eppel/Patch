/// Signature of the one behavior-settings command (#179): any subset of the
/// scalar behavior fields, applied and persisted by the engine in a single
/// `ConfigPatch`. Null fields are left untouched.
typedef BehaviorPatchFn = Future<void> Function({
  bool? flashOnMessage,
  bool? flashOnCritical,
  bool? audibleAlert,
  bool? flashWholeScreen,
  bool? hideKeyboard,
  int? flashCount,
  int? macrosColumns,
});

/// Owns the Behavior section's save→refetch loops (#141): flash toggles,
/// audible alert, flash pulse count, macros-panel columns, keyboard hiding,
/// and the factory-defaults reset. Bounds are enforced before any bridge
/// call. Presentation stays in the section widget per ADR-0005.
class BehaviorPresenter {
  BehaviorPresenter({
    required this.patch,
    required this.resetBehavior,
    required this.refreshConfig,
  });

  /// One command for every behavior save — a single-field patch per toggle.
  final BehaviorPatchFn patch;

  /// The engine's factory-defaults reset (#180) — the presenter carries no
  /// default values; the engine owns them.
  final Future<void> Function() resetBehavior;
  final Future<void> Function() refreshConfig;

  /// The pulse counts the picker offers.
  static const flashCountOptions = {3, 4, 5, 6, 7};

  static const macrosColumnsMin = 1, macrosColumnsMax = 3;

  Future<void> saveFlashOnMessage(bool v) =>
      _save(() => patch(flashOnMessage: v));
  Future<void> saveFlashOnCritical(bool v) =>
      _save(() => patch(flashOnCritical: v));
  Future<void> saveAudibleAlert(bool v) => _save(() => patch(audibleAlert: v));
  Future<void> saveFlashWholeScreen(bool v) =>
      _save(() => patch(flashWholeScreen: v));
  Future<void> saveHideKeyboard(bool v) => _save(() => patch(hideKeyboard: v));

  Future<bool> saveFlashCount(int count) async {
    if (!flashCountOptions.contains(count)) return false;
    await _save(() => patch(flashCount: count));
    return true;
  }

  Future<bool> saveMacrosColumns(int columns) async {
    if (columns < macrosColumnsMin || columns > macrosColumnsMax) return false;
    await _save(() => patch(macrosColumns: columns));
    return true;
  }

  /// Factory defaults for every Behavior setting — one engine command, one
  /// refetch. The default values live engine-side only.
  Future<void> resetDefaults() => _save(resetBehavior);

  Future<void> _save(Future<void> Function() action) async {
    await action();
    await refreshConfig();
  }
}
