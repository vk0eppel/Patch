import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/config.dart';
import '../models/message.dart';
import '../models/selection.dart';
import '../theme/patch_theme.dart';
import '../util/message_filter.dart';
import '../widgets/channel_tab.dart';
import '../widgets/flash_button.dart';
import '../widgets/message_list.dart';
import '../widgets/message_input.dart';
import '../widgets/message_search_bar.dart';
import '../widgets/name_prompt.dart';
import '../widgets/pulsing_peers_button.dart';
import '../widgets/peers_panel.dart';
import '../widgets/show_files_dialog.dart';
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

  /// What the message area currently shows/targets — Channel(s), ALL compose,
  /// or a DM thread. See models/selection.dart.
  Selection _selection = const ChannelSelection({});

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
  /// First-run name prompt: shown at most once per session. Reset on relaunch,
  /// so an unnamed operator is nudged again next time but never nagged twice.
  bool _namePromptShown = false;
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

  String _clientName = '';
  String _clientRole = '';

  /// Peer ids with an open DM thread (so history is preserved when returning).
  final Set<String> _openDms = {};

  /// DM thread keys (`dm:<peer>`) with unread messages — cleared when viewed.
  final Set<String> _unreadDms = {};

  /// Bumped on each new unread DM while the peers panel is closed; drives the
  /// one-shot pulse on the peers toggle ([PulsingPeersButton]).
  int _dmPulseNotify = 0;

  StreamSubscription<Map<String, dynamic>>? _eventSub;

  /// Coalesces `peer_updated` bursts into one `getPeers()` fetch. `last_seen` is
  /// refreshed on every received packet, so a busy channel fires `peer_updated`
  /// per message; without this each one would do a full peer-list FFI round-trip.
  Timer? _peersRefresh;

  // ── Derived state ───────────────────────────────────────────────────────────

  List<PatchChannel> get _selectedChannels => switch (_selection) {
        ChannelSelection(ids: final ids) =>
          _channels.where((c) => ids.contains(c.id)).toList(),
        _ => const [],
      };

  /// ALL mode — the broadcast tab is selected (exclusive). Shows every
  /// channel's traffic; sends broadcasts.
  bool get _isAllMode => _selection.isAllMode;

  bool get _isMultiChannel => _selection.isMultiChannel;

  /// DM mode — a single direct-message thread is selected (exclusive, like
  /// ALL mode). Shows that one private conversation.
  bool get _isDmMode => _selection.isDmMode;

  /// The peer id of the open DM thread, or null when not in DM mode.
  String? get _dmPeerId => _selection.dmPeerId;

  /// Display name for a DM peer — from the live peer list, else the last message
  /// they sent in the thread, else a short fallback.
  String _dmPeerName(String peerId) {
    for (final p in _peers) {
      if (p.peerId == peerId) return p.peerName;
    }
    final thread = _messages['dm:$peerId'];
    if (thread != null) {
      for (final m in thread.reversed) {
        if (m.senderId == peerId) return m.senderName;
      }
    }
    return 'Unknown';
  }

  /// Whether the open DM peer looks offline — no resolved address, or not heard
  /// from within the peers-panel "offline" window (beyond 5× the heartbeat, the
  /// same threshold as the grey dot). DMs are best-effort with no delivery
  /// receipt, so we warn before one that probably won't arrive.
  bool get _isDmPeerOffline {
    final id = _dmPeerId;
    if (id == null) return false;
    final peer = _peers
        .cast<PeerInfo?>()
        .firstWhere((p) => p?.peerId == id, orElse: () => null);
    if (peer == null || peer.address.isEmpty) return true;
    return DateTime.now().difference(peer.lastSeen).inSeconds >
        _heartbeatSecs * 5;
  }

  /// Warn (once) when a DM has just been sent to a peer that appears offline.
  /// The message is still stored locally and sent best-effort, but the recipient
  /// may never receive it. Called after every DM send — typed, macro, or flash.
  void _warnIfDmPeerOffline() {
    if (!_isDmMode || !_isDmPeerOffline || !mounted) return;
    final name = _dmPeerName(_dmPeerId!);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('$name appears offline — they may not receive this DM'),
          backgroundColor: PatchTheme.warning,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Messages for the current view, merged and sorted by timestamp. In ALL mode
  /// that's every channel's traffic (but not DM threads); in DM mode the one
  /// thread; otherwise the selected channels plus any broadcasts (`__all__`).
  List<PatchMessage> get _combinedMessages {
    final all = <PatchMessage>[];
    switch (_selection) {
      case DmSelection(peerId: final p):
        all.addAll(_messages['dm:$p'] ?? []);
      case AllSelection():
        for (final entry in _messages.entries) {
          if (entry.key.startsWith('dm:')) continue; // DMs stay private
          all.addAll(entry.value);
        }
      case ChannelSelection(ids: final ids):
        for (final id in ids) {
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

  /// Send a macro. In a DM thread the macro text is sent as a DM (a quick canned
  /// reply); otherwise a per-channel macro goes to its own channel and a global
  /// macro (empty `channelId`) fires on every selected channel — or, in ALL mode,
  /// broadcasts on `__all__`.
  void _fireMacro(ChannelMacro cm) {
    if (_isDmMode) {
      widget.bridge.sendDirectMessage(
        peerId: _dmPeerId!,
        payload: cm.macro.payload,
        priority: cm.macro.priority,
      );
      _warnIfDmPeerOffline();
    } else if (cm.channelId.isEmpty) {
      final targets = switch (_selection) {
        AllSelection() => [kAllChannelId],
        ChannelSelection(ids: final ids) => ids.toList(),
        DmSelection() => const <String>[], // unreachable: _isDmMode handled above
      };
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
    // Dual action: also fire the macro's OSC packet to external gear (once).
    final osc = cm.macro.osc;
    if (osc != null) {
      widget.bridge.sendOscMacro(osc.address, osc.port, osc.path, osc.arg);
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

  /// Show the first-run name prompt once per session when the display name is
  /// still the system default. Deferred to a post-frame callback so there's a
  /// built, mounted context to push the dialog onto.
  void _maybeShowNamePrompt({
    required bool nameIsDefault,
    required String currentName,
  }) {
    if (!shouldShowNamePrompt(
      nameIsDefault: nameIsDefault,
      alreadyShown: _namePromptShown,
    )) {
      return;
    }
    _namePromptShown = true; // once per session, whatever the outcome
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showNamePrompt(
        context,
        currentName: currentName,
        onSaveName: (name) => widget.bridge.setClientName(name),
        onSaveRole: (role) =>
            widget.bridge.setRole(role.isEmpty ? null : role),
      );
    });
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
          _channels = data
              .map((c) => PatchChannel.fromJson(c as Map<String, dynamic>))
              .toList();
          // Remove stale ids (deleted channels) from a Channel selection, or
          // seed with the first channel if nothing was selected yet. ALL/DM
          // selections don't depend on the channel list, so a reload never
          // kicks the user out of either (see Selection's doc comment).
          final sel = _selection;
          if (sel is ChannelSelection) {
            final validIds = _channels.map((c) => c.id).toSet();
            final kept = sel.ids.where(validIds.contains).toSet();
            _selection = kept.isNotEmpty
                ? ChannelSelection(kept)
                : (_channels.isNotEmpty
                    ? ChannelSelection({_channels.first.id})
                    : const ChannelSelection({}));
          }
          // Load messages for whatever's now selected, if not already fetched.
          final idsNeeded = _selection.dmPeerId != null
              ? {'dm:${_selection.dmPeerId}'}
              : _selection.tabIds;
          for (final id in idsNeeded) {
            if (!_messages.containsKey(id)) {
              widget.bridge.getMessages(id);
            }
          }
        });
        // Keep the engine's view of the selection current (for MIDI global macros).
        _syncSelection();

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
        if (msg.channelId.startsWith('dm:')) {
          // A plain DM is a silent unread dot, but a *critical* DM flashes too
          // (honouring the global flash-on-critical flag) — same attention
          // treatment as a direct ping. _triggerDmFlash also sets the unread dot
          // when the thread isn't in view, so it covers the non-critical case.
          if (_flashOnCritical && msg.isCritical) {
            _triggerDmFlash(msg.channelId);
          } else if (!_selection.containsRawId(msg.channelId)) {
            setState(() {
              _unreadDms.add(msg.channelId);
              // Pulse the peers toggle only when the panel is closed (open → the
              // unread dot on the peer row is already visible).
              if (!_showPeers) _dmPulseNotify++;
            });
          }
        } else if (msg.channelId == kAllChannelId) {
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
        } else if (chId.startsWith('dm:')) {
          _triggerDmFlash(chId);
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

      case 'show_file_loaded':
        widget.bridge.getChannels();
        // A show file also restores static peers — refresh the peers panel.
        widget.bridge.getPeers();
        setState(() => _selection = const ChannelSelection({}));

      case 'config':
        final cfg =
            AppConfig.fromJson(event['data'] as Map<String, dynamic>);
        setState(() {
          _clientName = cfg.clientName;
          _clientRole = cfg.role ?? '';
          _flashOnCritical = cfg.flashOnCritical;
          _flashOnMessage = cfg.flashOnMessage;
          _globalFlashCount = cfg.flashCount;
          _macrosColumns = cfg.macrosColumns;
          _hideKeyboard = cfg.hideKeyboard;
          _audibleAlert = cfg.audibleAlert;
          _globalMacros = cfg.globalMacros;
          _heartbeatSecs = cfg.heartbeatIntervalSecs;
        });
        _maybeShowNamePrompt(
          nameIsDefault: cfg.nameIsDefault,
          currentName: cfg.clientName,
        );

      case 'show_file_saved':
      case 'interface_changed':
        break;

      case 'client_name_changed':
        setState(() => _clientName = event['name'] as String? ?? _clientName);

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
      if (_selection.containsRawId(channelId)) {
        _flashNotify++;
        _flashColor = ch.color;
        _flashPulseCount = ch.flashCount ?? _globalFlashCount;
      }
    });
  }

  /// Flash for a broadcast (`__all__`): pulses the ALL tab and always flashes the
  /// message area (a broadcast is visible in whatever view the operator is in),
  /// in the neutral broadcast (white) colour.
  void _triggerBroadcastFlash() {
    _playAlert();
    setState(() {
      _flashCounts[kAllChannelId] = (_flashCounts[kAllChannelId] ?? 0) + 1;
      _flashNotify++;
      _flashColor = PatchTheme.broadcast;
      _flashPulseCount = _globalFlashCount;
    });
  }

  /// Flash for a **direct** ping (`dm:{peer}`). Unlike a plain DM (silent unread
  /// dot), a direct flash plays the alert sound and pulses the message area when
  /// the thread is in view — a deliberate "look at me" from one person. The DM
  /// tab is opened (so it appears even with no prior message) and marked unread
  /// when the thread isn't the one being viewed.
  void _triggerDmFlash(String dmKey) {
    final peerId = dmKey.substring(3);
    _playAlert();
    setState(() {
      _openDms.add(peerId); // ensure the tab exists even on a first-ever ping
      if (_selection.containsRawId(dmKey)) {
        _flashNotify++;
        _flashColor = PatchTheme.accent;
        _flashPulseCount = _globalFlashCount;
      } else {
        _unreadDms.add(dmKey);
        if (!_showPeers) _dmPulseNotify++;
      }
    });
  }

  // ── Channel selection ───────────────────────────────────────────────────────

  /// Tap — toggle channel in/out of selection. At least one channel stays selected.
  /// ALL and DM threads are exclusive selections.
  void _toggleChannel(String id) {
    setState(() {
      final sel = _selection;
      if (id == kAllChannelId) {
        // Stash the current Channel selection for snap-back after send.
        _selection = AllSelection(sel is ChannelSelection ? sel.ids : {});
        if (!_messages.containsKey(kAllChannelId)) {
          widget.bridge.getMessages(kAllChannelId);
        }
      } else if (id.startsWith('dm:')) {
        _selection = DmSelection(id.substring(3));
        _unreadDms.remove(id);
        if (!_messages.containsKey(id)) widget.bridge.getMessages(id);
      } else if (sel is AllSelection || sel is DmSelection) {
        // Tapping a channel cancels ALL compose / DM mode.
        _selection = ChannelSelection({id});
        if (!_messages.containsKey(id)) widget.bridge.getMessages(id);
      } else if (sel is ChannelSelection && sel.ids.contains(id)) {
        if (sel.ids.length > 1) {
          _selection = ChannelSelection({...sel.ids}..remove(id));
        }
      } else if (sel is ChannelSelection) {
        _selection = ChannelSelection({...sel.ids, id});
        if (!_messages.containsKey(id)) widget.bridge.getMessages(id);
      }
    });
    _syncSelection();
    if (_hideKeyboard) FocusScope.of(context).unfocus();
  }

  /// After a broadcast send, snap back to the channel(s) selected before ALL.
  void _snapBackFromAll() {
    setState(() {
      final sel = _selection;
      if (sel is AllSelection && sel.previous.isNotEmpty) {
        _selection = ChannelSelection(sel.previous);
      } else if (_channels.isNotEmpty) {
        _selection = ChannelSelection({_channels.first.id});
      }
    });
    _syncSelection();
  }

  /// Open (and select) the DM thread with a peer — from the peers panel button.
  void _openDm(String peerId) {
    final key = 'dm:$peerId';
    setState(() {
      _openDms.add(peerId);
      _selection = DmSelection(peerId);
      _unreadDms.remove(key);
    });
    if (!_messages.containsKey(key)) widget.bridge.getMessages(key);
    _syncSelection();
    if (_hideKeyboard) FocusScope.of(context).unfocus();
  }

  /// Push the current selection to the engine so a MIDI-triggered macro routes
  /// the same way a tap/F-key would (the engine has no other view of UI
  /// selection). DM keys are excluded from the channel list — they aren't
  /// channels — but the DM peer is pushed separately via `setDmTarget` so a
  /// MIDI macro fired while a DM thread is open goes to that peer instead of
  /// silently matching no selected channel (see `_fireMacro`'s DM-mode rule).
  void _syncSelection() {
    widget.bridge.setSelectedChannels(_selection.tabIds.toList());
    widget.bridge.setDmTarget(_selection.dmPeerId);
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The custom headers (channel strip / message area / peers / macros)
      // are plain Containers, not a real AppBar, so nothing insets them from
      // the iOS status bar/notch or the bottom home indicator without this.
      body: SafeArea(child: Row(
        children: [
          _ChannelStrip(
            channels: _channels,
            selectedIds: _selection.tabIds,
            flashCounts: _flashCounts,
            globalFlashCount: _globalFlashCount,
            onTap: _toggleChannel,
            bridge: widget.bridge,
            clientName: _clientName,
            clientRole: _clientRole,
          ),
          // Peers sit on the LEFT, beside the channel list — grouping "who/where"
          // context together (channels + peers), leaving macros on the right.
          // A left border separates it from the same-coloured channel strip.
          if (_showPeers)
            SizedBox(
              width: _kPeersPanelWidth,
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: PatchTheme.border)),
                ),
                child: PeersPanel(
                  peers: _peers,
                  heartbeatSecs: _heartbeatSecs,
                  onClearStale: () => widget.bridge.clearStalePeers(),
                  onClose: () => setState(() => _showPeers = false),
                  onDm: _openDm,
                  unreadPeerIds: {
                    for (final k in _unreadDms) k.substring(3),
                  },
                ),
              ),
            ),
          Expanded(
            // Same left border as the peers panel — so there's always a
            // separator against the channel strip (peers hidden) or against
            // the peers panel (peers shown), keeping the footer dividers
            // (identity chip / clear inactive / typing bar) visually
            // consistent across the whole bottom row either way.
            child: Container(
              decoration: const BoxDecoration(
                border: Border(left: BorderSide(color: PatchTheme.border)),
              ),
              child: _channels.isEmpty
                  ? const Center(child: Text('No channels'))
                  : _ChannelView(
                      selectedChannels: _selectedChannels,
                      isAllMode: _isAllMode,
                      isDmMode: _isDmMode,
                      dmPeerId: _dmPeerId,
                      dmPeerName:
                          _dmPeerId == null ? null : _dmPeerName(_dmPeerId!),
                      onDmSent: _warnIfDmPeerOffline,
                      messages: _combinedMessages,
                      channelColors: _channelColors,
                      delivery: _delivery,
                      aggregatedMacros: _aggregatedMacros,
                      bridge: widget.bridge,
                      showPeers: _showPeers,
                      onTogglePeers: () =>
                          setState(() => _showPeers = !_showPeers),
                      hasUnreadDms: _unreadDms.isNotEmpty,
                      dmPulseNotify: _dmPulseNotify,
                      showMacros: _showMacros,
                      onToggleMacros: () =>
                          setState(() => _showMacros = !_showMacros),
                      flashNotify: _flashNotify,
                      flashColor: _flashColor,
                      flashPulseCount: _flashPulseCount,
                      hideKeyboard: _hideKeyboard,
                      onBroadcastSent: _snapBackFromAll,
                    ),
            ),
          ),
          if (_showMacros)
            SizedBox(
              width: _kMacroColumnWidth * _macrosColumns,
              // Same left border as the peers panel / message area — keeps
              // the separator consistent across every column boundary.
              child: Container(
                decoration: const BoxDecoration(
                  border: Border(left: BorderSide(color: PatchTheme.border)),
                ),
                child: MacrosPanel(
                  macros: _aggregatedMacros,
                  globalMacros: _aggregatedGlobalMacros,
                  isMulti: _isMultiChannel,
                  columns: _macrosColumns,
                  onMacro: _fireMacro,
                  onClose: () => setState(() => _showMacros = false),
                ),
              ),
            ),
        ],
      )),
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
  final String clientName;
  final String clientRole;

  const _ChannelStrip({
    required this.channels,
    required this.selectedIds,
    required this.flashCounts,
    required this.globalFlashCount,
    required this.onTap,
    required this.bridge,
    required this.clientName,
    required this.clientRole,
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                // Two buttons must fit an 80 px-wide strip. IconButton's own
                // `constraints` param is overridden by Material 3's default
                // style (48 px minimumSize) and is silently ignored — only a
                // tight outer SizedBox reliably caps the size, since an
                // external tight constraint always wins.
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.folder_outlined,
                        color: PatchTheme.textMuted),
                    tooltip: 'Show Files',
                    onPressed: () => showDialog(
                      context: context,
                      builder: (_) => ShowFilesDialog(bridge: bridge),
                    ),
                  ),
                ),
                SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.settings_outlined,
                        color: PatchTheme.textMuted),
                    tooltip: 'Settings',
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(
                          builder: (_) => SettingsScreen(
                              bridge: bridge, channels: channels),
                        ))
                        .then((_) => bridge.getConfig()),
                  ),
                ),
              ],
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
                color: PatchTheme.broadcast, // neutral white — not a department
              ),
              isSelected: selectedIds.contains(kAllChannelId),
              flashCount: flashCounts[kAllChannelId] ?? 0,
              pulseCount: globalFlashCount,
              onTap: () => onTap(kAllChannelId),
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1, indent: 12, endIndent: 12),
          Expanded(
            child: ListView(
              children: [
                for (final ch in channels)
                  ChannelTab(
                    channel: ch,
                    isSelected: selectedIds.contains(ch.id),
                    flashCount: flashCounts[ch.id] ?? 0,
                    pulseCount: ch.flashCount ?? globalFlashCount,
                    onTap: () => onTap(ch.id),
                  ),
              ],
            ),
          ),
          const Divider(color: PatchTheme.border, height: 1),
          _IdentityChip(
            name: clientName,
            role: clientRole,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(
                  builder: (_) =>
                      SettingsScreen(bridge: bridge, channels: channels),
                ))
                .then((_) => bridge.getConfig()),
          ),
        ],
      ),
    );
  }
}

