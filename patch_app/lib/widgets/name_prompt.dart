import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Whether the first-run "set your name" prompt should be shown: the display
/// name is still the system default and we haven't already shown it this
/// session. Pure so the decision is unit-testable without a bridge.
bool shouldShowNamePrompt({
  required bool nameIsDefault,
  required bool alreadyShown,
}) =>
    nameIsDefault && !alreadyShown;

/// Show the skippable first-run name prompt. Pre-fills [currentName], selected
/// for immediate overtype. Calls [onSave] with a trimmed, non-empty name when
/// the operator saves; "Skip" or a barrier tap closes without calling it.
///
/// Never blocks — it's a dialog over the home screen, not a gate before it, so
/// a crew member in a hurry can always dismiss and get on comms.
Future<void> showNamePrompt(
  BuildContext context, {
  required String currentName,
  required ValueChanged<String> onSave,
}) {
  final controller = TextEditingController(text: currentName)
    ..selection = TextSelection(baseOffset: 0, extentOffset: currentName.length);
  return showDialog<void>(
    context: context,
    barrierDismissible: true, // dismiss = skip; must never block comms
    builder: (ctx) {
      void save() {
        final name = controller.text.trim();
        if (name.isEmpty) return; // don't save an empty name
        onSave(name);
        Navigator.of(ctx).pop();
      }

      return AlertDialog(
        title: const Text('Set your name'),
        content: SizedBox(
          width: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "This is how the crew sees you on the network. "
                "Pick a name they'll recognise.",
                style: TextStyle(color: PatchTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (_) => save(),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Skip'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: PatchTheme.accent),
            onPressed: save,
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      );
    },
  );
}
