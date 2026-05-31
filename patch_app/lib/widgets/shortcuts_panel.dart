import 'dart:math' show min;
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
/// [columns] (1 or 2) controls how many buttons appear per row. The preference
/// is persisted via the Rust config and toggled with the [1] [2] control in the
/// panel header.
///
/// When [isMulti] is true (multiple channels selected), shortcuts are grouped
/// by channel with a thin colour-coded divider and channel name label.
class ShortcutsPanel extends StatelessWidget {
  final List<ChannelShortcut> shortcuts;
  final bool isMulti;
  final int columns;
  final ValueChanged<int> onColumnsChanged;
  final ValueChanged<ChannelShortcut> onShortcut;

  const ShortcutsPanel({
    super.key,
    required this.shortcuts,
    required this.isMulti,
    required this.columns,
    required this.onColumnsChanged,
    required this.onShortcut,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────────────
          Container(
            height: PatchTheme.headerHeight,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const Text(
                  'MACROS',
                  style: TextStyle(
                    color: PatchTheme.textSecondary,
                    fontSize: PatchTheme.fontSizeSmall,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                _ColumnToggle(current: columns, onChanged: onColumnsChanged),
              ],
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          // ── Content ─────────────────────────────────────────────────────
          if (shortcuts.isEmpty)
            const Expanded(
              child: Center(
                child: Text(
                  'No macros',
                  style: TextStyle(color: PatchTheme.textMuted),
                ),
              ),
            )
          else if (!isMulti)
            ..._buildFlatRows(shortcuts)
          else
            ..._buildGroupedRows(shortcuts),
        ],
      ),
    );
  }

  /// Chunk [items] into rows of [columns] each and wrap each row in an Expanded.
  List<Widget> _rowsFrom(List<ChannelShortcut> items, {required bool showChannelBar}) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += columns) {
      final slice = items.sublist(i, min(i + columns, items.length));
      rows.add(Expanded(
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var col = 0; col < columns; col++)
              Expanded(
                child: col < slice.length
                    ? _ShortcutButton(
                        cs: slice[col],
                        showChannelBar: showChannelBar,
                        onTap: () => onShortcut(slice[col]),
                      )
                    : const _EmptyCell(),
              ),
          ],
          ),  // Row
        ),    // ConstrainedBox
      ));
    }
    return rows;
  }

  /// Flat rows — single channel, no grouping.
  List<Widget> _buildFlatRows(List<ChannelShortcut> items) =>
      _rowsFrom(items, showChannelBar: false);

  /// Rows grouped by channel with a full-width colour header per group.
  List<Widget> _buildGroupedRows(List<ChannelShortcut> items) {
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
      widgets.add(_ChannelGroupHeader(color: color, channelId: id));
      widgets.addAll(_rowsFrom(group, showChannelBar: true));
    }
    return widgets;
  }
}

// ── Column toggle ─────────────────────────────────────────────────────────────

class _ColumnToggle extends StatelessWidget {
  final int current;
  final ValueChanged<int> onChanged;

  const _ColumnToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [1, 2].map((n) {
        final active = current == n;
        return GestureDetector(
          onTap: () => onChanged(n),
          child: Container(
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color: active ? PatchTheme.accent.withAlpha(30) : Colors.transparent,
              border: Border.all(
                color: active ? PatchTheme.accent : PatchTheme.textMuted,
                width: 1,
              ),
              borderRadius: BorderRadius.circular(3),
            ),
            alignment: Alignment.center,
            child: Text(
              '$n',
              style: TextStyle(
                color: active ? PatchTheme.accent : PatchTheme.textMuted,
                fontSize: PatchTheme.fontSizeSmall,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ── Channel group header ───────────────────────────────────────────────────────

class _ChannelGroupHeader extends StatelessWidget {
  final Color color;
  final String channelId;

  const _ChannelGroupHeader({required this.color, required this.channelId});

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

// ── Empty cell (fills unused grid slot) ───────────────────────────────────────

class _EmptyCell extends StatelessWidget {
  const _EmptyCell();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: PatchTheme.border, width: 1),
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
      clipBehavior: Clip.hardEdge,
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
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
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
