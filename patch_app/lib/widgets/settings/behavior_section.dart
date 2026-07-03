import 'dart:io';

import 'package:flutter/material.dart';

import '../../presenters/settings/behavior_presenter.dart';
import '../../store/app_store.dart';
import '../../theme/patch_theme.dart';
import '../../util/run_guarded.dart';
import 'flash_count_picker.dart';
import 'section_scaffold.dart';

/// The Behavior section (#141): flash triggers, audible alert, pulse count,
/// macros-panel columns, keyboard hiding. Save→refetch loops and bounds live
/// in [BehaviorPresenter]; this widget owns presentation only (ADR-0005).
class BehaviorSection extends StatelessWidget {
  const BehaviorSection({super.key, required this.presenter});

  final BehaviorPresenter presenter;

  @override
  Widget build(BuildContext context) {
    final config = AppStoreScope.of(context).config;
    final flashOnMessage = config?.flashOnMessage ?? false;
    final flashOnCritical = config?.flashOnCritical ?? true;
    final audibleAlert = config?.audibleAlert ?? false;
    final flashWholeScreen = config?.flashWholeScreen ?? false;
    final hideKeyboard = config?.hideKeyboard ?? true;
    final flashCount = config?.flashCount ?? 4;
    final macrosColumns = config?.macrosColumns ?? 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(child: SettingsSectionHeader('Behavior')),
          SettingsResetButton(
            section: 'Behavior',
            onReset: () => runGuarded(context, presenter.resetDefaults),
          ),
        ]),
        const SizedBox(height: 4),
        SwitchListTile(
          title: const Text(
            'Flash on every message',
            style: TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeSmall),
          ),
          subtitle: const Text(
            'Flash the channel border on any incoming message',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
          ),
          value: flashOnMessage,
          activeThumbColor: PatchTheme.accent,
          contentPadding: EdgeInsets.zero,
          onChanged: (val) =>
              runGuarded(context, () => presenter.saveFlashOnMessage(val)),
        ),
        SwitchListTile(
          title: const Text(
            'Flash on critical messages',
            style: TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeSmall),
          ),
          subtitle: const Text(
            'Flash the channel border when a priority-3 message arrives',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
          ),
          value: flashOnCritical,
          activeThumbColor: PatchTheme.accent,
          contentPadding: EdgeInsets.zero,
          onChanged: (val) =>
              runGuarded(context, () => presenter.saveFlashOnCritical(val)),
        ),
        SwitchListTile(
          title: const Text(
            'Audible alert',
            style: TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeSmall),
          ),
          subtitle: const Text(
            'Play a sound when a channel flashes (critical / page / broadcast)',
            style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
          ),
          value: audibleAlert,
          activeThumbColor: PatchTheme.accent,
          contentPadding: EdgeInsets.zero,
          onChanged: (val) =>
              runGuarded(context, () => presenter.saveAudibleAlert(val)),
        ),
        // Desktop-only — sandboxing makes drawing over other apps technically
        // impossible on iOS/Android, so the control is absent there entirely.
        if (Platform.isMacOS || Platform.isWindows) ...[
          SwitchListTile(
            title: const Text(
              'Flash whole screen',
              style: TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeSmall),
            ),
            subtitle: const Text(
              'Also pulse a full-screen overlay so a Flash is visible even when '
              'Patch isn\'t the focused app',
              style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
            ),
            value: flashWholeScreen,
            activeThumbColor: PatchTheme.accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) =>
                runGuarded(context, () => presenter.saveFlashWholeScreen(val)),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Flash pulses',
                    style: TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  Text(
                    'Number of times the channel flashes per event',
                    style:
                        TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            FlashCountPicker(
              value: flashCount,
              onChanged: (val) {
                if (val == null) return; // global picker never yields null
                runGuarded(context, () => presenter.saveFlashCount(val));
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Macros panel columns',
                    style: TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  Text(
                    'Number of columns in the macros side panel',
                    style:
                        TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1')),
                ButtonSegment(value: 2, label: Text('2')),
                ButtonSegment(value: 3, label: Text('3')),
              ],
              selected: {macrosColumns},
              onSelectionChanged: (s) => runGuarded(
                  context, () => presenter.saveMacrosColumns(s.first)),
              style: SegmentedButton.styleFrom(
                foregroundColor: PatchTheme.textSecondary,
                selectedForegroundColor: PatchTheme.accent,
                selectedBackgroundColor: PatchTheme.accent.withAlpha(30),
                side: const BorderSide(color: PatchTheme.border),
              ),
            ),
          ],
        ),
        if (Platform.isIOS || Platform.isAndroid) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text(
              'Hide keyboard on channel switch',
              style: TextStyle(
                  color: PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeSmall),
            ),
            subtitle: const Text(
              'Keeps the software keyboard hidden until you tap the input field',
              style: TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
            ),
            value: hideKeyboard,
            activeThumbColor: PatchTheme.accent,
            contentPadding: EdgeInsets.zero,
            onChanged: (val) =>
                runGuarded(context, () => presenter.saveHideKeyboard(val)),
          ),
        ],
      ],
    );
  }
}
