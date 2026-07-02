import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/config.dart';
import '../models/dm_thread.dart';
import '../presenters/home_presenter.dart';
import '../models/message.dart';
import '../models/selection.dart';
import '../models/selection_controller.dart';
import '../store/app_store.dart';
import '../theme/patch_theme.dart';
import '../util/flash_overlay_gateway.dart';
import '../util/message_filter.dart';
import '../util/message_view.dart';
import '../util/run_guarded.dart';
import '../util/workspace_store.dart';
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
  final WorkspaceStore? workspaceStore;
  final WorkspaceState initialWorkspace;

  const HomeScreen({
    super.key,
    required this.bridge,
    this.workspaceStore,
    this.initialWorkspace = const WorkspaceState(),
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

class _HomeScreenState extends State<HomeScreen> with WindowListener {
  /// Channels are owned by the AppStore (#57); selection reconciliation on
  /// change happens in the store listener (`_onStoreChanged`).
  List<PatchChannel> get _channels => AppStoreScope.of(context).channels;

  /// What the message area currently shows/targets — Channel(s), ALL compose,
  /// or a DM thread. See models/selection.dart. Transition rules live in
  /// [SelectionController] (#63, #94); it owns ensureMessages + syncSelection
  /// internally so this screen calls one method per interaction.
  late final SelectionController _selectionController;
  Selection get _selection => _selectionController.selection;

  /// Message buffers + delivery status are owned by the AppStore (#58); reading
  /// via `of(context)` rebuilds when a message lands or a buffer changes.
  Map<String, List<PatchMessage>> get _messages =>
      AppStoreScope.of(context).messages;

  // Config-derived values are owned by the AppStore (#56); reading via
  // `of(context)` rebuilds when config changes. Defaults apply before the
  // first load completes.
  AppConfig? get _config => AppStoreScope.of(context).config;
  int get _globalFlashCount => _config?.flashCount ?? 4;

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

  /// Peers are owned by the shared [AppStore]; reading via `of(context)`
  /// rebuilds the screen when the list changes (candidate 2, ADR-0004).
  List<PeerInfo> get _peers => AppStoreScope.of(context).peers;
  bool _showPeersValue = false;
  bool get _showPeers => _showPeersValue;
  set _showPeers(bool v) { _showPeersValue = v; _presenter.showPeers = v; }
  late bool _showMacros;
  // Full workspace state — panel flags + geometry kept together so a panel
  // toggle never clobbers previously-saved window geometry.
  late WorkspaceState _workspace;
  // Debounce timer for window move/resize saves.
  Timer? _windowSaveDebounce;
  /// First-run name prompt: shown at most once per session. Reset on relaunch,
  /// so an unnamed operator is nudged again next time but never nagged twice.
  bool _namePromptShown = false;
  int get _macrosColumns => _config?.macrosColumns ?? 1;
  /// `hideKeyboard` is a mobile-only concept (keeping the software keyboard
  /// hidden until tapped) — gate its effect to iOS/Android so desktop always
  /// keeps the typing bar focused through sends and channel switches,
  /// regardless of the underlying config value (#78).
  bool get _hideKeyboard =>
      (Platform.isIOS || Platform.isAndroid) && (_config?.hideKeyboard ?? true);
  /// Plays the bundled alert sound. A single reusable player; the source is
  /// preloaded in initState (ReleaseMode.stop) so even the first alert is instant.
  final AudioPlayer _alertPlayer = AudioPlayer();

  late final HomePresenter _presenter;
  StreamSubscription<HomeCommand>? _commandSub;
  final _configStreamCtrl = StreamController<AppConfig?>.broadcast();
  final _peersStreamCtrl = StreamController<List<PeerInfo>>.broadcast();
  /// Macros shown on every channel (configured once); fired on the currently-
  /// selected channel(s). Owned by the AppStore config (#56).
  List<MacroMessage> get _globalMacros => _config?.globalMacros ?? const [];

  String get _clientName => _config?.clientName ?? '';
  String get _clientRole => _config?.role ?? '';

  // ── Derived state ───────────────────────────────────────────────────────────

  List<PatchChannel> get _selectedChannels => switch (_selection) {
        ChannelSelection(ids: final ids) =>
          _channels.where((c) => ids.contains(c.id)).toList(),
        _ => const [],
      };

  bool get _isMultiChannel => _selection.isMultiChannel;

  /// DM mode — a single direct-message thread is selected (exclusive, like
  /// ALL mode). Shows that one private conversation.
  bool get _isDmMode => _selection.isDmMode;

  /// The peer id of the open DM thread, or null when not in DM mode.
  String? get _dmPeerId => _selection.dmPeerId;

  /// Warn (once) when a DM has just been sent to a peer that appears offline.
  /// The message is still stored locally and sent best-effort, but the recipient
  /// may never receive it. Called after every DM send — typed, macro, or flash.
  void _warnIfDmPeerOffline() {
    final id = _dmPeerId;
    if (!_isDmMode || id == null || !_presenter.isDmPeerOffline(id) || !mounted) return;
    final name = _presenter.dmPeerName(id);
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

  List<PatchMessage> get _combinedMessages =>
      combinedMessages(_messages, _selection);

  Map<String, Color> get _channelColors =>
      channelColors(_channels, _selectedChannels, _selection);

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

  /// Fire a macro. The UI only expresses intent — routing (DM-open precedence,
  /// own-channel vs selection, OSC dual-action once) is engine-owned via
  /// `fire_macro` (ADR-0009).
  void _fireMacro(ChannelMacro cm) {
    runGuarded(
        context,
        () => widget.bridge.fireMacro(
              channelId: cm.channelId.isEmpty ? null : cm.channelId,
              label: cm.macro.label,
            ));
    // Screen-local reaction (ADR-0005): warn when firing into a dead DM.
    if (_selection.isDmMode) _warnIfDmPeerOffline();
  }

  // ── Lifecycle ───────────────────────────────────────────────────────────────

  bool _controllerReady = false;

  @override
  void initState() {
    super.initState();
    _workspace = widget.initialWorkspace;
    _showMacros = _workspace.showMacros ?? false;
    if (_isDesktop) windowManager.addListener(this);
    _showPeersValue = _workspace.showPeers;
    // Peers, config, and channels are all loaded by the AppStore (see main).
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

  void _onFlashAppChanged() {
    if (mounted) setState(() {});
  }

  AppStore? _store;
  List<String>? _lastChannelIds;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Watch the store for side effects on its changes: the one-shot first-run
    // name prompt (config) and selection reconciliation (channels). Rebuilds on
    // store changes are handled separately by the `of(context)` reads in build.
    final store = AppStoreScope.of(context);
    if (!_controllerReady) {
      // Both deps are available here — AppStore via context, BridgeClient via widget.
      _selectionController = SelectionController(store, widget.bridge);
      _presenter = HomePresenter(
        pushes: widget.bridge.pushes,
        configStream: _configStreamCtrl.stream,
        peersStream: _peersStreamCtrl.stream,
        supportsFlashOverlay: Platform.isMacOS || Platform.isWindows,
        selectionController: _selectionController,
        channelGetter: () => AppStoreScope.read(context).channels,
        showPeers: _workspace.showPeers,
        broadcastColor: PatchTheme.broadcast,
        dmColor: PatchTheme.accent,
      )..addListener(_onFlashAppChanged);
      _commandSub = _presenter.commands.listen(_handleCommand);
      _controllerReady = true;
    }
    if (!identical(_store, store)) {
      _store?.removeListener(_onStoreChanged);
      _store = store;
      _store!.addListener(_onStoreChanged);
      _onStoreChanged();
    }
  }

  void _onStoreChanged() {
    final cfg = _store?.config;
    _configStreamCtrl.add(cfg);
    _peersStreamCtrl.add(_store?.peers ?? const []);
    if (cfg != null) {
      _maybeShowNamePrompt(
        nameIsDefault: cfg.nameIsDefault,
        currentName: cfg.clientName,
      );
      // First config load: if the Operator has never explicitly toggled the
      // macros panel, derive the default from whether any macros are configured.
      if (_workspace.showMacros == null) {
        final hasMacros = cfg.globalMacros.isNotEmpty ||
            (_store?.channels.any((c) => c.macros.isNotEmpty) ?? false);
        setState(() {
          _showMacros = hasMacros;
          _workspace = _workspace.copyWith(showMacros: hasMacros);
        });
      }
    }
    // Reconcile the selection only when the channel set actually changed (the
    // listener fires on any store notify, incl. peers/config).
    final channels = _store?.channels;
    final ids = channels?.map((c) => c.id).toList();
    if (ids != null && !_sameIds(ids, _lastChannelIds)) {
      _lastChannelIds = ids;
      _reconcileSelectionWithChannels();
    }
  }

  static bool _sameIds(List<String> a, List<String>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Drop stale ids from a Channel selection (or seed the first channel when
  /// empty) after the channel list changes. Timing owned by the controller (#94).
  void _reconcileSelectionWithChannels() {
    final channels = _store?.channels ?? const [];
    setState(() => _selectionController.reconcileWithChannels(channels));
  }

  @override
  void dispose() {
    _windowSaveDebounce?.cancel();
    if (_isDesktop) windowManager.removeListener(this);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _store?.removeListener(_onStoreChanged);
    _commandSub?.cancel();
    _configStreamCtrl.close();
    _peersStreamCtrl.close();
    _presenter.dispose();
    _alertPlayer.dispose();
    super.dispose();
  }

  // ── Workspace persistence ───────────────────────────────────────────────────

  void _savePanels() {
    _workspace = _workspace.copyWith(
      showPeers: _showPeers,
      showMacros: _showMacros,
    );
    widget.workspaceStore?.save(_workspace);
  }

  void _scheduleWindowSave() {
    _windowSaveDebounce?.cancel();
    _windowSaveDebounce = Timer(
      const Duration(milliseconds: 500),
      _saveWindowGeometry,
    );
  }

  Future<void> _saveWindowGeometry() async {
    final pos = await windowManager.getPosition();
    final size = await windowManager.getSize();
    _workspace = _workspace.copyWith(
      windowX: pos.dx,
      windowY: pos.dy,
      windowWidth: size.width,
      windowHeight: size.height,
    );
    widget.workspaceStore?.save(_workspace);
  }

  @override
  void onWindowMoved() => _scheduleWindowSave();

  @override
  void onWindowResized() => _scheduleWindowSave();

  /// Global F-key handler. Which macro fires (per-channel beats global) is
  /// engine-owned via `fire_key_binding` (ADR-0009); this handler only decides
  /// synchronously whether to consume the event, using the same "any binding
  /// on a selected channel or a global" predicate — an existence check, not
  /// routing.
  bool _handleHardwareKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final label = _fKeyLabels[event.logicalKey];
    if (label == null) return false;
    final bound = _aggregatedMacros.any((cs) => cs.macro.keyBinding == label) ||
        _globalMacros.any((gm) => gm.keyBinding == label);
    if (!bound) return false;
    runGuarded(context, () => widget.bridge.fireKeyBinding(label));
    if (_selection.isDmMode) _warnIfDmPeerOffline();
    return true; // consumed
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
        // setClientName is push-driven (ClientNameChanged → store); setRole has
        // no push, so refetch config via the store after it (#56).
        onSaveName: (name) =>
            runGuarded(context, () => widget.bridge.setClientName(name)),
        onSaveRole: (role) {
          final store = AppStoreScope.read(context);
          runGuarded(context, () async {
            await widget.bridge.setRole(role.isEmpty ? null : role);
            await store.refreshConfig();
          });
        },
      );
    });
  }

  /// Routes imperative commands from [HomePresenter] — SnackBars need
  /// BuildContext, audio needs the pre-loaded player, overlay needs the gateway.
  void _handleCommand(HomeCommand cmd) {
    if (!mounted) return;
    switch (cmd) {
      case ShowDeliveryFailure(:final status):
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
      case ShowPermissionDenied(:final context):
        ScaffoldMessenger.of(this.context).showSnackBar(
          SnackBar(
            content: Text(context.isEmpty
                ? 'Network access denied — check Local Network permission in System Settings'
                : context),
            backgroundColor: PatchTheme.critical,
            duration: const Duration(seconds: 8),
          ),
        );
      case PlayAlert():
        unawaited(_emitAlert());
      case PulseOverlay(:final color, :final pulseCount):
        unawaited(FlashOverlayGateway.pulse(color, pulseCount));
    }
  }

  /// Drop the store's buffer for cleared messages after a `clearMessages`
  /// command (#58). `channelId` null = all.
  void _onMessagesCleared(String? channelId) {
    AppStoreScope.read(context).dropMessages(channelId);
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

  // ── Channel selection ───────────────────────────────────────────────────────

  /// Tap — toggle channel in/out of selection. At least one channel stays selected.
  /// ALL and DM threads are exclusive selections. Transition rule and side effects
  /// (ensureMessages, syncSelection) handled by [SelectionController] (#63, #94);
  /// this screen keeps only the screen-local unread-clear (ADR-0005).
  void _toggleChannel(String id) {
    setState(() => _selectionController.selectTab(id));
    if (DmThread.isKey(id)) _presenter.clearUnread(id);
    if (_hideKeyboard) FocusScope.of(context).unfocus();
  }

  /// After a send in ALL mode, snap back to the channel(s) selected before ALL.
  void _snapBackFromAll() {
    setState(() => _selectionController.snapBackFromAll(_channels));
  }

  /// Open (and select) the DM thread with a peer — from the peers panel button.
  /// This screen keeps the screen-local open-thread/unread bookkeeping (ADR-0005).
  void _openDm(String peerId) {
    setState(() => _selectionController.openDm(peerId));
    _presenter.openDmThread(peerId);
    if (_hideKeyboard) FocusScope.of(context).unfocus();
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
            flashCounts: _presenter.flashCounts,
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
                  onClearStale: () =>
                      runGuarded(context, () => widget.bridge.clearStalePeers()),
                  onClose: () {
                    setState(() => _showPeers = false);
                    _savePanels();
                  },
                  onDm: _openDm,
                  unreadPeerIds: {
                    for (final k in _presenter.unreadDms)
                      if (DmThread.tryParse(k) case final DmThread dm)
                        dm.peerId,
                  },
                  onRefresh: () => AppStoreScope.read(context).refreshPeers(),
                  onOpenSettings: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(bridge: widget.bridge),
                    ),
                  ),
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
                      selection: _selection,
                      channels: _channels,
                      dmPeerName:
                          _dmPeerId == null ? null : _presenter.dmPeerName(_dmPeerId!),
                      onDmSent: _warnIfDmPeerOffline,
                      onMessagesCleared: _onMessagesCleared,
                      messages: _combinedMessages,
                      channelColors: _channelColors,
                      delivery: AppStoreScope.of(context).delivery,
                      aggregatedMacros: _aggregatedMacros,
                      bridge: widget.bridge,
                      showPeers: _showPeers,
                      onTogglePeers: () {
                        setState(() => _showPeers = !_showPeers);
                        _savePanels();
                      },
                      hasUnreadDms: _presenter.unreadDms.isNotEmpty,
                      dmPulseNotify: _presenter.dmPulseNotify,
                      showMacros: _showMacros,
                      onToggleMacros: () {
                        setState(() => _showMacros = !_showMacros);
                        _savePanels();
                      },
                      flashNotify: _presenter.flashNotify,
                      flashColor: _presenter.flashColor,
                      flashPulseCount: _presenter.flashPulseCount,
                      hideKeyboard: _hideKeyboard,
                      onOneShotSent: _snapBackFromAll,
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
                  onClose: () {
                    setState(() => _showMacros = false);
                    _savePanels();
                  },
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
                      // After a load, channels refresh via the ChannelsChanged
                      // push (the 'channels' arm also fixes a stale selection);
                      // peers aren't push-backed, so refresh them here (ADR-0004).
                      builder: (_) => ShowFilesDialog(
                        bridge: bridge,
                        onShowFileLoaded: () =>
                            AppStoreScope.read(context).refreshPeers(),
                      ),
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
                    // No post-return refresh needed: settings mutates the
                    // shared AppStore directly, so home already reflects it (#56).
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => SettingsScreen(bridge: bridge),
                        )),
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
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SettingsScreen(bridge: bridge),
                )),
          ),
        ],
      ),
    );
  }
}

