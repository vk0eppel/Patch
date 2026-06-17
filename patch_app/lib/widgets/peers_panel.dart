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

  final VoidCallback? onClearStale;
  final VoidCallback? onClose;

  /// Open a direct-message thread with the given peer id. Only offered for real
  /// (dynamic) peers — not configured-only `ManualIp` entries, whose id is a
  /// synthetic UUID that wouldn't reach a live Patch instance.
  final ValueChanged<String>? onDm;

  /// Peer ids that have an unread DM — shown as a dot on the peer row.
  final Set<String> unreadPeerIds;

  const PeersPanel({
    super.key,
    required this.peers,
    this.heartbeatSecs = 7,
    this.onClearStale,
    this.onClose,
    this.onDm,
    this.unreadPeerIds = const {},
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
                      onDm: widget.onDm,
                      isUnread: widget.unreadPeerIds.contains(widget.peers[i].peerId),
                    ),
                  ),
          ),
          if (widget.onClearStale != null) ...[
            const Divider(color: PatchTheme.border, height: 1),
            TextButton.icon(
              onPressed: widget.onClearStale,
              icon: const Icon(Icons.person_remove_outlined, size: 14),
              label: const Text('Clear inactive'),
              style: TextButton.styleFrom(
                foregroundColor: PatchTheme.textMuted,
                textStyle: const TextStyle(fontSize: 11),
                padding: const EdgeInsets.symmetric(vertical: 8),
                minimumSize: const Size(double.infinity, 0),
              ),
            ),
          ],
        ],
      ),
    );
  }
}


class _PeerTile extends StatelessWidget {
  final PeerInfo peer;
  final int heartbeatSecs;
  final ValueChanged<String>? onDm;
  final bool isUnread;

  const _PeerTile({
    required this.peer,
    required this.heartbeatSecs,
    this.onDm,
    this.isUnread = false,
  });

  int get _healthySecs => heartbeatSecs * 2;
  int get _staleSecs => heartbeatSecs * 5;

  bool get _isManual =>
      peer.discoveryMode == 'manual_ip' || peer.discoveryMode == 'ManualIp';

  Color get _dotColor {
    // A clean departure ('/patch/bye' / mDNS removal) reads grey regardless of
    // the still-recent last_seen — the italic name distinguishes it from a peer
    // that merely went quiet.
    if (peer.departed) return PatchTheme.textMuted;
    if (_isManual) return PatchTheme.textMuted;
    final age = DateTime.now().difference(peer.lastSeen).inSeconds;
    if (age <= _healthySecs) return PatchTheme.success;
    if (age <= _staleSecs) return PatchTheme.warning;
    return PatchTheme.textMuted;
  }

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    peer.peerName,
                    style: TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeSmall,
                      fontWeight: FontWeight.w600,
                      // Departed peers ('/patch/bye' / mDNS removal) render in
                      // italic so a clean departure is told apart at a glance.
                      fontStyle:
                          peer.departed ? FontStyle.italic : FontStyle.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isUnread) ...[
                  const SizedBox(width: 4),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: const BoxDecoration(
                      color: PatchTheme.critical,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
                if (peer.role != null && peer.role!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _RoleBadge(peer.role!),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
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

    if (onDm == null || _isManual) return tile;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => onDm!(peer.peerId),
      child: tile,
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
