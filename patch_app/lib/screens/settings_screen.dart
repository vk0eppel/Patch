import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

/// Settings screen — identity, channels, shortcuts, and session management.
class SettingsScreen extends StatefulWidget {
  final BridgeClient bridge;
  final List<PatchChannel> channels;

  const SettingsScreen({
    super.key,
    required this.bridge,
    required this.channels,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameCtrl = TextEditingController();
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _nameSaved = false;
  List<SessionMeta> _sessions = [];
  late List<PatchChannel> _channels;

  // Behavior
  bool _flashOnCritical = true;
  bool _flashOnMessage = false;

  // Network interfaces
  List<Map<String, String>> _interfaces = [];
  String? _selectedInterface; // null = auto
  bool _interfaceChangedPending = false;

  @override
  void initState() {
    super.initState();
    _channels = List.of(widget.channels);
    _sub = widget.bridge.events.listen(_handleEvent);
    widget.bridge.getConfig();
    widget.bridge.listSessions();
    widget.bridge.getInterfaces();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _sub?.cancel();
    super.dispose();
  }

  void _handleEvent(Map<String, dynamic> event) {
    final type = event['event'] as String?;
    switch (type) {
      case 'config':
        final data = event['data'] as Map<String, dynamic>;
        setState(() {
          _nameCtrl.text = data['client_name'] as String? ?? '';
          _selectedInterface = data['network_interface'] as String?;
          _flashOnCritical = (data['flash_on_critical'] as bool?) ?? true;
          _flashOnMessage = (data['flash_on_message'] as bool?) ?? false;
        });
      case 'interfaces':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _interfaces = data
              .map((i) => {
                    'name': (i as Map<String, dynamic>)['name'] as String,
                    'ip': i['ip'] as String,
                  })
              .toList();
        });
      case 'interface_changed':
        setState(() => _interfaceChangedPending = true);
      case 'client_name_changed':
        setState(() => _nameSaved = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _nameSaved = false);
        });
      case 'sessions':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _sessions = data
              .map((s) => SessionMeta.fromJson(s as Map<String, dynamic>))
              .toList();
        });
      case 'channels':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _channels = data
              .map((c) => PatchChannel.fromJson(c as Map<String, dynamic>))
              .toList();
        });
      case 'channel_list_updated':
        widget.bridge.getChannels();
      case 'session_saved':
      case 'session_loaded':
        widget.bridge.listSessions();
    }
  }

  void _saveName() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    widget.bridge.setClientName(name);
  }

  void _confirmDeleteChannel(PatchChannel channel) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${channel.displayName}?'),
        content: const Text(
          'This will remove the channel and all its shortcuts. This cannot be undone.',
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
              widget.bridge.deleteChannel(channel.id);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showSaveSessionDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Save Session'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: 'Session name (e.g. "Festival Day 1")',
          ),
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
              if (name.isNotEmpty) {
                widget.bridge.saveSession(name);
              }
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SETTINGS'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // ── Identity ────────────────────────────────────────────────────
          _SectionHeader('Identity'),
          const SizedBox(height: 10),
          _UsernameField(
            controller: _nameCtrl,
            saved: _nameSaved,
            onSave: _saveName,
          ),

          const SizedBox(height: 32),

          // ── Behavior ─────────────────────────────────────────────────────
          _SectionHeader('Behavior'),
          const SizedBox(height: 4),
          SwitchListTile(
            title: const Text(
              'Flash on every message',
              style: TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeSmall),
            ),
            subtitle: const Text(
              'Flash the channel border on any incoming message',
              style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
            ),
            value: _flashOnMessage,
            activeThumbColor: PatchTheme.accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) {
              setState(() => _flashOnMessage = val);
              widget.bridge.setFlashOnMessage(val);
            },
          ),
          SwitchListTile(
            title: const Text(
              'Flash on critical messages',
              style: TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeSmall),
            ),
            subtitle: const Text(
              'Flash the channel border when a priority-3 message arrives',
              style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
            ),
            value: _flashOnCritical,
            activeThumbColor: PatchTheme.accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) {
              setState(() => _flashOnCritical = val);
              widget.bridge.setFlashOnCritical(val);
            },
          ),

          const SizedBox(height: 32),

          // ── Network Interface ────────────────────────────────────────────
          _SectionHeader('Network Interface'),
          const SizedBox(height: 4),
          const Text(
            'Bind OSC to a specific NIC. Use Auto on single-homed machines. Takes effect after restart.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 12),
          _InterfacePicker(
            interfaces: _interfaces,
            selected: _selectedInterface,
            restartPending: _interfaceChangedPending,
            onSelect: (name) {
              setState(() {
                _selectedInterface = name;
                _interfaceChangedPending = false;
              });
              widget.bridge.setInterface(name ?? 'auto');
            },
          ),

          const SizedBox(height: 32),

          // ── Sessions ────────────────────────────────────────────────────
          _SectionHeader('Sessions'),
          const SizedBox(height: 4),
          const Text(
            'Save the current channel layout as a named preset. Load it on any machine running Patch.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 12),
          _SessionPanel(
            sessions: _sessions,
            bridge: widget.bridge,
            onSaveNew: _showSaveSessionDialog,
          ),

          const SizedBox(height: 32),

          // ── Channels & shortcuts ─────────────────────────────────────────
          _SectionHeader('Channels & Shortcuts'),
          const SizedBox(height: 4),
          const Text(
            'Per-channel one-tap buttons shown above the message input.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 16),
          ..._channels.map((ch) => _ChannelShortcutEditor(
                channel: ch,
                bridge: widget.bridge,
                onDelete: () => _confirmDeleteChannel(ch),
              )),
        ],
      ),
    );
  }
}

