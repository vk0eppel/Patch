import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  int _selectedIndex = 0;
  final Map<String, List<PatchMessage>> _messages = {};
  List<PeerInfo> _peers = [];
  bool _showPeers = false;
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  PatchChannel? get _activeChannel =>
      _channels.isEmpty ? null : _channels[_selectedIndex];

  @override
  void initState() {
    super.initState();
    _eventSub = widget.bridge.events.listen(_handleEvent);
    // Initial data load
    widget.bridge.getChannels();
    widget.bridge.getPeers();
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }

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
          _channels = data.map((c) => PatchChannel.fromJson(c as Map<String, dynamic>)).toList();
          if (_activeChannel != null) {
            widget.bridge.getMessages(_activeChannel!.id);
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

      case 'ack_send':
        // Command acknowledgement — no UI action needed.
        break;

      case 'peers':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _peers = data.map((p) => PeerInfo.fromJson(p as Map<String, dynamic>)).toList();
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

      // Settings-related — no UI update needed here; handled in SettingsScreen.
      case 'config':
      case 'client_name_changed':
      case 'config_updated':
        break;

      // Session events — refresh channels after load/save.
      case 'session_saved':
        break; // SettingsScreen handles its own list refresh.
      case 'session_loaded':
        widget.bridge.getChannels();
        setState(() => _selectedIndex = 0);

      case 'error':
        debugPrint('Bridge error: ${event['message']}');
    }
  }

  void _triggerFlash(String channelId) {
    final idx = _channels.indexWhere((c) => c.id == channelId);
    if (idx == -1) return;
    // Visual flash handled by ChannelTab widget via a key/notification
    // TODO: implement flash animation controller
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ FLASH — ${_channels[idx].displayName}'),
        backgroundColor: PatchTheme.warning,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _selectChannel(int index) {
    setState(() => _selectedIndex = index);
    final ch = _channels[index];
    if (!(_messages.containsKey(ch.id))) {
      widget.bridge.getMessages(ch.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          // ── Channel strip (left sidebar) ─────────────────────────────────
          _ChannelStrip(
            channels: _channels,
            selectedIndex: _selectedIndex,
            onSelect: _selectChannel,
            bridge: widget.bridge,
          ),

          // ── Main content area ─────────────────────────────────────────────
          Expanded(
            child: _activeChannel == null
                ? const Center(child: Text('No channels'))
                : _ChannelView(
                    channel: _activeChannel!,
                    messages: _messages[_activeChannel!.id] ?? [],
                    bridge: widget.bridge,
                    showPeers: _showPeers,
                    onTogglePeers: () => setState(() => _showPeers = !_showPeers),
                  ),
          ),

          // ── Peers panel (right, toggleable) ──────────────────────────────
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
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final BridgeClient bridge;

  const _ChannelStrip({
    required this.channels,
    required this.selectedIndex,
    required this.onSelect,
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
          // PATCH logo / wordmark
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
              itemBuilder: (ctx, i) => ChannelTab(
                channel: channels[i],
                isSelected: i == selectedIndex,
                onTap: () => onSelect(i),
              ),
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          // Add channel button
          IconButton(
            icon: const Icon(Icons.add, color: PatchTheme.textMuted),
            tooltip: 'Add channel',
            onPressed: () => _showAddChannel(context, bridge),
          ),
          // Settings button
          IconButton(
            icon: const Icon(Icons.settings_outlined, color: PatchTheme.textMuted),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(bridge: bridge, channels: channels),
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
            TextField(controller: idCtrl, decoration: const InputDecoration(hintText: 'ID (slug, e.g. "rf")')),
            const SizedBox(height: 8),
            TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: 'Display Name')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              bridge.upsertChannel(idCtrl.text.trim(), nameCtrl.text.trim(), '#607D8B');
              Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }
}

// ── Per-channel view ──────────────────────────────────────────────────────────

class _ChannelView extends StatelessWidget {
  final PatchChannel channel;
  final List<PatchMessage> messages;
  final BridgeClient bridge;
  final bool showPeers;
  final VoidCallback onTogglePeers;

  const _ChannelView({
    required this.channel,
    required this.messages,
    required this.bridge,
    required this.showPeers,
    required this.onTogglePeers,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Channel header bar
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          color: PatchTheme.surface,
          child: Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: channel.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                channel.displayName,
                style: const TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeLarge,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              // Flash button
              FlashButton(
                onFlash: () => bridge.sendFlash(channel.id),
              ),
              const SizedBox(width: 8),
              // Peers toggle
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
        // Message list
        Expanded(child: MessageList(messages: messages)),
        const Divider(color: PatchTheme.border, height: 1),
        // Shortcut bar
        if (channel.shortcuts.isNotEmpty)
          ShortcutBar(
            shortcuts: channel.shortcuts,
            onShortcut: (s) => bridge.sendMessage(
              channelId: channel.id,
              payload: s.payload,
              priority: s.priority,
            ),
          ),
        // Message input
        MessageInput(
          onSend: (text) => bridge.sendMessage(channelId: channel.id, payload: text),
        ),
      ],
    );
  }
}