// ── Per-channel (or multi-channel) view ──────────────────────────────────────

/// Channel context key — identifies the viewed channel(s)/thread so a switch
/// resets the in-channel search (never silently hide messages on a new view).
String _channelContextKey(_ChannelView w) {
  if (w.isDmMode) return 'dm:${w.dmPeerId}';
  if (w.isAllMode) return '__all__';
  return (w.selectedChannels.map((c) => c.id).toList()..sort()).join(',');
}

class _ChannelView extends StatefulWidget {
  final List<PatchChannel> selectedChannels;

  /// Broadcast (ALL) mode — `selectedChannels` is empty; send/flash target the
  /// reserved `__all__` id and the feed shows every channel's traffic.
  final bool isAllMode;

  /// Direct-message mode — a 1:1 private thread. `selectedChannels` is empty;
  /// send targets `dmPeerId` and there's no flash/macros.
  final bool isDmMode;
  final String? dmPeerId;
  final String? dmPeerName;

  /// Called by the parent after a DM is sent (typed or flash) so it can warn
  /// when the recipient looks offline — the parent owns the peer list + context.
  final VoidCallback onDmSent;
  final List<PatchMessage> messages;
  final Map<String, Color> channelColors; // empty when single channel
  final Map<String, MessageDeliveryStatus> delivery;
  final List<ChannelMacro> aggregatedMacros;
  final BridgeClient bridge;
  final bool showPeers;
  final VoidCallback onTogglePeers;
  final bool hasUnreadDms;

