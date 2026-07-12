import 'dart:async';

import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/flash_model.dart'
    as fm
    show
        FlashEvent,
        FlashState,
        FlashSettings,
        applyFlashEvent,
        markDmUnread,
        clearUnread,
        clearDmThread,
        openDmThread,
        flashOutput,
        decideFlashCommand;
import '../models/message.dart'
    show MessageDeliveryStatus, PeerInfo, PeerStatus;
import '../models/selection.dart';
import '../models/selection_controller.dart';
import '../widgets/name_prompt.dart' show shouldShowNamePrompt;

export '../models/flash_model.dart' show FlashState, FlashSettings;

// ── Store reduction ───────────────────────────────────────────────────────────

/// What the Home screen must do in response to one store notification.
/// Pure data — the widget applies these (dialogs, setState, workspace saves).
class HomeStoreEffects {
  /// Show the one-shot first-run name prompt (at most once per session).
  final bool showNamePrompt;

  /// Set the macros-panel default (derived from whether any Macros are
  /// configured) — only on the first config load while the Operator has never
  /// explicitly toggled the panel. Null means leave it alone.
  final bool? defaultMacrosPanel;

  /// The Channel id list changed — reconcile the current selection.
  final bool reconcileSelection;

  const HomeStoreEffects({
    required this.showNamePrompt,
    required this.defaultMacrosPanel,
    required this.reconcileSelection,
  });
}

// ── Commands ──────────────────────────────────────────────────────────────────

sealed class HomeCommand {
  const HomeCommand();
}

final class ShowDeliveryFailure extends HomeCommand {
  final String messageId;
  final MessageDeliveryStatus status;
  const ShowDeliveryFailure({required this.messageId, required this.status});

  /// The operator-facing summary of a Critical Message delivery failure —
  /// phrased here, behind the tested seam, so the widget only displays it.
  String get summary {
    final who = status.total == 0
        ? 'no peers were online'
        : status.failedPeers.isNotEmpty
        ? 'not received by ${status.failedPeers.join(', ')}'
        : 'not received by all peers';
    return 'Critical message $who';
  }
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
  }) : _channelGetter = channelGetter ?? (() => const []),
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
  bool _namePromptShown = false;
  List<String>? _lastChannelIds;
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

  /// The operator-facing warning to show after sending a Direct Message to
  /// [peerId], or null when the Peer looks reachable — decided and phrased
  /// here so the widget only displays it (#149).
  String? dmOfflineWarning(String peerId) {
    if (!isDmPeerOffline(peerId)) return null;
    return '${dmPeerName(peerId)} appears offline — '
        'they may not receive this DM';
  }

  // ── Public API ────────────────────────────────────────────────────────────

  Stream<HomeCommand> get commands => _commandCtrl.stream;

  /// Reduce one store notification: apply config/peers immediately and decide
  /// the one-shot effects (name prompt, macros-panel default, selection
  /// reconcile). The Home screen calls this directly from its store listener
  /// — no intermediate controller hop (#160).
  HomeStoreEffects onStoreChanged({
    required AppConfig? config,
    required List<PeerInfo> peers,
    required List<String> channelIds,
    required bool macrosPanelPreferenceSet,
    required bool anyMacrosConfigured,
  }) {
    _applyConfig(config);
    _peers = peers;

    var showNamePrompt = false;
    bool? defaultMacrosPanel;
    if (config != null) {
      showNamePrompt = shouldShowNamePrompt(
        nameIsDefault: config.nameIsDefault,
        alreadyShown: _namePromptShown,
      );
      if (showNamePrompt) _namePromptShown = true;
      if (!macrosPanelPreferenceSet) {
        defaultMacrosPanel = anyMacrosConfigured;
      }
    }

    var reconcile = false;
    if (!_sameIds(channelIds, _lastChannelIds)) {
      _lastChannelIds = List.of(channelIds);
      reconcile = true;
    }

    return HomeStoreEffects(
      showNamePrompt: showNamePrompt,
      defaultMacrosPanel: defaultMacrosPanel,
      reconcileSelection: reconcile,
    );
  }

  static bool _sameIds(List<String> a, List<String>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

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
          _commandCtrl.add(
            ShowDeliveryFailure(messageId: messageId, status: status),
          );
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
    final decision = fm.decideFlashCommand(
      prev,
      event,
      sel,
      _channelGetter(),
      _settings,
    );
    _state = decision.state;
    if (_state != prev) {
      _fireCommands(decision.playAlert, decision.pulse);
      notifyListeners();
    }
  }

  void _fireFlashCommandsIfNeeded(fm.FlashState prev) {
    final out = fm.flashOutput(prev, _state, _settings);
    _fireCommands(out.playAlert, out.pulse);
  }

  void _fireCommands(bool playAlert, ({Color color, int count})? pulse) {
    if (playAlert) _commandCtrl.add(const PlayAlert());
    if (pulse case final p?) {
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
