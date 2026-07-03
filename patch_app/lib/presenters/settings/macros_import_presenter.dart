import '../../models/channel.dart';

/// Owns the "import global macros from a peer" request/offer race (#142),
/// mirroring [ChannelsImportPresenter] but kept separate so the two flows
/// can't cross-trigger each other's dialog if both are in flight at once.
/// Presentation (dialogs, snackbars) stays in the screen per ADR-0005.
class MacrosImportPresenter {
  MacrosImportPresenter({
    required this.requestGlobalMacros,
    required this.previewGlobalMacros,
  });

  final Future<void> Function(String peerId) requestGlobalMacros;
  final Future<List<MacroImportOutcome>> Function(List<MacroMessage> offered)
      previewGlobalMacros;

  bool _awaiting = false;

  Future<void> request(String peerId) async {
    _awaiting = true;
    await requestGlobalMacros(peerId);
  }

  /// Whether the offer should be shown — false if unsolicited.
  bool handleOffer() {
    if (!_awaiting) return false;
    _awaiting = false;
    return true;
  }

  /// Call when the await window elapses with no offer. Returns whether it
  /// actually cleared the flag — false if an offer already arrived first.
  bool timeout() {
    if (!_awaiting) return false;
    _awaiting = false;
    return true;
  }

  Future<List<MacroImportOutcome>> preview(List<MacroMessage> offered) =>
      previewGlobalMacros(offered);
}
