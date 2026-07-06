import 'package:flutter/material.dart';

import '../../bridge/bridge_client.dart';
import '../../src/rust/api.dart' as rust;
import '../../models/channel.dart';
import '../../presenters/settings/macros_section_presenter.dart';
import '../../presenters/settings/save_result.dart';
import '../../store/app_store.dart';
import '../../theme/patch_theme.dart';
import '../../util/run_guarded.dart';
import 'flash_count_picker.dart';
import 'section_scaffold.dart';

/// The Global Macros section (#141): one-touch callouts shown on every
/// Channel's panel. Macro CRUD refetches config via the store; the OSC
/// dual-action is validated by [validateMacroOscTarget] before saving.
class GlobalMacrosSection extends StatelessWidget {
  const GlobalMacrosSection({
    super.key,
    required this.bridge,
    required this.presenter,
    required this.globalMacros,
    required this.onImportFromPeer,
    required this.onReset,
  });

  final BridgeClient bridge;
  final MacrosSectionPresenter presenter;
  final List<MacroMessage> globalMacros;
  final VoidCallback onImportFromPeer;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(child: SettingsSectionHeader('Global Macros')),
          IconButton(
            icon: const Icon(Icons.cloud_download_outlined, size: 18),
            color: PatchTheme.textMuted,
            tooltip: 'Import macros from a peer',
            onPressed: onImportFromPeer,
          ),
          SettingsResetButton(section: 'Global Macros', onReset: onReset),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Macros shown on every channel\'s panel. Firing one sends on the '
          'channel(s) you currently have selected — for common callouts you '
          'don\'t want to recreate on each channel.',
          style: TextStyle(
            color: PatchTheme.textSecondary,
            fontSize: PatchTheme.fontSizeSmall,
          ),
        ),
        const SizedBox(height: 16),
        _GlobalMacrosEditor(macros: globalMacros, bridge: bridge, presenter: presenter),
      ],
    );
  }
}

/// The Channels & Macros section (#141): per-Channel editing — name, colour,
/// Channel Macros, per-channel flash overrides. OSC dual-actions are
/// validated before saving (ADR-0002).
class ChannelsMacrosSection extends StatelessWidget {
  const ChannelsMacrosSection({
    super.key,
    required this.bridge,
    required this.presenter,
    required this.channels,
    required this.onImportFromPeer,
    required this.onDeleteChannel,
  });

  final BridgeClient bridge;
  final MacrosSectionPresenter presenter;
  final List<PatchChannel> channels;
  final VoidCallback onImportFromPeer;
  final void Function(PatchChannel) onDeleteChannel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: SettingsSectionHeader('Channels & Macros')),
            IconButton(
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              color: PatchTheme.textMuted,
              tooltip: 'Import channels from a peer',
              onPressed: onImportFromPeer,
            ),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New channel'),
              style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
              onPressed: () => _showChannelDialog(
                context,
                bridge,
                existingIds: channels.map((c) => c.id).toSet(),
              ),
            ),
            SettingsResetButton(
              section: 'Channels & Macros',
              onReset: () =>
                  runGuarded(context, () => rust.resetChannels()),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Edit a channel\'s name and colour, manage its one-tap macros, or create a new channel.',
          style: TextStyle(
              color: PatchTheme.textSecondary,
              fontSize: PatchTheme.fontSizeSmall),
        ),
        const SizedBox(height: 16),
        ...channels.map((ch) => _ChannelMacroEditor(
              channel: ch,
              bridge: bridge,
              presenter: presenter,
              onDelete: () => onDeleteChannel(ch),
              onEdit: () => _showChannelDialog(
                context,
                bridge,
                existing: ch,
                existingIds: channels.map((c) => c.id).toSet(),
              ),
            )),
      ],
    );
  }
}

// ── Macro helpers ─────────────────────────────────────────────────────────────

/// Surface a rejected macro save (invalid OSC target) the same way
/// `runGuarded` surfaces a thrown bridge failure — a critical-coloured
/// SnackBar with the operator-facing message (#163: the presenter now
/// returns a [SaveResult] instead of throwing).
void _showSaveError(BuildContext context, SaveResult result) {
  if (result case SaveError(:final message)) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: PatchTheme.critical,
          duration: const Duration(seconds: 5),
        ),
      );
  }
}

/// Lower-cases a string and capitalizes its first character. Used to turn an
/// uppercase button label (e.g. "LOW BATT") into a readable message ("Low batt")
/// when autofilling the macro message text.
String _capitalizeFirst(String s) {
  if (s.isEmpty) return s;
  final lower = s.toLowerCase();
  return lower[0].toUpperCase() + lower.substring(1);
}

