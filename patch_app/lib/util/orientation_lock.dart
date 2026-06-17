/// Whether the app should lock to landscape at startup.
///
/// Only on an **iPad-class iOS device** (shortest side ≥ 600 dp — the standard
/// Flutter tablet threshold). The multi-panel layout (channel strip + optional
/// peers panel + message area + optional macros panel) is fixed-width and
/// unusable in portrait; portrait support needs a responsive rewrite (out of
/// scope). Desktop (macOS/Windows/Linux) and iPhone are unaffected — kept pure
/// so the gating is unit-testable without platform channels.
bool shouldLockLandscape({required bool isIOS, required double shortestSide}) =>
    isIOS && shortestSide >= 600;
