import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme/patch_theme.dart';

/// A shortcut paired with its channel — used when aggregating shortcuts
/// from multiple selected channels.
class ChannelShortcut {
  final String channelId;
  final Color channelColor;
  final ShortcutMessage shortcut;

  const ChannelShortcut({
    required this.channelId,
    required this.channelColor,
    required this.shortcut,
  });
}

/// Horizontal strip of one-tap shortcut buttons.
///
/// [shortcuts] carries channel context so each chip can show its channel's
/// colour dot when multiple channels are active.
/// [showChannelDots] should be true when more than one channel is selected.
class ShortcutBar extends StatelessWidget {
  final List<ChannelShortcut> shortcuts;
  final ValueChanged<ChannelShortcut> onShortcut;
  final bool showChannelDots;

  const ShortcutBar({
    super.key,
    required this.shortcuts,
    required this.onShortcut,
    this.showChannelDots = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: shortcuts
              .map((cs) => _ShortcutChip(
                    cs: cs,
                    showChannelDot: showChannelDots,
                    onTap: () => onShortcut(cs),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  final ChannelShortcut cs;
  final bool showChannelDot;
  final VoidCallback onTap;

  const _ShortcutChip({
    required this.cs,
    required this.showChannelDot,
    required this.onTap,
  });

  Color get _chipColor {
    return switch (cs.shortcut.priority) {
      3 => PatchTheme.critical.withAlpha(30),
      2 => PatchTheme.warning.withAlpha(30),
      _ => PatchTheme.surfaceHigh,
    };
  }

  Color get _borderColor {
    return switch (cs.shortcut.priority) {
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
              // Channel dot — only when viewing multiple channels
              if (showChannelDot) ...[
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(bottom: 3),
                  decoration: BoxDecoration(
                    color: cs.channelColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
              Text(
                cs.shortcut.label,
                style: const TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeSmall,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (cs.shortcut.keyBinding != null)
                Text(
                  cs.shortcut.keyBinding!,
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
