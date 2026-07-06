import 'package:flutter/material.dart';

import 'channel.dart';
import 'dm_thread.dart';
import 'events.dart';
import 'flash_state.dart';
export 'flash_state.dart';
import 'message.dart' show kAllChannelId, PatchMessage;
import 'selection.dart';

// ── Flash events (merged from flash.dart) ─────────────────────────────────────

sealed class FlashEvent {
  const FlashEvent();
}

class ChannelFlashEvent extends FlashEvent {
  final String channelId;
  final Color color;
  final int pulseCount;
  const ChannelFlashEvent({
    required this.channelId,
    required this.color,
    required this.pulseCount,
  });
}

/// A crew-wide broadcast flash — always pulses the message area regardless of
/// what's currently selected.
class BroadcastFlashEvent extends FlashEvent {
  final int pulseCount;
  const BroadcastFlashEvent({required this.pulseCount});
}

class DmFlashEvent extends FlashEvent {
  final String peerId;
  const DmFlashEvent({required this.peerId});
}

/// Decides whether an inbound message should flash. Pure — callers apply result.
FlashEvent? decideMessageFlash({
  required PatchMessage msg,
  required List<PatchChannel> channels,
  required bool globalOnCritical,
  required bool globalOnMessage,
  required int globalPulseCount,
}) {
  if (DmThread.tryParse(msg.channelId) case final DmThread dm) {
    if (globalOnCritical && msg.isCritical) {
      return DmFlashEvent(peerId: dm.peerId);
    }
    return null;
  }
  if (msg.channelId == kAllChannelId) {
    final shouldFlash = globalOnMessage || (globalOnCritical && msg.isCritical);
    return shouldFlash ? BroadcastFlashEvent(pulseCount: globalPulseCount) : null;
  }
  final ch = channels
      .cast<PatchChannel?>()
      .firstWhere((c) => c?.id == msg.channelId, orElse: () => null);
  if (ch == null) return null;
  final shouldFlash = (globalOnMessage || ch.flashOnMessage) ||
      ((globalOnCritical || ch.flashOnCritical) && msg.isCritical);
  if (!shouldFlash) return null;
  return ChannelFlashEvent(
    channelId: ch.id,
    color: ch.color,
    pulseCount: ch.flashCount ?? globalPulseCount,
  );
}

// ── Flash state reducers ──────────────────────────────────────────────────────

/// Reduces a [PatchEvent] into a new [FlashState]. Pure — no side effects.
///
/// [HomePresenter] calls this on each push, diffs [FlashState.flashNotify] and
/// [FlashState.dmPulseNotify] to emit commands, then calls `notifyListeners()`.
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
      if (DmThread.isKey(message.channelId) &&
          !selection.containsRawId(message.channelId)) {
        return markDmUnread(state, message.channelId, settings.showPeers);
      }
      return state;

    case Flashed(:final channelId):
      final FlashEvent flash;
      if (channelId == kAllChannelId) {
        flash = BroadcastFlashEvent(pulseCount: settings.flashCount);
      } else if (DmThread.tryParse(channelId) case final DmThread dm) {
        flash = DmFlashEvent(peerId: dm.peerId);
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
      final dmKey = DmThread(peerId).key;
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
      unreadDms: {...state.unreadDms}..remove(DmThread(peerId).key),
    );

FlashState clearDmThread(FlashState state, String peerId) =>
    state.copyWith(unreadDms: {...state.unreadDms}..remove(DmThread(peerId).key));

/// Derives the side-effect commands from a flash state transition. Pure.
({bool playAlert, ({Color color, int count})? pulse}) flashOutput(
  FlashState prev,
  FlashState next,
  FlashSettings settings,
) {
  if (next.flashNotify == prev.flashNotify) {
    return (playAlert: false, pulse: null);
  }
  return (
    playAlert: settings.audibleAlert,
    pulse: settings.flashWholeScreen
        ? (color: next.flashColor, count: next.flashPulseCount)
        : null,
  );
}

/// One seam for "does this inbound push produce a screen effect": chains
/// [reduceEvent] (does the event even count as a flash, given the current
/// selection/settings) and [flashOutput] (does the resulting state change
/// warrant a command) into a single pure decision. [HomePresenter] calls
/// this on each push instead of composing the two itself, so the whole
/// event → command path is one unit, testable without a widget tree.
({FlashState state, bool playAlert, ({Color color, int count})? pulse})
    decideFlashCommand(
  FlashState prev,
  PatchEvent event,
  Selection selection,
  List<PatchChannel> channels,
  FlashSettings settings,
) {
  final next = reduceEvent(prev, event, selection, channels, settings);
  final out = flashOutput(prev, next, settings);
  return (state: next, playAlert: out.playAlert, pulse: out.pulse);
}
