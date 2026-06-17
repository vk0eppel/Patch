// Widget tests for PeersPanel — name display, status dots, role badge, empty state.
// Pure widget (no bridge/engine). PeersPanel runs a 3 s periodic timer, so each
// test unmounts it at the end (pump an empty tree) to cancel that timer.
//
// Note: last-seen subtitle, IP address, and channel dots are intentionally omitted
// from the redesigned panel (diagnostic clutter during a live show) — no tests for those.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/theme/patch_theme.dart';
import 'package:patch/widgets/peers_panel.dart';

/// Finds containers with a specific `BoxDecoration` color (status dots).
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
  bool departed = false,
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
      departed: departed,
    );

Widget _host(List<PeerInfo> peers) =>
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          child: PeersPanel(peers: peers),
        ),
      ),
    );

void main() {
  testWidgets('peer name is shown', (tester) async {
    await tester.pumpWidget(
      _host([_peer(name: 'MON', mode: 'osc_beacon')]),
    );
    expect(find.text('MON'), findsOneWidget);
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

  testWidgets('departed peer: gray dot despite a recent last_seen', (tester) async {
    // Heard from just now, but it announced a clean departure → still gray.
    await tester.pumpWidget(
      _host([_peer(name: 'Gone', mode: 'osc_beacon', departed: true)]),
    );
    expect(_dotsWithColor(PatchTheme.success), findsNothing);
    expect(_dotsWithColor(PatchTheme.textMuted), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('departed peer name is italic, live peer name is not', (tester) async {
    await tester.pumpWidget(_host([
      _peer(name: 'Gone', mode: 'osc_beacon', departed: true),
      _peer(name: 'Here', mode: 'osc_beacon'),
    ]));
    final gone = tester.widget<Text>(find.text('Gone'));
    final here = tester.widget<Text>(find.text('Here'));
    expect(gone.style?.fontStyle, FontStyle.italic);
    expect(here.style?.fontStyle, FontStyle.normal);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status dot carries a tooltip explaining the colours', (tester) async {
    await tester.pumpWidget(
      _host([_peer(name: 'MON', mode: 'osc_beacon')]),
    );
    final tips = tester.widgetList<Tooltip>(find.byType(Tooltip));
    final dotTip = tips.firstWhere(
      (t) => (t.message ?? '').contains('Green'),
      orElse: () => fail('no status-dot tooltip found'),
    );
    expect(dotTip.message, contains('Amber'));
    expect(dotTip.message, contains('Grey'));
    expect(dotTip.message, contains('manual')); // covers the manual / offline grey case
    await tester.pumpWidget(const SizedBox());
  });
}
