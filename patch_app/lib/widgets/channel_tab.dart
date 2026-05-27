import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme/patch_theme.dart';

class ChannelTab extends StatefulWidget {
  final PatchChannel channel;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Increment this each time a flash arrives for this channel to
  /// trigger the pulse animation.
  final int flashCount;

  /// How many times the tab should pulse per flash event.
  final int pulseCount;

  const ChannelTab({
    super.key,
    required this.channel,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    this.flashCount = 0,
    this.pulseCount = 4,
  });

  @override
  State<ChannelTab> createState() => _ChannelTabState();
}

class _ChannelTabState extends State<ChannelTab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _glow;

  int _remainingPulses = 0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );

    // Scale: snap up, ease back down
    _scale = TweenSequence([
      TweenSequenceItem(
          tween: Tween(begin: 1.0, end: 1.35)
              .chain(CurveTween(curve: Curves.easeOut)),
          weight: 30),
      TweenSequenceItem(
          tween: Tween(begin: 1.35, end: 1.0)
              .chain(CurveTween(curve: Curves.elasticOut)),
          weight: 70),
    ]).animate(_ctrl);

    // Glow: bright flash in first half, fade in second half
    _glow = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 70),
    ]).animate(_ctrl);

    _ctrl.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _remainingPulses > 0) {
      _remainingPulses--;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(ChannelTab old) {
    super.didUpdateWidget(old);
    if (widget.flashCount > old.flashCount) {
      _remainingPulses = (widget.pulseCount - 1).clamp(0, 99);
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, child) {
          return Transform.scale(
            scale: _scale.value,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                // Blend normal selected colour with the flash glow
                color: Color.lerp(
                  widget.isSelected
                      ? widget.channel.color.withAlpha(40)
                      : Colors.transparent,
                  widget.channel.color.withAlpha(180),
                  _glow.value,
                ),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: Color.lerp(
                    widget.isSelected
                        ? widget.channel.color
                        : Colors.transparent,
                    Colors.white,
                    _glow.value * 0.7,
                  )!,
                  width: widget.isSelected || _glow.value > 0 ? 1.5 : 0,
                ),
                boxShadow: _glow.value > 0
                    ? [
                        BoxShadow(
                          color: widget.channel.color
                              .withAlpha((180 * _glow.value).toInt()),
                          blurRadius: 12 * _glow.value,
                          spreadRadius: 2 * _glow.value,
                        )
                      ]
                    : null,
              ),
              child: child,
            ),
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: widget.channel.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.channel.displayName,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: widget.isSelected
                    ? PatchTheme.textPrimary
                    : PatchTheme.textSecondary,
                fontSize: 10,
                fontWeight:
                    widget.isSelected ? FontWeight.w700 : FontWeight.w400,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