// ── Per-channel shortcut editor ───────────────────────────────────────────────

class _ChannelMacroEditor extends StatelessWidget {
  final PatchChannel channel;
  final BridgeClient bridge;
  final MacrosSectionPresenter presenter;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const _ChannelMacroEditor({
    required this.channel,
    required this.bridge,
    required this.presenter,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    return _MacroListCard(
      dotColor: channel.color,
      label: channel.displayName,
      macros: channel.macros,
      keyFor: (m) => '${channel.id}:${m.label}',
      emptyText: 'No macros yet',
      // Channel-macro CRUD refreshes the screens via the ChannelsChanged push
      // (no config refetch needed); runGuarded surfaces failures (ADR-0004).
      onUpsert: (ol, l, p, k, pr, mn, mc, osc) => runGuarded(context, () async {
        final result = await presenter.saveChannelMacro(
          channelId: channel.id,
          originalLabel: ol,
          label: l,
          payload: p,
          keyBinding: k,
          priority: pr,
          midiNote: mn,
          midiCc: mc,
          osc: osc,
        );
        if (context.mounted) _showSaveError(context, result);
      }),
      onDelete: (m) => runGuarded(
          context, () => rust.deleteMacro(channelId: channel.id, label: m.label)),
      onReorder: (labels) =>
          runGuarded(context,
              () => rust.reorderMacros(channelId: channel.id, orderedLabels: labels)),
      trailingActions: [
        IconButton(
          icon: const Icon(Icons.edit_outlined, size: 16, color: PatchTheme.textMuted),
          tooltip: 'Edit channel',
          onPressed: onEdit,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, size: 16, color: PatchTheme.textMuted),
          tooltip: 'Delete channel',
          onPressed: onDelete,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ],
      footer: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: PatchTheme.border)),
        ),
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(0, 8, 0, 4),
              child: Text(
                'Global Behavior settings always apply — these flags add triggers '
                'per channel but cannot suppress a global setting.',
                style: TextStyle(
                  color: PatchTheme.textMuted,
                  fontSize: 10,
                ),
              ),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Flash on every message',
                style: TextStyle(
                  color: PatchTheme.textSecondary,
                  fontSize: PatchTheme.fontSizeSmall,
                ),
              ),
              value: channel.flashOnMessage,
              activeThumbColor: PatchTheme.accent,
              onChanged: (val) => runGuarded(context,
                  () => rust.setChannelFlash(channelId: channel.id, flashOnMessage: val)),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Flash on critical messages',
                style: TextStyle(
                  color: PatchTheme.textSecondary,
                  fontSize: PatchTheme.fontSizeSmall,
                ),
              ),
              value: channel.flashOnCritical,
              activeThumbColor: PatchTheme.accent,
              onChanged: (val) => runGuarded(context,
                  () => rust.setChannelFlash(channelId: channel.id, flashOnCritical: val)),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Flash pulses',
                    style: TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                ),
                // null = use global; picker shows "–" for global
                FlashCountPicker(
                  value: channel.flashCount,
                  onChanged: (val) => runGuarded(
                      context,
                      () => rust.setChannelFlash(
                            channelId: channel.id,
                            // 0 signals "clear override" to the Rust side
                            flashCount: val ?? 0,
                          )),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Card shared by [_ChannelMacroEditor] and [_GlobalMacrosEditor]: header
/// (colour dot + label + Add button + [trailingActions]), a reorderable macro
/// list (or [emptyText] when empty), and an optional [footer] — the per-channel
/// flash-override switches, absent for global macros.
class _MacroListCard extends StatelessWidget {
  final Color dotColor;
  final String label;
  final List<MacroMessage> macros;
  final String Function(MacroMessage) keyFor;
  final String emptyText;
  final void Function(String? originalLabel, String label, String payload,
      String? keyBinding, int priority, int? midiNote, int? midiCc,
      MacroOsc? osc) onUpsert;
  final void Function(MacroMessage macro) onDelete;
  final void Function(List<String> labels) onReorder;
  final List<Widget> trailingActions;
  final Widget? footer;

  const _MacroListCard({
    required this.dotColor,
    required this.label,
    required this.macros,
    required this.keyFor,
    required this.emptyText,
    required this.onUpsert,
    required this.onDelete,
    required this.onReorder,
    this.trailingActions = const [],
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: PatchTheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PatchTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: PatchTheme.border)),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(6),
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 8, height: 8,
                  decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: PatchTheme.fontSizeSmall,
                    letterSpacing: 1,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add'),
                  style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
                  onPressed: () => _showMacroEditDialog(
                    context,
                    onSave: onUpsert,
                  ),
                ),
                ...trailingActions,
              ],
            ),
          ),
          if (macros.isEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Text(
                emptyText,
                style: const TextStyle(color: PatchTheme.textMuted, fontSize: PatchTheme.fontSizeSmall),
              ),
            )
          else
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false, // each row carries its own handle
              itemCount: macros.length,
              itemBuilder: (ctx, i) {
                final m = macros[i];
                return _MacroRow(
                  key: ValueKey(keyFor(m)),
                  shortcut: m,
                  index: i,
                  onEdit: () => _showMacroEditDialog(
                    context,
                    existing: m,
                    onSave: onUpsert,
                  ),
                  onDelete: () => onDelete(m),
                );
              },
              // onReorderItem is newer than the repo's supported Flutter range;
              // onReorder works across all Flutter 3.x.
              // ignore: deprecated_member_use
              onReorder: (oldIndex, newIndex) {
                if (newIndex > oldIndex) newIndex -= 1;
                final labels = macros.map((m) => m.label).toList();
                labels.insert(newIndex, labels.removeAt(oldIndex));
                onReorder(labels);
              },
            ),
          ?footer,
        ],
      ),
    );
  }

  /// Shared macro create/edit dialog. `onSave(originalLabel, label, payload,
  /// keyBinding, priority, midiNote, midiCc)` receives the trimmed/validated
  /// values, with `originalLabel` set to [existing]'s pre-edit label (null for
  /// a new macro) so the caller can rename in place rather than duplicate; the
  /// channel and global editors pass their own persistence call. MIDI fields
  /// are hidden when [allowMidi] is false.
  static void _showMacroEditDialog(
    BuildContext context, {
    MacroMessage? existing,
    bool allowMidi = true,
    required void Function(String? originalLabel, String label,
            String payload, String? keyBinding, int priority, int? midiNote,
            int? midiCc, MacroOsc? osc)
        onSave,
  }) {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final payloadCtrl = TextEditingController(text: existing?.payload ?? '');
    final keyCtrl = TextEditingController(text: existing?.keyBinding ?? '');
    final noteCtrl =
        TextEditingController(text: existing?.midiNote?.toString() ?? '');
    final ccCtrl =
        TextEditingController(text: existing?.midiCc?.toString() ?? '');
    final oscAddrCtrl = TextEditingController(text: existing?.osc?.address ?? '');
    final oscPortCtrl =
        TextEditingController(text: existing?.osc?.port.toString() ?? '');
    final oscPathCtrl = TextEditingController(text: existing?.osc?.path ?? '');
    final oscArgCtrl = TextEditingController(text: existing?.osc?.arg ?? '');
    MacroOscArgType oscArgType = existing?.osc?.argType ?? MacroOscArgType.string;
    bool oscEnabled = existing?.osc != null;
    int priority = existing?.priority ?? 1;
    // For a new macro, mirror the label into the message text (capitalized-first)
    // until the user edits the message themselves. Off when editing an existing
    // macro so its saved message is never overwritten.
    bool autofillPayload = existing == null;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          // Scrollable so the content (especially with MIDI + OSC fields expanded)
          // never overflows the dialog's max height on short/!tall screens.
          scrollable: true,
          title: Text(existing == null ? 'New Macro' : 'Edit Macro'),
          content: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: 'Button label', hintText: 'e.g. HOLD'),
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (value) {
                    // Mirror label → message until the user edits the message.
                    // Setting .text programmatically does not fire the payload
                    // field's onChanged, so it won't flip `autofillPayload`.
                    if (autofillPayload) {
                      payloadCtrl.text = _capitalizeFirst(value);
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: payloadCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Message text',
                    hintText: 'e.g. HOLD — do not transmit',
                  ),
                  // Once the user types here, stop mirroring the label.
                  onChanged: (_) => autofillPayload = false,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Key binding (optional)',
                    hintText: 'e.g. F1',
                  ),
                ),
                if (allowMidi) ...[
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: noteCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'MIDI note',
                            hintText: '0–127',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: ccCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'MIDI CC',
                            hintText: '0–127',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Fire this macro hands-free from a footswitch, pad, or '
                    'keyboard. Leave blank for none.',
                    style: TextStyle(
                      color: PatchTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                const Text(
                  'Priority',
                  style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
                ),
                const SizedBox(height: 6),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 1, label: Text('Info')),
                    ButtonSegment(value: 2, label: Text('Warning')),
                    ButtonSegment(value: 3, label: Text('Critical')),
                  ],
                  selected: {priority},
                  onSelectionChanged: (s) => setDialogState(() => priority = s.first),
                  style: ButtonStyle(
                    foregroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) return Colors.black;
                      return PatchTheme.textSecondary;
                    }),
                    backgroundColor: WidgetStateProperty.resolveWith((states) {
                      if (states.contains(WidgetState.selected)) {
                        return priority == 3 ? PatchTheme.critical : priority == 2 ? PatchTheme.warning : PatchTheme.accent;
                      }
                      return PatchTheme.surfaceHigh;
                    }),
                  ),
                ),
                // ── OSC target (dual action) ──────────────────────────────
                const SizedBox(height: 6),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Also send OSC',
                    style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
                  ),
                  subtitle: const Text(
                    'Fire an OSC message to gear (QLab, Companion, vMix…) when this macro fires.',
                    style: TextStyle(color: PatchTheme.textMuted, fontSize: 11),
                  ),
                  value: oscEnabled,
                  activeThumbColor: PatchTheme.accent,
                  onChanged: (v) => setDialogState(() => oscEnabled = v),
                ),
                if (oscEnabled) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: oscAddrCtrl,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(labelText: 'IP', hintText: '192.168.1.50'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: oscPortCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Port', hintText: '53000'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: oscPathCtrl,
                    decoration: const InputDecoration(labelText: 'OSC path', hintText: '/cue/1/start'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: oscArgCtrl,
                    decoration: const InputDecoration(labelText: 'Argument (optional)', hintText: 'e.g. go'),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Argument type',
                    style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<MacroOscArgType>(
                    segments: const [
                      ButtonSegment(value: MacroOscArgType.string, label: Text('String')),
                      ButtonSegment(value: MacroOscArgType.int, label: Text('Int')),
                      ButtonSegment(value: MacroOscArgType.float, label: Text('Float')),
                    ],
                    selected: {oscArgType},
                    onSelectionChanged: (s) => setDialogState(() => oscArgType = s.first),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Sent to the console as that OSC type — e.g. Float for a fader '
                    '(0.0–1.0), Int for a cue number.',
                    style: TextStyle(
                      color: PatchTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final label = labelCtrl.text.trim();
                final payload = payloadCtrl.text.trim();
                if (label.isEmpty || payload.isEmpty) return;
                // Parse a MIDI field: empty or out-of-range (0–127) → null.
                int? midi(TextEditingController c) {
                  final t = c.text.trim();
                  if (t.isEmpty) return null;
                  final v = int.tryParse(t);
                  return (v != null && v >= 0 && v <= 127) ? v : null;
                }

                // OSC-target validity is decided in exactly one place:
                // validateMacroOscTarget, reached via the presenter's
                // validateThenSave seam after Save. Build the raw value here
                // and let that seam reject it — no second, looser check.
                MacroOsc? osc;
                if (oscEnabled) {
                  final a = oscArgCtrl.text.trim();
                  osc = MacroOsc(
                    address: oscAddrCtrl.text.trim(),
                    port: int.tryParse(oscPortCtrl.text.trim()) ?? 0,
                    path: oscPathCtrl.text.trim(),
                    arg: a.isEmpty ? null : a,
                    argType: oscArgType,
                  );
                }

                onSave(
                  existing?.label,
                  label,
                  payload,
                  keyCtrl.text.trim().isEmpty ? null : keyCtrl.text.trim(),
                  priority,
                  allowMidi ? midi(noteCtrl) : null,
                  allowMidi ? midi(ccCtrl) : null,
                  osc,
                );
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Editor card for the global macros (shown on every channel). Mirrors the
/// per-channel card minus the channel header/flash settings; reuses the shared
/// [_MacroListCard].
class _GlobalMacrosEditor extends StatelessWidget {
  final List<MacroMessage> macros;
  final BridgeClient bridge;
  final MacrosSectionPresenter presenter;

  const _GlobalMacrosEditor({
    required this.macros,
    required this.bridge,
    required this.presenter,
  });

  @override
  Widget build(BuildContext context) {
    return _MacroListCard(
      dotColor: PatchTheme.accent,
      label: 'GLOBAL',
      macros: macros,
      keyFor: (m) => '__global__:${m.label}',
      emptyText: 'No global macros yet',
      // Global macros live on the config — refetch it through the store after
      // each mutation so both screens reflect the change (#56).
      onUpsert: (ol, l, p, k, pr, mn, mc, osc) => runGuarded(context, () async {
        final store = AppStoreScope.read(context);
        final result = await presenter.saveGlobalMacro(
          originalLabel: ol,
          label: l,
          payload: p,
          keyBinding: k,
          priority: pr,
          midiNote: mn,
          midiCc: mc,
          osc: osc,
        );
        if (result is SaveError) {
          if (context.mounted) _showSaveError(context, result);
          return;
        }
        await store.refreshConfig();
      }),
      onDelete: (m) => runGuarded(context, () async {
        final store = AppStoreScope.read(context);
        await rust.deleteGlobalMacro(label: m.label);
        await store.refreshConfig();
      }),
      onReorder: (labels) => runGuarded(context, () async {
        final store = AppStoreScope.read(context);
        await rust.reorderGlobalMacros(orderedLabels: labels);
        await store.refreshConfig();
      }),
    );
  }
}

class _MacroRow extends StatelessWidget {
  final MacroMessage shortcut;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// Position in the list — used to anchor the drag handle.
  final int index;

  const _MacroRow({
    super.key,
    required this.shortcut,
    required this.onEdit,
    required this.onDelete,
    required this.index,
  });

  Color get _priorityColor => switch (shortcut.priority) {
        3 => PatchTheme.critical,
        2 => PatchTheme.warning,
        _ => PatchTheme.textMuted,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: PatchTheme.border.withAlpha(80))),
      ),
      child: Row(
        children: [
          // Drag handle — grab to reorder.
          ReorderableDragStartListener(
            index: index,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Tooltip(
                message: 'Drag to reorder',
                child: Icon(Icons.drag_handle, size: 16, color: PatchTheme.textMuted),
              ),
            ),
          ),
          // Priority dot
          Container(
            width: 7, height: 7,
            decoration: BoxDecoration(color: _priorityColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          // Label
          SizedBox(
            width: 90,
            child: Text(
              shortcut.label,
              style: const TextStyle(
                color: PatchTheme.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: PatchTheme.fontSizeSmall,
              ),
            ),
          ),
          // Message preview
          Expanded(
            child: Text(
              shortcut.payload,
              style: const TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Key binding badge
          if (shortcut.keyBinding != null)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: PatchTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: PatchTheme.border),
              ),
              child: Text(
                shortcut.keyBinding!,
                style: const TextStyle(color: PatchTheme.textMuted, fontSize: 10),
              ),
            ),
          // MIDI binding badge (♪ note / CC)
          if (shortcut.midiNote != null || shortcut.midiCc != null)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: PatchTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: PatchTheme.border),
              ),
              child: Text(
                shortcut.midiNote != null
                    ? '♪ ${shortcut.midiNote}'
                    : 'CC ${shortcut.midiCc}',
                style: const TextStyle(color: PatchTheme.textMuted, fontSize: 10),
              ),
            ),
          // OSC target badge
          if (shortcut.osc != null)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: PatchTheme.surfaceHigh,
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: PatchTheme.accent.withAlpha(120)),
              ),
              child: Tooltip(
                message: '${shortcut.osc!.address}:${shortcut.osc!.port} ${shortcut.osc!.path}',
                child: const Text('OSC',
                    style: TextStyle(color: PatchTheme.accent, fontSize: 9, fontWeight: FontWeight.w700)),
              ),
            ),
          const SizedBox(width: 8),
          // Edit
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 16, color: PatchTheme.textMuted),
            onPressed: onEdit,
            tooltip: 'Edit',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          // Delete
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: PatchTheme.textMuted),
            onPressed: onDelete,
            tooltip: 'Delete',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

