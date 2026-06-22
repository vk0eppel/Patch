import 'dart:async';

import 'package:flutter/widgets.dart';

import '../bridge/bridge_client.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/message.dart';

/// Single shared store for domain state both screens read (candidate 2,
/// ADR-0004). A [ChangeNotifier] that owns the fetched domain state and reduces
/// the typed engine pushes that affect it, so the request/response fetches can
/// return `Future`s instead of round-tripping through a stringly-typed event
/// stream — and a change made in one screen is reflected in the other via
/// [notifyListeners].
///
/// Migrated incrementally: this slice owns **peers**. Channels, config, and
/// messages move here in later slices; until then the screens keep handling
/// those pushes themselves (both the store and the screens subscribe to
/// `bridge.pushes`, each reducing the domains it owns).
class AppStore extends ChangeNotifier {
  AppStore(this._bridge) {
    _sub = _bridge.pushes.listen(_onPush);
  }

  final BridgeClient _bridge;
  StreamSubscription<PatchEvent>? _sub;

  /// Coalesces `PeersChanged` bursts (one per received packet) into a single
  /// refetch — moved here from the home screen.
  Timer? _peersRefresh;

  List<PeerInfo> _peers = const [];
  List<PeerInfo> get peers => _peers;

  /// Null until the first load completes. Both screens read config-derived
  /// values from here (#56); a mutation in one screen refetches and notifies,
  /// so the other reflects it with no cross-screen event.
  AppConfig? _config;
  AppConfig? get config => _config;

  /// Load initial domain state. Call once after the engine has connected.
  Future<void> start() async {
    await Future.wait([refreshPeers(), refreshConfig()]);
  }

  /// Refetch the config and notify; throws are swallowed (keep the last good
  /// config rather than blanking the UI).
  Future<void> refreshConfig() async {
    try {
      _config = await _bridge.getConfig();
      notifyListeners();
    } catch (e) {
      debugPrint('AppStore.refreshConfig failed: $e');
    }
  }

  /// Refetch the peer list and notify. Failures are non-critical (a background
  /// refresh) — keep the current list and log rather than surfacing an error.
  Future<void> refreshPeers() async {
    try {
      _peers = await _bridge.getPeers();
      notifyListeners();
    } catch (e) {
      debugPrint('AppStore.refreshPeers failed: $e');
    }
  }

  void _schedulePeersRefresh() {
    _peersRefresh ??= Timer(const Duration(milliseconds: 800), () {
      _peersRefresh = null;
      refreshPeers();
    });
  }

  /// Exhaustive over [PatchEvent]: the store reduces the domains it owns and
  /// explicitly ignores the rest (the screens still handle those). A new event
  /// variant is a build break here too.
  void _onPush(PatchEvent event) {
    switch (event) {
      // The presence payload is dropped engine-side (see ADR-0004), so coalesce
      // the burst into one full-list refresh.
      case PeersChanged():
        _schedulePeersRefresh();
      // A full refetch (not a targeted drop) so a static-peer-backed entry
      // reappears as ManualIp rather than vanishing.
      case PeerExpired():
        refreshPeers();
      // The local name changed — refetch config so both screens reflect it.
      case ClientNameChanged():
        refreshConfig();
      // Not yet owned by the store — handled by the screens.
      case MessageReceived():
      case DeliveryUpdated():
      case Flashed():
      case ChannelsOffered():
      case PermissionDenied():
      case ChannelsChanged():
        break;
    }
  }

  @override
  void dispose() {
    _peersRefresh?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}

/// Provides the [AppStore] to the widget tree. `of` subscribes the caller to
/// rebuilds on [AppStore.notifyListeners]; `read` looks it up without
/// subscribing (for one-off reads in callbacks / event handlers).
class AppStoreScope extends InheritedNotifier<AppStore> {
  const AppStoreScope({
    super.key,
    required AppStore store,
    required super.child,
  }) : super(notifier: store);

  static AppStore of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppStoreScope>();
    assert(scope?.notifier != null, 'No AppStoreScope found in context');
    return scope!.notifier!;
  }

  static AppStore read(BuildContext context) {
    final scope =
        context.getInheritedWidgetOfExactType<AppStoreScope>();
    assert(scope?.notifier != null, 'No AppStoreScope found in context');
    return scope!.notifier!;
  }
}
