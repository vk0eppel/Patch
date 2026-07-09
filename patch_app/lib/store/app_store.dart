import 'dart:async';

import 'package:flutter/widgets.dart';

import '../bridge/bridge_client.dart';
import '../models/channel.dart';
import '../models/config.dart';
import '../models/delivery_tracker.dart';
import '../models/events.dart';
import '../models/message.dart';

/// Single shared store for domain state both screens read (candidate 2,
/// ADR-0004). A [ChangeNotifier] that owns the fetched domain state and reduces
/// the typed engine pushes that affect it, so the request/response fetches can
/// return `Future`s instead of round-tripping through a stringly-typed event
/// stream — and a change made in one screen is reflected in the other via
/// [notifyListeners].
///
/// Owns all shared domain state: peers, channels, config, and messages.
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

  List<PatchChannel> _channels = const [];
  List<PatchChannel> get channels => _channels;

  /// Mirror of the Rust ring-buffer cap (`MAX_BUFFER` in `state/mod.rs`) so the
  /// in-memory list doesn't grow unbounded over a long show.
  static const int _kMaxMessagesPerChannel = 500;

  /// Per-channel (and per-DM) message buffers, keyed by channel id / `dm:<peer>`.
  final Map<String, List<PatchMessage>> _messages = {};
  Map<String, List<PatchMessage>> get messages => _messages;

  /// Next value to stamp onto a message's [PatchMessage.localSeq] — global
  /// across every channel/DM, incrementing once per message this client
  /// stores, in true arrival order. Never derived from [PatchMessage.timestamp]
  /// (the sender's own clock) — see [PatchMessage.localSeq].
  int _nextLocalSeq = 0;
  int _stampSeq() => _nextLocalSeq++;

  /// Delivery status for Critical Messages we sent, keyed by message id.
  final DeliveryTracker _delivery = DeliveryTracker();
  Map<String, MessageDeliveryStatus> get delivery => _delivery.all;

  /// Whether the buffer for [channelId] has been fetched.
  bool hasMessages(String channelId) => _messages.containsKey(channelId);

  /// Fetch [channelId]'s history if not already loaded.
  Future<void> ensureMessages(String channelId) async {
    if (_messages.containsKey(channelId)) return;
    try {
      final fetched = await _bridge.getMessages(channelId);
      // A message can arrive (and be appended by _onPush) while the fetch is
      // in flight. Merge it after the history instead of overwriting it away
      // — the fetch snapshot may predate its store engine-side, so dropping
      // the pushed copy could lose it from the UI entirely. Dedup by id (the
      // snapshot may equally already include it) and restamp in final order
      // so localSeq keeps history before the just-arrived tail.
      final pushed = _messages[channelId] ?? const <PatchMessage>[];
      final fetchedIds = {for (final m in fetched) m.messageId};
      _messages[channelId] = [
        for (final m in fetched) m.withLocalSeq(_stampSeq()),
        for (final m in pushed)
          if (!fetchedIds.contains(m.messageId)) m.withLocalSeq(_stampSeq()),
      ];
      notifyListeners();
    } catch (e) {
      debugPrint('AppStore.ensureMessages($channelId) failed: $e');
    }
  }

  /// Drop the local buffer (and delivery entries) for [channelId], or all
  /// channels when null — after a `clearMessages` command.
  void dropMessages(String? channelId) {
    if (channelId != null) {
      final removed = _messages.remove(channelId);
      if (removed != null) {
        _delivery.clearForMessageIds(removed.map((m) => m.messageId));
      }
    } else {
      _messages.clear();
      _delivery.clearAll();
    }
    notifyListeners();
  }

  /// Load initial domain state. Call once after the engine has connected.
  Future<void> start() async {
    await Future.wait([refreshPeers(), refreshConfig(), refreshChannels()]);
  }

  /// Re-read everything fetched after the engine reported this subscriber's
  /// event stream lagged ([Resynced]) — dropped pushes may include
  /// MessageReceived, which nothing else ever refetches. Loaded message
  /// buffers are replaced from the engine's ring buffer (restamped in buffer
  /// order); delivery entries are kept — the lag doesn't invalidate them.
  Future<void> resync() async {
    await Future.wait([refreshPeers(), refreshConfig(), refreshChannels()]);
    for (final channelId in _messages.keys.toList()) {
      try {
        final fetched = await _bridge.getMessages(channelId);
        _messages[channelId] = [
          for (final m in fetched) m.withLocalSeq(_stampSeq()),
        ];
      } catch (e) {
        debugPrint('AppStore.resync($channelId) failed: $e');
      }
    }
    notifyListeners();
  }

  /// Refetch the channel list and notify; throws are swallowed.
  Future<void> refreshChannels() =>
      _refresh('refreshChannels', _bridge.getChannels, (v) => _channels = v);

  /// Refetch the config and notify; throws are swallowed (keep the last good
  /// config rather than blanking the UI).
  Future<void> refreshConfig() =>
      _refresh('refreshConfig', _bridge.getConfig, (v) => _config = v);

  /// Refetch the peer list and notify. Failures are non-critical (a background
  /// refresh) — keep the current list and log rather than surfacing an error.
  Future<void> refreshPeers() =>
      _refresh('refreshPeers', _bridge.getPeers, (v) => _peers = v);

  /// The one fetch → assign → notify body behind the refresh triad (#185).
  /// A failed fetch keeps the last good value, logs, and does not notify.
  Future<void> _refresh<T>(
    String name,
    Future<T> Function() fetch,
    void Function(T) assign,
  ) async {
    try {
      assign(await fetch());
      notifyListeners();
    } catch (e) {
      debugPrint('AppStore.$name failed: $e');
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
      // reappears as ManualIp rather than vanishing. Debounced like
      // PeersChanged: "Clear inactive peers" emits one PeerExpired per
      // removed peer, and N stale peers must not mean N refetches.
      case PeerExpired():
        _schedulePeersRefresh();
      // The local name changed — refetch config so both screens reflect it.
      case ClientNameChanged():
        refreshConfig();
      case ChannelsChanged():
        refreshChannels();
      // This subscriber's event stream lagged — refetch everything.
      case Resynced():
        resync();
      // Store the message + track delivery. The flash/unread *reaction* is a
      // screen-local concern (home's _handlePush), not the store's (#58).
      case MessageReceived(:final message):
        final list = _messages.putIfAbsent(message.channelId, () => [])
          ..add(message.withLocalSeq(_stampSeq()));
        if (list.length > _kMaxMessagesPerChannel) {
          final excess = list.length - _kMaxMessagesPerChannel;
          // Drop the trimmed messages' delivery entries too — they'd
          // otherwise accumulate for the session (the same leak
          // DeliveryTracker.clearForMessageIds exists to prevent on clear).
          _delivery
              .clearForMessageIds(list.take(excess).map((m) => m.messageId));
          list.removeRange(0, excess);
        }
        notifyListeners();
      case DeliveryUpdated(:final messageId, :final status):
        _delivery.track(messageId, status);
        notifyListeners();
      // Screen-local UI — not the store's concern.
      case Flashed():
      case ChannelsOffered():
      case GlobalMacrosOffered():
      case PermissionDenied():
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
