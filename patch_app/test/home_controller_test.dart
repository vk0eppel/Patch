import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/config.dart';
import 'package:patch/models/message.dart' show PeerInfo;
import 'package:patch/presenters/home_controller.dart';

AppConfig cfg({
  String name = 'Operator',
  bool nameIsDefault = false,
}) =>
    AppConfig(
      clientName: name,
      nameIsDefault: nameIsDefault,
      oscPort: 9000,
      flashOnCritical: true,
      flashOnMessage: false,
      audibleAlert: false,
      flashCount: 3,
      macrosColumns: 2,
      hideKeyboard: false,
      heartbeatIntervalSecs: 7,
    );

void main() {
  group('HomeController.onStoreChanged', () {
    test('forwards config and peers onto the presenter streams', () async {
      final c = HomeController();
      final configs = <AppConfig?>[];
      final peers = <List<PeerInfo>>[];
      c.configStream.listen(configs.add);
      c.peersStream.listen(peers.add);

      c.onStoreChanged(
        config: cfg(),
        peers: const [],
        channelIds: const ['rf'],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      await Future<void>.delayed(Duration.zero);

      expect(configs, hasLength(1));
      expect(peers, hasLength(1));
      c.dispose();
    });

    test('name prompt fires once for a default name, never again', () {
      final c = HomeController();
      final first = c.onStoreChanged(
        config: cfg(nameIsDefault: true),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      final second = c.onStoreChanged(
        config: cfg(nameIsDefault: true),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      expect(first.showNamePrompt, isTrue);
      expect(second.showNamePrompt, isFalse);
      c.dispose();
    });

    test('no name prompt when the Operator already set a name', () {
      final c = HomeController();
      final fx = c.onStoreChanged(
        config: cfg(nameIsDefault: false),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: false,
      );
      expect(fx.showNamePrompt, isFalse);
      c.dispose();
    });

    test(
        'macros panel default derives from configured macros only while '
        'no explicit preference exists', () {
      final c = HomeController();
      final fx = c.onStoreChanged(
        config: cfg(),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: false,
        anyMacrosConfigured: true,
      );
      expect(fx.defaultMacrosPanel, isTrue);

      final afterPreference = c.onStoreChanged(
        config: cfg(),
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: true,
        anyMacrosConfigured: true,
      );
      expect(afterPreference.defaultMacrosPanel, isNull);
      c.dispose();
    });

    test('no macros panel default before the first config load', () {
      final c = HomeController();
      final fx = c.onStoreChanged(
        config: null,
        peers: const [],
        channelIds: const [],
        macrosPanelPreferenceSet: false,
        anyMacrosConfigured: false,
      );
      expect(fx.defaultMacrosPanel, isNull);
      c.dispose();
    });

    test('selection reconciles only when the Channel id list changes', () {
      final c = HomeController();
      HomeStoreEffects fire(List<String> ids) => c.onStoreChanged(
            config: cfg(),
            peers: const [],
            channelIds: ids,
            macrosPanelPreferenceSet: true,
            anyMacrosConfigured: false,
          );

      expect(fire(['rf']).reconcileSelection, isTrue);
      expect(fire(['rf']).reconcileSelection, isFalse);
      expect(fire(['rf', 'audio']).reconcileSelection, isTrue);
      expect(fire(['rf', 'audio']).reconcileSelection, isFalse);
      c.dispose();
    });
  });
}