  /// Increments on each new unread DM while the peers panel is closed — drives
  /// the one-shot pulse on the peers toggle.
  final int dmPulseNotify;
  final bool showMacros;
  final VoidCallback onToggleMacros;
  final int flashNotify;
  final Color flashColor;
  final int flashPulseCount;
  final bool hideKeyboard;
  final VoidCallback? onBroadcastSent;

  const _ChannelView({
    required this.selectedChannels,
    required this.isAllMode,
    required this.isDmMode,
    required this.dmPeerId,
    required this.dmPeerName,
    required this.onDmSent,
    required this.messages,
    required this.channelColors,
    required this.delivery,
    required this.aggregatedMacros,
    required this.bridge,
    required this.showPeers,
    required this.onTogglePeers,
    required this.hasUnreadDms,
    required this.dmPulseNotify,
    required this.showMacros,
    required this.onToggleMacros,
    required this.flashNotify,
    required this.flashColor,
    required this.flashPulseCount,
    required this.hideKeyboard,
    this.onBroadcastSent,
  });

  @override
  State<_ChannelView> createState() => _ChannelViewState();
}

class _ChannelViewState extends State<_ChannelView> {
  bool _searchExpanded = false;
  String _query = '';
  final Set<String> _priorityFilter = {};

  bool get _isMulti => widget.selectedChannels.length > 1;
  bool get _filterActive => _query.trim().isNotEmpty || _priorityFilter.isNotEmpty;

