import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../models/events.dart';
import '../../presenters/settings/identity_presenter.dart';
import '../../store/app_store.dart';
import '../../theme/patch_theme.dart';
import '../../util/run_guarded.dart';
import 'section_scaffold.dart';

/// The Identity section: display name and Role (#140). Save/seed/reset loops
/// live in [IdentityPresenter]; this widget owns only presentation — text
/// controllers and the transient "saved" ticks (ADR-0005).
class IdentitySection extends StatefulWidget {
  const IdentitySection({
    super.key,
    required this.presenter,
    required this.pushes,
  });

  final IdentityPresenter presenter;

  /// Engine pushes — the name save echoes back as [ClientNameChanged], which
  /// drives the saved tick.
  final Stream<PatchEvent> pushes;

  @override
  State<IdentitySection> createState() => _IdentitySectionState();
}

class _IdentitySectionState extends State<IdentitySection> {
  final _nameCtrl = TextEditingController();
  final _roleCtrl = TextEditingController();
  StreamSubscription<PatchEvent>? _pushSub;
  bool _nameSaved = false;
  bool _roleSaved = false;

  @override
  void initState() {
    super.initState();
    _pushSub = widget.pushes.listen((event) {
      if (event is ClientNameChanged) _tick(() => _nameSaved = true, () => _nameSaved = false);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Seed the controllers from config exactly once (presenter-gated) so a
    // later config notify never clobbers the Operator's edits (#56).
    final seed = widget.presenter.seedOnce(AppStoreScope.of(context).config);
    if (seed != null) {
      _nameCtrl.text = seed.name;
      _roleCtrl.text = seed.role;
    }
  }

  @override
  void dispose() {
    _pushSub?.cancel();
    _nameCtrl.dispose();
    _roleCtrl.dispose();
    super.dispose();
  }

  void _tick(VoidCallback on, VoidCallback off) {
    setState(on);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(off);
    });
  }

  void _saveName() =>
      runGuarded(context, () => widget.presenter.saveName(_nameCtrl.text));

  /// No engine event echoes a role save back, so tick optimistically.
  void _saveRole() {
    runGuarded(context, () => widget.presenter.saveRole(_roleCtrl.text));
    _tick(() => _roleSaved = true, () => _roleSaved = false);
  }

  void _reset() {
    final name = Platform.environment['USER'] ??
        Platform.environment['USERNAME'] ??
        'crew';
    runGuarded(context, () async {
      _nameCtrl.text = await widget.presenter.resetIdentity(defaultName: name);
      _roleCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(child: SettingsSectionHeader('Identity')),
          SettingsResetButton(section: 'Identity', onReset: _reset),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Your display name as seen by other Patch users on the network.',
          style: TextStyle(
              color: PatchTheme.textSecondary,
              fontSize: PatchTheme.fontSizeSmall),
        ),
        const SizedBox(height: 10),
        _UsernameField(
          controller: _nameCtrl,
          saved: _nameSaved,
          onSave: _saveName,
        ),
        const SizedBox(height: 12),
        const Text(
          'Optional role (e.g. "FOH", "Monitors", "PM") — shown next to your name '
          'in other crew\'s peers panel. Leave blank for none.',
          style: TextStyle(
              color: PatchTheme.textSecondary,
              fontSize: PatchTheme.fontSizeSmall),
        ),
        const SizedBox(height: 10),
        _UsernameField(
          controller: _roleCtrl,
          saved: _roleSaved,
          onSave: _saveRole,
          hintText: 'Your role (optional)',
          icon: Icons.badge_outlined,
        ),
      ],
    );
  }
}

class _UsernameField extends StatelessWidget {
  final TextEditingController controller;
  final bool saved;
  final VoidCallback onSave;
  final String hintText;
  final IconData icon;

  const _UsernameField({
    required this.controller,
    required this.saved,
    required this.onSave,
    this.hintText = 'Your name (shown to other crew)',
    this.icon = Icons.person_outline,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: const TextStyle(
              color: PatchTheme.textPrimary,
              fontSize: PatchTheme.fontSizeMedium,
            ),
            decoration: InputDecoration(
              hintText: hintText,
              prefixIcon: Icon(icon, color: PatchTheme.textSecondary, size: 18),
            ),
            onSubmitted: (_) => onSave(),
            textInputAction: TextInputAction.done,
          ),
        ),
        const SizedBox(width: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: saved
              ? const Icon(Icons.check_circle,
                  color: PatchTheme.success, key: ValueKey('saved'))
              : ElevatedButton(
                  key: const ValueKey('save'),
                  onPressed: onSave,
                  child: const Text('Save'),
                ),
        ),
      ],
    );
  }
}
