import '../../models/channel.dart';

/// The one request/offer race for peer-import flows (#182, was #142 twice):
/// a request arms the gate, so an unsolicited announce (a Peer offering
/// without us asking) is refused rather than popping a dialog; an admitted
/// offer or a timeout disarms it. Each import flow (Channels, Global Macros)
/// owns its own gate so two in-flight requests can't cross-trigger each
/// other's dialog. Presentation (dialogs, snackbars) stays in the screen per
/// ADR-0005.
class PeerRequestGate {
  PeerRequestGate({required this.sendRequest});

  final Future<void> Function(String peerId) sendRequest;

  bool _awaiting = false;

  Future<void> request(String peerId) async {
    _awaiting = true;
    await sendRequest(peerId);
  }

  /// Gate an incoming offer: while awaiting, disarms and admits (true);
  /// refuses an unsolicited offer (false). What to do with an admitted
  /// offer is the caller's business — the gate owns only the race.
  bool admitOffer() {
    if (!_awaiting) return false;
    _awaiting = false;
    return true;
  }

  /// Call when the await window elapses with no offer. Returns whether it
  /// actually disarmed — false if an offer already arrived first.
  bool timeout() {
    if (!_awaiting) return false;
    _awaiting = false;
    return true;
  }
}

/// The Channels flow's offer classification: the offered Channels not
/// already held locally (merge-adopt preview).
List<PatchChannel> freshChannels({
  required List<PatchChannel> offered,
  required List<PatchChannel> existing,
}) {
  final existingIds = existing.map((c) => c.id).toSet();
  return offered.where((c) => !existingIds.contains(c.id)).toList();
}
