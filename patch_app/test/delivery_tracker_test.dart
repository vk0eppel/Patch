// DeliveryTracker owns Critical Message delivery status, keyed by message id.
// clearForMessageIds exists because a per-channel messages_cleared only drops
// that channel's message list — without it, delivery entries for those ids
// would never be removed.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/delivery_tracker.dart';
import 'package:patch/models/message.dart';

const _inProgress = MessageDeliveryStatus(
  delivered: 1,
  total: 2,
  failed: false,
);
const _complete = MessageDeliveryStatus(delivered: 2, total: 2, failed: false);

void main() {
  test('statusFor returns null until tracked', () {
    final t = DeliveryTracker();
    expect(t.statusFor('m1'), isNull);
    t.track('m1', _inProgress);
    expect(t.statusFor('m1'), _inProgress);
  });

  test('all exposes every tracked id', () {
    final t = DeliveryTracker()
      ..track('m1', _inProgress)
      ..track('m2', _complete);
    expect(t.all, {'m1': _inProgress, 'm2': _complete});
  });

  test('clearForMessageIds removes only the given ids', () {
    final t = DeliveryTracker()
      ..track('m1', _inProgress)
      ..track('m2', _complete);
    t.clearForMessageIds(['m1']);
    expect(t.statusFor('m1'), isNull);
    expect(t.statusFor('m2'), _complete);
  });

  test('clearAll removes everything', () {
    final t = DeliveryTracker()
      ..track('m1', _inProgress)
      ..track('m2', _complete);
    t.clearAll();
    expect(t.all, isEmpty);
  });
}