// ── Per-channel (or multi-channel) view ──────────────────────────────────────

class _ChannelView extends StatefulWidget {
  /// What's selected — Channel(s), ALL, or a DM thread. [channels] resolves
  /// a [ChannelSelection]'s ids to the full [PatchChannel] objects below.
  final Selection selection;
  final List<PatchChannel> channels;

  final String? dmPeerName;

  /// Called by the parent after a DM is sent (typed or flash) so it can warn
  /// when the recipient looks offline — the parent owns the peer list + context.
  final VoidCallback onDmSent;

  /// Called after messages are cleared (null = all channels) so the parent can
  /// drop them from its buffer — the parent owns `_messages` (ADR-0004).
  final void Function(String? channelId) onMessagesCleared;
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

  /// Called after a send/flash while [selection] is the one-shot ALL compose
  /// state, so the parent can snap back to whatever was selected before ALL.
  final VoidCallback? onOneShotSent;

  const _ChannelView({
    required this.selection,
    required this.channels,
    required this.dmPeerName,
    required this.onDmSent,
    required this.onMessagesCleared,
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
    this.onOneShotSent,
  });

  /// Broadcast (ALL) mode — `selectedChannels` is empty; send/flash target the
  /// reserved `__all__` id and the feed shows every channel's traffic.
  bool get isAllMode => selection.isAllMode;

