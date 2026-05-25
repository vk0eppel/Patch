import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/channel.dart';
import '../theme/patch_theme.dart';

/// Horizontal strip of one-tap shortcut message buttons.
/// Keyboard bindings (F1–F8 etc.) fire when the channel is focused.
class ShortcutBar extends StatelessWidget {
  final List<ShortcutMessage> shortcuts;
  final ValueChanged<ShortcutMessage> onShortcut;

  const ShortcutBar({
    super.key,
    required this.shortcuts,
    required this.onShortcut,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: shortcuts.map((s) => _ShortcutChip(
            shortcut: s,
            onTap: () => onShortcut(s),
          )).toList(),
        ),
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  final ShortcutMessage shortcut;
  final VoidCallback onTap;

  const _ShortcutChip({required this.shortcut, required this.onTap});

  Color get _chipColor {
    return switch (shortcut.priority) {
      3 => PatchTheme.critical.withAlpha(30),
      2 => PatchTheme.warning.withAlpha(30),
      _ => PatchTheme.surfaceHigh,
    };
  }

  Color get _borderColor {
    return switch (shortcut.priority) {
      3 => PatchTheme.critical,
      2 => PatchTheme.warning,
      _ => PatchTheme.border,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _chipColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _borderColor),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                shortcut.label,
                style: const TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeSmall,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (shortcut.keyBinding != null)
                Text(
                  shortcut.keyBinding!,
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 9,
                    letterSpacing: 0.5,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
