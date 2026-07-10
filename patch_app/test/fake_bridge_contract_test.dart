import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/events.dart';

import 'support/fake_bridge.dart';

/// Pins the shared fixture's own contract (#188): a bridge method a test
/// exercises without stubbing fails loudly — it can never silently fall
/// through to a live FFI-calling implementation.
void main() {
  test('an unstubbed bridge call throws instead of reaching FFI', () {
    final bridge = FakeBridge();
    expect(() => bridge.shutdown(), throwsA(isA<UnimplementedError>()));
    expect(() => bridge.resetChannels(), throwsA(isA<UnimplementedError>()));
  });

  test('push delivers synchronously to every listener', () {
    final bridge = FakeBridge();
    final seen = <PatchEvent>[];
    bridge.pushes.listen(seen.add);
    bridge.push(const PeersChanged());
    expect(seen, [const PeersChanged()]);
  });
}