  @override
  void didUpdateWidget(_ChannelView old) {
    super.didUpdateWidget(old);
    // Reset search when the viewed channel(s) change — a filter left active from
    // a previous view could otherwise hide a critical on the new one.
    if (_channelContextKey(old) != _channelContextKey(widget) &&
        (_searchExpanded || _filterActive)) {
      _resetSearch();
    }
  }

  void _resetSearch() {
    setState(() {
      _searchExpanded = false;
      _query = '';
      _priorityFilter.clear();
    });
  }

  void _toggleCategory(String cat) {
    setState(() {
      if (!_priorityFilter.remove(cat)) _priorityFilter.add(cat);
    });
  }

  void _sendMessage(String text) {
    if (widget.isDmMode) {
      widget.bridge.sendDirectMessage(peerId: widget.dmPeerId!, payload: text);
      widget.onDmSent();
    } else if (widget.isAllMode) {
      widget.bridge.sendMessage(channelId: kAllChannelId, payload: text);
      widget.onBroadcastSent?.call();
    } else {
      for (final ch in widget.selectedChannels) {
        widget.bridge.sendMessage(channelId: ch.id, payload: text);
      }
    }
  }

  void _sendFlash() {
    if (widget.isDmMode) {
      widget.bridge.sendDmFlash(widget.dmPeerId!);
      widget.onDmSent();
    } else if (widget.isAllMode) {
      widget.bridge.sendFlash(kAllChannelId);
      widget.onBroadcastSent?.call();
    } else {
      for (final ch in widget.selectedChannels) {
        widget.bridge.sendFlash(ch.id);
      }
    }
  }

