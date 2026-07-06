import 'package:flutter/material.dart';

import '../models/channel.dart';
import '../models/dm_thread.dart';
import '../models/message.dart';
import '../models/selection.dart';

/// Merges and sorts messages for the current view. Pure — no side effects.
/// Sorted by [PatchMessage.localSeq] (local arrival order), not
/// [PatchMessage.timestamp] — the embedded timestamp is the sender's own
/// clock, so sorting by it would misorder messages when machines' clocks
/// disagree.
List<PatchMessage> combinedMessages(
  Map<String, List<PatchMessage>> messages,
  Selection selection,
) {
  final all = <PatchMessage>[];
  switch (selection) {
    case DmSelection(peerId: final p):
      all.addAll(messages[DmThread(p).key] ?? []);
    case AllSelection():
      for (final entry in messages.entries) {
        if (DmThread.isKey(entry.key)) continue;
        all.addAll(entry.value);
      }
    case ChannelSelection(ids: final ids):
      for (final id in ids) {
        all.addAll(messages[id] ?? []);
      }
      all.addAll(messages[kAllChannelId] ?? []);
  }
  all.sort((a, b) => a.localSeq.compareTo(b.localSeq));
  return all;
}

/// Channel-colour map for the message list. Populated in multi-channel and ALL
/// modes so each row shows its channel dot; empty for a single channel. Pure.
Map<String, Color> channelColors(
  List<PatchChannel> allChannels,
  List<PatchChannel> selectedChannels,
  Selection selection,
) {
  if (selection.isAllMode) {
    return {for (final c in allChannels) c.id: c.color};
  }
  if (!selection.isMultiChannel) return {};
  return {for (final c in selectedChannels) c.id: c.color};
}
