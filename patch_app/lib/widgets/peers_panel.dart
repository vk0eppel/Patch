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
  final VoidCallback? onClearStale;
  final VoidCallback? onClose;
  const PeersPanel({super.key, required this.peers, this.onClearStale, this.onClose});

  @override
  State<PeersPanel> createState() => _PeersPanelState();
}

class _PeersPanelState extends State<PeersPanel> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
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
                    itemBuilder: (ctx, i) => _PeerTile(peer: widget.peers[i]),
                  ),
          ),
        ],
      ),
    );
  }
}


class _PeerTile extends StatelessWidget {
  final PeerInfo peer;
  const _PeerTile({required this.peer});

  String get _discoveryIcon {
    return switch (peer.discoveryMode) {
      'Mdns' || 'mdns' => '🔍',
      'ManualIp' || 'manual_ip' => '📌',
      _ => '📡',
    };
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
                  peer.address.isNotEmpty ? peer.address : 'unknown IP',
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 10,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Green = heard from within the last 35 s (5 × 7 s heartbeat interval).
          // Gray = ManualIp synthetic entry (never contacted), or real entry gone quiet.
          Builder(builder: (context) {
            final bool isOnline;
            if (peer.discoveryMode == 'ManualIp' ||
                peer.discoveryMode == 'manual_ip') {
              isOnline = false;
            } else {
              final age = DateTime.now().difference(peer.lastSeen);
              isOnline = age.inSeconds <= 35;
            }
            return Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: isOnline ? PatchTheme.success : PatchTheme.textMuted,
                shape: BoxShape.circle,
              ),
            );
          }),
        ],
      ),
    );
  }
}
