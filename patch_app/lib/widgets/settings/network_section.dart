import 'package:flutter/material.dart';

import '../../presenters/settings/network_presenter.dart';
import '../../screens/help_screen.dart';
import '../../store/app_store.dart';
import '../../theme/patch_theme.dart';
import '../../util/run_guarded.dart';
import '../bounded_int_field.dart';
import '../interface_picker.dart';
import 'section_scaffold.dart';

/// The Network section: discovery interface, heartbeat interval, OSC port
/// (#140). Validate→save→refetch loops live in [NetworkPresenter]; this
/// widget owns only the picker state and the transient "applied" tick
/// (ADR-0005).
class NetworkSection extends StatefulWidget {
  const NetworkSection({super.key, required this.presenter});

  final NetworkPresenter presenter;

  @override
  State<NetworkSection> createState() => _NetworkSectionState();
}

class _NetworkSectionState extends State<NetworkSection> {
  List<Map<String, String>> _interfaces = [];
  bool _interfaceApplied = false;

  @override
  void initState() {
    super.initState();
    widget.presenter.loadInterfaces().then((ifaces) {
      if (mounted) setState(() => _interfaces = ifaces);
    });
  }

  void _selectInterface(String? name) {
    // null only happens by tapping the "Select a network…" placeholder
    // itself while unresolved — a no-op, not a way to unpin.
    if (name == null) return;
    runGuarded(context, () async {
      await widget.presenter.selectInterface(name);
      if (!mounted) return;
      setState(() => _interfaceApplied = true);
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _interfaceApplied = false);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final config = AppStoreScope.of(context).config;
    final heartbeat = config?.heartbeatIntervalSecs ?? 7;
    final oscPort = config?.oscPort ?? 9000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Expanded(child: SettingsSectionHeader('Network')),
          IconButton(
            icon: const Icon(Icons.help_outline, size: 16),
            color: PatchTheme.textMuted,
            tooltip: 'Networking guide',
            onPressed: () => openHelp(context,
                assetPath: 'assets/docs/networking.md', title: 'Networking'),
          ),
        ]),
        const SizedBox(height: 4),
        const Text(
          'Confines Patch to this network — peers on other networks are '
          'ignored unless added as static peers. Applies within a few '
          'seconds — no restart.',
          style: TextStyle(
              color: PatchTheme.textSecondary,
              fontSize: PatchTheme.fontSizeSmall),
        ),
        const SizedBox(height: 12),
        InterfacePicker(
          interfaces: _interfaces,
          selected: config?.networkInterface,
          applied: _interfaceApplied,
          onSelect: _selectInterface,
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Heartbeat interval',
                    style: TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  Text(
                    'How often (seconds) Patch announces itself. Lower = faster peer '
                    'detection but more traffic. Applies live, 1–60.',
                    style:
                        TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            BoundedIntField(
              // Key by value so an external config refresh reseeds the field.
              key: ValueKey(heartbeat),
              value: heartbeat,
              min: NetworkPresenter.heartbeatMin,
              max: NetworkPresenter.heartbeatMax,
              suffix: 's',
              onSubmit: (secs) => runGuarded(
                  context, () => widget.presenter.saveHeartbeatInterval(secs)),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'OSC port',
                    style: TextStyle(
                      color: PatchTheme.textPrimary,
                      fontSize: PatchTheme.fontSizeSmall,
                    ),
                  ),
                  Text(
                    'UDP port for OSC discovery + messaging. All peers must share '
                    'it. Applies live (socket rebinds), 1024–65535.',
                    style:
                        TextStyle(color: PatchTheme.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            BoundedIntField(
              key: ValueKey(oscPort),
              value: oscPort,
              min: NetworkPresenter.oscPortMin,
              max: NetworkPresenter.oscPortMax,
              onSubmit: (port) =>
                  runGuarded(context, () => widget.presenter.saveOscPort(port)),
            ),
            IconButton(
              icon: const Icon(Icons.help_outline, size: 16),
              color: PatchTheme.textMuted,
              tooltip: 'OSC integration guide',
              onPressed: () => openHelp(context,
                  assetPath: 'assets/docs/osc-integration.md',
                  title: 'OSC Integration'),
            ),
          ],
        ),
      ],
    );
  }
}
