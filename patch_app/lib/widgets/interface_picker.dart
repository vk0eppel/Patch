import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Dropdown for scoping the discovery beacon to a network interface ("Auto" =
/// all). [selected] is the persisted `network_interface` (null = auto).
///
/// The saved interface may not be in the current enumeration — the NIC is down,
/// has no IPv4, was filtered, or the config came from another machine. A
/// `DropdownButton` throws if its `value` matches no item, so a missing saved
/// interface is surfaced as an "(not connected)" item: the setting stays visible
/// and editable instead of crashing the screen.
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

    // Build dropdown items: Auto + each enumerated interface.
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(
        value: null,
        child: Text('Auto (all interfaces)'),
      ),
      ...interfaces.map((iface) => DropdownMenuItem(
            value: iface['name'],
            child: Text('${iface['name']}  •  ${iface['ip']}'),
          )),
    ];

    // Saved-but-unavailable interface → keep a matching item so the dropdown
    // doesn't assert, and the user can see/change their stale selection.
    if (selected != null && !names.contains(selected)) {
      items.add(DropdownMenuItem(
        value: selected,
        child: Text('$selected  •  (not connected)'),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
              Icon(Icons.check_circle_outline, size: 14, color: PatchTheme.success),
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
