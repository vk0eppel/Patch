import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
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
  late List<PatchChannel> _channels;

  // Behavior
  bool _flashOnCritical = true;
  bool _flashOnMessage = false;
  int _flashCount = 4;
  bool _hideKeyboard = true;
  int _macrosColumns = 1;

  // Network interfaces
  List<Map<String, String>> _interfaces = [];
  String? _selectedInterface; // null = auto
  bool _interfaceChangedPending = false;

  // Static peers
  List<Map<String, dynamic>> _staticPeers = [];

  @override
  void initState() {
    super.initState();
    _channels = List.of(widget.channels);
    _sub = widget.bridge.events.listen(_handleEvent);
    widget.bridge.getConfig();
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
          _flashCount = (data['flash_count'] as int?) ?? 4;
          _hideKeyboard = (data['hide_keyboard'] as bool?) ?? true;
          _macrosColumns = (data['macros_columns'] as int?) ?? 1;
          _staticPeers = List<Map<String, dynamic>>.from(
            (data['static_peers'] as List<dynamic>? ?? [])
                .map((p) => Map<String, dynamic>.from(p as Map)),
          );
        });
      case 'config_updated':
        widget.bridge.getConfig();
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
      case 'channels':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _channels = data
              .map((c) => PatchChannel.fromJson(c as Map<String, dynamic>))
              .toList();
        });
      case 'channel_list_updated':
        widget.bridge.getChannels();
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
          'This will remove the channel and all its macros. This cannot be undone.',
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

  /// Show a confirmation dialog before resetting a section to defaults.
  /// Returns true if the user confirms.
  Future<bool> _confirmReset(String section) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text('Reset $section?'),
            content: SizedBox(
              width: double.infinity,
              child: Text(
                'This will restore factory defaults for $section.',
                style: const TextStyle(color: PatchTheme.textSecondary),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Reset'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _resetButton(String section, VoidCallback onReset) {
    return IconButton(
      icon: const Icon(Icons.restart_alt, size: 18),
      color: PatchTheme.textMuted,
      tooltip: 'Reset $section to defaults',
      onPressed: () async {
        if (await _confirmReset(section)) onReset();
      },
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
          Row(children: [
            Expanded(child: _SectionHeader('Identity')),
            _resetButton('Identity', () {
              final name = Platform.environment['USER'] ??
                  Platform.environment['USERNAME'] ??
                  'crew';
              _nameCtrl.text = name;
              widget.bridge.setClientName(name);
            }),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Your display name as seen by other Patch users on the network.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 10),
          _UsernameField(
            controller: _nameCtrl,
            saved: _nameSaved,
            onSave: _saveName,
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

          // ── Static Peers ─────────────────────────────────────────────────
          Row(
            children: [
              Expanded(child: _SectionHeader('Static Peers')),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add peer'),
                style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
                onPressed: () => _showAddPeerDialog(context, widget.bridge),
              ),
              _resetButton('Static Peers', () {
                for (final peer in List.of(_staticPeers)) {
                  widget.bridge.removeStaticPeer(
                    peer['address'] as String,
                    peer['port'] as int,
                  );
                }
              }),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Add peers by IP when mDNS is blocked (AP isolation, VLANs, show networks). '
            'Static peers are always sent to and never expire.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          if (_interfaces.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: _interfaces.map((iface) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.laptop, size: 13, color: PatchTheme.textMuted),
                  const SizedBox(width: 4),
                  Text(
                    'This device: ${iface['ip']} (${iface['name']})',
                    style: const TextStyle(
                      color: PatchTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              )).toList(),
            ),
          ],
          const SizedBox(height: 12),
          if (_staticPeers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No static peers',
                style: TextStyle(color: PatchTheme.textMuted, fontSize: PatchTheme.fontSizeSmall),
              ),
            )
          else
            ..._staticPeers.map((peer) => _StaticPeerRow(
                  peer: peer,
                  onDelete: () => widget.bridge.removeStaticPeer(
                    peer['address'] as String,
                    peer['port'] as int,
                  ),
                )),

          const SizedBox(height: 32),

          // ── Behavior ─────────────────────────────────────────────────────
          Row(children: [
            Expanded(child: _SectionHeader('Behavior')),
            _resetButton('Behavior', () {
              setState(() {
                _flashOnCritical = true;
                _flashOnMessage = false;
                _flashCount = 4;
                _hideKeyboard = true;
                _macrosColumns = 1;
              });
              widget.bridge.setFlashOnCritical(true);
              widget.bridge.setFlashOnMessage(false);
              widget.bridge.setFlashCount(4);
              widget.bridge.setHideKeyboard(true);
              widget.bridge.setMacrosColumns(1);
            }),
          ]),
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
          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Flash pulses',
                      style: TextStyle(
                        color: PatchTheme.textPrimary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    Text(
                      'Number of times the channel flashes per event',
                      style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _FlashCountPicker(
                value: _flashCount,
                onChanged: (val) {
                  if (val == null) return; // global picker never yields null
                  setState(() => _flashCount = val);
                  widget.bridge.setFlashCount(val);
                },
              ),
            ],
          ),

          const SizedBox(height: 8),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Macros panel columns',
                      style: TextStyle(
                        color: PatchTheme.textPrimary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    Text(
                      'Number of columns in the macros side panel',
                      style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SegmentedButton<int>(
                segments: const [
                  ButtonSegment(value: 1, label: Text('1')),
                  ButtonSegment(value: 2, label: Text('2')),
                ],
                selected: {_macrosColumns},
                onSelectionChanged: (s) {
                  final val = s.first;
                  setState(() => _macrosColumns = val);
                  widget.bridge.setMacrosColumns(val);
                },
                style: SegmentedButton.styleFrom(
                  foregroundColor: PatchTheme.textSecondary,
                  selectedForegroundColor: PatchTheme.accent,
                  selectedBackgroundColor: PatchTheme.accent.withAlpha(30),
                  side: const BorderSide(color: PatchTheme.border),
                ),
              ),
            ],
          ),

          if (Platform.isIOS || Platform.isAndroid) ...[
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text(
                'Hide keyboard on channel switch',
                style: TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeSmall),
              ),
              subtitle: const Text(
                'Keeps the software keyboard hidden until you tap the input field',
                style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
              ),
              value: _hideKeyboard,
              activeThumbColor: PatchTheme.accent,
              contentPadding: EdgeInsets.zero,
              onChanged: (val) {
                setState(() => _hideKeyboard = val);
                widget.bridge.setHideKeyboard(val);
              },
            ),
          ],

          const SizedBox(height: 32),

          // ── Channels & macros ─────────────────────────────────────────
          Row(
            children: [
              Expanded(child: _SectionHeader('Channels & Macros')),
              TextButton.icon(
                icon: const Icon(Icons.add, size: 16),
                label: const Text('New channel'),
                style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
                onPressed: () => _showChannelDialog(
                  context,
                  widget.bridge,
                  existingIds: _channels.map((c) => c.id).toSet(),
                ),
              ),
              _resetButton('Channels & Macros', () {
                widget.bridge.resetChannels();
              }),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Edit a channel\'s name and colour, manage its one-tap macros, or create a new channel.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 16),
          ..._channels.map((ch) => _ChannelMacroEditor(
                channel: ch,
                bridge: widget.bridge,
                onDelete: () => _confirmDeleteChannel(ch),
                onEdit: () => _showChannelDialog(
                  context,
                  widget.bridge,
                  existing: ch,
                  existingIds: _channels.map((c) => c.id).toSet(),
                ),
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

// ── Per-channel shortcut editor ───────────────────────────────────────────────

class _ChannelMacroEditor extends StatelessWidget {
  final PatchChannel channel;
  final BridgeClient bridge;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

  const _ChannelMacroEditor({
    required this.channel,
    required this.bridge,
    required this.onDelete,
    required this.onEdit,
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
                  onPressed: () => _showMacroDialog(context, channel, bridge),
                ),
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
            ),
          ),
          // Shortcut list
          if (channel.macros.isEmpty)
            const Padding(
              padding: EdgeInsets.all(14),
              child: Text(
                'No macros yet',
                style: TextStyle(color: PatchTheme.textMuted, fontSize: PatchTheme.fontSizeSmall),
              ),
            )
          else
            ...channel.macros.map((s) => _MacroRow(
                  shortcut: s,
                  channelId: channel.id,
                  bridge: bridge,
                  onEdit: () => _showMacroDialog(context, channel, bridge, existing: s),
                )),
          // Per-channel flash settings
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
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
                    _FlashCountPicker(
                      value: channel.flashCount,
                      onChanged: (val) => bridge.setChannelFlash(
                        channel.id,
                        // 0 signals "clear override" to the Rust side
                        flashCount: val ?? 0,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static void _showMacroDialog(
    BuildContext context,
    PatchChannel channel,
    BridgeClient bridge, {
    MacroMessage? existing,
  }) {
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final payloadCtrl = TextEditingController(text: existing?.payload ?? '');
    final keyCtrl = TextEditingController(text: existing?.keyBinding ?? '');
    int priority = existing?.priority ?? 1;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
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
                bridge.upsertMacro(
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

class _MacroRow extends StatelessWidget {
  final MacroMessage shortcut;
  final String channelId;
  final BridgeClient bridge;
  final VoidCallback onEdit;

  const _MacroRow({
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
            onPressed: () => bridge.deleteMacro(channelId: channelId, label: shortcut.label),
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
  Color(0xFFE53935), // red       (FOH default)
  Color(0xFFF4511E), // deep-orange (LIGHTING default)
  Color(0xFFFFB300), // amber     (PRODUCTION default)
  Color(0xFF43A047), // green     (STAGE default)
  Color(0xFF00897B), // teal      (VIDEO default)
  Color(0xFF1E88E5), // blue      (RF default)
  Color(0xFF3949AB), // indigo
  Color(0xFF8E24AA), // purple    (MON default)
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
                bridge.upsertChannel(id, name, _colorToHex(color));
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

// ── Static peer row ───────────────────────────────────────────────────────────

class _StaticPeerRow extends StatelessWidget {
  final Map<String, dynamic> peer;
  final VoidCallback onDelete;

  const _StaticPeerRow({required this.peer, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final address = peer['address'] as String;
    final port = peer['port'] as int;
    final label = peer['label'] as String?;

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
          const Icon(Icons.push_pin_outlined, size: 14, color: PatchTheme.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$address:$port',
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontSize: PatchTheme.fontSizeSmall,
                    fontFamily: 'monospace',
                  ),
                ),
                if (label != null && label.isNotEmpty)
                  Text(
                    label,
                    style: const TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, size: 16, color: PatchTheme.textMuted),
            tooltip: 'Remove peer',
            onPressed: onDelete,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }
}

void _showAddPeerDialog(BuildContext context, BridgeClient bridge) {
  final addrCtrl = TextEditingController();
  final portCtrl = TextEditingController(text: '9000');
  final labelCtrl = TextEditingController();
  String? error;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Add Static Peer'),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: addrCtrl,
                decoration: const InputDecoration(
                  labelText: 'IP address',
                  hintText: '192.168.1.50',
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'OSC port',
                  hintText: '9000',
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'e.g. Monitor World',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!, style: const TextStyle(color: PatchTheme.critical)),
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
              final address = addrCtrl.text.trim();
              final portStr = portCtrl.text.trim();
              if (address.isEmpty) {
                setDialogState(() => error = 'IP address is required');
                return;
              }
              final port = int.tryParse(portStr);
              if (port == null || port < 1 || port > 65535) {
                setDialogState(() => error = 'Port must be 1–65535');
                return;
              }
              final label = labelCtrl.text.trim();
              bridge.addStaticPeer(
                address,
                port,
                label: label.isEmpty ? null : label,
              );
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

// ── Flash pulse count picker ──────────────────────────────────────────────────
//
// Compact segmented control: 1 · 2 · 3 · 4 · 5.
// When [value] is null (per-channel use) a "–" (global) option is prepended.

class _FlashCountPicker extends StatelessWidget {
  /// Current value. null means "use global" (only valid for per-channel pickers).
  final int? value;

  /// Called with the new value, or null to clear a per-channel override.
  final void Function(int? val) onChanged;

  const _FlashCountPicker({required this.value, required this.onChanged});

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
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
