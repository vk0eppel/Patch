import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';
import '../widgets/channel_tab.dart';
import '../widgets/flash_button.dart';
import '../widgets/message_list.dart';
import '../widgets/message_input.dart';
import '../widgets/peers_panel.dart';
import '../widgets/shortcut_bar.dart';
import 'settings_screen.dart';

/// Root screen — channel tab strip on the left, message area on the right.
class HomeScreen extends StatefulWidget {
  final BridgeClient bridge;
  const HomeScreen({super.key, required this.bridge});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<PatchChannel> _channels = [];

  /// IDs of currently selected channels (at least one always).
  Set<String> _selectedIds = {};

  final Map<String, List<PatchMessage>> _messages = {};

  /// Incremented each time a flash arrives per channel — drives tab animation.
  final Map<String, int> _flashCounts = {};

  /// Incremented on every flash (any channel) — drives the message box pulse.
  int _flashNotify = 0;
  Color _flashColor = Colors.white;

  bool _flashOnCritical = true;

  List<PeerInfo> _peers = [];
  bool _showPeers = false;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  // ── Derived state ───────────────────────────────────────────────────────────

  List<PatchChannel> get _selectedChannels =>
      _channels.where((c) => _selectedIds.contains(c.id)).toList();

  bool get _isMultiChannel => _selectedIds.length > 1;

  /// Messages from all selected channels, merged and sorted by timestamp.
  List<PatchMessage> get _combinedMessages {
    final all = <PatchMessage>[];
    for (final id in _selectedIds) {
      all.addAll(_messages[id] ?? []);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return all;
  }

  /// Channel-colour map for the message list (only populated in multi-channel mode).
  Map<String, Color> get _channelColors {
    if (!_isMultiChannel) return {};
    return {for (final c in _selectedChannels) c.id: c.color};
  }

  /// Shortcuts from all selected channels, each tagged with their channel.
  List<ChannelShortcut> get _aggregatedShortcuts {
    return [
      for (final ch in _selectedChannels)
        for (final s in ch.shortcuts)
          ChannelShortcut(channelId: ch.id, channelColor: ch.color, shortcut: s),
    ];
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _eventSub = widget.bridge.events.listen(_handleEvent);
    widget.bridge.getChannels();
    widget.bridge.getPeers();
    widget.bridge.getConfig();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

  // ── Event dispatch ──────────────────────────────────────────────────────────

  void _handleEvent(Map<String, dynamic> event) {
    try {
      _dispatch(event);
    } catch (e, stack) {
      debugPrint('Bridge event error [${event['event']}]: $e\n$stack');
    }
  }

  void _dispatch(Map<String, dynamic> event) {
    final type = event['event'] as String?;
    switch (type) {
      case 'channels':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _channels = data
              .map((c) => PatchChannel.fromJson(c as Map<String, dynamic>))
              .toList();
          // Seed selection with first channel if nothing selected yet.
          if (_selectedIds.isEmpty && _channels.isNotEmpty) {
            _selectedIds = {_channels.first.id};
            widget.bridge.getMessages(_channels.first.id);
          }
          // Remove stale IDs (deleted channels).
          final validIds = _channels.map((c) => c.id).toSet();
          _selectedIds = _selectedIds.intersection(validIds);
          if (_selectedIds.isEmpty && _channels.isNotEmpty) {
            _selectedIds = {_channels.first.id};
          }
          // Load messages for any newly-selected channel we haven't fetched yet.
          for (final id in _selectedIds) {
            if (!_messages.containsKey(id)) {
              widget.bridge.getMessages(id);
            }
          }
        });

      case 'messages':
        final chId = event['channel_id'] as String;
        final data = event['data'] as List<dynamic>;
        setState(() {
          _messages[chId] = data
              .map((m) => PatchMessage.fromJson(m as Map<String, dynamic>))
              .toList();
        });

      case 'message':
        final msg = PatchMessage.fromJson(event['data'] as Map<String, dynamic>);
        setState(() {
          _messages.putIfAbsent(msg.channelId, () => []).add(msg);
        });
        if (msg.isCritical && _flashOnCritical) _triggerFlash(msg.channelId);

      case 'ack_send':
        break;

      case 'peers':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _peers = data
              .map((p) => PeerInfo.fromJson(p as Map<String, dynamic>))
              .toList();
        });

      case 'peer_updated':
        final peer = PeerInfo.fromJson(event['data'] as Map<String, dynamic>);
        setState(() {
          _peers.removeWhere((p) => p.peerId == peer.peerId);
          _peers.add(peer);
        });

      case 'peer_expired':
        final peerId = event['data']['peer_id'] as String;
        setState(() => _peers.removeWhere((p) => p.peerId == peerId));