  Future<void> _exportMessages() async {
    final label = widget.isDmMode
        ? 'dm_${widget.dmPeerName ?? ''}'.toLowerCase()
        : widget.isAllMode
            ? 'all_channels'
            : widget.selectedChannels.length == 1
                ? widget.selectedChannels.first.displayName.toLowerCase()
                : 'all_channels';
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Messages',
      fileName: 'patch_$label.csv',
      allowedExtensions: ['csv'],
      type: FileType.custom,
    );
    if (path == null) return;
    // DM → that thread; ALL / multi-channel → everything (null); single → that one.
    final channelId = widget.isDmMode
        ? 'dm:${widget.dmPeerId}'
        : (!widget.isAllMode && widget.selectedChannels.length == 1)
            ? widget.selectedChannels.first.id
            : null;
    widget.bridge.exportMessages(channelId: channelId, path: path);
  }

  void _confirmClear(BuildContext context) {
    final label = widget.isDmMode
        ? 'this conversation'
        : widget.isAllMode
            ? 'all channels'
            : widget.selectedChannels.length == 1
                ? widget.selectedChannels.first.displayName
                : '${widget.selectedChannels.length} channels';
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
              if (widget.isDmMode) {
                widget.bridge.clearMessages(channelId: 'dm:${widget.dmPeerId}');
              } else if (widget.isAllMode) {
                widget.bridge.clearMessages(channelId: null); // clear everything
              } else {
                for (final ch in widget.selectedChannels) {
                  widget.bridge.clearMessages(channelId: ch.id);
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
    final filtered = filterMessages(
      widget.messages,
      query: _query,
      categories: _priorityFilter,
    );
    final content = Column(
      children: [
        // ── Header ────────────────────────────────────────────────────────
        Container(
          height: PatchTheme.headerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: PatchTheme.surface,
          alignment: Alignment.center,
          child: Row(
            children: [
              // Peers toggle on the LEFT, mirroring the peers panel's position
              // (it opens on the left). When the panel is open it carries its own
              // hide button, so this only shows while the panel is hidden — which
              // is also why a DM pulse never fires with the panel open.
              if (!widget.showPeers) ...[
                PulsingPeersButton(
                  pulseNotify: widget.dmPulseNotify,
                  hasUnread: widget.hasUnreadDms,
                  onPressed: widget.onTogglePeers,
                ),
                const SizedBox(width: 8),
              ],
              // Channel dot(s) + name(s)
              if (widget.isDmMode) ...[
                const Text('💬', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.dmPeerName ?? 'Direct message',
                    style: const TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeLarge,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else if (widget.isAllMode) ...[
                const Text('📢', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    'ALL CHANNELS',
                    style: TextStyle(
                      color: PatchTheme.broadcast,
                      fontSize: PatchTheme.fontSizeLarge,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ] else if (_isMulti) ...[
                Expanded(child: _MultiChannelLabel(channels: widget.selectedChannels)),
              ] else ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: widget.selectedChannels.first.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.selectedChannels.first.displayName,
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
              // Macros toggle stays on the RIGHT, mirroring the macros panel.
              if (!widget.showMacros) ...[
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.keyboard_outlined, color: PatchTheme.textMuted, size: 20),
                  tooltip: 'Show macros',
                  onPressed: widget.onToggleMacros,
                ),
              ],
            ],
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Messages ──────────────────────────────────────────────────────
        Expanded(
          child: Column(
            children: [
              if (_searchExpanded) ...[
                MessageSearchBar(
                  query: _query,
                  categories: _priorityFilter,
                  onQueryChanged: (q) => setState(() => _query = q),
                  onToggleCategory: _toggleCategory,
                  onClose: _resetSearch,
                ),
                const Divider(color: PatchTheme.border, height: 1),
              ],
              Expanded(
                child: Stack(
                  children: [
                    MessageList(
                      messages: filtered,
                      channelColors:
                          (_isMulti || widget.isAllMode) ? widget.channelColors : null,
                      delivery: widget.delivery,
                    ),
                    // Search toggle. Tinted accent while a filter is active so the
                    // Operator knows the feed is filtered even with the bar closed.
                    Positioned(
                      top: 4,
                      right: 76,
                      child: IconButton(
                        icon: const Icon(Icons.search, size: 18),
                        color: _filterActive ? PatchTheme.accent : PatchTheme.textMuted,
                        tooltip: 'Search messages',
                        onPressed: () =>
                            setState(() => _searchExpanded = !_searchExpanded),
                      ),
                    ),
                    Positioned(
                      top: 4,
                      right: 40,
                      child: IconButton(
                        icon: const Icon(Icons.download_outlined, size: 18),
                        color: PatchTheme.textMuted,
                        tooltip: 'Export messages',
                        onPressed: _exportMessages,
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
            ],
          ),
        ),
        const Divider(color: PatchTheme.border, height: 1),

        // ── Input ─────────────────────────────────────────────────────────
        MessageInput(
          onSend: _sendMessage,
          hideKeyboard: widget.hideKeyboard,
          hint: widget.isDmMode
              ? '💬 Message ${widget.dmPeerName ?? ''}…'
              : widget.isAllMode
                  ? '📢 Broadcast to ALL channels…'
                  : null,
        ),
      ],
    );

    return Stack(children: [
      content,
      _FlashLayer(
        flashNotify: widget.flashNotify,
        flashColor: widget.flashColor,
        pulseCount: widget.flashPulseCount,
      ),
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

// ── Identity chip — operator name + role in the channel strip ────────────────

class _IdentityChip extends StatelessWidget {
  final String name;
  final String role;
  final VoidCallback onTap;

  const _IdentityChip({
    required this.name,
    required this.role,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: role.isNotEmpty ? '$name · $role' : name,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          height: PatchTheme.footerHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // No icon here — footerHeight now matches headerHeight (48),
              // too tight for icon + name + role without overflowing.
              Text(
                name.isEmpty ? '—' : name,
                style: const TextStyle(
                  color: PatchTheme.textSecondary,
                  fontSize: PatchTheme.fontSizeSmall,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
              if (role.isNotEmpty)
                Text(
                  role,
                  style: const TextStyle(
                    color: PatchTheme.textMuted,
                    fontSize: 10.0,
                    height: 1.1,
                  ),
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
            ],
          ),
        ),
      ),
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
