import 'package:flutter/material.dart';

import 'flash.dart';
import 'message.dart' show kAllChannelId;
import 'selection.dart';

class FlashApplicator extends ChangeNotifier {
  FlashApplicator({
    Color broadcastColor = Colors.white,
    Color dmColor = Colors.blue,
    Future<void> Function()? onAlert,
    Future<void> Function(Color, int)? onPulseOverlay,
  })  : _broadcastColor = broadcastColor,
        _dmColor = dmColor,
        _onAlert = onAlert,
        _onPulseOverlay = onPulseOverlay;

  final Color _broadcastColor;
  final Color _dmColor;
  final Future<void> Function()? _onAlert;
  final Future<void> Function(Color, int)? _onPulseOverlay;

  bool audibleAlert = false;
  bool flashWholeScreen = false;

  final Map<String, int> _flashCounts = {};
  int _flashNotify = 0;
  Color _flashColor = Colors.white;
  int _flashPulseCount = 4;
  final Set<String> _openDms = {};
  final Set<String> _unreadDms = {};
  int _dmPulseNotify = 0;

  Map<String, int> get flashCounts => Map.unmodifiable(_flashCounts);
  int get flashNotify => _flashNotify;
  Color get flashColor => _flashColor;
  int get flashPulseCount => _flashPulseCount;
  Set<String> get openDms => Set.unmodifiable(_openDms);
  Set<String> get unreadDms => Set.unmodifiable(_unreadDms);
  int get dmPulseNotify => _dmPulseNotify;

  void apply(
    FlashEvent event,
    Selection selection, {
    required int globalFlashCount,
    required bool showPeers,
  }) {
    switch (event) {
      case ChannelFlashEvent(:final channelId, :final color, :final pulseCount):
        _flashCounts[channelId] = (_flashCounts[channelId] ?? 0) + 1;
        if (selection.containsRawId(channelId)) {
          _flashNotify++;
          _flashColor = color;
          _flashPulseCount = pulseCount;
          _fireAlert();
          _firePulseOverlay(color, pulseCount);
        }
      case BroadcastFlashEvent(:final pulseCount):
        _flashCounts[kAllChannelId] = (_flashCounts[kAllChannelId] ?? 0) + 1;
        _flashNotify++;
        _flashColor = _broadcastColor;
        _flashPulseCount = pulseCount;
        _fireAlert();
        _firePulseOverlay(_broadcastColor, pulseCount);
      case DmFlashEvent(:final peerId):
        final dmKey = 'dm:$peerId';
        _openDms.add(peerId);
        if (selection.containsRawId(dmKey)) {
          _flashNotify++;
          _flashColor = _dmColor;
          _flashPulseCount = globalFlashCount;
          _fireAlert();
          _firePulseOverlay(_dmColor, globalFlashCount);
        } else {
          _unreadDms.add(dmKey);
          if (!showPeers) _dmPulseNotify++;
        }
    }
    notifyListeners();
  }

  void markDmUnread(String channelId, {required bool showPeers}) {
    _unreadDms.add(channelId);
    if (!showPeers) _dmPulseNotify++;
    notifyListeners();
  }

  void clearUnread(String id) {
    _unreadDms.remove(id);
    notifyListeners();
  }

  void clearDmThread(String peerId) {
    _unreadDms.remove('dm:$peerId');
    notifyListeners();
  }

  /// Called when the Operator explicitly opens a DM thread (taps a peer row).
  /// Ensures the thread exists in [openDms] and clears its unread marker —
  /// distinct from [clearUnread] which only clears and from [apply] with a
  /// [DmFlashEvent] which opens the thread as a side-effect of a Flash arriving.
  void openDmThread(String peerId) {
    _openDms.add(peerId);
    _unreadDms.remove('dm:$peerId');
    notifyListeners();
  }

  void _fireAlert() {
    if (audibleAlert) _onAlert?.call();
  }

  void _firePulseOverlay(Color color, int pulseCount) {
    if (flashWholeScreen) _onPulseOverlay?.call(color, pulseCount);
  }
}
