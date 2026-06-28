import 'package:flutter/material.dart';

import 'channel.dart';
import 'events.dart';
import 'flash.dart';
import 'flash_state.dart';
export 'flash_state.dart';
import 'message.dart' show kAllChannelId;
import 'selection.dart';

/// Reduces a [PatchEvent] into a new [FlashState]. Pure — no side effects.
///
/// The adapter ([FlashApplicator]) calls this on each push, diffs
/// [FlashState.flashNotify] and [FlashState.dmPulseNotify] to fire callbacks,
/// then calls `notifyListeners()`.
FlashState reduceEvent(
  FlashState state,
  PatchEvent event,
  Selection selection,
  List<PatchChannel> channels,
  FlashSettings settings,
) {
  switch (event) {
    case MessageReceived(:final message):
      final flash = decideMessageFlash(
        msg: message,
        channels: channels,
        globalOnCritical: settings.flashOnCritical,
        globalOnMessage: settings.flashOnMessage,
        globalPulseCount: settings.flashCount,
      );
      if (flash != null) {
        return applyFlashEvent(state, flash, selection, settings);
      }
      if (message.channelId.startsWith('dm:') &&
          !selection.containsRawId(message.channelId)) {
        return markDmUnread(state, message.channelId, settings.showPeers);
      }
      return state;

    case Flashed(:final channelId):
      final FlashEvent flash;
      if (channelId == kAllChannelId) {
        flash = BroadcastFlashEvent(pulseCount: settings.flashCount);
      } else if (channelId.startsWith('dm:')) {
        flash = DmFlashEvent(peerId: channelId.substring(3));
      } else {
        final ch = channels
            .cast<PatchChannel?>()
            .firstWhere((c) => c?.id == channelId, orElse: () => null);
        flash = ChannelFlashEvent(
          channelId: channelId,
          color: ch?.color ?? Colors.white,
          pulseCount: ch?.flashCount ?? settings.flashCount,
        );
      }
      return applyFlashEvent(state, flash, selection, settings);

    default:
      return state;
  }
}

FlashState applyFlashEvent(
  FlashState state,
  FlashEvent event,
  Selection selection,
  FlashSettings settings,
) {
  switch (event) {
    case ChannelFlashEvent(:final channelId, :final color, :final pulseCount):
      final counts = {...state.flashCounts, channelId: (state.flashCounts[channelId] ?? 0) + 1};
      if (!selection.containsRawId(channelId)) {
        return state.copyWith(flashCounts: counts);
      }
      return state.copyWith(
        flashCounts: counts,
        flashNotify: state.flashNotify + 1,
        flashColor: color,
        flashPulseCount: pulseCount,
      );

    case BroadcastFlashEvent(:final pulseCount):
      return state.copyWith(
        flashCounts: {...state.flashCounts, kAllChannelId: (state.flashCounts[kAllChannelId] ?? 0) + 1},
        flashNotify: state.flashNotify + 1,
        flashColor: settings.broadcastColor,
        flashPulseCount: pulseCount,
      );

    case DmFlashEvent(:final peerId):
      final dmKey = 'dm:$peerId';
      final openDms = {...state.openDms, peerId};
      if (selection.containsRawId(dmKey)) {
        return state.copyWith(
          openDms: openDms,
          flashNotify: state.flashNotify + 1,
          flashColor: settings.dmColor,
          flashPulseCount: settings.flashCount,
        );
      }
      return state.copyWith(
        openDms: openDms,
        unreadDms: {...state.unreadDms, dmKey},
        dmPulseNotify: settings.showPeers ? state.dmPulseNotify : state.dmPulseNotify + 1,
      );
  }
}

FlashState markDmUnread(FlashState state, String channelId, bool showPeers) =>
    state.copyWith(
      unreadDms: {...state.unreadDms, channelId},
      dmPulseNotify: showPeers ? state.dmPulseNotify : state.dmPulseNotify + 1,
    );

FlashState clearUnread(FlashState state, String id) =>
    state.copyWith(unreadDms: {...state.unreadDms}..remove(id));

FlashState openDmThread(FlashState state, String peerId) => state.copyWith(
      openDms: {...state.openDms, peerId},
      unreadDms: {...state.unreadDms}..remove('dm:$peerId'),
    );

FlashState clearDmThread(FlashState state, String peerId) =>
    state.copyWith(unreadDms: {...state.unreadDms}..remove('dm:$peerId'));
