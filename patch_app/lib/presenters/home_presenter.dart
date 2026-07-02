import 'dart:async';

import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/flash_model.dart' as fm
    show
        FlashEvent,
        FlashState,
        FlashSettings,
        applyFlashEvent,
        reduceEvent,
        markDmUnread,
        clearUnread,
        clearDmThread,
        openDmThread,
        flashOutput;
import '../models/message.dart' show MessageDeliveryStatus, PeerInfo, PeerStatus;
import '../models/selection.dart';
import '../models/selection_controller.dart';

export '../models/flash_model.dart' show FlashState, FlashSettings;

// ── Commands ──────────────────────────────────────────────────────────────────

sealed class HomeCommand {
  const HomeCommand();
}

final class ShowDeliveryFailure extends HomeCommand {
  final String messageId;
  final MessageDeliveryStatus status;
  const ShowDeliveryFailure({required this.messageId, required this.status});
}

final class ShowPermissionDenied extends HomeCommand {
  final String context;
  const ShowPermissionDenied({required this.context});
}

final class PulseOverlay extends HomeCommand {
  final Color color;
  final int pulseCount;
  const PulseOverlay({required this.color, required this.pulseCount});
}

final class PlayAlert extends HomeCommand {
  const PlayAlert();
}

// ── Presenter ─────────────────────────────────────────────────────────────────

class HomePresenter extends ChangeNotifier {
  HomePresenter({
    required Stream<PatchEvent> pushes,
    Stream<AppConfig?>? configStream,
    Stream<List<PeerInfo>>? peersStream,
    this.supportsFlashOverlay = false,
    this._selectionController,
    List<PatchChannel> Function()? channelGetter,
    bool showPeers = false,
    Color broadcastColor = Colors.white,
    Color dmColor = Colors.blue,
  })  : _channelGetter = channelGetter ?? (() => const []),
        _settings = fm.FlashSettings(
          broadcastColor: broadcastColor,
          dmColor: dmColor,
          showPeers: showPeers,
          flashCount: 4,
          flashOnCritical: true,
          flashOnMessage: false,
        ) {
    _pushSub = pushes.listen(_handlePush);
    _configSub = configStream?.listen(_applyConfig);
    _peersSub = peersStream?.listen((peers) => _peers = peers);
  }

  final bool supportsFlashOverlay;
  final SelectionController? _selectionController;
  StreamSubscription<PatchEvent>? _pushSub;
  StreamSubscription<AppConfig?>? _configSub;
  StreamSubscription<List<PeerInfo>>? _peersSub;
  List<PeerInfo> _peers = [];
  final _commandCtrl = StreamController<HomeCommand>.broadcast(sync: true);

  final List<PatchChannel> Function() _channelGetter;

  fm.FlashSettings _settings;
  fm.FlashState _state = fm.FlashState.empty;

  // ── Settings setters ──────────────────────────────────────────────────────

  set showPeers(bool v) => _settings = _settings.copyWith(showPeers: v);

  bool get showPeers => _settings.showPeers;
  int get flashCount => _settings.flashCount;
  bool get flashOnCritical => _settings.flashOnCritical;
  bool get flashOnMessage => _settings.flashOnMessage;

  // ── FlashState getters ────────────────────────────────────────────────────

  Map<String, int> get flashCounts => _state.flashCounts;
  int get flashNotify => _state.flashNotify;
  Color get flashColor => _state.flashColor;
  int get flashPulseCount => _state.flashPulseCount;
  Set<String> get openDms => _state.openDms;
  Set<String> get unreadDms => _state.unreadDms;
  int get dmPulseNotify => _state.dmPulseNotify;

  // ── Peer lookup ──────────────────────────────────────────────────────────

  String dmPeerName(String peerId) {
    for (final p in _peers) {
      if (p.peerId == peerId) return p.peerName;
    }
    return 'Unknown';
  }

  bool isDmPeerOffline(String peerId) {
    // Reachability is classified engine-side (PeerStatus) — including the
    // no-resolved-address case (#137). No Dart-side re-derivation.
    final peer = _peers.cast<PeerInfo?>().firstWhere(
          (p) => p?.peerId == peerId,
          orElse: () => null,
        );
    return peer == null || peer.status == PeerStatus.offline;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Stream<HomeCommand> get commands => _commandCtrl.stream;

  void apply(fm.FlashEvent event) {
    final sel = _selectionController?.selection ?? ChannelSelection(const {});
    final prev = _state;
    _state = fm.applyFlashEvent(_state, event, sel, _settings);
    _fireFlashCommandsIfNeeded(prev);
    notifyListeners();
  }

  void markDmUnread(String channelId) {
    _state = fm.markDmUnread(_state, channelId, _settings.showPeers);
    notifyListeners();
  }

  void clearUnread(String id) {
    _state = fm.clearUnread(_state, id);
    notifyListeners();
  }

  void clearDmThread(String peerId) {
    _state = fm.clearDmThread(_state, peerId);
    notifyListeners();
  }

  void openDmThread(String peerId) {
    _state = fm.openDmThread(_state, peerId);
    notifyListeners();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _applyConfig(AppConfig? cfg) {
    if (cfg == null) return;
    _settings = _settings.copyWith(
      flashCount: cfg.flashCount,
      flashOnCritical: cfg.flashOnCritical,
      flashOnMessage: cfg.flashOnMessage,
      audibleAlert: cfg.audibleAlert,
      flashWholeScreen: cfg.flashWholeScreen && supportsFlashOverlay,
    );
    notifyListeners();
  }

  void _handlePush(PatchEvent event) {
    switch (event) {
      case DeliveryUpdated(:final messageId, :final status):
        if (status.failed) {
          _commandCtrl
              .add(ShowDeliveryFailure(messageId: messageId, status: status));
        }
      case PermissionDenied(:final context):
        _commandCtrl.add(ShowPermissionDenied(context: context));
      default:
        if (_selectionController != null) {
          _handleFlashPush(event);
        }
    }
  }

  void _handleFlashPush(PatchEvent event) {
    final sel = _selectionController!.selection;
    final prev = _state;
    _state = fm.reduceEvent(_state, event, sel, _channelGetter(), _settings);
    if (_state != prev) {
      _fireFlashCommandsIfNeeded(prev);
      notifyListeners();
    }
  }

  void _fireFlashCommandsIfNeeded(fm.FlashState prev) {
    final out = fm.flashOutput(prev, _state, _settings);
    if (out.playAlert) _commandCtrl.add(const PlayAlert());
    if (out.pulse case final p?) {
      _commandCtrl.add(PulseOverlay(color: p.color, pulseCount: p.count));
    }
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    _configSub?.cancel();
    _peersSub?.cancel();
    _commandCtrl.close();
    super.dispose();
  }
}
