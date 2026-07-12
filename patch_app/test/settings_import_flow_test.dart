import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/events.dart';
import 'package:patch/screens/settings_screen.dart';
import 'package:patch/store/app_store.dart';

import 'support/fake_bridge.dart';

/// #182: the picker → request → offer flow, end to end through a fake
/// bridge — the previously-untested dialog choreography around the
/// PeerRequestGate. Uses the shared FakeBridge (#188) with a peer preloaded.
FakeBridge _bridge() =>
    FakeBridge()..peersToReturn = [peerInfo('peer-foh', peerName: 'FOH')];

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
    final bridge = _bridge();
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
    bridge.push(
      ChannelsOffered(
        fromPeerId: 'peer-foh',
        fromName: 'FOH',
        channels: [
          PatchChannel(
            id: 'rf',
            displayName: 'RF',
            color: const Color(0xFFFF0000),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Channels from FOH'), findsOneWidget);

    // Flush the gate's 6s timeout timer so the test ends with no timer pending.
    await tester.pump(const Duration(seconds: 7));
  });

  testWidgets('an unsolicited offer opens nothing', (tester) async {
    final bridge = _bridge();
    final store = AppStore(bridge);
    await store.start();

    await tester.pumpWidget(
      AppStoreScope(
        store: store,
        child: MaterialApp(home: SettingsScreen(bridge: bridge)),
      ),
    );
    await tester.pumpAndSettle();

    bridge.push(
      ChannelsOffered(
        fromPeerId: 'peer-foh',
        fromName: 'FOH',
        channels: [
          PatchChannel(
            id: 'rf',
            displayName: 'RF',
            color: const Color(0xFFFF0000),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Channels from FOH'), findsNothing);
  });
}
