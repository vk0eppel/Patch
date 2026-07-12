import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart';
import 'package:patch/models/selection.dart';
import 'package:patch/util/message_view.dart';

PatchMessage _msg(String channelId, DateTime ts, {int seq = 0}) => PatchMessage(
  messageId: channelId + ts.millisecondsSinceEpoch.toString(),
  senderId: 's',
  senderName: 'S',
  channelId: channelId,
  priority: 1,
  payload: 'hi',
  timestamp: ts,
  localSeq: seq,
);

final _t1 = DateTime(2026, 1, 1, 12, 0, 0);
final _t2 = DateTime(2026, 1, 1, 12, 0, 1);
final _t3 = DateTime(2026, 1, 1, 12, 0, 2);

void main() {
  // ── combinedMessages ─────────────────────────────────────────────────────────

  group('combinedMessages — DmSelection', () {
    test('returns only the dm thread messages', () {
      final messages = {
        'dm:p1': [_msg('dm:p1', _t1)],
        'rf': [_msg('rf', _t2)],
      };
      final result = combinedMessages(messages, const DmSelection('p1'));
      expect(result, hasLength(1));
      expect(result.first.channelId, 'dm:p1');
    });

    test('returns empty list when thread has no messages', () {
      final result = combinedMessages({}, const DmSelection('p1'));
      expect(result, isEmpty);
    });
  });

  group('combinedMessages — AllSelection', () {
    test('includes all non-DM messages sorted by local arrival order', () {
      final messages = {
        'rf': [_msg('rf', _t3, seq: 2)],
        kAllChannelId: [_msg(kAllChannelId, _t1, seq: 1)],
        'dm:p1': [_msg('dm:p1', _t2, seq: 3)],
      };
      final result = combinedMessages(messages, AllSelection(const {}));
      expect(result.map((m) => m.channelId), ['__all__', 'rf']);
      expect(result, hasLength(2));
    });
  });

  group('combinedMessages — ChannelSelection', () {
    test('includes selected channel messages + broadcast, sorted by local '
        'arrival order', () {
      final messages = {
        'rf': [_msg('rf', _t2, seq: 2)],
        'audio': [_msg('audio', _t3, seq: 3)],
        kAllChannelId: [_msg(kAllChannelId, _t1, seq: 1)],
      };
      final result = combinedMessages(messages, const ChannelSelection({'rf'}));
      expect(result.map((m) => m.channelId), ['__all__', 'rf']);
    });

    test('excludes non-selected channels', () {
      final messages = {
        'rf': [_msg('rf', _t1)],
        'audio': [_msg('audio', _t2)],
      };
      final result = combinedMessages(messages, const ChannelSelection({'rf'}));
      expect(result.map((m) => m.channelId), ['rf']);
    });

    test('sorts by local arrival order (localSeq), not the sender\'s embedded '
        'timestamp — immune to clock skew between machines', () {
      final messages = {
        // Arrived locally first (localSeq 1) despite a later embedded
        // timestamp — simulates a sender with a fast clock.
        'rf': [_msg('rf', _t3, seq: 1)],
        // Arrived locally second (localSeq 2) despite an earlier embedded
        // timestamp — simulates a sender with a slow/unset clock.
        'audio': [_msg('audio', _t1, seq: 2)],
      };
      final result = combinedMessages(
        messages,
        const ChannelSelection({'rf', 'audio'}),
      );
      expect(result.map((m) => m.channelId), ['rf', 'audio']);
    });
  });

  // ── channelColors ─────────────────────────────────────────────────────────────

  const rf = PatchChannel(id: 'rf', displayName: 'RF', color: Colors.red);
  const audio = PatchChannel(
    id: 'audio',
    displayName: 'Audio',
    color: Colors.blue,
  );

  group('channelColors — AllSelection', () {
    test('returns all channel colors', () {
      final colors = channelColors(
        [rf, audio],
        [rf, audio],
        AllSelection(const {}),
      );
      expect(colors, {'rf': Colors.red, 'audio': Colors.blue});
    });
  });

  group('channelColors — ChannelSelection single', () {
    test('returns empty map for a single channel', () {
      final colors = channelColors(
        [rf, audio],
        [rf],
        const ChannelSelection({'rf'}),
      );
      expect(colors, isEmpty);
    });
  });

  group('channelColors — ChannelSelection multi', () {
    test('returns map for selected channels only', () {
      final colors = channelColors(
        [rf, audio],
        [rf, audio],
        const ChannelSelection({'rf', 'audio'}),
      );
      expect(colors, {'rf': Colors.red, 'audio': Colors.blue});
    });
  });
}