  /// Direct-message mode — a 1:1 private thread. `selectedChannels` is empty;
  /// send targets `dmPeerId` and there's no flash/macros.
  bool get isDmMode => selection.isDmMode;

  String? get dmPeerId => selection.dmPeerId;

  List<PatchChannel> get selectedChannels => switch (selection) {
        ChannelSelection(ids: final ids) =>
          channels.where((c) => ids.contains(c.id)).toList(),
        _ => const [],
      };

  @override
  State<_ChannelView> createState() => _ChannelViewState();
}

class _ChannelViewState extends State<_ChannelView> {
  bool _searchExpanded = false;
  String _query = '';
  final Set<String> _priorityFilter = {};
  // Owned here so _toggleChannel / channel-switch can call requestFocus()
  // without MessageInput exposing its internals. Passed as MessageInput.focusNode
  // so MessageInput itself can also requestFocus() after a send.
  final _inputFocusNode = FocusNode();

  bool get _isMulti => widget.selectedChannels.length > 1;
  bool get _filterActive => _query.trim().isNotEmpty || _priorityFilter.isNotEmpty;

  @override
  void dispose() {
    _inputFocusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(_ChannelView old) {
    super.didUpdateWidget(old);
    // Reset search when the viewed channel(s) change — a filter left active from
    // a previous view could otherwise hide a critical on the new one.
    if (widget.selection != old.selection &&
        (_searchExpanded || _filterActive)) {
      _resetSearch();
    }
    // On desktop, keep the typing bar focused through channel/DM switches so
    // the operator never needs to click back in before the next send.
    if (!widget.hideKeyboard && widget.selection != old.selection) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _inputFocusNode.requestFocus());
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
      runGuarded(context,
          () => widget.bridge.sendDirectMessage(peerId: widget.dmPeerId!, payload: text));
      widget.onDmSent();
    } else if (widget.isAllMode) {
      runGuarded(
          context, () => widget.bridge.sendMessage(channelId: kAllChannelId, payload: text));
      widget.onOneShotSent?.call();
    } else {
      for (final ch in widget.selectedChannels) {
        runGuarded(context, () => widget.bridge.sendMessage(channelId: ch.id, payload: text));
      }
    }
  }

  void _sendFlash() {
    if (widget.isDmMode) {
      runGuarded(context, () => widget.bridge.sendDmFlash(widget.dmPeerId!));
      widget.onDmSent();
    } else if (widget.isAllMode) {
      runGuarded(context, () => widget.bridge.sendFlash(kAllChannelId));
      widget.onOneShotSent?.call();
    } else {
      for (final ch in widget.selectedChannels) {
        runGuarded(context, () => widget.bridge.sendFlash(ch.id));
      }
    }
  }

  void _clear(String? channelId) {
    runGuarded(context, () async {
      await widget.bridge.clearMessages(channelId: channelId);
      widget.onMessagesCleared(channelId);
    });
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
    if (path == null || !mounted) return;
    // DM → that thread; ALL / multi-channel → everything (null); single → that one.
    final channelId = widget.isDmMode
        ? DmThread(widget.dmPeerId!).key
        : (!widget.isAllMode && widget.selectedChannels.length == 1)
            ? widget.selectedChannels.first.id
            : null;
    runGuarded(
        context, () => widget.bridge.exportMessages(channelId: channelId, path: path));
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
                _clear(DmThread(widget.dmPeerId!).key);
              } else if (widget.isAllMode) {
                _clear(null); // clear everything
              } else {
                for (final ch in widget.selectedChannels) {
                  _clear(ch.id);
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
          focusNode: _inputFocusNode,
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
