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
}) =>
    PeerInfo(
      peerId: name,
      peerName: name,
      channels: const [],
      address: address,
      oscPort: 9000,
      lastSeen: DateTime.now().subtract(seenAgo),
      discoveryMode: mode,
    );

Widget _host(List<PeerInfo> peers) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 200, child: PeersPanel(peers: peers))),
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
