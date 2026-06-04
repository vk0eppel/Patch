import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// The FLASH button — prominent, hard to miss.
/// Sends a high-priority page to everyone in the channel.
class FlashButton extends StatefulWidget {
  final VoidCallback onFlash;

  const FlashButton({super.key, required this.onFlash});

  @override
  State<FlashButton> createState() => _FlashButtonState();
}

class _FlashButtonState extends State<FlashButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<Color?> _colorAnim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _colorAnim = ColorTween(
      begin: PatchTheme.surfaceHigh,
      end: PatchTheme.warning,
    ).animate(_anim);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _handleFlash() {
    widget.onFlash();
    _anim.forward().then((_) => _anim.reverse());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => ElevatedButton.icon(
        onPressed: _handleFlash,
        icon: const Icon(Icons.flash_on, size: 18),
        label: const Text(
          'FLASH',
          style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.5),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _colorAnim.value ?? PatchTheme.surfaceHigh,
          foregroundColor: PatchTheme.textPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}
