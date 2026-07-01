import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/message.dart';
import '../store/app_store.dart';
import '../theme/patch_theme.dart';
import '../util/run_guarded.dart';
import '../widgets/bounded_int_field.dart';
import '../widgets/interface_picker.dart';
import 'help_screen.dart';

/// Settings screen — identity, channels, shortcuts, and show file management.
class SettingsScreen extends StatefulWidget {
  final BridgeClient bridge;

  const SettingsScreen({
    super.key,
    required this.bridge,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _nameCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  StreamSubscription<PatchEvent>? _pushSub;
  bool _nameSaved = false;
  bool _roleSaved = false;
  // Channels are owned by the AppStore (#57).
  List<PatchChannel> get _channels => AppStoreScope.of(context).channels;

  /// "vX.Y.Z (build)" from the bundle's own Info.plist — null until
  /// PackageInfo resolves (fast, but not synchronous on first build).
  String? _versionLabel;

  // Config-derived values are owned by the AppStore (#56); reading via
  // `of(context)` rebuilds when config changes. Defaults apply before first load.
  AppConfig? get _config => AppStoreScope.of(context).config;
  bool get _flashOnCritical => _config?.flashOnCritical ?? true;
  bool get _flashOnMessage => _config?.flashOnMessage ?? false;
  int get _flashCount => _config?.flashCount ?? 4;
  bool get _hideKeyboard => _config?.hideKeyboard ?? true;
  bool get _audibleAlert => _config?.audibleAlert ?? false;
  bool get _flashWholeScreen => _config?.flashWholeScreen ?? false;
  int get _macrosColumns => _config?.macrosColumns ?? 1;
  List<MacroMessage> get _globalMacros => _config?.globalMacros ?? const [];
  String? get _selectedInterface => _config?.networkInterface; // null = auto
  int get _heartbeatInterval => _config?.heartbeatIntervalSecs ?? 7;
  int get _oscPort => _config?.oscPort ?? 9000;
  List<StaticPeerInfo> get _staticPeers => _config?.staticPeers ?? const [];

  // Available network interfaces (from getInterfaces — not config) + the
  // transient "applied" tick.
  List<Map<String, String>> _interfaces = [];
  bool _interfaceApplied = false;

  // Live peers (for "import channels from a peer") — owned by the AppStore.
  List<PeerInfo> get _peers => AppStoreScope.of(context).peers;

  /// True between sending a channels request and receiving the offer, so an
  /// unsolicited `channels_offered` (a peer announcing without us asking) is
  /// ignored rather than popping a dialog.
  bool _awaitingOffer = false;

  /// Same purpose as [_awaitingOffer], but for global-macro import — kept
  /// separate so the two request/offer flows can't cross-trigger each other's
  /// dialog if both are in flight at once.
  bool _awaitingMacrosOffer = false;

  // ── Section nav (#73) ──────────────────────────────────────────────────
  // A left rail (or, below _kNarrowBreakpoint, an app-bar jump menu) lets a
  // crew member skip straight to a section instead of scrolling the whole
  // page. Below the width threshold there's no room for a permanent rail.
  static const _kNarrowBreakpoint = 600.0;
  static const _sectionTitles = [
    'Identity',
    'Network',
    'Static Peers',
    'Behavior',
    'Global Macros',
    'Channels & Macros',
    'Help',
  ];
  final List<GlobalKey> _sectionKeys =
      List.generate(_sectionTitles.length, (_) => GlobalKey());
  final _viewportKey = GlobalKey();
  final _scrollController = ScrollController();
  int _activeSection = 0;
  // True while a tap-triggered scroll animation is in flight — alignment: 0
  // doesn't always land the header at *exactly* the viewport top (sub-pixel
  // rounding), so the scrollspy below can disagree with the section the user
  // just tapped for a frame or two. Suppress it until the animation settles.
  bool _programmaticScroll = false;

  // Scrollspy: the active section is whichever header has most recently
  // scrolled past the top of the viewport — sections are in document order,
  // so the first one that *hasn't* passed yet ends the search.
  void _onScroll() {
    if (_programmaticScroll) return;
    final viewportBox =
        _viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null) return;
    final viewportTop = viewportBox.localToGlobal(Offset.zero).dy;

    // No default of 0 here — an indeterminate frame (no section's box
    // resolved yet) must leave the current highlight alone, not jump to
    // Identity.
    int? active;
    for (var i = 0; i < _sectionKeys.length; i++) {
      final box =
          _sectionKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      if (box.localToGlobal(Offset.zero).dy <= viewportTop + 1) {
        active = i;
      } else {
        break;
      }
    }
    if (active != null && active != _activeSection) {
      setState(() => _activeSection = active!);
    }
  }

  Future<void> _scrollToSection(int index) async {
    final ctx = _sectionKeys[index].currentContext;
    if (ctx == null) return;
    // Set the active section immediately rather than waiting on the scroll
    // listener — the listener is suppressed for the duration of the
    // animation below, so this is the only thing driving the highlight.
    setState(() => _activeSection = index);
    _programmaticScroll = true;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: 0,
    );
    _programmaticScroll = false;
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _pushSub = widget.bridge.pushes.listen(_handlePush);
    // Config/peers/channels are owned by the AppStore; the interface list is a
    // local, single-consumer fetch (#59).
    _loadInterfaces();
    // Refresh peers via the store now that the screen is up (peers are owned by
    // the AppStore — #55). Post-frame so the InheritedNotifier is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppStoreScope.read(context).refreshPeers();
    });
    // Read the version straight from the bundle (same source as the OS-native
    // About panel) so this label can't itself drift from what's installed.
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() {
        _versionLabel = 'v${info.version} (${info.buildNumber})';
      });
    });
  }

  @override
  void dispose() {
    _store?.removeListener(_seedControllersFromConfig);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _nameCtrl.dispose();
    _roleCtrl.dispose();
    _pushSub?.cancel();
    super.dispose();
  }

  AppStore? _store;
  bool _controllersSeeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Seed the name/role text controllers from config once it's loaded (the
    // config arm used to do this on every event). Seed-once so the user's edits
    // aren't clobbered by a later config notify (#56).
    final store = AppStoreScope.of(context);
    if (!identical(_store, store)) {
      _store?.removeListener(_seedControllersFromConfig);
      _store = store;
      _store!.addListener(_seedControllersFromConfig);
    }
    _seedControllersFromConfig();
  }

  void _seedControllersFromConfig() {
    if (_controllersSeeded) return;
    final cfg = _store?.config;
    if (cfg == null) return;
    _controllersSeeded = true;
    _nameCtrl.text = cfg.clientName;
    _roleCtrl.text = cfg.role ?? '';
  }

  Future<void> _loadInterfaces() async {
    try {
      final ifaces = await widget.bridge.getInterfaces();
      if (!mounted) return;
      setState(() {
        _interfaces =
            ifaces.map((i) => {'name': i.name, 'ip': i.ip}).toList();
      });
    } catch (e) {
      debugPrint('getInterfaces failed: $e'); // non-critical — picker stays empty
    }
  }

  /// Typed engine pushes (slice 1.3, ADR-0004). Exhaustive over [PatchEvent];
  /// variants this screen doesn't consume are explicitly ignored so a new event
  /// can't be silently dropped.
  void _handlePush(PatchEvent event) {
    switch (event) {
      case ClientNameChanged():
        // The local name was saved — flash the "saved" tick (payload unused).
        setState(() => _nameSaved = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _nameSaved = false);
        });
      // Channels are owned by the AppStore now — it reduces ChannelsChanged.
      case ChannelsChanged():
        break;
      case ChannelsOffered(:final fromName, :final channels):
        if (!_awaitingOffer) break; // ignore unsolicited announces
        _awaitingOffer = false;
        if (mounted) _showOfferDialog(fromName, channels);
      case GlobalMacrosOffered(:final fromName, :final globalMacros):
        if (!_awaitingMacrosOffer) break; // ignore unsolicited announces
        _awaitingMacrosOffer = false;
        if (mounted) _showMacrosOfferDialog(fromName, globalMacros);
      // Not consumed by settings — handled on the home screen.
      case MessageReceived():
      case DeliveryUpdated():
      case Flashed():
      case PeerExpired():
      case PeersChanged():
      case PermissionDenied():
        break;
    }
  }

  /// Run a config-mutating command, then refetch the config so the UI reflects
  /// the new state. Replaces the old `config_updated` round-trip event
  /// (ADR-0004); failures surface via [runGuarded].
  void _applyConfigChange(Future<void> Function() action) {
    final store = AppStoreScope.read(context);
    runGuarded(context, () async {
      await action();
      await store.refreshConfig();
    });
  }

  void _saveName() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    runGuarded(context, () => widget.bridge.setClientName(name));
  }

  /// Save the role (empty string clears it). No engine event echoes back, so
  /// show the "saved" tick optimistically for a moment.
  void _saveRole() {
    _applyConfigChange(() => widget.bridge.setRole(_roleCtrl.text));
    setState(() => _roleSaved = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _roleSaved = false);
    });
  }

  // ── Import channels from a peer over the network ──────────────────────────

  /// Pick a peer (with a resolved address) to request a channel layout from.
  void _showImportFromPeer() {
    AppStoreScope.read(context).refreshPeers(); // refresh before showing it
    final candidates =
        _peers.where((p) => p.address.isNotEmpty && p.oscPort > 0).toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import channels from…'),
        content: SizedBox(
          width: double.infinity,
          child: candidates.isEmpty
              ? const Text(
                  'No peers with a known address are online yet. Wait for a peer '
                  'to appear in the peers panel, then try again.',
                  style: TextStyle(color: PatchTheme.textSecondary),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Pick a peer to copy their channel layout from. Only channels "
                      "you don't already have are added — your channels are kept.",
                      style: TextStyle(
                        color: PatchTheme.textSecondary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...candidates.map((p) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline, size: 18),
                          title: Text(p.peerName),
                          subtitle: Text(p.address),
                          onTap: () {
                            Navigator.pop(ctx);
                            _requestFromPeer(p.peerId, p.peerName);
                          },
                        )),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _requestFromPeer(String peerId, String name) {
    setState(() => _awaitingOffer = true);
    runGuarded(context, () => widget.bridge.requestChannels(peerId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Requesting channels from $name…'),
        duration: const Duration(seconds: 2),
      ),
    );
    // Clear the flag if no offer arrives (peer offline / not a Patch node), so a
    // later unsolicited announce can't pop a stale dialog.
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _awaitingOffer) setState(() => _awaitingOffer = false);
    });
  }

  /// Preview a peer's offered channels and merge-adopt the ones we're missing.
  void _showOfferDialog(String fromName, List<PatchChannel> channels) {
    final existing = _channels.map((c) => c.id).toSet();
    final fresh = channels.where((c) => !existing.contains(c.id)).toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Channels from $fromName'),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                fresh.isEmpty
                    ? 'You already have all ${channels.length} of their channels.'
                    : '${fresh.length} new of ${channels.length} will be added '
                        '(existing channels are kept unchanged):',
                style: const TextStyle(
                  color: PatchTheme.textSecondary,
                  fontSize: PatchTheme.fontSizeSmall,
                ),
              ),
              const SizedBox(height: 12),
              ...channels.map((c) {
                final isNew = !existing.contains(c.id);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: c.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.displayName,
                          style: const TextStyle(color: PatchTheme.textPrimary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        isNew ? 'new' : 'have',
                        style: TextStyle(
                          color:
                              isNew ? PatchTheme.success : PatchTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: fresh.isEmpty
                ? null
                : () {
                    final messenger = ScaffoldMessenger.of(context);
                    runGuarded(context, () async {
                      final added = await widget.bridge.adoptChannels(fresh);
                      messenger.showSnackBar(SnackBar(
                        content: Text(added == 0
                            ? 'No new channels to add — you already have them all'
                            : 'Added $added channel${added == 1 ? '' : 's'}'),
                        duration: const Duration(seconds: 3),
                      ));
                    });
                    Navigator.pop(ctx);
                  },
            child: Text(fresh.isEmpty ? 'Nothing to add' : 'Add ${fresh.length}'),
          ),
        ],
      ),
    );
  }

  // ── Import global macros from a peer over the network ─────────────────────

  /// Pick a peer (with a resolved address) to request global macros from.
  /// Same peer filter as [_showImportFromPeer] — not restricted to
  /// online-only; an unreachable peer simply times out.
  void _showImportMacrosFromPeer() {
    AppStoreScope.read(context).refreshPeers(); // refresh before showing it
    final candidates =
        _peers.where((p) => p.address.isNotEmpty && p.oscPort > 0).toList();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Import macros from…'),
        content: SizedBox(
          width: double.infinity,
          child: candidates.isEmpty
              ? const Text(
                  'No peers with a known address are online yet. Wait for a peer '
                  'to appear in the peers panel, then try again.',
                  style: TextStyle(color: PatchTheme.textSecondary),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      "Pick a peer to copy their global macros from. Macros you "
                      "already have, exactly, are skipped — yours are kept.",
                      style: TextStyle(
                        color: PatchTheme.textSecondary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...candidates.map((p) => ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.person_outline, size: 18),
                          title: Text(p.peerName),
                          subtitle: Text(p.address),
                          onTap: () {
                            Navigator.pop(ctx);
                            _requestMacrosFromPeer(p.peerId, p.peerName);
                          },
                        )),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _requestMacrosFromPeer(String peerId, String name) {
    setState(() => _awaitingMacrosOffer = true);
    runGuarded(context, () => widget.bridge.requestGlobalMacros(peerId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Requesting macros from $name…'),
        duration: const Duration(seconds: 2),
      ),
    );
    // Clear the flag if no offer arrives (peer offline / older version that
    // doesn't speak the macros-import protocol), so a later unsolicited
    // announce can't pop a stale dialog.
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted && _awaitingMacrosOffer) {
        setState(() => _awaitingMacrosOffer = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No response from $name — they may be running an older version '
              "that doesn't support macro import.",
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    });
  }

  /// Preview a peer's offered global macros — classified Rust-side
  /// (`previewGlobalMacros`) so the warning lines reuse the exact same
  /// OSC-target/binding-collision logic `adoptGlobalMacros` will apply — and
  /// merge-adopt the ones that aren't exact duplicates.
  void _showMacrosOfferDialog(String fromName, List<MacroMessage> offered) {
    showDialog(
      context: context,
      builder: (ctx) => FutureBuilder<List<MacroImportOutcome>>(
        future: widget.bridge.previewGlobalMacros(offered),
        builder: (ctx, snapshot) {
          if (!snapshot.hasData) {
            return const AlertDialog(
              content: SizedBox(
                height: 80,
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          final outcomes = snapshot.data!;
          final newCount = outcomes.whereType<MacroAdded>().length +
              outcomes.whereType<MacroAddedBindingDropped>().length;
          final warnings = <String>[
            for (final o in outcomes)
              if (o is MacroAddedBindingDropped)
                '${o.macro.label}: ${o.reason}'
              else if (o is MacroSkipped)
                '${o.label}: ${o.reason}',
          ];
          return AlertDialog(
            title: Text('Macros from $fromName'),
            content: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    newCount == 0
                        ? 'You already have all ${outcomes.length} of their macros.'
                        : '$newCount new of ${outcomes.length} will be added '
                            '(your existing macros are kept unchanged):',
                    style: const TextStyle(
                      color: PatchTheme.textSecondary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  if (warnings.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    ...warnings.map((w) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Text(
                            w,
                            style: const TextStyle(
                              color: PatchTheme.warning,
                              fontSize: 11,
                            ),
                          ),
                        )),
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
                onPressed: newCount == 0
                    ? null
                    : () {
                        final messenger = ScaffoldMessenger.of(context);
                        final store = AppStoreScope.read(context);
                        runGuarded(context, () async {
                          final result =
                              await widget.bridge.adoptGlobalMacros(offered);
                          await store.refreshConfig();
                          final added = result.whereType<MacroAdded>().length +
                              result
                                  .whereType<MacroAddedBindingDropped>()
                                  .length;
                          messenger.showSnackBar(SnackBar(
                            content: Text(added == 0
                                ? 'No new macros to add — you already have them all'
                                : 'Added $added macro${added == 1 ? '' : 's'}'),
                            duration: const Duration(seconds: 3),
                          ));
                        });
                        Navigator.pop(ctx);
                      },
                child:
                    Text(newCount == 0 ? 'Nothing to add' : 'Add $newCount'),
              ),
            ],
          );
        },
      ),
    );
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
              runGuarded(context, () => widget.bridge.deleteChannel(channel.id));
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

  Widget _jumpMenuButton() {
    return PopupMenuButton<int>(
      icon: const Icon(Icons.list_alt_outlined),
      tooltip: 'Jump to section',
      onSelected: _scrollToSection,
      itemBuilder: (context) => [
        for (var i = 0; i < _sectionTitles.length; i++)
          PopupMenuItem(value: i, child: Text(_sectionTitles[i])),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < _kNarrowBreakpoint;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SETTINGS'),
        toolbarHeight: PatchTheme.headerHeight,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: narrow ? [_jumpMenuButton()] : null,
      ),
      body: narrow
          ? _buildContent()
          : Row(
              children: [
                _SettingsRail(
                  titles: _sectionTitles,
                  activeIndex: _activeSection,
                  onTap: _scrollToSection,
                ),
                const VerticalDivider(width: 1, color: PatchTheme.border),
                Expanded(child: _buildContent()),
              ],
            ),
    );
  }

  Widget _buildContent() {
    // SingleChildScrollView + Column, not ListView — a lazily-built ListView
    // disposes section headers once they scroll past its cache extent, which
    // nulls out their GlobalKey context and breaks the scrollspy in _onScroll
    // (it would fall back to section 0). Settings is a bounded page, so
    // there's no virtualization to gain here.
    return SingleChildScrollView(
      key: _viewportKey,
      controller: _scrollController,
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Identity ────────────────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[0],
            child: Row(children: [
              Expanded(child: _SectionHeader('Identity')),
              _resetButton('Identity', () {
                final name = Platform.environment['USER'] ??
                    Platform.environment['USERNAME'] ??
                    'crew';
                _nameCtrl.text = name;
                // setClientName is push-driven (ClientNameChanged → store);
                // setRole has no push, so refetch config via _applyConfigChange.
                runGuarded(context, () => widget.bridge.setClientName(name));
                _roleCtrl.clear();
                _applyConfigChange(() => widget.bridge.setRole(null));
              }),
            ]),
          ),
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
          const SizedBox(height: 12),
          const Text(
            'Optional role (e.g. "FOH", "Monitors", "PM") — shown next to your name '
            'in other crew\'s peers panel. Leave blank for none.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 10),
          _UsernameField(
            controller: _roleCtrl,
            saved: _roleSaved,
            onSave: _saveRole,
            hintText: 'Your role (optional)',
            icon: Icons.badge_outlined,
          ),

          const SizedBox(height: 32),

          // ── Network ──────────────────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[1],
            child: Row(children: [
              const Expanded(child: _SectionHeader('Network')),
              IconButton(
                icon: const Icon(Icons.help_outline, size: 16),
                color: PatchTheme.textMuted,
                tooltip: 'Networking guide',
                onPressed: () => openHelp(context, assetPath: '../docs/networking.md', title: 'Networking'),
              ),
            ]),
          ),
          const SizedBox(height: 4),
          const Text(
            'Which network Patch announces discovery on. Patch always listens on every interface; '
            'this just scopes the beacon. Applies within a few seconds — no restart.',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeSmall),
          ),
          const SizedBox(height: 12),
          InterfacePicker(
            interfaces: _interfaces,
            selected: _selectedInterface,
            applied: _interfaceApplied,
            onSelect: (name) {
              final store = AppStoreScope.read(context);
              runGuarded(context, () async {
                await widget.bridge.setInterface(name ?? 'auto');
                await store.refreshConfig(); // picker reflects the new NIC
                if (!mounted) return;
                // Flash the "applied" tick (was the interface_changed event).
                setState(() => _interfaceApplied = true);
                Future.delayed(const Duration(seconds: 3), () {
                  if (mounted) setState(() => _interfaceApplied = false);
                });
              });
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Heartbeat interval',
                      style: TextStyle(
                        color: PatchTheme.textPrimary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    Text(
                      'How often (seconds) Patch announces itself. Lower = faster peer '
                      'detection but more traffic. Applies live, 1–60.',
                      style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              BoundedIntField(
                // Key by value so an external config refresh reseeds the field.
                key: ValueKey(_heartbeatInterval),
                value: _heartbeatInterval,
                min: 1,
                max: 60,
                suffix: 's',
                onSubmit: (secs) =>
                    _applyConfigChange(() => widget.bridge.setHeartbeatInterval(secs)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'OSC port',
                      style: TextStyle(
                        color: PatchTheme.textPrimary,
                        fontSize: PatchTheme.fontSizeSmall,
                      ),
                    ),
                    Text(
                      'UDP port for OSC discovery + messaging. All peers must share '
                      'it. Applies live (socket rebinds), 1024–65535.',
                      style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              BoundedIntField(
                key: ValueKey(_oscPort),
                value: _oscPort,
                min: 1024,
                max: 65535,
                onSubmit: (port) =>
                    _applyConfigChange(() => widget.bridge.setOscPort(port)),
              ),
              IconButton(
                icon: const Icon(Icons.help_outline, size: 16),
                color: PatchTheme.textMuted,
                tooltip: 'OSC integration guide',
                onPressed: () => openHelp(context, assetPath: '../docs/osc-integration.md', title: 'OSC Integration'),
              ),
            ],
          ),

          const SizedBox(height: 32),

          // ── Static Peers ─────────────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[2],
            child: Row(
              children: [
                Expanded(child: _SectionHeader('Static Peers')),
                IconButton(
                  icon: const Icon(Icons.help_outline, size: 16),
                  color: PatchTheme.textMuted,
                  tooltip: 'Networking guide',
                  onPressed: () => openHelp(context, assetPath: '../docs/networking.md', title: 'Networking'),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add peer'),
                  style: TextButton.styleFrom(foregroundColor: PatchTheme.accent),
                  onPressed: () => _showAddPeerDialog(context, widget.bridge),
                ),
                _resetButton('Static Peers', () {
                  final store = AppStoreScope.read(context);
                  runGuarded(context, () async {
                    for (final peer in List.of(_staticPeers)) {
                      await widget.bridge.removeStaticPeer(peer.address, peer.port);
                    }
                    await store.refreshConfig();
                    await store.refreshPeers();
                  });
                }),
              ],
            ),
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
                      fontSize: PatchTheme.fontSizeMedium,
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
                  onDelete: () {
                    final store = AppStoreScope.read(context);
                    runGuarded(context, () async {
                      await widget.bridge.removeStaticPeer(peer.address, peer.port);
                      await store.refreshConfig();
                      await store.refreshPeers();
                    });
                  },
                )),

          const SizedBox(height: 32),

          // ── Behavior ─────────────────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[3],
            child: Row(children: [
              Expanded(child: _SectionHeader('Behavior')),
              _resetButton('Behavior', () {
                // Values reflect after each mutation's config refetch (#56).
                _applyConfigChange(() => widget.bridge.setFlashOnCritical(true));
                _applyConfigChange(() => widget.bridge.setFlashOnMessage(false));
                _applyConfigChange(() => widget.bridge.setFlashCount(4));
                _applyConfigChange(() => widget.bridge.setHideKeyboard(true));
                _applyConfigChange(() => widget.bridge.setAudibleAlert(false));
                _applyConfigChange(() => widget.bridge.setMacrosColumns(1));
              }),
            ]),
          ),
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
            onChanged: (val) =>
                _applyConfigChange(() => widget.bridge.setFlashOnMessage(val)),
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
            onChanged: (val) =>
                _applyConfigChange(() => widget.bridge.setFlashOnCritical(val)),
          ),
          SwitchListTile(
            title: const Text(
              'Audible alert',
              style: TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeSmall),
            ),
            subtitle: const Text(
              'Play a sound when a channel flashes (critical / page / broadcast)',
              style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
            ),
            value: _audibleAlert,
            activeThumbColor: PatchTheme.accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) =>
                _applyConfigChange(() => widget.bridge.setAudibleAlert(val)),
          ),
          // Desktop-only — sandboxing makes drawing over other apps technically
          // impossible on iOS/Android, so the control is absent there entirely.
          if (Platform.isMacOS || Platform.isWindows) ...[
            SwitchListTile(
              title: const Text(
                'Flash whole screen',
                style: TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeSmall),
              ),
              subtitle: const Text(
                'Also pulse a full-screen overlay so a Flash is visible even when '
                'Patch isn\'t the focused app',
                style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
              ),
              value: _flashWholeScreen,
              activeThumbColor: PatchTheme.accent,
              contentPadding: EdgeInsets.zero,
              onChanged: (val) =>
                  _applyConfigChange(() => widget.bridge.setFlashWholeScreen(val)),
            ),
          ],
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
                  _applyConfigChange(() => widget.bridge.setFlashCount(val));
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
                  ButtonSegment(value: 3, label: Text('3')),
                ],
                selected: {_macrosColumns},
                onSelectionChanged: (s) =>
                    _applyConfigChange(() => widget.bridge.setMacrosColumns(s.first)),
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
              onChanged: (val) =>
                  _applyConfigChange(() => widget.bridge.setHideKeyboard(val)),
            ),
          ],

          const SizedBox(height: 32),

          // ── Global macros ─────────────────────────────────────────────
          // Shown before "Channels & Macros": global macros are the everyday
          // default quick-sends; per-channel customisation is the next step.
          KeyedSubtree(
            key: _sectionKeys[4],
            child: Row(children: [
              Expanded(child: _SectionHeader('Global Macros')),
              IconButton(
                icon: const Icon(Icons.cloud_download_outlined, size: 18),
                color: PatchTheme.textMuted,
                tooltip: 'Import macros from a peer',
                onPressed: _showImportMacrosFromPeer,
              ),
              _resetButton('Global Macros',
                  () => _applyConfigChange(() => widget.bridge.resetGlobalMacros())),
            ]),
          ),
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
          _GlobalMacrosEditor(macros: _globalMacros, bridge: widget.bridge),

          const SizedBox(height: 32),

          // ── Channels & macros ─────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[5],
            child: Row(
              children: [
                Expanded(child: _SectionHeader('Channels & Macros')),
                IconButton(
                  icon: const Icon(Icons.cloud_download_outlined, size: 18),
                  color: PatchTheme.textMuted,
                  tooltip: 'Import channels from a peer',
                  onPressed: _showImportFromPeer,
                ),
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
                  runGuarded(context, () => widget.bridge.resetChannels());
                }),
              ],
            ),
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

          const SizedBox(height: 32),

          // ── Help & Documentation ──────────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[6],
            child: const _SectionHeader('Help & Documentation'),
          ),
          const SizedBox(height: 8),
          ..._kHelpEntries.map((e) => ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.article_outlined, size: 18, color: PatchTheme.textMuted),
                title: Text(e.label, style: const TextStyle(fontSize: PatchTheme.fontSizeSmall)),
                onTap: () => openHelp(context, assetPath: e.assetPath, title: e.label),
              )),

          const SizedBox(height: 32),
          Center(
            child: Text(
              _versionLabel ?? '',
              style: const TextStyle(
                color: PatchTheme.textMuted,
                fontSize: PatchTheme.fontSizeSmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Help entry descriptor ─────────────────────────────────────────────────────

class _HelpEntry {
  final String label;
  final String assetPath;
  const _HelpEntry(this.label, this.assetPath);
}

const _kHelpEntries = [
  _HelpEntry('Quick Start',          '../docs/quick-start.md'),
  _HelpEntry('Networking',           '../docs/networking.md'),
  _HelpEntry('Channels & Show Files','../docs/channels-and-show-files.md'),
  _HelpEntry('OSC Integration',      '../docs/osc-integration.md'),
  _HelpEntry('Integrations',         '../docs/integrations.md'),
  _HelpEntry('Troubleshooting',      '../docs/troubleshooting.md'),
];

// ── Settings rail ─────────────────────────────────────────────────────────────

class _SettingsRail extends StatelessWidget {
  final List<String> titles;
  final int activeIndex;
  final ValueChanged<int> onTap;

  const _SettingsRail({
    required this.titles,
    required this.activeIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      color: PatchTheme.surface,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          for (var i = 0; i < titles.length; i++)
            InkWell(
              onTap: () => onTap(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: i == activeIndex
                          ? PatchTheme.accent
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
                child: Text(
                  titles[i],
                  style: TextStyle(
                    color: i == activeIndex
                        ? PatchTheme.textPrimary
                        : PatchTheme.textSecondary,
                    fontSize: PatchTheme.fontSizeSmall,
                    fontWeight: i == activeIndex ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
            ),
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
  final String hintText;
  final IconData icon;

  const _UsernameField({
    required this.controller,
    required this.saved,
    required this.onSave,
    this.hintText = 'Your name (shown to other crew)',
    this.icon = Icons.person_outline,
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
            decoration: InputDecoration(
              hintText: hintText,
              prefixIcon: Icon(icon, color: PatchTheme.textSecondary, size: 18),
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

// ── Macro helpers ─────────────────────────────────────────────────────────────

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
    return _MacroListCard(
      dotColor: channel.color,
      label: channel.displayName,
      macros: channel.macros,
      keyFor: (m) => '${channel.id}:${m.label}',
      emptyText: 'No macros yet',
      // Channel-macro CRUD refreshes the screens via the ChannelsChanged push
      // (no config refetch needed); runGuarded surfaces failures (ADR-0004).
      onUpsert: (ol, l, p, k, pr, mn, mc, osc) => runGuarded(
          context,
          () => bridge.upsertMacro(
                channelId: channel.id,
                originalLabel: ol,
                label: l,
                payload: p,
                keyBinding: k,
                priority: pr,
                midiNote: mn,
                midiCc: mc,
                oscAddress: osc?.address,
                oscPort: osc?.port,
                oscPath: osc?.path,
                oscArg: osc?.arg,
                oscArgType: osc?.argType ?? MacroOscArgType.string,
              )),
      onDelete: (m) => runGuarded(
          context, () => bridge.deleteMacro(channelId: channel.id, label: m.label)),
      onReorder: (labels) =>
          runGuarded(context, () => bridge.reorderMacros(channel.id, labels)),
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
              onChanged: (val) => runGuarded(
                  context, () => bridge.setChannelFlash(channel.id, flashOnMessage: val)),
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
              onChanged: (val) => runGuarded(
                  context, () => bridge.setChannelFlash(channel.id, flashOnCritical: val)),
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
                  onChanged: (val) => runGuarded(
                      context,
                      () => bridge.setChannelFlash(
                            channel.id,
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
    String? error;
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
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: PatchTheme.critical, fontSize: 11)),
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

                MacroOsc? osc;
                if (oscEnabled) {
                  final addr = oscAddrCtrl.text.trim();
                  final port = int.tryParse(oscPortCtrl.text.trim());
                  final path = oscPathCtrl.text.trim();
                  if (addr.isEmpty || port == null || port < 1 || port > 65535 || !path.startsWith('/')) {
                    setDialogState(() => error =
                        'OSC needs an IP, a port (1–65535), and a path starting with "/".');
                    return;
                  }
                  final a = oscArgCtrl.text.trim();
                  osc = MacroOsc(
                    address: addr,
                    port: port,
                    path: path,
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

  const _GlobalMacrosEditor({required this.macros, required this.bridge});

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
        await bridge.upsertGlobalMacro(
          originalLabel: ol,
          label: l,
          payload: p,
          keyBinding: k,
          priority: pr,
          midiNote: mn,
          midiCc: mc,
          oscAddress: osc?.address,
          oscPort: osc?.port,
          oscPath: osc?.path,
          oscArg: osc?.arg,
          oscArgType: osc?.argType ?? MacroOscArgType.string,
        );
        await store.refreshConfig();
      }),
      onDelete: (m) => runGuarded(context, () async {
        final store = AppStoreScope.read(context);
        await bridge.deleteGlobalMacro(m.label);
        await store.refreshConfig();
      }),
      onReorder: (labels) => runGuarded(context, () async {
        final store = AppStoreScope.read(context);
        await bridge.reorderGlobalMacros(labels);
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
                runGuarded(context, () => bridge.upsertChannel(id, name, _colorToHex(color)));
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
  final StaticPeerInfo peer;
  final VoidCallback onDelete;

  const _StaticPeerRow({required this.peer, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final address = peer.address;
    final port = peer.port;
    final label = peer.label;

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
                    fontSize: PatchTheme.fontSizeMedium,
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
              // Refetch config after adding so the parent's `config` arm
              // refreshes _staticPeers (replaces config_updated — ADR-0004).
              // Use the outer `context` (the dialog `ctx` is about to pop).
              final store = AppStoreScope.read(context);
              runGuarded(context, () async {
                await bridge.addStaticPeer(
                  address,
                  port,
                  label: label.isEmpty ? null : label,
                );
                await store.refreshConfig();
                // Refresh peers too — a static peer shows in the peers panel.
                // The store owns peers now (#55).
                await store.refreshPeers();
              });
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