      case 'channel_flash':
        final chId = event['data']['channel_id'] as String;
        _triggerFlash(chId);

      case 'channel_list_updated':
        widget.bridge.getChannels();

      case 'session_loaded':
        widget.bridge.getChannels();
        setState(() => _selectedIds = {});

      case 'config':
        setState(() {
          _flashOnCritical =
              (event['data']['flash_on_critical'] as bool?) ?? true;
        });

      case 'session_saved':
      case 'client_name_changed':
      case 'config_updated':
      case 'interface_changed':
        break;

      case 'error':
        debugPrint('Bridge error: ${event['message']}');
    }
  }

  void _triggerFlash(String channelId) {
    final ch = _channels.firstWhere(
      (c) => c.id == channelId,
      orElse: () => _channels.isEmpty
          ? const PatchChannel(id: '', displayName: '?', color: Colors.white)
          : _channels.first,
    );
    setState(() {
      _flashCounts[channelId] = (_flashCounts[channelId] ?? 0) + 1;
      _flashNotify++;
      _flashColor = ch.color;
    });
  }

  // ── Channel selection ───────────────────────────────────────────────────────

  /// Tap — select exclusively.
  void _selectOnly(String id) {
    setState(() => _selectedIds = {id});
    if (!_messages.containsKey(id)) {
      widget.bridge.getMessages(id);
    }
  }

  /// Long press — toggle into/out of multi-selection.
  void _toggleChannel(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        if (_selectedIds.length > 1) _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
        if (!_messages.containsKey(id)) {
          widget.bridge.getMessages(id);
        }
      }
    });
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _ChannelStrip(
            channels: _channels,
            selectedIds: _selectedIds,
            flashCounts: _flashCounts,
            onTap: _selectOnly,
            onLongPress: _toggleChannel,
            bridge: widget.bridge,
          ),
          Expanded(
            child: _channels.isEmpty
                ? const Center(child: Text('No channels'))
                : _ChannelView(
                    selectedChannels: _selectedChannels,
                    messages: _combinedMessages,
                    channelColors: _channelColors,
                    aggregatedShortcuts: _aggregatedShortcuts,
                    bridge: widget.bridge,
                    showPeers: _showPeers,
                    onTogglePeers: () =>
                        setState(() => _showPeers = !_showPeers),
                    flashNotify: _flashNotify,
                    flashColor: _flashColor,
                  ),
          ),
          if (_showPeers)
            SizedBox(
              width: 220,
              child: PeersPanel(peers: _peers),
            ),
        ],
      ),
    );
  }
}

// ── Channel strip ─────────────────────────────────────────────────────────────

class _ChannelStrip extends StatelessWidget {
  final List<PatchChannel> channels;
  final Set<String> selectedIds;
  final Map<String, int> flashCounts;
  final ValueChanged<String> onTap;
  final ValueChanged<String> onLongPress;
  final BridgeClient bridge;

