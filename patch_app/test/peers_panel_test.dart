// Widget test for PeersPanel — focuses on the per-peer "last seen" line.
// Pure widget (no bridge/engine). PeersPanel runs a 3 s periodic timer, so each
// test unmounts it at the end (pump an empty tree) to cancel that timer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/theme/patch_theme.dart';
import 'package:patch/widgets/peers_panel.dart';

/// Finds status dots (the only `Container`s with a coloured `BoxDecoration`).
Finder _dotsWithColor(Color c) => find.byWidgetPredicate(
      (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).color == c,
    );

PeerInfo _peer({
  required String name,
  required String mode,
  Duration seenAgo = Duration.zero,
  String address = '192.168.1.5',
  List<String> channels = const [],
  String? role,
}) =>
    PeerInfo(
      peerId: name,
      peerName: name,
      role: role,
      channels: channels,
      address: address,
      oscPort: 9000,
      lastSeen: DateTime.now().subtract(seenAgo),
      discoveryMode: mode,
    );

Widget _host(List<PeerInfo> peers, {Map<String, Color> channelColors = const {}}) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: PeersPanel(peers: peers, channelColors: channelColors),
        ),
      ),
    );

void main() {
  testWidgets('dynamic peer shows a relative "last seen"', (tester) async {
    await tester.pumpWidget(
      _host([_peer(name: 'MON', mode: 'osc_beacon', seenAgo: const Duration(seconds: 30))]),
    );
    expect(find.text('MON'), findsOneWidget);
    expect(find.textContaining('ago'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // unmount → cancel the panel timer
  });

  testWidgets('a freshly-heard peer reads "now"', (tester) async {
    await tester.pumpWidget(_host([_peer(name: 'FOH', mode: 'mdns')]));
    expect(find.textContaining('now'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual peer shows its address, not a relative time', (tester) async {
    await tester.pumpWidget(_host([_peer(name: 'Booth', mode: 'manual_ip', address: '10.0.0.9')]));
    expect(find.textContaining('ago'), findsNothing);
    expect(find.textContaining('10.0.0.9'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('empty list shows the no-peers hint', (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(find.text('No peers yet'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dot is amber when a heartbeat or more has been missed', (tester) async {
    await tester.pumpWidget(
      _host([_peer(name: 'MON', mode: 'osc_beacon', seenAgo: const Duration(seconds: 20))]),
    );
    expect(_dotsWithColor(PatchTheme.warning), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('renders a colour dot per announced channel, "+N" past the cap',
      (tester) async {
    // Two distinct channel colours (kept away from the status-dot palette so the
    // finder counts only channel dots), one unknown channel → grey fallback.
    const rf = Color(0xFF111111);
    const audio = Color(0xFF222222);
    await tester.pumpWidget(_host(
      [
        _peer(
          name: 'MON',
          mode: 'osc_beacon',
          channels: const ['rf', 'audio', 'ghost'],
        ),
      ],
      channelColors: const {'rf': rf, 'audio': audio},
    ));
    expect(_dotsWithColor(rf), findsOneWidget);
    expect(_dotsWithColor(audio), findsOneWidget);
    // 'ghost' isn't in the viewer's map → grey fallback dot.
    expect(_dotsWithColor(PatchTheme.textMuted), findsOneWidget);
    expect(find.text('+'), findsNothing); // 3 ≤ cap, no overflow label

    // Past the cap (5) the remainder collapses into a "+N" label.
    await tester.pumpWidget(_host(
      [
        _peer(
          name: 'MON',
          mode: 'osc_beacon',
          channels: const ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
        ),
      ],
    ));
    expect(find.text('+2'), findsOneWidget); // 7 channels, 5 shown
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('shows the role badge when set, omits it when unset', (tester) async {
    await tester.pumpWidget(_host([
      _peer(name: 'Sam', mode: 'osc_beacon', role: 'FOH'),
      _peer(name: 'Alex', mode: 'osc_beacon'), // no role
    ]));
    expect(find.text('FOH'), findsOneWidget);
    expect(find.text('Sam'), findsOneWidget);
    expect(find.text('Alex'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dot is green when healthy, gray when stale or manual', (tester) async {
    await tester.pumpWidget(_host([
      _peer(name: 'FOH', mode: 'mdns'), // fresh → green
      _peer(name: 'Old', mode: 'osc_beacon', seenAgo: const Duration(seconds: 90)), // stale → gray
      _peer(name: 'Booth', mode: 'manual_ip'), // configured → gray
    ]));
    expect(_dotsWithColor(PatchTheme.success), findsOneWidget);
    expect(_dotsWithColor(PatchTheme.textMuted), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });
}
