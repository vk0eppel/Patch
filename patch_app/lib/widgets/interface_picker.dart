import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Dropdown for scoping the discovery beacon to a network interface. Pinning
/// is mandatory — there is no "Auto"/all-interfaces option. [selected] is the
/// persisted `network_interface`; null means unresolved (pending the
/// engine's first-run auto-select, or a manual choice here).
///
/// The saved interface may not be in the current enumeration — the NIC is down,
/// has no IPv4, was filtered, or the config came from another machine. A
/// `DropdownButton` throws if its `value` matches no item, so a missing saved
/// interface is surfaced as an "(not connected)" item — distinct from the
/// "Select a network…" placeholder shown when nothing has ever been resolved —
/// the setting stays visible and editable instead of crashing the screen.
class InterfacePicker extends StatelessWidget {
  final List<Map<String, String>> interfaces;
  final String? selected; // null = auto
  final bool applied;
  final ValueChanged<String?> onSelect;

  const InterfacePicker({
    super.key,
    required this.interfaces,
    required this.selected,
    required this.applied,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final names = interfaces.map((i) => i['name']).toSet();

    // Build dropdown items: each enumerated interface, plus a placeholder
    // when nothing has ever been resolved (mandatory pinning has no Auto).
    final items = <DropdownMenuItem<String?>>[
      if (selected == null)
        const DropdownMenuItem(value: null, child: Text('Select a network…')),
      ...interfaces.map(
        (iface) => DropdownMenuItem(
          value: iface['name'],
          child: Text('${iface['name']}  •  ${iface['ip']}'),
        ),
      ),
    ];

    // Saved-but-unavailable interface → keep a matching item so the dropdown
    // doesn't assert, and the user can see/change their stale selection.
    if (selected != null && !names.contains(selected)) {
      items.add(
        DropdownMenuItem(
          value: selected,
          child: Text('$selected  •  (not connected)'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (selected == null) ...[
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: PatchTheme.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: PatchTheme.warning),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 16,
                  color: PatchTheme.warning,
                ),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No network selected — Patch cannot discover or be '
                    'discovered by other devices until you choose one. '
                    'Static peers still work.',
                    style: TextStyle(
                      color: PatchTheme.warning,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          decoration: BoxDecoration(
            color: PatchTheme.surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: PatchTheme.border),
          ),
          child: DropdownButton<String?>(
            value: selected,
            isExpanded: true,
            underline: const SizedBox.shrink(),
            dropdownColor: PatchTheme.surface,
            style: const TextStyle(
              color: PatchTheme.textPrimary,
              fontSize: PatchTheme.fontSizeSmall,
            ),
            items: items,
            onChanged: onSelect,
          ),
        ),
        if (applied) ...[
          const SizedBox(height: 8),
          Row(
            children: const [
              Icon(
                Icons.check_circle_outline,
                size: 14,
                color: PatchTheme.success,
              ),
              SizedBox(width: 6),
              Text(
                'Applied — active within a few seconds.',
                style: TextStyle(color: PatchTheme.success, fontSize: 11),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
