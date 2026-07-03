/// Owns the Behavior section's save→refetch loops (#141): flash toggles,
/// audible alert, flash pulse count, macros-panel columns, keyboard hiding,
/// and the factory-defaults reset. Bounds are enforced before any bridge
/// call. Presentation stays in the section widget per ADR-0005.
class BehaviorPresenter {
  BehaviorPresenter({
    required this.setFlashOnMessage,
    required this.setFlashOnCritical,
    required this.setAudibleAlert,
    required this.setFlashWholeScreen,
    required this.setHideKeyboard,
    required this.setFlashCount,
    required this.setMacrosColumns,
    required this.refreshConfig,
  });

  final Future<void> Function(bool) setFlashOnMessage;
  final Future<void> Function(bool) setFlashOnCritical;
  final Future<void> Function(bool) setAudibleAlert;
  final Future<void> Function(bool) setFlashWholeScreen;
  final Future<void> Function(bool) setHideKeyboard;
  final Future<void> Function(int) setFlashCount;
  final Future<void> Function(int) setMacrosColumns;
  final Future<void> Function() refreshConfig;

  /// The pulse counts the picker offers.
  static const flashCountOptions = {3, 4, 5, 6, 7};

  static const macrosColumnsMin = 1, macrosColumnsMax = 3;

  Future<void> saveFlashOnMessage(bool v) => _save(() => setFlashOnMessage(v));
  Future<void> saveFlashOnCritical(bool v) =>
      _save(() => setFlashOnCritical(v));
  Future<void> saveAudibleAlert(bool v) => _save(() => setAudibleAlert(v));
  Future<void> saveFlashWholeScreen(bool v) =>
      _save(() => setFlashWholeScreen(v));
  Future<void> saveHideKeyboard(bool v) => _save(() => setHideKeyboard(v));

  Future<bool> saveFlashCount(int count) async {
    if (!flashCountOptions.contains(count)) return false;
    await _save(() => setFlashCount(count));
    return true;
  }

  Future<bool> saveMacrosColumns(int columns) async {
    if (columns < macrosColumnsMin || columns > macrosColumnsMax) return false;
    await _save(() => setMacrosColumns(columns));
    return true;
  }

  /// Factory defaults for every Behavior setting, then one refetch.
  Future<void> resetDefaults() async {
    await setFlashOnCritical(true);
    await setFlashOnMessage(false);
    await setFlashCount(4);
    await setHideKeyboard(true);
    await setAudibleAlert(false);
    await setMacrosColumns(1);
    await refreshConfig();
  }

  Future<void> _save(Future<void> Function() action) async {
    await action();
    await refreshConfig();
  }
}
