// Unit tests for the landscape-lock gating decision. The SystemChrome call in
// main() is platform glue verified manually on an iPad simulator (per #6); the
// decision logic is pure and tested here.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/util/orientation_lock.dart';

void main() {
  test('locks on an iPad-class iOS device', () {
    expect(shouldLockLandscape(isIOS: true, shortestSide: 768), isTrue); // iPad
    expect(shouldLockLandscape(isIOS: true, shortestSide: 600), isTrue); // boundary
  });

  test('does not lock on iPhone', () {
    expect(shouldLockLandscape(isIOS: true, shortestSide: 375), isFalse);
  });

  test('does not lock on desktop (non-iOS), regardless of size', () {
    expect(shouldLockLandscape(isIOS: false, shortestSide: 1200), isFalse);
    expect(shouldLockLandscape(isIOS: false, shortestSide: 700), isFalse);
  });
}
