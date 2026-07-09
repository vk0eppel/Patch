import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/config.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/message.dart';
import 'package:patch/screens/settings_screen.dart';
import 'package:patch/store/app_store.dart';

/// #182: the picker → request → offer flow, end to end through a fake bridge —
/// the previously-untested dialog choreography around the PeerRequestGate.
class _FakeBridge extends BridgeClient {
  final _pushController = StreamController<PatchEvent>.broadcast();
  final requestedChannelsFrom = <String>[];

  @override
  Stream<PatchEvent> get pushes => _pushController.stream;

  void push(PatchEvent e) => _pushController.add(e);

  @override
  Future<List<PeerInfo>> getPeers() async => [
        PeerInfo(
          peerId: 'peer-foh',
          peerName: 'FOH',
          role: null,
          channels: const [],
          address: '10.0.0.5',
          oscPort: 9000,
          lastSeen: DateTime(2026, 7, 9),
          discoveryMode: 'OscBeacon',
          status: PeerStatus.online,
          departed: false,
        ),
      ];

  @override
  Future<AppConfig> getConfig() async => AppConfig(
        clientName: 'Me',
        oscPort: 9000,
        flashOnCritical: true,
        flashOnMessage: false,
        flashCount: 4,
        macrosColumns: 1,
        hideKeyboard: true,
        audibleAlert: false,
        heartbeatIntervalSecs: 7,
        nameIsDefault: false,
      );

  @override
  Future<List<PatchChannel>> getChannels() async => const [];

  @override
  Future<List<PatchMessage>> getMessages(String channelId,
          {int limit = 500}) async =>
      const [];

  @override
  Future<List<({String name, String ip})>> getInterfaces() async => const [];

  @override
  Future<void> requestChannels({required String peerId}) async {
    requestedChannelsFrom.add(peerId);
  }
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Patch',
      packageName: 'patch',
      version: '0.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
  });

  testWidgets('picker → request → offer: picking a Peer requests its channels '
      'and the solicited offer opens the preview dialog', (tester) async {
    final bridge = _FakeBridge();
    final store = AppStore(bridge);
    await store.start();

    await tester.pumpWidget(
      AppStoreScope(
        store: store,
        child: MaterialApp(home: SettingsScreen(bridge: bridge)),
      ),
    );
    await tester.pumpAndSettle();

    // Open the channels import picker and pick the peer (the button lives
    // far down the page — bring it into the viewport first).
    await tester.ensureVisible(find.byTooltip('Import channels from a peer'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Import channels from a peer'));
    await tester.pumpAndSettle();
    expect(find.text('FOH'), findsOneWidget);
    await tester.tap(find.text('FOH'));
    await tester.pump();
    expect(bridge.requestedChannelsFrom, ['peer-foh']);

    // The solicited offer arrives → the preview dialog opens.
    bridge.push(ChannelsOffered(
      fromPeerId: 'peer-foh',
      fromName: 'FOH',
      channels: [
        PatchChannel(id: 'rf', displayName: 'RF', color: const Color(0xFFFF0000)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Channels from FOH'), findsOneWidget);

    // Flush the gate's 6s timeout timer so the test ends with no timer pending.
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('an unsolicited offer opens nothing', (tester) async {
    final bridge = _FakeBridge();
    final store = AppStore(bridge);
    await store.start();

    await tester.pumpWidget(
      AppStoreScope(
        store: store,
        child: MaterialApp(home: SettingsScreen(bridge: bridge)),
      ),
    );
    await tester.pumpAndSettle();

    bridge.push(ChannelsOffered(
      fromPeerId: 'peer-foh',
      fromName: 'FOH',
      channels: [
        PatchChannel(id: 'rf', displayName: 'RF', color: const Color(0xFFFF0000)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Channels from FOH'), findsNothing);
  });
}
