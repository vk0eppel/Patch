import 'dart:async';

import 'package:flutter/material.dart';

import 'channel.dart';
import 'events.dart';
import 'flash.dart';
import 'flash_model.dart' as fm;
import 'selection_controller.dart';

export 'flash_model.dart' show FlashState, FlashSettings;

class FlashApplicator extends ChangeNotifier {
  FlashApplicator({
    required this._selectionController,
    required Stream<PatchEvent> pushes,
    bool showPeers = false,
    int flashCount = 4,
    bool flashOnCritical = true,
    bool flashOnMessage = false,
    List<PatchChannel> channels = const [],
    Color broadcastColor = Colors.white,
    Color dmColor = Colors.blue,
    this._onAlert,
    this._onPulseOverlay,
  })  : _channels = List.of(channels),
        _settings = fm.FlashSettings(
          flashCount: flashCount,
          flashOnCritical: flashOnCritical,
          flashOnMessage: flashOnMessage,
          broadcastColor: broadcastColor,
          dmColor: dmColor,
          showPeers: showPeers,
        ) {
    _pushSub = pushes.listen(_handlePush);
  }

  final SelectionController _selectionController;
  final Future<void> Function()? _onAlert;
  final Future<void> Function(Color, int)? _onPulseOverlay;
  StreamSubscription<PatchEvent>? _pushSub;

  bool audibleAlert = false;
  bool flashWholeScreen = false;

  List<PatchChannel> _channels;
  set channels(List<PatchChannel> v) => _channels = List.of(v);

  fm.FlashSettings _settings;

  set showPeers(bool v) => _settings = _settings.copyWith(showPeers: v);
  set flashCount(int v) => _settings = _settings.copyWith(flashCount: v);
  set flashOnCritical(bool v) => _settings = _settings.copyWith(flashOnCritical: v);
  set flashOnMessage(bool v) => _settings = _settings.copyWith(flashOnMessage: v);

  bool get showPeers => _settings.showPeers;
  int get flashCount => _settings.flashCount;
  bool get flashOnCritical => _settings.flashOnCritical;
  bool get flashOnMessage => _settings.flashOnMessage;

  fm.FlashState _state = fm.FlashState.empty;

  Map<String, int> get flashCounts => _state.flashCounts;
  int get flashNotify => _state.flashNotify;
  Color get flashColor => _state.flashColor;
  int get flashPulseCount => _state.flashPulseCount;
  Set<String> get openDms => _state.openDms;
  Set<String> get unreadDms => _state.unreadDms;
  int get dmPulseNotify => _state.dmPulseNotify;

  void _handlePush(PatchEvent event) {
    final prev = _state;
    _state = fm.reduceEvent(
      _state,
      event,
      _selectionController.selection,
      _channels,
      _settings,
    );
    _fireCallbacksIfFlashed(prev);
    notifyListeners();
  }

  void apply(FlashEvent event) {
    final prev = _state;
    _state = fm.applyFlashEvent(_state, event, _selectionController.selection, _settings);
    _fireCallbacksIfFlashed(prev);
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

  void _fireCallbacksIfFlashed(fm.FlashState prev) {
    if (_state.flashNotify != prev.flashNotify) {
      if (audibleAlert) _onAlert?.call();
      if (flashWholeScreen) _onPulseOverlay?.call(_state.flashColor, _state.flashPulseCount);
    }
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    super.dispose();
  }
}
