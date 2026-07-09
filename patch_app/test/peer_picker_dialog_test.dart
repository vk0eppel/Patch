import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/widgets/peer_picker_dialog.dart';

PeerInfo peer(String name, {String address = '10.0.0.5', int port = 9000}) =>
    PeerInfo(
      peerId: 'id-$name',
      peerName: name,
      role: null,
      channels: const [],
      address: address,
      oscPort: port,
      lastSeen: DateTime(2026, 7, 9),
      discoveryMode: 'OscBeacon',
      status: PeerStatus.online,
      departed: false,
    );

Widget host(PeerPickerDialog dialog) =>
    MaterialApp(home: Scaffold(body: dialog));

void main() {
  testWidgets('lists only peers with a known address and port; tap picks',
      (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(host(PeerPickerDialog(
      title: 'Import channels from…',
      blurb: 'Pick a peer.',
      peers: [
        peer('FOH'),
        peer('NoAddress', address: ''),
        peer('NoPort', port: 0),
      ],
      onPick: (id, name) => picked.add('$id:$name'),
    )));

    expect(find.text('FOH'), findsOneWidget);
    expect(find.text('NoAddress'), findsNothing);
    expect(find.text('NoPort'), findsNothing);

    await tester.tap(find.text('FOH'));
    await tester.pumpAndSettle();
    expect(picked, ['id-FOH:FOH']);
  });

  testWidgets('no eligible peers shows the wait-for-a-peer empty state',
      (tester) async {
    await tester.pumpWidget(host(PeerPickerDialog(
      title: 'Import macros from…',
      blurb: 'Pick a peer.',
      peers: [peer('Ghost', address: '')],
      onPick: (_, _) => fail('nothing to pick'),
    )));

    expect(find.textContaining('No peers with a known address'), findsOneWidget);
  });
}
