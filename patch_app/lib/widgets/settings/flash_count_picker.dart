import 'package:flutter/material.dart';

import '../../theme/patch_theme.dart';

// ── Flash pulse count picker ──────────────────────────────────────────────────
//
// Compact segmented control: 1 · 2 · 3 · 4 · 5.
// When [value] is null (per-channel use) a "–" (global) option is prepended.

class FlashCountPicker extends StatelessWidget {
  /// Current value. null means "use global" (only valid for per-channel pickers).
  final int? value;

  /// Called with the new value, or null to clear a per-channel override.
  final void Function(int? val) onChanged;

  const FlashCountPicker({
    super.key,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // When value is null we're in per-channel mode — show a "–" (global) option.
    final showGlobal = value == null;
    final options = <({int? v, String label})>[
      if (showGlobal) (v: null, label: '–'),
      (v: 3, label: '3'),
      (v: 4, label: '4'),
      (v: 5, label: '5'),
      (v: 6, label: '6'),
      (v: 7, label: '7'),
    ];

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: options.map((opt) {
        final selected = opt.v == value;
        return GestureDetector(
          onTap: () => onChanged(opt.v),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? PatchTheme.accent : PatchTheme.surfaceHigh,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: selected ? PatchTheme.accent : PatchTheme.border,
              ),
            ),
            child: Text(
              opt.label,
              style: TextStyle(
                color: selected ? Colors.white : PatchTheme.textSecondary,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