  const _ChannelStrip({
    required this.channels,
    required this.selectedIds,
    required this.flashCounts,
    required this.onTap,
    required this.onLongPress,
    required this.bridge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 80,
      color: PatchTheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 12),
          const Text(
            'P',
            style: TextStyle(
              color: PatchTheme.accent,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(color: PatchTheme.border, height: 1),
          const SizedBox(height: 8),
          Expanded(
            child: ListView.builder(
              itemCount: channels.length,
              itemBuilder: (ctx, i) {
                final ch = channels[i];
                return ChannelTab(
                  channel: ch,
                  isSelected: selectedIds.contains(ch.id),
                  flashCount: flashCounts[ch.id] ?? 0,
                  onTap: () => onTap(ch.id),
                  onLongPress: () => onLongPress(ch.id),
                );
              },
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          IconButton(
            icon: const Icon(Icons.add, color: PatchTheme.textMuted),
            tooltip: 'Add channel',
            onPressed: () => _showAddChannel(context, bridge),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: PatchTheme.textMuted),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) =>
                    SettingsScreen(bridge: bridge, channels: channels),
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  void _showAddChannel(BuildContext context, BridgeClient bridge) {
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('New Channel'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: idCtrl,
              decoration:
                  const InputDecoration(hintText: 'ID (slug, e.g. "rf")'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration:
                  const InputDecoration(hintText: 'Display Name'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              bridge.upsertChannel(
                  idCtrl.text.trim(), nameCtrl.text.trim(), '#607D8B');
              Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

// ── Per-channel (or multi-channel) view ──────────────────────────────────────

class _ChannelView extends StatelessWidget {
  final List<PatchChannel> selectedChannels;
  final List<PatchMessage> messages;
  final Map<String, Color> channelColors; // empty when single channel
  final List<ChannelShortcut> aggregatedShortcuts;
  final BridgeClient bridge;
  final bool showPeers;
  final VoidCallback onTogglePeers;
  final int flashNotify;
  final Color flashColor;

  const _ChannelView({
    required this.selectedChannels,
    required this.messages,
    required this.channelColors,
    required this.aggregatedShortcuts,
    required this.bridge,
    required this.showPeers,
    required this.onTogglePeers,
    required this.flashNotify,
    required this.flashColor,
  });

  bool get _isMulti => selectedChannels.length > 1;

  void _sendMessage(String text) {
    for (final ch in selectedChannels) {
      bridge.sendMessage(channelId: ch.id, payload: text);
    }
  }

  void _sendFlash() {
    for (final ch in selectedChannels) {
      bridge.sendFlash(ch.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        // ── Header ────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: PatchTheme.surface,
          child: Row(
            children: [
              // Channel dot(s) + name(s)
              if (_isMulti)
                _MultiChannelLabel(channels: selectedChannels)
              else ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: selectedChannels.first.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  selectedChannels.first.displayName,
                  style: const TextStyle(
                    color: PatchTheme.textPrimary,
                    fontSize: PatchTheme.fontSizeLarge,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
              const Spacer(),
              FlashButton(onFlash: _sendFlash),
              const SizedBox(width: 8),
              IconButton(
                icon: Icon(
                  Icons.people,
                  color: showPeers ? PatchTheme.accent : PatchTheme.textMuted,
                  size: 20,
                ),
                tooltip: showPeers ? 'Hide peers' : 'Show peers',
                onPressed: onTogglePeers,
              ),
            ],
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Messages ──────────────────────────────────────────────────────
        Expanded(
          child: MessageList(
            messages: messages,
            channelColors: _isMulti ? channelColors : null,
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Shortcuts ─────────────────────────────────────────────────────
        if (aggregatedShortcuts.isNotEmpty)
          ShortcutBar(
            shortcuts: aggregatedShortcuts,
            showChannelDots: _isMulti,
            onShortcut: (cs) => bridge.sendMessage(
              channelId: cs.channelId,
              payload: cs.shortcut.payload,
              priority: cs.shortcut.priority,
            ),
          ),

        // ── Input ─────────────────────────────────────────────────────────
        MessageInput(onSend: _sendMessage),
      ],
    );

    return Stack(children: [
      content,
      _FlashLayer(flashNotify: flashNotify, flashColor: flashColor),
    ]);
  }
}

// ── Multi-channel header label ────────────────────────────────────────────────

class _MultiChannelLabel extends StatelessWidget {
  final List<PatchChannel> channels;
  const _MultiChannelLabel({required this.channels});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Up to 4 stacked dots
        SizedBox(
          width: 20,
          height: 10,
          child: Stack(
            children: [
              for (var i = 0; i < channels.length && i < 4; i++)
                Positioned(
                  left: i * 5.0,
                  top: 1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: channels[i].color,
                      shape: BoxShape.circle,
                      border: Border.all(color: PatchTheme.surface, width: 1),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          channels.length <= 3
              ? channels.map((c) => c.displayName).join(' · ')
              : '${channels.length} channels',
          style: const TextStyle(
            color: PatchTheme.textPrimary,
            fontSize: PatchTheme.fontSizeLarge,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.0,
          ),
        ),
      ],
    );
  }
}

// ── Flash layer — message box border + background pulse ──────────────────────

/// Positioned.fill overlay that pulses the channel colour 3 times when
/// [flashNotify] increments. Uses timer-based setState for reliable pulses.
class _FlashLayer extends StatefulWidget {
  final int flashNotify;
  final Color flashColor;

  const _FlashLayer({required this.flashNotify, required this.flashColor});

  @override
  State<_FlashLayer> createState() => _FlashLayerState();
}

class _FlashLayerState extends State<_FlashLayer> {
  bool _lit = false;

  @override
  void didUpdateWidget(_FlashLayer old) {
    super.didUpdateWidget(old);
    if (widget.flashNotify > old.flashNotify) _pulse();
  }

  Future<void> _pulse() async {
    for (var i = 0; i < 3; i++) {
      if (!mounted) return;
      setState(() => _lit = true);
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      setState(() => _lit = false);
      if (i < 2) await Future.delayed(const Duration(milliseconds: 150));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.flashColor;
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _lit ? c.withAlpha(38) : Colors.transparent, // ~15% tint
            border: Border.all(
              color: _lit ? c.withAlpha(230) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
      ),
    );
  }
}
