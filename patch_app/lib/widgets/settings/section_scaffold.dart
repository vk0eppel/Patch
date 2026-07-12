import 'package:flutter/material.dart';

import '../../theme/patch_theme.dart';

/// Uppercase section header used by every Settings section (#140).
class SettingsSectionHeader extends StatelessWidget {
  final String title;
  const SettingsSectionHeader(this.title, {super.key});

  @override
  Widget build(BuildContext context) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: PatchTheme.textSecondary,
        fontSize: PatchTheme.fontSizeSmall,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.5,
      ),
    );
  }
}

/// The shared "Reset <section>?" confirmation dialog.
Future<bool> confirmSettingsReset(BuildContext context, String section) async {
  return await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text('Reset $section?'),
          content: SizedBox(
            width: double.infinity,
            child: Text(
              'This will restore factory defaults for $section.',
              style: const TextStyle(color: PatchTheme.textSecondary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Reset'),
            ),
          ],
        ),
      ) ??
      false;
}

/// Reset-to-defaults icon button with the shared confirmation dialog.
class SettingsResetButton extends StatelessWidget {
  final String section;
  final VoidCallback onReset;
  const SettingsResetButton({
    super.key,
    required this.section,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.restart_alt, size: 18),
      color: PatchTheme.textMuted,
      tooltip: 'Reset $section to defaults',
      onPressed: () async {
        if (await confirmSettingsReset(context, section)) onReset();
      },
    );
  }
}
