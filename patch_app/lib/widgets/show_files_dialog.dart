import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../bridge/bridge_client.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

/// Modal show files panel — shows named show files and file import/export.
/// Open with: showDialog(context: ctx, builder: (_) => ShowFilesDialog(bridge: bridge))
class ShowFilesDialog extends StatefulWidget {
  final BridgeClient bridge;

  const ShowFilesDialog({super.key, required this.bridge});

  @override
  State<ShowFilesDialog> createState() => _ShowFilesDialogState();
}

class _ShowFilesDialogState extends State<ShowFilesDialog> {
  List<ShowFileMeta> _showFiles = [];
  StreamSubscription<Map<String, dynamic>>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.bridge.events.listen(_handleEvent);
    widget.bridge.listShowFiles();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _handleEvent(Map<String, dynamic> event) {
    switch (event['event'] as String?) {
      case 'show_files':
        final data = event['data'] as List<dynamic>;
        if (mounted) {
          setState(() {
            _showFiles = data
                .map((s) => ShowFileMeta.fromJson(s as Map<String, dynamic>))
                .toList();
          });
        }
      case 'show_file_saved':
      case 'show_file_loaded':
        widget.bridge.listShowFiles();
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _loadFromFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['toml'],
      dialogTitle: 'Import Patch Show File',
    );
    if (result == null || result.files.isEmpty || result.files.first.path == null) return;
    final path = result.files.first.path!;
    await widget.bridge.importLayout(path);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveToFile() async {
    final name = await _askName(context, title: 'Export Show File', hint: 'Show file name');
    if (name == null || !mounted) return;

    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Patch Show File',
      fileName: '${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}.toml',
      allowedExtensions: ['toml'],
      type: FileType.custom,
    );
    if (path == null) return;
    await widget.bridge.exportLayout(path, name: name);
  }

  Future<void> _saveNew() async {
    final name = await _askName(context, title: 'Save Show File', hint: 'Show file name (e.g. "Festival Day 1")');
    if (name == null) return;
    await widget.bridge.saveShowFile(name);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: PatchTheme.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: PatchTheme.border),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 340, maxWidth: 420, maxHeight: 540),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
              child: Row(
                children: [
                  const Text(
                    'SHOW FILES',
                    style: TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: PatchTheme.fontSizeSmall,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.5,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18, color: PatchTheme.textMuted),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),

            // ── File actions ─────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.upload_file, size: 14),
                      label: const Text('Load from file…'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: PatchTheme.textSecondary,
                        side: const BorderSide(color: PatchTheme.border),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: _loadFromFile,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.download, size: 14),
                      label: const Text('Save to file…'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: PatchTheme.textSecondary,
                        side: const BorderSide(color: PatchTheme.border),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      onPressed: _saveToFile,
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            const Divider(color: PatchTheme.border, height: 1),

            // ── Show file list ─────────────────────────────────────────────────
            Flexible(
              child: _showFiles.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No saved show files yet.\nTap "+ Save current layout" to create one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: PatchTheme.textMuted, fontSize: PatchTheme.fontSizeSmall),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: _showFiles.length,
                      itemBuilder: (_, i) => _ShowFileRow(
                        showFile: _showFiles[i],
                        bridge: widget.bridge,
                        onLoaded: () => Navigator.of(context).pop(),
                      ),
                    ),
            ),

            const Divider(color: PatchTheme.border, height: 1),

            // ── Save button ───────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.all(12),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Save current layout'),
                onPressed: _saveNew,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Show file row ─────────────────────────────────────────────────────────────

class _ShowFileRow extends StatelessWidget {
  final ShowFileMeta showFile;
  final BridgeClient bridge;
  final VoidCallback onLoaded;

  const _ShowFileRow({
    required this.showFile,
    required this.bridge,
    required this.onLoaded,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: PatchTheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PatchTheme.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 15, color: PatchTheme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  showFile.name,
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: PatchTheme.fontSizeSmall,
                  ),
                ),
                Text(
                  '${showFile.channelCount} ch · ${_fmtDate(showFile.createdAt)}',
                  style: const TextStyle(color: PatchTheme.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
            onPressed: () {
              bridge.loadShowFile(showFile.slug);
              onLoaded();
            },
            child: const Text('Load'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 15, color: PatchTheme.textMuted),
            tooltip: 'Delete',
            onPressed: () => _confirmDelete(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime dt) =>
      '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${showFile.name}"?'),
        content: const Text(
          'This will permanently remove the saved show file.',
          style: TextStyle(color: PatchTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PatchTheme.critical),
            onPressed: () {
              bridge.deleteShowFile(showFile.slug);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ── Shared helper ─────────────────────────────────────────────────────────────

Future<String?> _askName(
  BuildContext context, {
  required String title,
  required String hint,
}) async {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        decoration: InputDecoration(hintText: hint),
        autofocus: true,
        textInputAction: TextInputAction.done,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = ctrl.text.trim();
            Navigator.pop(context, name.isEmpty ? null : name);
          },
          child: Text(title.contains('Export') ? 'Export' : 'Save'),
        ),
      ],
    ),
  );
}
