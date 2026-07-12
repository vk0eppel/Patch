import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Whether the first-run identity prompt should be shown: the display name is
/// still the system default and we haven't already shown it this session.
/// Pure so the decision is unit-testable without a bridge.
bool shouldShowNamePrompt({
  required bool nameIsDefault,
  required bool alreadyShown,
}) => nameIsDefault && !alreadyShown;

const _kRoleSuggestions = ['FOH', 'MON', 'PM', 'LD', 'TD', 'Stage', 'Comms'];

/// Show the first-run identity prompt. Collects name (pre-filled with
/// [currentName]) and role (empty, with suggestion chips) in one step.
///
/// Calls [onSaveName] with a trimmed non-empty name and [onSaveRole] with the
/// trimmed role (may be empty — role is optional). "Skip" or a barrier tap
/// closes without saving. Never blocks the home screen.
Future<void> showNamePrompt(
  BuildContext context, {
  required String currentName,
  required ValueChanged<String> onSaveName,
  required ValueChanged<String> onSaveRole,
}) {
  final nameCtrl = TextEditingController(
    text: currentName,
  )..selection = TextSelection(baseOffset: 0, extentOffset: currentName.length);
  final roleCtrl = TextEditingController();

  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          void save() {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            onSaveName(name);
            onSaveRole(roleCtrl.text.trim());
            Navigator.of(ctx).pop();
          }

          return AlertDialog(
            title: const Text('Set your identity'),
            content: SizedBox(
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "This is how the crew sees you on the network. "
                    "Set a name and optionally your role.",
                    style: TextStyle(color: PatchTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: nameCtrl,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Display name',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) {},
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: roleCtrl,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Role (optional)',
                      hintText: 'e.g. FOH Audio, Stage Manager',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => save(),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: _kRoleSuggestions.map((suggestion) {
                      final selected = roleCtrl.text.trim() == suggestion;
                      return GestureDetector(
                        onTap: () => setState(() {
                          roleCtrl.text = selected ? '' : suggestion;
                          roleCtrl.selection = TextSelection.collapsed(
                            offset: roleCtrl.text.length,
                          );
                        }),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: selected
                                ? PatchTheme.accent.withAlpha(40)
                                : PatchTheme.surfaceHigh,
                            border: Border.all(
                              color: selected
                                  ? PatchTheme.accent
                                  : PatchTheme.border,
                            ),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            suggestion,
                            style: TextStyle(
                              color: selected
                                  ? PatchTheme.accent
                                  : PatchTheme.textSecondary,
                              fontSize: PatchTheme.fontSizeSmall,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
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
                style: ElevatedButton.styleFrom(
                  backgroundColor: PatchTheme.accent,
                ),
                onPressed: save,
                child: const Text(
                  'Use this name',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      );
    },
  );
}
