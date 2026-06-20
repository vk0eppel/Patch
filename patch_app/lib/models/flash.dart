import 'package:flutter/material.dart';

import 'channel.dart';
import 'message.dart';

/// What should be flashed and how — the output of [decideMessageFlash] and the
/// input to `_HomeScreenState._applyFlash`. One of three Channel/ALL/Direct
/// Message shapes, mirroring [Selection]'s exclusivity.
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
/// what's currently selected (a broadcast is visible in whatever view the
/// Operator is in).
class BroadcastFlashEvent extends FlashEvent {
  final int pulseCount;
  const BroadcastFlashEvent({required this.pulseCount});
}

class DmFlashEvent extends FlashEvent {
  final String peerId;
  const DmFlashEvent({required this.peerId});
}

/// Decides whether an inbound message should flash, given the global flash
/// flags and per-channel overrides. Pure — callers apply the result (bump
/// counts, pulse if selected, mark unread) separately.
///
/// A non-critical DM that doesn't flash still needs an unread dot — that's a
/// DM-thread-visibility concern, not a flash decision, so it's handled by the
/// caller when this returns null for a `dm:` message.
FlashEvent? decideMessageFlash({
  required PatchMessage msg,
  required List<PatchChannel> channels,
  required bool globalOnCritical,
  required bool globalOnMessage,
  required int globalPulseCount,
}) {
  if (msg.channelId.startsWith('dm:')) {
    if (globalOnCritical && msg.isCritical) {
      return DmFlashEvent(peerId: msg.channelId.substring(3));
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
