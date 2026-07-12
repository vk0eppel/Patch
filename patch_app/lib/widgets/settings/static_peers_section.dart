import 'package:flutter/material.dart';

import '../../models/config.dart' show StaticPeerInfo;
import '../../presenters/settings/save_result.dart';
import '../../presenters/settings/static_peers_presenter.dart';
import '../../screens/help_screen.dart';
import '../../theme/patch_theme.dart';
import '../../util/run_guarded.dart';
import 'section_scaffold.dart';

/// The Static Peers section (#141): add/remove peers at fixed IPs. The
/// validate→save→refetch loops live in [StaticPeersPresenter]; this widget
/// owns presentation only (ADR-0005).
class StaticPeersSection extends StatelessWidget {
  const StaticPeersSection({
    super.key,
    required this.presenter,
    required this.staticPeers,
    required this.interfaces,
  });

  final StaticPeersPresenter presenter;
  final List<StaticPeerInfo> staticPeers;

  /// This device's NICs — shown so the Operator can tell peers which IP to
  /// aim at.
  final List<Map<String, String>> interfaces;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: SettingsSectionHeader('Static Peers')),
            IconButton(
              icon: const Icon(Icons.help_outline, size: 16),
              color: PatchTheme.textMuted,
              tooltip: 'Networking guide',
              onPressed: () => openHelp(
                context,
                assetPath: 'assets/docs/networking.md',
                title: 'Networking',
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add peer'),
              style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
              onPressed: () => _showAddPeerDialog(context, presenter),
            ),
            SettingsResetButton(
              section: 'Static Peers',
              onReset: () => runGuarded(
                context,
                () => presenter.removeAll([
                  for (final peer in staticPeers)
                    (address: peer.address, port: peer.port),
                ]),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Add peers by IP when mDNS is blocked (AP isolation, VLANs, show networks). '
          'Static peers are always sent to and never expire.',
          style: TextStyle(
            color: PatchTheme.textSecondary,
            fontSize: PatchTheme.fontSizeSmall,
          ),
        ),
        if (interfaces.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: interfaces
                .map(
                  (iface) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.laptop,
                        size: 13,
                        color: PatchTheme.textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'This device: ${iface['ip']} (${iface['name']})',
                        style: const TextStyle(
                          color: PatchTheme.textMuted,
                          fontSize: PatchTheme.fontSizeMedium,
                        ),
                      ),
                    ],
                  ),
                )
                .toList(),
          ),
        ],
        const SizedBox(height: 12),
        if (staticPeers.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'No static peers',
              style: TextStyle(
                color: PatchTheme.textMuted,
                fontSize: PatchTheme.fontSizeSmall,
              ),
            ),
          )
        else
          ...staticPeers.map(
            (peer) => _StaticPeerRow(
              peer: peer,
              onDelete: () => runGuarded(
                context,
                () => presenter.remove(peer.address, peer.port),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Static peer row ───────────────────────────────────────────────────────────

class _StaticPeerRow extends StatelessWidget {
  final StaticPeerInfo peer;
  final VoidCallback onDelete;

  const _StaticPeerRow({required this.peer, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final address = peer.address;
    final port = peer.port;
    final label = peer.label;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: PatchTheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PatchTheme.border),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.push_pin_outlined,
            size: 14,
            color: PatchTheme.textMuted,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$address:$port',
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontSize: PatchTheme.fontSizeMedium,
                    fontFamily: 'monospace',
                  ),
                ),
                if (label != null && label.isNotEmpty)
                  Text(
                    label,
                    style: const TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: PatchTheme.textMuted,
            ),
            tooltip: 'Remove peer',
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

void _showAddPeerDialog(BuildContext context, StaticPeersPresenter presenter) {
  final addrCtrl = TextEditingController();
  final portCtrl = TextEditingController(text: '9000');
  final labelCtrl = TextEditingController();
  String? error;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Add Static Peer'),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: addrCtrl,
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.50',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'OSC port',
                  hintText: '9000',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'e.g. Monitor World',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: const TextStyle(color: PatchTheme.critical),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final port = int.tryParse(portCtrl.text.trim());
              if (port == null) {
                setDialogState(() => error = 'Port must be 1–65535');
                return;
              }
              final label = labelCtrl.text.trim();
              // Validation + add + config/peers refetch live in the
              // presenter (#141). Rejected input stays in the dialog.
              runGuarded(context, () async {
                final result = await presenter.add(
                  addrCtrl.text,
                  port,
                  label.isEmpty ? null : label,
                );
                switch (result) {
                  case SaveError(:final message):
                    setDialogState(() => error = message);
                  case SaveOk():
                    if (ctx.mounted) Navigator.pop(ctx);
                }
              });
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}
