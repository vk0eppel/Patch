import 'dart:async';

import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

/// Collapsible right panel showing online peers.
///
/// Rebuilds every 3 s so dot colours and the "last seen" counter (both based on
/// DateTime.now()) stay accurate without waiting for an external event to
/// trigger a Flutter rebuild.
class PeersPanel extends StatefulWidget {
  final List<PeerInfo> peers;

  /// Presence heartbeat interval (s) — the dot thresholds derive from it
  /// (healthy ≤ 2×, amber ≤ 5×) so they track the configured interval.
  final int heartbeatSecs;

  /// The viewer's own channel id → colour map. Each peer announces the channel
  /// ids it's on (`PeerInfo.channels`); we render a colour dot per channel using
  /// this map, so a channel the viewer doesn't have falls back to a grey dot.
  final Map<String, Color> channelColors;
  final VoidCallback? onClearStale;
  final VoidCallback? onClose;
  const PeersPanel({
    super.key,
    required this.peers,
    this.heartbeatSecs = 7,
    this.channelColors = const {},
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
                      channelColors: widget.channelColors,
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

  /// Viewer's channel id → colour map (see [PeersPanel.channelColors]).
  final Map<String, Color> channelColors;

  const _PeerTile({
    required this.peer,
    required this.heartbeatSecs,
    this.channelColors = const {},
  });

  /// Max channel dots rendered before collapsing the rest into a "+N" label,
  /// so a peer on many channels can't overflow the narrow (160 px) panel.
  static const int _kMaxChannelDots = 5;

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

  /// A row of small colour dots, one per channel the peer announces, coloured
  /// from the viewer's [channelColors] (grey for a channel the viewer doesn't
  /// have). Collapses to "+N" past [_kMaxChannelDots]. Empty (a zero-height box)
  /// for peers with no announced channels — e.g. configured-only static peers.
  Widget _channelDots() {
    if (peer.channels.isEmpty) return const SizedBox.shrink();
    final shown = peer.channels.take(_kMaxChannelDots);
    final extra = peer.channels.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          for (final id in shown)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Tooltip(
                message: id,
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: channelColors[id] ?? PatchTheme.textMuted,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          if (extra > 0)
            Text(
              '+$extra',
              style: const TextStyle(color: PatchTheme.textMuted, fontSize: 9),
            ),
        ],
      ),
    );
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
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        peer.peerName,
                        style: const TextStyle(
                          color: PatchTheme.textPrimary,
                          fontSize: PatchTheme.fontSizeSmall,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (peer.role != null && peer.role!.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      _RoleBadge(peer.role!),
                    ],
                  ],
                ),
                Text(
                  _subtitle,
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                _channelDots(),
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

/// A peer's self-assigned role, rendered as a small **neutral** chip (no
/// role-specific colour — channel dots are the only colour cue in this panel).
class _RoleBadge extends StatelessWidget {
  final String role;
  const _RoleBadge(this.role);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: PatchTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: PatchTheme.border),
      ),
      child: Text(
        role,
        style: const TextStyle(
          color: PatchTheme.textSecondary,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
