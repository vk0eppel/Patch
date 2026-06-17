import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// The peers-panel toggle in the channel header (shown only while the panel is
/// closed). Carries the static unread-DM dot and pulses **once** in the accent
/// colour whenever [pulseNotify] increments — a brief "a DM just arrived" cue
/// that draws the eye without a full-screen flash.
///
/// Uses the timer-based `setState` pulse pattern (like `_FlashLayer` /
/// `ChannelTab`) rather than `AnimationController`/`TweenSequence`, which has
/// proven visually unreliable on macOS.
class PulsingPeersButton extends StatefulWidget {
  /// Monotonic counter; each increment fires one pulse.
  final int pulseNotify;

  /// Whether any DM thread is unread — shows the persistent red dot.
  final bool hasUnread;
  final VoidCallback onPressed;

  const PulsingPeersButton({
    super.key,
    required this.pulseNotify,
    required this.hasUnread,
    required this.onPressed,
  });

  @override
  State<PulsingPeersButton> createState() => _PulsingPeersButtonState();
}

class _PulsingPeersButtonState extends State<PulsingPeersButton> {
  bool _lit = false;

  /// Bumped per pulse so a DM arriving mid-pulse restarts the cue cleanly
  /// instead of leaving two overlapping timers running.
  int _gen = 0;

  @override
  void didUpdateWidget(PulsingPeersButton old) {
    super.didUpdateWidget(old);
    if (widget.pulseNotify > old.pulseNotify) _pulse();
  }

  Future<void> _pulse() async {
    final gen = ++_gen;
    if (!mounted) return;
    setState(() => _lit = true);
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted || gen != _gen) return;
    setState(() => _lit = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          icon: Icon(
            Icons.people,
            color: _lit ? PatchTheme.accent : PatchTheme.textMuted,
            size: 20,
          ),
          tooltip: 'Show peers',
          onPressed: widget.onPressed,
        ),
        if (widget.hasUnread)
          Positioned(
            right: 8,
            top: 8,
            child: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: PatchTheme.critical,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}
