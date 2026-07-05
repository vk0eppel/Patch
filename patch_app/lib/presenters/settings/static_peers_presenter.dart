import 'save_result.dart';

/// Owns the Static Peers section's validate→save→refetch loops (#141).
/// Address/port sanity is checked before any bridge call (the engine
/// validates the IP fully — `StaticPeer::new`); every mutation refetches
/// config *and* peers so both the list and the peers panel reflect it.
class StaticPeersPresenter {
  StaticPeersPresenter({
    required this.addStaticPeer,
    required this.removeStaticPeer,
    required this.refreshConfig,
    required this.refreshPeers,
  });

  final Future<void> Function(String address, int port, String? label)
      addStaticPeer;
  final Future<void> Function(String address, int port) removeStaticPeer;
  final Future<void> Function() refreshConfig;
  final Future<void> Function() refreshPeers;

  /// Add a Static Peer. Input is rejected before any bridge call for a blank
  /// address or an out-of-range port.
  Future<SaveResult> add(String address, int port, String? label) {
    final addr = address.trim();
    return validateThenSave(
      validate: () {
        if (addr.isEmpty) return 'Enter an IP address';
        if (port < 1 || port > 65535) return 'Port must be 1–65535';
        return null;
      },
      save: () => addStaticPeer(addr, port, label),
      refetch: _refetch,
    );
  }

  Future<void> remove(String address, int port) async {
    await removeStaticPeer(address, port);
    await _refetch();
  }

  /// Remove every configured Static Peer (the section reset).
  Future<void> removeAll(List<({String address, int port})> peers) async {
    for (final peer in peers) {
      await removeStaticPeer(peer.address, peer.port);
    }
    await _refetch();
  }

  Future<void> _refetch() async {
    await refreshConfig();
    await refreshPeers();
  }
}
