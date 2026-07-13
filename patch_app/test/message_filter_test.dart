// Unit tests for the pure in-channel message filter (sender/payload substring +
// priority category). No widget — just the matching rules.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/util/message_filter.dart';

PatchMessage _m({
  String sender = 'Sam',
  String payload = 'hello',
  int priority = 1,
}) => PatchMessage(
  messageId: '$sender-$payload-$priority',
  senderId: 's',
  senderName: sender,
  channelId: 'rf',
  timestamp: DateTime(2026, 6, 17),
  priority: priority,
  payload: payload,
);

void main() {
  group('messageCategory', () {
    test('maps priority to the three operator levels', () {
      expect(messageCategory(0), 'info'); // debug folds into info
      expect(messageCategory(1), 'info');
      expect(messageCategory(2), 'warning');
      expect(messageCategory(3), 'critical');
      expect(messageCategory(5), 'critical');
    });
  });

  group('filterMessages', () {
    final msgs = [
      _m(sender: 'FOH', payload: 'mic check', priority: 1),
      _m(sender: 'Monitors', payload: 'standby please', priority: 2),
      _m(sender: 'FOH', payload: 'SHOW STOP', priority: 3),
    ];

    test('empty query and no categories returns everything', () {
      expect(filterMessages(msgs).length, 3);
    });

    test('matches sender name, case-insensitively', () {
      final r = filterMessages(msgs, query: 'foh');
      expect(r.length, 2);
      expect(r.every((m) => m.senderName == 'FOH'), isTrue);
    });

    test('matches payload text, case-insensitively', () {
      final r = filterMessages(msgs, query: 'STANDBY');
      expect(r.length, 1);
      expect(r.first.senderName, 'Monitors');
    });

    test('priority categories filter the feed', () {
      final r = filterMessages(msgs, categories: {'critical'});
      expect(r.length, 1);
      expect(r.first.payload, 'SHOW STOP');
    });

    test('multiple categories are additive', () {
      final r = filterMessages(msgs, categories: {'warning', 'critical'});
      expect(r.length, 2);
    });

    test('query and category combine (both must match)', () {
      final r = filterMessages(msgs, query: 'foh', categories: {'critical'});
      expect(r.length, 1);
      expect(r.first.payload, 'SHOW STOP'); // FOH's info message is excluded
    });

    test('a whitespace-only query is treated as empty', () {
      expect(filterMessages(msgs, query: '   ').length, 3);
    });
  });
}
