import 'package:flutter/material.dart';

class FlashState {
  const FlashState._({
    required this.flashCounts,
    required this.flashNotify,
    required this.flashColor,
    required this.flashPulseCount,
    required this.openDms,
    required this.unreadDms,
    required this.dmPulseNotify,
  });

  static const empty = FlashState._(
    flashCounts: <String, int>{},
    flashNotify: 0,
    flashColor: Colors.white,
    flashPulseCount: 4,
    openDms: <String>{},
    unreadDms: <String>{},
    dmPulseNotify: 0,
  );

  final Map<String, int> flashCounts;
  final int flashNotify;
  final Color flashColor;
  final int flashPulseCount;
  final Set<String> openDms;
  final Set<String> unreadDms;
  final int dmPulseNotify;

  FlashState copyWith({
    Map<String, int>? flashCounts,
    int? flashNotify,
    Color? flashColor,
    int? flashPulseCount,
    Set<String>? openDms,
    Set<String>? unreadDms,
    int? dmPulseNotify,
  }) =>
      FlashState._(
        flashCounts: flashCounts ?? this.flashCounts,
        flashNotify: flashNotify ?? this.flashNotify,
        flashColor: flashColor ?? this.flashColor,
        flashPulseCount: flashPulseCount ?? this.flashPulseCount,
        openDms: openDms ?? this.openDms,
        unreadDms: unreadDms ?? this.unreadDms,
        dmPulseNotify: dmPulseNotify ?? this.dmPulseNotify,
      );
}

class FlashSettings {
  const FlashSettings({
    required this.flashCount,
    required this.flashOnCritical,
    required this.flashOnMessage,
    required this.broadcastColor,
    required this.dmColor,
    required this.showPeers,
  });

  final int flashCount;
  final bool flashOnCritical;
  final bool flashOnMessage;
  final Color broadcastColor;
  final Color dmColor;
  final bool showPeers;

  FlashSettings copyWith({
    int? flashCount,
    bool? flashOnCritical,
    bool? flashOnMessage,
    Color? broadcastColor,
    Color? dmColor,
    bool? showPeers,
  }) =>
      FlashSettings(
        flashCount: flashCount ?? this.flashCount,
        flashOnCritical: flashOnCritical ?? this.flashOnCritical,
        flashOnMessage: flashOnMessage ?? this.flashOnMessage,
        broadcastColor: broadcastColor ?? this.broadcastColor,
        dmColor: dmColor ?? this.dmColor,
        showPeers: showPeers ?? this.showPeers,
      );
}