// ── Section header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: PatchTheme.textSecondary,
        fontSize: PatchTheme.fontSizeSmall,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}

// ── Username field ────────────────────────────────────────────────────────────

class _UsernameField extends StatelessWidget {
  final TextEditingController controller;
  final bool saved;
  final VoidCallback onSave;

  const _UsernameField({
    required this.controller,
    required this.saved,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(
              color: PatchTheme.textPrimary,
              fontSize: PatchTheme.fontSizeMedium,
            ),
            decoration: const InputDecoration(
              hintText: 'Your name (shown to other crew)',
              prefixIcon: Icon(Icons.person_outline, color: PatchTheme.textSecondary, size: 18),
            ),
            onSubmitted: (_) => onSave(),
            textInputAction: TextInputAction.done,
          ),
        ),
        const SizedBox(width: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: saved
              ? const Icon(Icons.check_circle, color: PatchTheme.success, key: ValueKey('saved'))
              : ElevatedButton(
                  key: const ValueKey('save'),
                  onPressed: onSave,
                  child: const Text('Save'),
                ),
        ),
      ],
    );
  }
}

// ── Network interface picker ──────────────────────────────────────────────────

class _InterfacePicker extends StatelessWidget {
  final List<Map<String, String>> interfaces;
  final String? selected; // null = auto
  final bool restartPending;
  final ValueChanged<String?> onSelect;

