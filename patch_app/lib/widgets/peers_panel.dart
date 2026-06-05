import 'dart:async';

import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

/// Collapsible right panel showing online peers.
///
/// Rebuilds every 10 s so dot colours (based on DateTime.now()) stay accurate
/// without waiting for an external event to trigger a Flutter rebuild.
class PeersPanel extends StatefulWidget {
  final List<PeerInfo> peers;

  /// Presence heartbeat interval (s) — the dot thresholds derive from it
  /// (healthy ≤ 2×, amber ≤ 5×) so they track the configured interval.
  final int heartbeatSecs;
  final VoidCallback? onClearStale;
  final VoidCallback? onClose;
  const PeersPanel({
    super.key,
    required this.peers,
    this.heartbeatSecs = 7,
    this.onClearStale,
    this.onClose,
  });

  @override
  State<PeersPanel> createState() => _PeersPanelState();
}

class _PeersPanelState extends State<PeersPanel> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    // 3 s so the per-peer "last seen" counter stays visibly current.
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: PatchTheme.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                if (widget.onClose != null)
                  IconButton(
                    icon: const Icon(Icons.people, size: 18),
                    color: PatchTheme.accent,
                    tooltip: 'Hide peers',
                    onPressed: widget.onClose,
                  ),
                const Expanded(
                  child: Text(
                    'PEERS',
                    style: TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: PatchTheme.fontSizeSmall,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                ),
                if (widget.onClearStale != null)
                  IconButton(
                    icon: const Icon(Icons.person_remove_outlined, size: 16),
                    color: PatchTheme.textMuted,
                    tooltip: 'Clear inactive peers',
                    onPressed: widget.onClearStale,
                  ),
              ],
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          Expanded(
            child: widget.peers.isEmpty
                ? const Center(
                    child: Text(
                      'No peers yet',
                      style: TextStyle(color: PatchTheme.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.peers.length,
                    itemBuilder: (ctx, i) => _PeerTile(
                      peer: widget.peers[i],
                      heartbeatSecs: widget.heartbeatSecs,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}


class _PeerTile extends StatelessWidget {
  final PeerInfo peer;

  /// Presence heartbeat interval (s). Dot thresholds derive from it: healthy
  /// ≤ 2× (one dropped beat tolerated), amber ≤ 5×, gray beyond. With the default
  /// 7 s heartbeat that's the previous 14 s / 35 s, now tracking the interval.
  final int heartbeatSecs;

  const _PeerTile({required this.peer, required this.heartbeatSecs});

  int get _healthySecs => heartbeatSecs * 2;
  int get _staleSecs => heartbeatSecs * 5;

  bool get _isManual =>
      peer.discoveryMode == 'manual_ip' || peer.discoveryMode == 'ManualIp';

  /// Three-state health: green = healthy, amber = a heartbeat or more missed
  /// (going quiet), gray = offline or a configured-only (ManualIp) peer.
  Color get _dotColor {
    if (_isManual) return PatchTheme.textMuted;
    final age = DateTime.now().difference(peer.lastSeen).inSeconds;
    if (age <= _healthySecs) return PatchTheme.success;
    if (age <= _staleSecs) return PatchTheme.warning;
    return PatchTheme.textMuted;
  }

  String get _discoveryIcon {
    return switch (peer.discoveryMode) {
      'Mdns' || 'mdns' => '🔍',
      'ManualIp' || 'manual_ip' => '📌',
      _ => '📡',
    };
  }

  /// Secondary line. For dynamic peers this leads with *when* we last heard from
  /// them (the whole point — see who's online and how recently); static/manual
  /// peers have a synthetic `lastSeen`, so we just show their configured address.
  String get _subtitle {
    final addr = peer.address.isNotEmpty ? peer.address : 'unknown IP';
    return _isManual ? addr : '${_relativeLastSeen(peer.lastSeen)} · $addr';
  }

  static String _relativeLastSeen(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.isNegative || d.inSeconds < 5) return 'now';
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Text(_discoveryIcon, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  peer.peerName,
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontSize: PatchTheme.fontSizeSmall,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  _subtitle,
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Status dot: green (healthy) → amber (heartbeat missed, going quiet)
          // → gray (offline, or a configured-only ManualIp peer).
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: _dotColor,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
