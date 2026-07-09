import 'package:flutter/material.dart';

import '../models/message.dart';
import '../theme/patch_theme.dart';

/// The one peer-picker dialog for both import-from-Peer flows (#182). Owns
/// the candidate rule — a Peer is pickable when it has a known address and
/// port (not restricted to online-only; an unreachable Peer simply times
/// out at the request gate). Tapping a Peer pops the dialog and calls
/// [onPick]. The flows differ only in [title]/[blurb] and what they do with
/// the pick.
class PeerPickerDialog extends StatelessWidget {
  const PeerPickerDialog({
    super.key,
    required this.title,
    required this.blurb,
    required this.peers,
    required this.onPick,
  });

  final String title;
  final String blurb;
  final List<PeerInfo> peers;
  final void Function(String peerId, String peerName) onPick;

  @override
  Widget build(BuildContext context) {
    final candidates =
        peers.where((p) => p.address.isNotEmpty && p.oscPort > 0).toList();
    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: double.infinity,
        child: candidates.isEmpty
            ? const Text(
                'No peers with a known address are online yet. Wait for a peer '
                'to appear in the peers panel, then try again.',
                style: TextStyle(color: PatchTheme.textSecondary),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    blurb,
                    style: const TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...candidates.map((p) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.person_outline, size: 18),
                        title: Text(p.peerName),
                        subtitle: Text(p.address),
                        onTap: () {
                          Navigator.pop(context);
                          onPick(p.peerId, p.peerName);
                        },
                      )),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
