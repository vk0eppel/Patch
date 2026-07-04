import 'dart:async';

import 'package:flutter/material.dart';
import '../models/message.dart';
import '../screens/help_screen.dart';
import '../theme/patch_theme.dart';

/// Collapsible right panel showing online peers.
///
/// Each peer's dot colour comes straight from `PeerInfo.status` — classified
/// engine-side (`Peer::status`) against the configured heartbeat interval, not
/// recomputed here. A peer that goes quiet with no new packets won't trigger a
/// `peer_updated` event on its own, so this still polls — every 3 s while the
/// panel is visible, it asks the parent to re-fetch peers via [onRefresh]
/// (wired to `bridge.getPeers()`) so a quiet peer's status ages from
/// online → stale → offline even without fresh traffic.
class PeersPanel extends StatefulWidget {
  final List<PeerInfo> peers;

  final VoidCallback? onClearStale;
  final VoidCallback? onClose;

  /// Open a direct-message thread with the given peer id. Only offered for real
  /// (dynamic) peers — not configured-only `ManualIp` entries, whose id is a
  /// synthetic UUID that wouldn't reach a live Patch instance.
  final ValueChanged<String>? onDm;

  /// Peer ids that have an unread DM — shown as a dot on the peer row.
  final Set<String> unreadPeerIds;

  /// Called every 3 s while this panel is mounted, so the caller can re-fetch
  /// peers and keep status dots current. No-op if omitted (e.g. in tests).
  final VoidCallback? onRefresh;

  /// Opens the settings screen at the static-peers section. Used by the
  /// empty-state hint when no peers have been discovered yet.
  final VoidCallback? onOpenSettings;

  const PeersPanel({
    super.key,
    required this.peers,
    this.onClearStale,
    this.onClose,
    this.onDm,
    this.unreadPeerIds = const {},
    this.onRefresh,
    this.onOpenSettings,
  });

  @override
  State<PeersPanel> createState() => _PeersPanelState();
}

class _PeersPanelState extends State<PeersPanel> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 3), (_) {
      widget.onRefresh?.call();
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
                ? _PeersEmptyState(onOpenSettings: widget.onOpenSettings)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: widget.peers.length,
                    itemBuilder: (ctx, i) => _PeerTile(
                      peer: widget.peers[i],
                      onDm: widget.onDm,
                      isUnread: widget.unreadPeerIds.contains(widget.peers[i].peerId),
                    ),
                  ),
          ),
          if (widget.onClearStale != null) ...[
            const Divider(color: PatchTheme.border, height: 1),
            // A tight SizedBox (not the button's own `minimumSize`) pins this
            // footer to the same height as the identity chip / message input,
            // so their top dividers line up — `minimumSize` alone isn't
            // reliable here since `VisualDensity` (platform-adaptive on
            // desktop) shrinks Material buttons below it.
            SizedBox(
              width: double.infinity,
              height: PatchTheme.footerHeight,
              child: TextButton.icon(
                onPressed: widget.onClearStale,
                icon: const Icon(Icons.person_remove_outlined, size: 14),
                label: const Text('Clear inactive'),
                style: TextButton.styleFrom(
                  foregroundColor: PatchTheme.textMuted,
                  textStyle: const TextStyle(fontSize: 11),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}


// ── Empty state ───────────────────────────────────────────────────────────────

class _PeersEmptyState extends StatelessWidget {
  final VoidCallback? onOpenSettings;
  const _PeersEmptyState({this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Waiting for peers…',
            style: TextStyle(
              color: PatchTheme.textSecondary,
              fontSize: PatchTheme.fontSizeSmall,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Make sure Patch is running on other devices on the same network.',
            style: TextStyle(color: PatchTheme.textMuted, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              GestureDetector(
                onTap: () => openHelp(context, assetPath: 'assets/docs/networking.md', title: 'Networking'),
                child: const Text(
                  'Networking guide',
                  style: TextStyle(
                    color: PatchTheme.accent,
                    fontSize: 11,
                    decoration: TextDecoration.underline,
                    decorationColor: PatchTheme.accent,
                  ),
                ),
              ),
              if (onOpenSettings != null)
                GestureDetector(
                  onTap: onOpenSettings,
                  child: const Text(
                    'Add a static peer',
                    style: TextStyle(
                      color: PatchTheme.accent,
                      fontSize: 11,
                      decoration: TextDecoration.underline,
                      decorationColor: PatchTheme.accent,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

/// Explains the peer status dot at a glance — the thing an Operator actually
/// reads (liveness), not how the peer was discovered.
const String _kDotLegend =
    'Green: online\nAmber: going quiet\nGrey: offline, left, or manual peer';

class _PeerTile extends StatelessWidget {
  final PeerInfo peer;
  final ValueChanged<String>? onDm;
  final bool isUnread;

  const _PeerTile({
    required this.peer,
    this.onDm,
    this.isUnread = false,
  });

  Color get _dotColor => switch (peer.status) {
        PeerStatus.online => PatchTheme.success,
        PeerStatus.stale => PatchTheme.warning,
        PeerStatus.offline => PatchTheme.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    final tile = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                          // Departed peers ('/patch/bye' / mDNS removal) render
                          // in italic so a clean departure is told apart at a
                          // glance.
                          fontStyle: peer.departed
                              ? FontStyle.italic
                              : FontStyle.normal,
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
              Tooltip(
                message: _kDotLegend,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _dotColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
          if (peer.address.isNotEmpty)
            Text(
              '${peer.address}:${peer.oscPort}',
              style: const TextStyle(
                color: PatchTheme.textMuted,
                fontSize: 9,
              ),
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );

    if (onDm == null || peer.isManual) return tile;

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