  const _InterfacePicker({
    required this.interfaces,
    required this.selected,
    required this.restartPending,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    // Build dropdown items: Auto + each interface
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
        if (restartPending) ...[
          const SizedBox(height: 8),
          Row(
            children: const [
              Icon(Icons.info_outline, size: 14, color: PatchTheme.warning),
              SizedBox(width: 6),
              Text(
                'Restart patch-core for the new interface to take effect.',
                style: TextStyle(color: PatchTheme.warning, fontSize: 11),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── Session panel ─────────────────────────────────────────────────────────────

class _SessionPanel extends StatelessWidget {
  final List<SessionMeta> sessions;
  final BridgeClient bridge;
  final VoidCallback onSaveNew;

  const _SessionPanel({
    required this.sessions,
    required this.bridge,
    required this.onSaveNew,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ElevatedButton.icon(
          icon: const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save current layout…'),
          onPressed: onSaveNew,
        ),
        if (sessions.isNotEmpty) ...[
          const SizedBox(height: 12),
          ...sessions.map((s) => _SessionRow(session: s, bridge: bridge)),
        ],
      ],
    );
  }
}

class _SessionRow extends StatelessWidget {
  final SessionMeta session;
  final BridgeClient bridge;

  const _SessionRow({required this.session, required this.bridge});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: PatchTheme.surface,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PatchTheme.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.folder_outlined, size: 16, color: PatchTheme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.name,
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: PatchTheme.fontSizeSmall,
                  ),
                ),
                Text(
                  '${session.channelCount} channel${session.channelCount == 1 ? '' : 's'} · ${_formatDate(session.createdAt)}',
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
            onPressed: () => bridge.loadSession(session.slug),
            child: const Text('Load'),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: PatchTheme.textMuted),
            tooltip: 'Delete session',
            onPressed: () => _confirmDelete(context),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete "${session.name}"?'),
        content: const Text(
          'This will permanently remove the saved session.',
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
              bridge.deleteSession(session.slug);
              Navigator.pop(context);
            },
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
}

// ── Per-channel shortcut editor ───────────────────────────────────────────────

class _ChannelShortcutEditor extends StatelessWidget {
  final PatchChannel channel;
  final BridgeClient bridge;
  final VoidCallback onDelete;

  const _ChannelShortcutEditor({
    required this.channel,
    required this.bridge,
    required this.onDelete,
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
          // Channel header
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
                  decoration: BoxDecoration(color: channel.color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  channel.displayName,
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
                  onPressed: () => _showShortcutDialog(context, channel, bridge),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 16, color: PatchTheme.textMuted),
                  tooltip: 'Delete channel',
                  onPressed: onDelete,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                ),
              ],
            ),
          ),
          // Shortcut list
          if (channel.shortcuts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No shortcuts yet',
                style: TextStyle(color: PatchTheme.textMuted, fontSize: PatchTheme.fontSizeSmall),
              ),
            )
          else
            ...channel.shortcuts.map((s) => _ShortcutRow(
                  shortcut: s,
                  channelId: channel.id,
                  bridge: bridge,
                  onEdit: () => _showShortcutDialog(context, channel, bridge, existing: s),
                )),
          // Per-channel flash settings
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: PatchTheme.border)),
            ),
            child: Column(
              children: [
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
                  onChanged: (val) =>
                      bridge.setChannelFlash(channel.id, flashOnMessage: val),
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
                  onChanged: (val) =>
                      bridge.setChannelFlash(channel.id, flashOnCritical: val),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static void _showShortcutDialog(
    BuildContext context,
    PatchChannel channel,
    BridgeClient bridge, {
    ShortcutMessage? existing,
  }) {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final payloadCtrl = TextEditingController(text: existing?.payload ?? '');
    final keyCtrl = TextEditingController(text: existing?.keyBinding ?? '');
    int priority = existing?.priority ?? 1;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New Shortcut' : 'Edit Shortcut'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(labelText: 'Button label', hintText: 'e.g. HOLD'),
                  textCapitalization: TextCapitalization.characters,
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: payloadCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Message text',
                    hintText: 'e.g. HOLD — do not transmit',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: keyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Key binding (optional)',
                    hintText: 'e.g. F1',
                  ),
                ),
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
                bridge.upsertShortcut(
                  channelId: channel.id,
                  label: label,
                  payload: payload,
                  keyBinding: keyCtrl.text.trim().isEmpty ? null : keyCtrl.text.trim(),
                  priority: priority,
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

class _ShortcutRow extends StatelessWidget {
  final ShortcutMessage shortcut;
  final String channelId;
  final BridgeClient bridge;
  final VoidCallback onEdit;

  const _ShortcutRow({
    required this.shortcut,
    required this.channelId,
    required this.bridge,
    required this.onEdit,
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
            onPressed: () => bridge.deleteShortcut(channelId: channelId, label: shortcut.label),
            tooltip: 'Delete',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}