// ── Channel create / edit dialog ──────────────────────────────────────────────
//
// Used both for "+ New channel" and the per-channel "Edit" button. On create
// the user picks the slug (channel id) — it can't change later because peers
// address messages by id over OSC. On edit the slug is shown read-only.

// Default channel palette — matches `default_channels()` in patch-core's
// state/config.rs, plus a few extras for variety.
const List<Color> _channelPalette = [
  Color(0xFFE53935), // red       (AUDIO default)
  Color(0xFFFFB300), // amber     (LIGHTING default)
  Color(0xFF43A047), // green     (STAGE default)
  Color(0xFF1E88E5), // blue      (RF default)
  Color(0xFF8E24AA), // purple    (VIDEO default)
  Color(0xFFF4511E), // deep-orange
  Color(0xFF00897B), // teal
  Color(0xFF3949AB), // indigo
  Color(0xFFD81B60), // pink
  Color(0xFF607D8B), // blue-grey (fallback for new channels)
];

// Compiled once (lazily) instead of on every dialog open / keystroke.
final RegExp _slugInvalidChars = RegExp(r'[^a-z0-9-]+');
final RegExp _slugDashRuns = RegExp(r'-+');
final RegExp _slugEdgeDashes = RegExp(r'^-|-$');
final RegExp _hex6 = RegExp(r'^[0-9a-fA-F]{6}$');
final RegExp _channelIdRegex = RegExp(r'^[a-z0-9][a-z0-9-]*$');

