import '../../models/channel.dart';

/// Owns the "import channels from a peer" request/offer race (#142): a
/// request sets an awaiting flag so an unsolicited `channels_offered` (a peer
/// announcing without us asking) is ignored rather than popping a dialog, and
/// computes which offered channels are new. Presentation (dialogs, snackbars)
/// stays in the screen per ADR-0005.
class ChannelsImportPresenter {
  ChannelsImportPresenter({required this.requestChannels});

  final Future<void> Function(String peerId) requestChannels;

  bool _awaiting = false;

  Future<void> request(String peerId) async {
    _awaiting = true;
    await requestChannels(peerId);
  }

  /// Null if the offer should be ignored (unsolicited). Otherwise the
  /// offered channels not already present locally.
  List<PatchChannel>? handleOffer({
    required List<PatchChannel> offered,
    required List<PatchChannel> existing,
  }) {
    if (!_awaiting) return null;
    _awaiting = false;
    final existingIds = existing.map((c) => c.id).toSet();
    return offered.where((c) => !existingIds.contains(c.id)).toList();
  }

  /// Call when the await window elapses with no offer. Returns whether it
  /// actually cleared the flag — false if an offer already arrived first.
  bool timeout() {
    if (!_awaiting) return false;
    _awaiting = false;
    return true;
  }
}
