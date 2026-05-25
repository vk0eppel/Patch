import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../theme/patch_theme.dart';

class ChannelTab extends StatelessWidget {
  final PatchChannel channel;
  final bool isSelected;
  final VoidCallback onTap;

  const ChannelTab({
    super.key,
    required this.channel,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? channel.color.withAlpha(40) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: isSelected
              ? Border.all(color: channel.color, width: 1.5)
              : Border.all(color: Colors.transparent),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: channel.color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              channel.displayName,
              textAlign: TextAlign.center,
              maxLines: 2,
              style: TextStyle(
                color: isSelected ? PatchTheme.textPrimary : PatchTheme.textSecondary,
                fontSize: 10,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w400,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
