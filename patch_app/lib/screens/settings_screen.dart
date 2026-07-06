import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../bridge/bridge_client.dart';
import '../src/rust/api.dart' as rust;
import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/message.dart';
import '../store/app_store.dart';
import '../theme/patch_theme.dart';
import '../util/run_guarded.dart';
import '../presenters/settings/behavior_presenter.dart';
import '../presenters/settings/channels_import_presenter.dart';
import '../presenters/settings/identity_presenter.dart';
import '../presenters/settings/macros_import_presenter.dart';
import '../presenters/settings/macros_section_presenter.dart';
import '../presenters/settings/network_presenter.dart';
import '../presenters/settings/static_peers_presenter.dart';
import '../widgets/settings/behavior_section.dart';
import '../widgets/settings/identity_section.dart';
import '../widgets/settings/macros_sections.dart';
import '../widgets/settings/network_section.dart';
import '../widgets/settings/static_peers_section.dart';
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
  StreamSubscription<PatchEvent>? _pushSub;

  // Section presenters (#140): each owns its validate→save→refetch loops;
  // the section widgets own presentation only (ADR-0005).
  late final _identityPresenter = IdentityPresenter(
    setClientName: (name) => rust.setClientName(name: name),
    setRole: widget.bridge.setRole,
    refreshConfig: () => AppStoreScope.read(context).refreshConfig(),
  );
  late final _behaviorPresenter = BehaviorPresenter(
    setFlashOnMessage: (enabled) => rust.setFlashOnMessage(enabled: enabled),
    setFlashOnCritical: (enabled) => rust.setFlashOnCritical(enabled: enabled),
    setAudibleAlert: (enabled) => rust.setAudibleAlert(enabled: enabled),
    setFlashWholeScreen: (enabled) =>
        rust.setFlashWholeScreen(enabled: enabled),
    setHideKeyboard: (enabled) => rust.setHideKeyboard(enabled: enabled),
    setFlashCount: (count) => rust.setFlashCount(count: count),
    setMacrosColumns: (columns) => rust.setMacrosColumns(columns: columns),
    refreshConfig: () => AppStoreScope.read(context).refreshConfig(),
  );
  late final _staticPeersPresenter = StaticPeersPresenter(
    addStaticPeer: (a, port, label) =>
        rust.addStaticPeer(address: a, port: port, label: label),
    removeStaticPeer: (address, port) =>
        rust.removeStaticPeer(address: address, port: port),
    refreshConfig: () => AppStoreScope.read(context).refreshConfig(),
    refreshPeers: () => AppStoreScope.read(context).refreshPeers(),
  );
  late final _networkPresenter = NetworkPresenter(
    setInterface: (name) => rust.setInterface(name: name),
    setHeartbeatInterval: widget.bridge.setHeartbeatInterval,
    setOscPort: (port) => rust.setOscPort(port: port),
    refreshConfig: () => AppStoreScope.read(context).refreshConfig(),
    getInterfaces: widget.bridge.getInterfaces,
  );
  late final _channelsImportPresenter = ChannelsImportPresenter(
    requestChannels: (peerId) => rust.requestChannels(peerId: peerId),
  );
  late final _macrosImportPresenter = MacrosImportPresenter(
    requestGlobalMacros: (peerId) => rust.requestGlobalMacros(peerId: peerId),
    previewGlobalMacros: widget.bridge.previewGlobalMacros,
  );
  late final _macrosSectionPresenter = MacrosSectionPresenter(
    upsertChannelMacro: ({
      required channelId,
      originalLabel,
      required label,
      required payload,
      keyBinding,
      priority = 1,
      midiNote,
      midiCc,
      osc,
    }) {
      final flatOsc = flattenMacroOsc(osc);
      return widget.bridge.upsertMacro(
        channelId: channelId,
        originalLabel: originalLabel,
        label: label,
        payload: payload,
        keyBinding: keyBinding,
        priority: priority,
        midiNote: midiNote,
        midiCc: midiCc,
        oscAddress: flatOsc.address,
        oscPort: flatOsc.port,
        oscPath: flatOsc.path,
        oscArg: flatOsc.arg,
        oscArgType: flatOsc.argType,
      );
    },
    upsertGlobalMacro: ({
      originalLabel,
      required label,
      required payload,
      keyBinding,
      priority = 1,
      midiNote,
      midiCc,
      osc,
    }) {
      final flatOsc = flattenMacroOsc(osc);
      return widget.bridge.upsertGlobalMacro(
        originalLabel: originalLabel,
        label: label,
        payload: payload,
        keyBinding: keyBinding,
        priority: priority,
        midiNote: midiNote,
        midiCc: midiCc,
        oscAddress: flatOsc.address,
        oscPort: flatOsc.port,
        oscPath: flatOsc.path,
        oscArg: flatOsc.arg,
        oscArgType: flatOsc.argType,
      );
    },
  );

  // Channels are owned by the AppStore (#57).
  List<PatchChannel> get _channels => AppStoreScope.of(context).channels;

  /// "vX.Y.Z (build)" from the bundle's own Info.plist — null until
  /// PackageInfo resolves (fast, but not synchronous on first build).
  String? _versionLabel;

  // Config-derived values are owned by the AppStore (#56); reading via
  // `of(context)` rebuilds when config changes. Defaults apply before first load.
  AppConfig? get _config => AppStoreScope.of(context).config;
  List<MacroMessage> get _globalMacros => _config?.globalMacros ?? const [];
  List<StaticPeerInfo> get _staticPeers => _config?.staticPeers ?? const [];

  // Available network interfaces (from getInterfaces — not config), shown in
  // the Static Peers section.
  List<Map<String, String>> _interfaces = [];

  // Live peers (for "import channels from a peer") — owned by the AppStore.
  List<PeerInfo> get _peers => AppStoreScope.of(context).peers;

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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _pushSub?.cancel();
    super.dispose();
  }

  /// The interface list shown in the Static Peers section ("This device: …").
  /// Fetched via [NetworkPresenter] — moves with that section in #141.
  Future<void> _loadInterfaces() async {
    final ifaces = await _networkPresenter.loadInterfaces();
    if (mounted) setState(() => _interfaces = ifaces);
  }

  /// Typed engine pushes (slice 1.3, ADR-0004). Exhaustive over [PatchEvent];
  /// variants this screen doesn't consume are explicitly ignored so a new event
  /// can't be silently dropped.
  void _handlePush(PatchEvent event) {
    switch (event) {
      // Consumed inside IdentitySection (saved tick); channels are owned by
      // the AppStore now — it reduces ChannelsChanged.
      case ClientNameChanged():
      case ChannelsChanged():
        break;
      case ChannelsOffered(:final fromName, :final channels):
        final fresh = _channelsImportPresenter.handleOffer(
          offered: channels,
          existing: _channels,
        );
        if (fresh != null && mounted) {
          _showOfferDialog(fromName, channels, fresh);
        }
      case GlobalMacrosOffered(:final fromName, :final globalMacros):
        if (!_macrosImportPresenter.handleOffer()) break;
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
    runGuarded(context, () => _channelsImportPresenter.request(peerId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Requesting channels from $name…'),
        duration: const Duration(seconds: 2),
      ),
    );
    // Clear the flag if no offer arrives (peer offline / not a Patch node), so a
    // later unsolicited announce can't pop a stale dialog.
    Future.delayed(const Duration(seconds: 6), _channelsImportPresenter.timeout);
  }

  /// Preview a peer's offered channels ([fresh] — the ones we're missing,
  /// computed by [ChannelsImportPresenter]) and merge-adopt them.
  void _showOfferDialog(
    String fromName,
    List<PatchChannel> channels,
    List<PatchChannel> fresh,
  ) {
    final existing = _channels.map((c) => c.id).toSet();
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
    runGuarded(context, () => _macrosImportPresenter.request(peerId));
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
      if (mounted && _macrosImportPresenter.timeout()) {
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
        future: _macrosImportPresenter.preview(offered),
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
              runGuarded(context, () => rust.deleteChannel(id: channel.id));
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
          // ── Identity (#140: section widget + presenter) ─────────────────
          KeyedSubtree(
            key: _sectionKeys[0],
            child: IdentitySection(
              presenter: _identityPresenter,
              pushes: widget.bridge.pushes,
            ),
          ),

          const SizedBox(height: 32),

          // ── Network (#140: section widget + presenter) ───────────────────
          KeyedSubtree(
            key: _sectionKeys[1],
            child: NetworkSection(presenter: _networkPresenter),
          ),

          const SizedBox(height: 32),

          // ── Static Peers (#141: section widget + presenter) ─────────
          KeyedSubtree(
            key: _sectionKeys[2],
            child: StaticPeersSection(
              presenter: _staticPeersPresenter,
              staticPeers: _staticPeers,
              interfaces: _interfaces,
            ),
          ),

          const SizedBox(height: 32),

          // ── Behavior (#141: section widget + presenter) ──────────────────
          KeyedSubtree(
            key: _sectionKeys[3],
            child: BehaviorSection(presenter: _behaviorPresenter),
          ),

          const SizedBox(height: 32),

          // ── Global Macros (#141) — shown before "Channels & Macros":
          // global macros are the everyday default quick-sends; per-channel
          // customisation is the next step.
          KeyedSubtree(
            key: _sectionKeys[4],
            child: GlobalMacrosSection(
              bridge: widget.bridge,
              presenter: _macrosSectionPresenter,
              globalMacros: _globalMacros,
              onImportFromPeer: _showImportMacrosFromPeer,
              onReset: () =>
                  _applyConfigChange(() => rust.resetGlobalMacros()),
            ),
          ),

          const SizedBox(height: 32),

          // ── Channels & Macros (#141) ──────────────────────────────────────
          KeyedSubtree(
            key: _sectionKeys[5],
            child: ChannelsMacrosSection(
              bridge: widget.bridge,
              presenter: _macrosSectionPresenter,
              channels: _channels,
              onImportFromPeer: _showImportFromPeer,
              onDeleteChannel: _confirmDeleteChannel,
            ),
          ),

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
  _HelpEntry('Quick Start',          'assets/docs/quick-start.md'),
  _HelpEntry('Networking',           'assets/docs/networking.md'),
  _HelpEntry('Channels & Show Files','assets/docs/channels-and-show-files.md'),
  _HelpEntry('OSC Integration',      'assets/docs/osc-integration.md'),
  _HelpEntry('Integrations',         'assets/docs/integrations.md'),
  _HelpEntry('Troubleshooting',      'assets/docs/troubleshooting.md'),
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

// ── Network interface picker ──────────────────────────────────────────────────

