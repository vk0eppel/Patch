import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

/// Collapsible right panel showing online peers.
class PeersPanel extends StatelessWidget {
  final List<PeerInfo> peers;
  const PeersPanel({super.key, required this.peers});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 14, 12, 8),
            child: Text(
              'ONLINE',
              style: TextStyle(
                color: PatchTheme.textSecondary,
                fontSize: PatchTheme.fontSizeSmall,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          Expanded(
            child: peers.isEmpty
                ? const Center(
                    child: Text(
                      'No peers',
                      style: TextStyle(color: PatchTheme.textMuted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: peers.length,
                    itemBuilder: (ctx, i) => _PeerTile(peer: peers[i]),
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
                ),
              ],
            ),
          ),
          // Online indicator
          Container(
            width: 7,
            height: 7,
            decoration: const BoxDecoration(
              color: PatchTheme.success,
              shape: BoxShape.circle,
            ),
          ),
        ],
      ),
    );
  }
}
