import 'package:flutter_test/flutter_test.dart';
import 'package:patch/util/section_scroll_spy.dart';

/// #183: the Settings scrollspy's active-section decision, extracted from
/// widget plumbing so its rules are assertable.
void main() {
  late SectionScrollSpy spy;

  setUp(() => spy = SectionScrollSpy());

  group('SectionScrollSpy', () {
    test('the last section whose top passed the viewport top is active', () {
      // viewport top at 100; sections at 0, 60, 140 → section 1 is active.
      expect(
        spy.activeFor(sectionTops: [0, 60, 140], viewportTop: 100),
        1,
      );
    });

    test('a header within 1px of the top counts as passed (tolerance)', () {
      expect(
        spy.activeFor(sectionTops: [0, 100.9, 200], viewportTop: 100),
        1,
      );
      expect(
        spy.activeFor(sectionTops: [0, 101.5, 200], viewportTop: 100),
        0,
      );
    });

    test('an unresolved section (null top) is skipped, not a stop', () {
      // Section 1's box hasn't resolved; section 2 has passed the top and
      // must still be found.
      expect(
        spy.activeFor(sectionTops: [0, null, 90], viewportTop: 100),
        2,
      );
    });

    test('an indeterminate frame (no tops resolved) leaves the highlight '
        'alone', () {
      expect(
        spy.activeFor(sectionTops: [null, null, null], viewportTop: 100),
        isNull,
      );
    });

    test('sections are in document order — the first unpassed section ends '
        'the search', () {
      // Section 2 misordered below the viewport top must not be reached
      // once section 1 is above it... i.e. search stops at first top beyond
      // the viewport top.
      expect(
        spy.activeFor(sectionTops: [0, 200, 50], viewportTop: 100),
        0,
      );
    });

    test('while suppressed (programmatic scroll in flight) every frame is '
        'a no-op', () {
      spy.suppressed = true;
      expect(
        spy.activeFor(sectionTops: [0, 60], viewportTop: 100),
        isNull,
      );
      spy.suppressed = false;
      expect(
        spy.activeFor(sectionTops: [0, 60], viewportTop: 100),
        1,
      );
    });
  });
}
