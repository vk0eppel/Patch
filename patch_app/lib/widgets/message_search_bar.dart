import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// In-channel search bar: a text field plus Info/Warning/Critical priority
/// toggles. Presentational and bridge-free — the parent owns the query and the
/// active category set and applies the filtering. Shown only while search is
/// expanded; removed (not just hidden) on collapse, so it reseeds empty.
class MessageSearchBar extends StatefulWidget {
  /// Initial query text (usually empty on open).
  final String query;

  /// Currently-active priority categories: any of 'info' / 'warning' / 'critical'.
  final Set<String> categories;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<String> onToggleCategory;
  final VoidCallback onClose;

  const MessageSearchBar({
    super.key,
    required this.query,
    required this.categories,
    required this.onQueryChanged,
    required this.onToggleCategory,
    required this.onClose,
  });

  @override
  State<MessageSearchBar> createState() => _MessageSearchBarState();
}

class _MessageSearchBarState extends State<MessageSearchBar> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.query,
  );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static const _cats = ['info', 'warning', 'critical'];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              style: const TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeSmall,
              ),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search sender or message…',
                border: OutlineInputBorder(),
              ),
              onChanged: widget.onQueryChanged,
            ),
          ),
          const SizedBox(width: 8),
          for (final cat in _cats) ...[
            FilterChip(
              label: Text(
                cat[0].toUpperCase() + cat.substring(1),
                style: const TextStyle(fontSize: 11),
              ),
              selected: widget.categories.contains(cat),
              onSelected: (_) => widget.onToggleCategory(cat),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            const SizedBox(width: 4),
          ],
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: PatchTheme.textMuted,
            tooltip: 'Close search',
            onPressed: widget.onClose,
          ),
        ],
      ),
    );
  }
}
