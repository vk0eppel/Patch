import 'dart:async';

import '../models/config.dart';
import '../models/message.dart' show PeerInfo;
import '../widgets/name_prompt.dart' show shouldShowNamePrompt;

/// What the Home screen must do in response to one store notification.
/// Pure data — the widget applies these (dialogs, setState, workspace saves).
class HomeStoreEffects {
  /// Show the one-shot first-run name prompt (at most once per session).
  final bool showNamePrompt;

  /// Set the macros-panel default (derived from whether any Macros are
  /// configured) — only on the first config load while the Operator has never
  /// explicitly toggled the panel. Null means leave it alone.
  final bool? defaultMacrosPanel;

  /// The Channel id list changed — reconcile the current selection.
  final bool reconcileSelection;

  const HomeStoreEffects({
    required this.showNamePrompt,
    required this.defaultMacrosPanel,
    required this.reconcileSelection,
  });
}

/// Owns the Home screen's store→presenter wiring: fans each store
/// notification into the config/peers streams `HomePresenter` consumes, and
/// reduces the notification to [HomeStoreEffects] — the one-shot name-prompt
/// gate, the first-load macros-panel default, and channel-set change
/// detection. Extracted from `home_screen.dart` so this wiring is testable
/// without pumping the whole screen (#139). Screen presentation (dialogs,
/// flash reactions) stays in the widget per ADR-0005.
class HomeController {
  final _configCtrl = StreamController<AppConfig?>.broadcast();
  final _peersCtrl = StreamController<List<PeerInfo>>.broadcast();

  bool _namePromptShown = false;
  List<String>? _lastChannelIds;

  /// Config values as they arrive from the store — `HomePresenter`'s
  /// `configStream` input.
  Stream<AppConfig?> get configStream => _configCtrl.stream;

  /// Peer lists as they arrive from the store — `HomePresenter`'s
  /// `peersStream` input.
  Stream<List<PeerInfo>> get peersStream => _peersCtrl.stream;

  /// Reduce one store notification: forward config/peers to the streams and
  /// decide the one-shot effects.
  HomeStoreEffects onStoreChanged({
    required AppConfig? config,
    required List<PeerInfo> peers,
    required List<String> channelIds,
    required bool macrosPanelPreferenceSet,
    required bool anyMacrosConfigured,
  }) {
    _configCtrl.add(config);
    _peersCtrl.add(peers);

    var showNamePrompt = false;
    bool? defaultMacrosPanel;
    if (config != null) {
      showNamePrompt = shouldShowNamePrompt(
        nameIsDefault: config.nameIsDefault,
        alreadyShown: _namePromptShown,
      );
      if (showNamePrompt) _namePromptShown = true;
      if (!macrosPanelPreferenceSet) {
        defaultMacrosPanel = anyMacrosConfigured;
      }
    }

    var reconcile = false;
    if (!_sameIds(channelIds, _lastChannelIds)) {
      _lastChannelIds = List.of(channelIds);
      reconcile = true;
    }

    return HomeStoreEffects(
      showNamePrompt: showNamePrompt,
      defaultMacrosPanel: defaultMacrosPanel,
      reconcileSelection: reconcile,
    );
  }

  static bool _sameIds(List<String> a, List<String>? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void dispose() {
    _configCtrl.close();
    _peersCtrl.close();
  }
}
