/// The Settings scrollspy's active-section decision (#183), pure so its
/// rules are testable: the active section is whichever header has most
/// recently scrolled past the top of the viewport. The widget owns geometry
/// (RenderBox reads) and the [suppressed] lifecycle around programmatic
/// tap-scrolls; this class owns the decision.
class SectionScrollSpy {
  /// `ensureVisible(alignment: 0)` doesn't always land the header at
  /// *exactly* the viewport top (sub-pixel rounding), so a header within
  /// this tolerance counts as passed.
  static const tolerance = 1.0;

  /// True while a tap-triggered scroll animation is in flight — the spy
  /// would disagree with the section the user just tapped for a frame or
  /// two, so every frame is a no-op until the animation settles.
  bool suppressed = false;

  /// The active section for this frame, or null to leave the current
  /// highlight alone (suppressed, or an indeterminate frame where no
  /// section's geometry resolved). [sectionTops] are the headers' global
  /// tops in document order; a null entry (unresolved RenderBox) is skipped.
  /// The first resolved header still below the viewport top ends the search
  /// — sections are in document order, so nothing past it can have passed.
  int? activeFor({
    required List<double?> sectionTops,
    required double viewportTop,
  }) {
    if (suppressed) return null;
    int? active;
    for (var i = 0; i < sectionTops.length; i++) {
      final top = sectionTops[i];
      if (top == null) continue;
      if (top <= viewportTop + tolerance) {
        active = i;
      } else {
        break;
      }
    }
    return active;
  }
}