String _slugify(String input) => input
    .toLowerCase()
    .trim()
    .replaceAll(_slugInvalidChars, '-')
    .replaceAll(_slugDashRuns, '-')
    .replaceAll(_slugEdgeDashes, '');

String _colorToHex(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

Color? _hexToColor(String hex) {
  final s = hex.replaceFirst('#', '').trim();
  if (!_hex6.hasMatch(s)) return null;
  return Color(int.parse('FF$s', radix: 16));
}

void _showChannelDialog(
  BuildContext context,
  BridgeClient bridge, {
  PatchChannel? existing,
  required Set<String> existingIds,
}) {
  final idCtrl = TextEditingController(text: existing?.id ?? '');
  final nameCtrl = TextEditingController(text: existing?.displayName ?? '');
  final hexCtrl = TextEditingController(
    text: _colorToHex(existing?.color ?? _channelPalette.last),
  );
  Color color = existing?.color ?? _channelPalette.last;
  // Auto-slugify the id from the display name as the user types — only when
  // creating, and only if the user hasn't manually edited the id field.
  bool idAutoSync = existing == null;
  String? error;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) {
        void setColor(Color c) {
          color = c;
          hexCtrl.text = _colorToHex(c);
        }

        return AlertDialog(
          title: Text(existing == null ? 'New Channel' : 'Edit Channel'),
          content: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    hintText: 'e.g. RF, Front of House',
                  ),
                  textCapitalization: TextCapitalization.characters,
                  autofocus: true,
                  onChanged: (v) {
                    if (idAutoSync) {
                      setDialogState(() => idCtrl.text = _slugify(v));
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: idCtrl,
                  enabled: existing == null,
                  decoration: InputDecoration(
                    labelText: 'Channel ID (slug)',
                    helperText: existing == null
                        ? 'Used in OSC addresses (/patch/channel/<id>/…). Lowercase, no spaces.'
                        : 'Cannot be changed — peers address messages by ID.',
                    helperMaxLines: 2,
                  ),
                  onChanged: (_) => idAutoSync = false,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Colour',
                  style: TextStyle(
                    color: PatchTheme.textSecondary,
                    fontSize: PatchTheme.fontSizeSmall,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in _channelPalette)
                      GestureDetector(
                        onTap: () => setDialogState(() => setColor(p)),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: p,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: p.toARGB32() == color.toARGB32()
                                  ? PatchTheme.textPrimary
                                  : Colors.transparent,
                              width: 2,
                            ),
                          ),
                          child: p.toARGB32() == color.toARGB32()
                              ? const Icon(Icons.check, size: 16, color: Colors.white)
                              : null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: hexCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Hex (custom)',
                    hintText: '#RRGGBB',
                  ),
                  onChanged: (v) {
                    final parsed = _hexToColor(v);
                    if (parsed != null) {
                      setDialogState(() => color = parsed);
                    }
                  },
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: PatchTheme.critical)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final id = idCtrl.text.trim();
                final name = nameCtrl.text.trim();
                if (id.isEmpty || name.isEmpty) {
                  setDialogState(() => error = 'Name and ID are required');
                  return;
                }
                if (!_channelIdRegex.hasMatch(id)) {
                  setDialogState(() => error =
                      'ID must be lowercase letters, digits, or hyphens, and start with a letter or digit.');
                  return;
                }
                if (existing == null && existingIds.contains(id)) {
                  setDialogState(() => error = 'A channel with ID "$id" already exists.');
                  return;
                }
                runGuarded(context,
                    () => rust.upsertChannel(id: id, displayName: name, color: _colorToHex(color)));
                Navigator.pop(ctx);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ),
  );
}

