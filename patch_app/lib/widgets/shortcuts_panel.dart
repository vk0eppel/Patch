import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme/patch_theme.dart';

/// A shortcut paired with its channel context — used when aggregating shortcuts
/// from multiple selected channels for display in [ShortcutsPanel].
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

/// Vertical side panel showing all shortcuts as fixed-height buttons.
///
/// Designed for show use: every shortcut is always visible with no scrolling.
/// The panel fills available height; buttons share that height equally so there
/// is never any hidden content. Users curate the shortcut list before the show
/// to keep button sizes comfortable.
///
/// When [isMulti] is true (multiple channels selected), shortcuts are grouped
/// by channel with a thin colour-coded divider and channel name label.
class ShortcutsPanel extends StatelessWidget {
  final List<ChannelShortcut> shortcuts;
  final bool isMulti;
  final ValueChanged<ChannelShortcut> onShortcut;

  const ShortcutsPanel({
    super.key,
    required this.shortcuts,
    required this.isMulti,
    required this.onShortcut,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: PatchTheme.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: const Text(
              'SHORTCUTS',
              style: TextStyle(
                color: PatchTheme.textSecondary,
                fontSize: PatchTheme.fontSizeSmall,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          if (shortcuts.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'No shortcuts',
                  style: TextStyle(color: PatchTheme.textMuted),
                ),
              ),
            )
          else if (!isMulti)
            // Single channel — flat list, no channel grouping
            ..._buildFlatButtons(shortcuts)
          else
            // Multi-channel — group by channel with colour headers
            ..._buildGroupedButtons(shortcuts),
        ],
      ),
    );
  }

  /// Flat list of Expanded buttons, one per shortcut — no channel grouping.
  List<Widget> _buildFlatButtons(List<ChannelShortcut> items) {
    return items
        .map((cs) => Expanded(
              child: _ShortcutButton(
                cs: cs,
                showChannelBar: false,
                onTap: () => onShortcut(cs),
              ),
            ))
        .toList();
  }

  /// Buttons grouped by channel. Each group gets a thin colour header.
  /// Total flex weight = number of shortcuts (groups consume no vertical space).
  List<Widget> _buildGroupedButtons(List<ChannelShortcut> items) {
    // Preserve order: build groups in the order channels first appear.
    final seen = <String>[];
    final groups = <String, List<ChannelShortcut>>{};
    for (final cs in items) {
      if (!seen.contains(cs.channelId)) seen.add(cs.channelId);
      groups.putIfAbsent(cs.channelId, () => []).add(cs);
    }

    final widgets = <Widget>[];
    for (final id in seen) {
      final group = groups[id]!;
      final color = group.first.channelColor;

      // Thin channel-colour divider + name label (intrinsic height, no flex)
      widgets.add(_ChannelGroupHeader(color: color, channelId: id, shortcuts: group));

      for (final cs in group) {
        widgets.add(Expanded(
          child: _ShortcutButton(
            cs: cs,
            showChannelBar: true,
            onTap: () => onShortcut(cs),
          ),
        ));
      }
    }
    return widgets;
  }
}

// ── Channel group header ───────────────────────────────────────────────────────

class _ChannelGroupHeader extends StatelessWidget {
  final Color color;
  final String channelId;
  final List<ChannelShortcut> shortcuts;

  const _ChannelGroupHeader({
    required this.color,
    required this.channelId,
    required this.shortcuts,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 20,
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: color, width: 3),
          top: const BorderSide(color: PatchTheme.border, width: 1),
        ),
      ),
      padding: const EdgeInsets.only(left: 8),
      alignment: Alignment.centerLeft,
      child: Text(
        channelId.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

// ── Individual shortcut button ─────────────────────────────────────────────────

class _ShortcutButton extends StatelessWidget {
  final ChannelShortcut cs;
  final bool showChannelBar;
  final VoidCallback onTap;

  const _ShortcutButton({
    required this.cs,
    required this.showChannelBar,
    required this.onTap,
  });

  Color get _bgColor {
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
    return Material(
      color: _bgColor,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: showChannelBar
                  ? BorderSide(color: cs.channelColor, width: 3)
                  : BorderSide(color: _borderColor, width: 1),
              bottom: const BorderSide(color: PatchTheme.border, width: 1),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          alignment: Alignment.center,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                cs.shortcut.label,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeSmall,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
              ),
              if (cs.shortcut.keyBinding != null) ...[
                const SizedBox(height: 2),
                Text(
                  cs.shortcut.keyBinding!,
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 9,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
