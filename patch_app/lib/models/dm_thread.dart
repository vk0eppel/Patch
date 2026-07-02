/// The local key for a Direct Message thread with one Peer.
///
/// A DM thread is buffered under `dm:{other_peer_id}` — each side keys the
/// thread by the *other* Operator's Peer, and the `dm:` prefix never crosses
/// the wire (the engine derives it locally on receive). DM keys are never
/// valid Channel ids and are excluded from ALL and channel selection; this
/// type is the one place that knows the key shape.
final class DmThread {
  final String peerId;
  const DmThread(this.peerId);

  static const _prefix = 'dm:';

  /// Parse a local `dm:{peer_id}` key; null for anything else (Channel ids,
  /// the ALL sentinel, …).
  static DmThread? tryParse(String id) =>
      id.startsWith(_prefix) ? DmThread(id.substring(_prefix.length)) : null;

  /// Whether `id` is a DM thread key rather than a Channel id.
  static bool isKey(String id) => id.startsWith(_prefix);

  /// The `dm:{peer_id}` form used as the local buffer/selection key.
  String get key => '$_prefix$peerId';

  @override
  bool operator ==(Object other) => other is DmThread && peerId == other.peerId;

  @override
  int get hashCode => peerId.hashCode;

  @override
  String toString() => key;
}
