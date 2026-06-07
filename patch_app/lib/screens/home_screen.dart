import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
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
import '../widgets/sessions_dialog.dart';
import '../widgets/macros_panel.dart' show MacrosPanel, ChannelMacro;
import 'settings_screen.dart';

// `kAllChannelId` (the reserved broadcast id surfaced via the ALL tab) is defined
// in models/message.dart so both this screen and message_list.dart can share it.

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
  bool _flashOnMessage = false;
  int _globalFlashCount = 4;
  int _flashPulseCount = 4; // resolved count at the time of the last flash

  // ── F-key map ───────────────────────────────────────────────────────────────
  static final _fKeyLabels = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.f1:  'F1',
    LogicalKeyboardKey.f2:  'F2',
    LogicalKeyboardKey.f3:  'F3',
    LogicalKeyboardKey.f4:  'F4',
    LogicalKeyboardKey.f5:  'F5',
    LogicalKeyboardKey.f6:  'F6',
    LogicalKeyboardKey.f7:  'F7',
    LogicalKeyboardKey.f8:  'F8',
    LogicalKeyboardKey.f9:  'F9',
    LogicalKeyboardKey.f10: 'F10',
    LogicalKeyboardKey.f11: 'F11',
    LogicalKeyboardKey.f12: 'F12',
  };

  static const double _kMacroColumnWidth = 160.0;
  static const double _kPeersPanelWidth = 160.0;

  /// Mirror of the Rust ring buffer cap (`MAX_BUFFER` in `state/mod.rs`) so the
  /// in-memory list doesn't grow unbounded over a long show.
  static const int _kMaxMessagesPerChannel = 500;

  List<PeerInfo> _peers = [];
  bool _showPeers = false;
  bool _showMacros = false;
  int _macrosColumns = 1;
  bool _hideKeyboard = true;
  /// Play a sound when a channel flashes (critical / page / broadcast). Off by default.
  bool _audibleAlert = false;
  /// Plays the bundled alert sound. A single reusable player; the source is
  /// preloaded in initState (ReleaseMode.stop) so even the first alert is instant.
  final AudioPlayer _alertPlayer = AudioPlayer();
  /// Macros shown on every channel (configured once); fired on the currently-
  /// selected channel(s). Sourced from the engine config via `getConfig`.
  List<MacroMessage> _globalMacros = [];
  /// Presence heartbeat interval (s) from config — drives the peer dot thresholds.
  int _heartbeatSecs = 7;
  /// Delivery status for criticals we've sent, keyed by message id.
  final Map<String, MessageDeliveryStatus> _delivery = {};
  StreamSubscription<Map<String, dynamic>>? _eventSub;

  /// Coalesces `peer_updated` bursts into one `getPeers()` fetch. `last_seen` is
  /// refreshed on every received packet, so a busy channel fires `peer_updated`
  /// per message; without this each one would do a full peer-list FFI round-trip.
  Timer? _peersRefresh;

  // ── Derived state ───────────────────────────────────────────────────────────

  List<PatchChannel> get _selectedChannels =>
      _channels.where((c) => _selectedIds.contains(c.id)).toList();

  /// ALL mode — the broadcast tab is selected (it's exclusive, so it's the only
  /// id in `_selectedIds`). Shows every channel's traffic; sends broadcasts.
  bool get _isAllMode => _selectedIds.contains(kAllChannelId);

  bool get _isMultiChannel => _selectedIds.length > 1;

  /// Messages for the current view, merged and sorted by timestamp. In ALL mode
  /// that's every channel's traffic; otherwise it's the selected channels plus
  /// any broadcasts (`__all__`), so a broadcast shows up in whatever channel a
  /// heads-down operator is viewing.
  List<PatchMessage> get _combinedMessages {
    final all = <PatchMessage>[];
    if (_isAllMode) {
      for (final list in _messages.values) {
        all.addAll(list);
      }
    } else {
      for (final id in _selectedIds) {
        all.addAll(_messages[id] ?? []);
      }
      all.addAll(_messages[kAllChannelId] ?? []);
    }
    all.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return all;
  }

  /// Channel-colour map for the message list. Populated in multi-channel and ALL
  /// modes (so each row shows its channel dot); empty for a single channel.
  Map<String, Color> get _channelColors {
    if (_isAllMode) return {for (final c in _channels) c.id: c.color};
    if (!_isMultiChannel) return {};
    return {for (final c in _selectedChannels) c.id: c.color};
  }

  /// Macros from all selected channels, each tagged with their channel.
  List<ChannelMacro> get _aggregatedMacros {
    return [
      for (final ch in _selectedChannels)
        for (final s in ch.macros)
          ChannelMacro(channelId: ch.id, channelColor: ch.color, macro: s),
    ];
  }

  /// Global macros wrapped for the panel. The empty `channelId` sentinel marks
  /// them as global so `_fireMacro` routes them to the selected channel(s).
  List<ChannelMacro> get _aggregatedGlobalMacros => [
        for (final gm in _globalMacros)
          ChannelMacro(channelId: '', channelColor: PatchTheme.accent, macro: gm),
      ];

  /// Send a macro. A per-channel macro goes to its own channel; a global macro
  /// (empty `channelId`) fires on every currently-selected channel — or, in ALL
  /// mode, broadcasts on `__all__` — as if it existed on each of them.
  void _fireMacro(ChannelMacro cm) {
    if (cm.channelId.isEmpty) {
      final targets = _isAllMode ? [kAllChannelId] : _selectedIds.toList();
      for (final id in targets) {
        widget.bridge.sendMessage(
          channelId: id,
          payload: cm.macro.payload,
          priority: cm.macro.priority,
        );
      }
    } else {
      widget.bridge.sendMessage(
        channelId: cm.channelId,
        payload: cm.macro.payload,
        priority: cm.macro.priority,
      );
    }
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _eventSub = widget.bridge.events.listen(_handleEvent);
    widget.bridge.getChannels();
    widget.bridge.getPeers();
    widget.bridge.getConfig();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    // Use the playback audio category so the alert sounds on iOS even with the
    // ring/silent switch on (an operational alert must not be muted by silent).
    unawaited(AudioPlayer.global.setAudioContext(AudioContext(
      iOS: AudioContextIOS(category: AVAudioSessionCategory.playback),
    )));
    // Preload the alert so the *first* play after launch isn't delayed by asset
    // extraction + native prepare. ReleaseMode.stop keeps the source loaded
    // between plays, so `_emitAlert` just seeks to the start and resumes.
    unawaited(_alertPlayer.setReleaseMode(ReleaseMode.stop));
    unawaited(_alertPlayer.setSource(AssetSource('sounds/alert.wav')));
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _peersRefresh?.cancel();
    _eventSub?.cancel();
    _alertPlayer.dispose();
    super.dispose();
  }

  /// Debounced full peer-list refresh (trailing edge, ~800 ms).
  void _schedulePeersRefresh() {
    _peersRefresh ??= Timer(const Duration(milliseconds: 800), () {
      _peersRefresh = null;
      widget.bridge.getPeers();
    });
  }

  /// Global F-key handler — fires the first shortcut whose keyBinding matches.
  /// Returns true to consume the event (prevents the key reaching other widgets).
  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final label = _fKeyLabels[event.logicalKey];
    if (label == null) return false;
    // Per-channel macros take precedence over a global macro on the same key.
    for (final cs in _aggregatedMacros) {
      if (cs.macro.keyBinding == label) {
        _fireMacro(cs);
        return true; // consumed
      }
    }
    for (final gm in _globalMacros) {
      if (gm.keyBinding == label) {
        _fireMacro(ChannelMacro(
          channelId: '',
          channelColor: PatchTheme.accent,
          macro: gm,
        ));
        return true; // consumed
      }
    }
    return false;
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
          // Remove stale IDs (deleted channels), but keep the synthetic ALL id
          // so a channel reload doesn't silently kick the user out of ALL mode.
          final validIds = _channels.map((c) => c.id).toSet()..add(kAllChannelId);
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
          final list = _messages.putIfAbsent(msg.channelId, () => [])..add(msg);
          // Keep the in-memory list bounded, mirroring the engine ring buffer.
          if (list.length > _kMaxMessagesPerChannel) {
            list.removeRange(0, list.length - _kMaxMessagesPerChannel);
          }
        });
        // Flash if global OR per-channel flag is set.
        if (msg.channelId == kAllChannelId) {
          // Broadcast — global flags only (it isn't tied to a channel).
          final shouldFlash =
              _flashOnMessage || (_flashOnCritical && msg.isCritical);
          if (shouldFlash) _triggerBroadcastFlash();
        } else {
          final ch = _channels.cast<PatchChannel?>()
              .firstWhere((c) => c?.id == msg.channelId, orElse: () => null);
          if (ch != null) {
            final shouldFlash =
                (_flashOnMessage || ch.flashOnMessage) ||
                ((_flashOnCritical || ch.flashOnCritical) && msg.isCritical);
            if (shouldFlash) _triggerFlash(msg.channelId);
          }
        }

      case 'ack_send':
        break;

      case 'message_delivery':
        final id = event['message_id'] as String;
        final status = MessageDeliveryStatus.fromEvent(event);
        setState(() => _delivery[id] = status);
        // A failed critical can't go unnoticed — also raise a red SnackBar.
        if (status.failed && mounted) {
          final who = status.total == 0
              ? 'no peers were online'
              : status.failedPeers.isNotEmpty
                  ? 'not received by ${status.failedPeers.join(', ')}'
                  : 'not received by all peers';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Critical message $who'),
              backgroundColor: PatchTheme.critical,
              duration: const Duration(seconds: 6),
            ),
          );
        }

      case 'peers':
        final data = event['data'] as List<dynamic>;
        setState(() {
          _peers = data
              .map((p) => PeerInfo.fromJson(p as Map<String, dynamic>))
              .toList();
        });

      case 'peer_updated':
        // The event carries only PeerPresence (no address) and fires on every
        // received packet, so coalesce bursts into one full-list refresh rather
        // than a getPeers() per message.
        _schedulePeersRefresh();

      case 'peer_expired':
        // Refresh the full list — a static-peer-backed entry should
        // immediately reappear as ManualIp (gray dot) rather than disappearing.
        widget.bridge.getPeers();

      case 'channel_flash':
        final chId = event['data']['channel_id'] as String;
        if (chId == kAllChannelId) {
          _triggerBroadcastFlash();
        } else {
          _triggerFlash(chId);
        }

      case 'channel_list_updated':
        widget.bridge.getChannels();

      case 'messages_cleared':
        final clearedId = event['channel_id'] as String?;
        setState(() {
          if (clearedId != null) {
            _messages.remove(clearedId);
          } else {
            _messages.clear();
            _delivery.clear();
          }
        });

      case 'session_loaded':
        widget.bridge.getChannels();
        // A session also restores static peers — refresh the peers panel.
        widget.bridge.getPeers();
        setState(() => _selectedIds = {});

      case 'config':
        setState(() {
          _flashOnCritical =
              (event['data']['flash_on_critical'] as bool?) ?? true;
          _flashOnMessage =
              (event['data']['flash_on_message'] as bool?) ?? false;
          _globalFlashCount =
              (event['data']['flash_count'] as int?) ?? 4;
          _macrosColumns =
              (event['data']['macros_columns'] as int?) ?? 1;
          _hideKeyboard =
              (event['data']['hide_keyboard'] as bool?) ?? true;
          _audibleAlert =
              (event['data']['audible_alert'] as bool?) ?? false;
          _globalMacros =
              ((event['data']['global_macros'] as List<dynamic>?) ?? [])
                  .map((m) => MacroMessage.fromJson(m as Map<String, dynamic>))
                  .toList();
          _heartbeatSecs =
              (event['data']['heartbeat_interval_secs'] as int?) ?? 7;
        });

      case 'session_saved':
      case 'client_name_changed':
      case 'interface_changed':
        break;

      case 'config_updated':
        // Re-fetch config (flash flags) and peers (static peer list may have changed).
        widget.bridge.getConfig();
        widget.bridge.getPeers();

      case 'permission_denied':
        final msg = event['message'] as String? ??
            'Network access denied — check Local Network permission in System Settings';
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: PatchTheme.critical,
              duration: const Duration(seconds: 8),
            ),
          );
        }

      case 'error':
        final msg = event['message'] as String? ?? 'Something went wrong';
        debugPrint('Bridge error: $msg');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(msg),
              backgroundColor: PatchTheme.critical,
              duration: const Duration(seconds: 5),
            ),
          );
        }
    }
  }

  /// Short audible alert played alongside a flash, when enabled in Settings.
  /// Uses the preloaded bundled asset via `audioplayers` (`SystemSound.alert` is
  /// a no-op on macOS/iOS). Fire-and-forget.
  void _playAlert() {
    if (_audibleAlert) unawaited(_emitAlert());
  }

  /// Replays the preloaded alert from the start (no first-play latency); falls
  /// back to a fresh load if the preload wasn't ready yet.
  Future<void> _emitAlert() async {
    try {
      await _alertPlayer.seek(Duration.zero);
      await _alertPlayer.resume();
    } catch (_) {
      try {
        await _alertPlayer.play(AssetSource('sounds/alert.wav'));
      } catch (_) {
        // Best-effort — never let a failed alert disrupt messaging.
      }
    }
  }

  void _triggerFlash(String channelId) {
    final ch = _channels.firstWhere(
      (c) => c.id == channelId,
      orElse: () => _channels.isEmpty
          ? const PatchChannel(id: '', displayName: '?', color: Colors.white)
          : _channels.first,
    );
    _playAlert();
    setState(() {
      _flashCounts[channelId] = (_flashCounts[channelId] ?? 0) + 1;
      // Only pulse the main screen overlay when the channel is selected.
      if (_selectedIds.contains(channelId)) {
        _flashNotify++;
        _flashColor = ch.color;
        _flashPulseCount = ch.flashCount ?? _globalFlashCount;
      }
    });
  }

  /// Flash for a broadcast (`__all__`): pulses the ALL tab and always flashes the
  /// message area (a broadcast is visible in whatever view the operator is in),
  /// in the accent colour.
  void _triggerBroadcastFlash() {
    _playAlert();
    setState(() {
      _flashCounts[kAllChannelId] = (_flashCounts[kAllChannelId] ?? 0) + 1;
      _flashNotify++;
      _flashColor = PatchTheme.accent;
      _flashPulseCount = _globalFlashCount;
    });
  }

  // ── Channel selection ───────────────────────────────────────────────────────

  /// Tap — toggle channel in/out of selection. At least one channel stays selected.
  void _toggleChannel(String id) {
    setState(() {
      if (id == kAllChannelId) {
        // ALL is an exclusive mode — selecting it replaces the selection.
        _selectedIds = {kAllChannelId};
        if (!_messages.containsKey(kAllChannelId)) {
          widget.bridge.getMessages(kAllChannelId); // backfill broadcast history
        }
      } else if (_isAllMode) {
        // Tapping a normal channel exits ALL mode.
        _selectedIds = {id};
        if (!_messages.containsKey(id)) widget.bridge.getMessages(id);
      } else if (_selectedIds.contains(id)) {
        if (_selectedIds.length > 1) _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
        if (!_messages.containsKey(id)) widget.bridge.getMessages(id);
      }
    });
    if (_hideKeyboard) FocusScope.of(context).unfocus();
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
            globalFlashCount: _globalFlashCount,
            onTap: _toggleChannel,
            bridge: widget.bridge,
          ),
          Expanded(
            child: _channels.isEmpty
                ? const Center(child: Text('No channels'))
                : _ChannelView(
                    selectedChannels: _selectedChannels,
                    isAllMode: _isAllMode,
                    messages: _combinedMessages,
                    channelColors: _channelColors,
                    delivery: _delivery,
                    aggregatedMacros: _aggregatedMacros,
                    bridge: widget.bridge,
                    showPeers: _showPeers,
                    onTogglePeers: () =>
                        setState(() => _showPeers = !_showPeers),
                    showMacros: _showMacros,
                    onToggleMacros: () =>
                        setState(() => _showMacros = !_showMacros),
                    flashNotify: _flashNotify,
                    flashColor: _flashColor,
                    flashPulseCount: _flashPulseCount,
                    hideKeyboard: _hideKeyboard,
                  ),
          ),
          if (_showMacros)
            SizedBox(
              width: _kMacroColumnWidth * _macrosColumns,
              child: MacrosPanel(
                macros: _aggregatedMacros,
                globalMacros: _aggregatedGlobalMacros,
                isMulti: _selectedIds.length > 1,
                columns: _macrosColumns,
                onMacro: _fireMacro,
                onClose: () => setState(() => _showMacros = false),
              ),
            ),
          if (_showPeers)
            SizedBox(
              width: _kPeersPanelWidth,
              child: PeersPanel(
                peers: _peers,
                heartbeatSecs: _heartbeatSecs,
                channelColors: {for (final c in _channels) c.id: c.color},
                onClearStale: () => widget.bridge.clearStalePeers(),
                onClose: () => setState(() => _showPeers = false),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Channel strip ─────────────────────────────────────────────────────────────

class _ChannelStrip extends StatelessWidget {
  static const double _kChannelStripWidth = 80.0;

  final List<PatchChannel> channels;
  final Set<String> selectedIds;
  final Map<String, int> flashCounts;
  final int globalFlashCount;
  final ValueChanged<String> onTap;
  final BridgeClient bridge;

  const _ChannelStrip({
    required this.channels,
    required this.selectedIds,
    required this.flashCounts,
    required this.globalFlashCount,
    required this.onTap,
    required this.bridge,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _kChannelStripWidth,
      color: PatchTheme.surface,
      child: Column(
        children: [
          SizedBox(
            height: PatchTheme.headerHeight,
            child: Image.asset(
              'assets/icon/icon_master.png',
              width: double.infinity,
              fit: BoxFit.fitWidth,
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          const SizedBox(height: 8),
          // Pinned ALL tab — crew-wide broadcast view/send. Wrapped in a
          // full-width SizedBox so its frame matches the channel tabs below
          // (those stretch to the strip width inside the ListView; a bare tab in
          // this Column would otherwise centre-shrink to hug its text).
          SizedBox(
            width: double.infinity,
            child: ChannelTab(
              channel: const PatchChannel(
                id: kAllChannelId,
                displayName: 'ALL',
                color: PatchTheme.accent,
              ),
              isSelected: selectedIds.contains(kAllChannelId),
              flashCount: flashCounts[kAllChannelId] ?? 0,
              pulseCount: globalFlashCount,
              onTap: () => onTap(kAllChannelId),
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1, indent: 12, endIndent: 12),
          Expanded(
            child: ListView.builder(
              itemCount: channels.length,
              itemBuilder: (ctx, i) {
                final ch = channels[i];
                return ChannelTab(
                  channel: ch,
                  isSelected: selectedIds.contains(ch.id),
                  flashCount: flashCounts[ch.id] ?? 0,
                  pulseCount: ch.flashCount ?? globalFlashCount,
                  onTap: () => onTap(ch.id),
                );
              },
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          // Channels are created/edited/deleted in Settings → Channels & Macros
          // (with colour); no separate quick-add here.
          IconButton(
            icon: const Icon(Icons.folder_outlined, color: PatchTheme.textMuted),
            tooltip: 'Sessions',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => SessionsDialog(bridge: bridge),
            ),
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
}

// ── Per-channel (or multi-channel) view ──────────────────────────────────────

class _ChannelView extends StatelessWidget {
  final List<PatchChannel> selectedChannels;

  /// Broadcast (ALL) mode — `selectedChannels` is empty; send/flash target the
  /// reserved `__all__` id and the feed shows every channel's traffic.
  final bool isAllMode;
  final List<PatchMessage> messages;
  final Map<String, Color> channelColors; // empty when single channel
  final Map<String, MessageDeliveryStatus> delivery;
  final List<ChannelMacro> aggregatedMacros;
  final BridgeClient bridge;
  final bool showPeers;
  final VoidCallback onTogglePeers;
  final bool showMacros;
  final VoidCallback onToggleMacros;
  final int flashNotify;
  final Color flashColor;
  final int flashPulseCount;
  final bool hideKeyboard;

  const _ChannelView({
    required this.selectedChannels,
    required this.isAllMode,
    required this.messages,
    required this.channelColors,
    required this.delivery,
    required this.aggregatedMacros,
    required this.bridge,
    required this.showPeers,
    required this.onTogglePeers,
    required this.showMacros,
    required this.onToggleMacros,
    required this.flashNotify,
    required this.flashColor,
    required this.flashPulseCount,
    required this.hideKeyboard,
  });

  bool get _isMulti => selectedChannels.length > 1;

  void _sendMessage(String text) {
    if (isAllMode) {
      bridge.sendMessage(channelId: kAllChannelId, payload: text); // one broadcast
    } else {
      for (final ch in selectedChannels) {
        bridge.sendMessage(channelId: ch.id, payload: text);
      }
    }
  }

  void _sendFlash() {
    if (isAllMode) {
      bridge.sendFlash(kAllChannelId);
    } else {
      for (final ch in selectedChannels) {
        bridge.sendFlash(ch.id);
      }
    }
  }

  Future<void> _exportMessages(BuildContext context) async {
    final label = isAllMode
        ? 'all_channels'
        : selectedChannels.length == 1
            ? selectedChannels.first.displayName.toLowerCase()
            : 'all_channels';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Messages',
      fileName: 'patch_$label.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (path == null) return;
    // ALL or multi-channel → export everything (null); single channel → that one.
    final channelId =
        (!isAllMode && selectedChannels.length == 1) ? selectedChannels.first.id : null;
    bridge.exportMessages(channelId: channelId, path: path);
  }

  void _confirmClear(BuildContext context) {
    final label = isAllMode
        ? 'all channels'
        : selectedChannels.length == 1
            ? selectedChannels.first.displayName
            : '${selectedChannels.length} channels';
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear messages?'),
        content: SizedBox(
          width: double.infinity,
          child: Text(
            'This will clear the message history for $label. '
            'Messages are not stored to disk — this cannot be undone.',
            style: const TextStyle(color: PatchTheme.textSecondary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PatchTheme.critical),
            onPressed: () {
              if (isAllMode) {
                bridge.clearMessages(channelId: null); // clear everything
              } else {
                for (final ch in selectedChannels) {
                  bridge.clearMessages(channelId: ch.id);
                }
              }
              Navigator.pop(context);
            },
            child: const Text('Clear', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        // ── Header ────────────────────────────────────────────────────────
        Container(
          height: PatchTheme.headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: PatchTheme.surface,
          alignment: Alignment.center,
          child: Row(
            children: [
              // Channel dot(s) + name(s)
              if (isAllMode) ...[
                const Text('📢', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'ALL CHANNELS',
                    style: TextStyle(
                      color: PatchTheme.accent,
                      fontSize: PatchTheme.fontSizeLarge,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else if (_isMulti) ...[
                Expanded(child: _MultiChannelLabel(channels: selectedChannels)),
              ] else ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: selectedChannels.first.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    selectedChannels.first.displayName,
                    style: const TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeLarge,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              FlashButton(onFlash: _sendFlash),
              if (!showMacros)
                IconButton(
                  icon: const Icon(Icons.keyboard_outlined, color: PatchTheme.textMuted, size: 20),
                  tooltip: 'Show macros',
                  onPressed: onToggleMacros,
                ),
              if (!showPeers)
                IconButton(
                  icon: const Icon(Icons.people, color: PatchTheme.textMuted, size: 20),
                  tooltip: 'Show peers',
                  onPressed: onTogglePeers,
                ),
            ],
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Messages ──────────────────────────────────────────────────────
        Expanded(
          child: Stack(
            children: [
              MessageList(
                messages: messages,
                channelColors: (_isMulti || isAllMode) ? channelColors : null,
                delivery: delivery,
              ),
              Positioned(
                top: 4,
                right: 40,
                child: IconButton(
                  icon: const Icon(Icons.download_outlined, size: 18),
                  color: PatchTheme.textMuted,
                  tooltip: 'Export messages',
                  onPressed: () => _exportMessages(context),
                ),
              ),
              Positioned(
                top: 4,
                right: 4,
                child: IconButton(
                  icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                  color: PatchTheme.textMuted,
                  tooltip: 'Clear messages',
                  onPressed: () => _confirmClear(context),
                ),
              ),
            ],
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Input ─────────────────────────────────────────────────────────
        MessageInput(
          onSend: _sendMessage,
          hideKeyboard: hideKeyboard,
          hint: isAllMode ? '📢 Broadcast to ALL channels…' : null,
        ),
      ],
    );

    return Stack(children: [
      content,
      _FlashLayer(flashNotify: flashNotify, flashColor: flashColor, pulseCount: flashPulseCount),
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
        Expanded(
          child: Text(
            channels.length <= 3
                ? channels.map((c) => c.displayName).join(' · ')
                : '${channels.length} channels',
            style: const TextStyle(
              color: PatchTheme.textPrimary,
              fontSize: PatchTheme.fontSizeLarge,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

// ── Flash layer — message box border + background pulse ──────────────────────

/// Positioned.fill overlay that pulses the channel colour [pulseCount] times
/// when [flashNotify] increments. Uses timer-based setState for reliable pulses.
class _FlashLayer extends StatefulWidget {
  final int flashNotify;
  final Color flashColor;
  final int pulseCount;

  const _FlashLayer({
    required this.flashNotify,
    required this.flashColor,
    required this.pulseCount,
  });

  @override
  State<_FlashLayer> createState() => _FlashLayerState();
}

class _FlashLayerState extends State<_FlashLayer> {
  bool _lit = false;

  /// Bumped on every pulse so a flash arriving mid-pulse cancels the in-flight
  /// loop instead of running two overlapping `setState` cycles.
  int _pulseGen = 0;

  @override
  void didUpdateWidget(_FlashLayer old) {
    super.didUpdateWidget(old);
    if (widget.flashNotify > old.flashNotify) _pulse();
  }

  Future<void> _pulse() async {
    final gen = ++_pulseGen; // invalidate any pulse still running
    final count = widget.pulseCount.clamp(3, 7);
    for (var i = 0; i < count; i++) {
      if (!mounted || gen != _pulseGen) return;
      setState(() => _lit = true);
      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted || gen != _pulseGen) return;
      setState(() => _lit = false);
      if (i < count - 1) await Future.delayed(const Duration(milliseconds: 150));
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
