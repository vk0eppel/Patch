import 'dart:async';

import 'package:flutter/material.dart';

import 'channel.dart';
import 'events.dart';
import 'flash.dart';
import 'message.dart' show kAllChannelId;
import 'selection_controller.dart';

class FlashApplicator extends ChangeNotifier {
  FlashApplicator({
    required SelectionController selectionController,
    required Stream<PatchEvent> pushes,
    this.showPeers = false,
    this.flashCount = 4,
    this.flashOnCritical = true,
    this.flashOnMessage = false,
    List<PatchChannel> channels = const [],
    Color broadcastColor = Colors.white,
    Color dmColor = Colors.blue,
    Future<void> Function()? onAlert,
    Future<void> Function(Color, int)? onPulseOverlay,
  })  : _selectionController = selectionController, // ignore: prefer_initializing_formals
        _channels = List.of(channels),
        _broadcastColor = broadcastColor, // ignore: prefer_initializing_formals
        _dmColor = dmColor, // ignore: prefer_initializing_formals
        _onAlert = onAlert, // ignore: prefer_initializing_formals
        _onPulseOverlay = onPulseOverlay { // ignore: prefer_initializing_formals
    _pushSub = pushes.listen(_handlePush);
  }

  final SelectionController _selectionController;
  final Color _broadcastColor;
  final Color _dmColor;
  final Future<void> Function()? _onAlert;
  final Future<void> Function(Color, int)? _onPulseOverlay;
  StreamSubscription<PatchEvent>? _pushSub;

  bool audibleAlert = false;
  bool flashWholeScreen = false;
  bool showPeers;
  int flashCount;
  bool flashOnCritical;
  bool flashOnMessage;

  List<PatchChannel> _channels;
  set channels(List<PatchChannel> v) => _channels = List.of(v);

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

  void _handlePush(PatchEvent event) {
    switch (event) {
      case MessageReceived(:final message):
        final flash = decideMessageFlash(
          msg: message,
          channels: _channels,
          globalOnCritical: flashOnCritical,
          globalOnMessage: flashOnMessage,
          globalPulseCount: flashCount,
        );
        if (flash != null) {
          apply(flash);
        } else if (message.channelId.startsWith('dm:') &&
            !_selectionController.selection.containsRawId(message.channelId)) {
          markDmUnread(message.channelId);
        }
      case Flashed(:final channelId):
        final FlashEvent flashEvent;
        if (channelId == kAllChannelId) {
          flashEvent = BroadcastFlashEvent(pulseCount: flashCount);
        } else if (channelId.startsWith('dm:')) {
          flashEvent = DmFlashEvent(peerId: channelId.substring(3));
        } else {
          final ch = _channels
              .cast<PatchChannel?>()
              .firstWhere((c) => c?.id == channelId, orElse: () => null);
          flashEvent = ChannelFlashEvent(
            channelId: channelId,
            color: ch?.color ?? Colors.white,
            pulseCount: ch?.flashCount ?? flashCount,
          );
        }
        apply(flashEvent);
      default:
        break;
    }
  }

  void apply(FlashEvent event) {
    final selection = _selectionController.selection;
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
          _flashPulseCount = flashCount;
          _fireAlert();
          _firePulseOverlay(_dmColor, flashCount);
        } else {
          _unreadDms.add(dmKey);
          if (!showPeers) _dmPulseNotify++;
        }
    }
    notifyListeners();
  }

  void markDmUnread(String channelId) {
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

  @override
  void dispose() {
    _pushSub?.cancel();
    super.dispose();
  }

  void _fireAlert() {
    if (audibleAlert) _onAlert?.call();
  }

  void _firePulseOverlay(Color color, int pulseCount) {
    if (flashWholeScreen) _onPulseOverlay?.call(color, pulseCount);
  }
}
