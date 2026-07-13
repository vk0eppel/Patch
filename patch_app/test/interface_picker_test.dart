// Widget tests for InterfacePicker — the Settings → Network interface dropdown.
//
// Regression: a persisted network_interface that isn't in the current
// enumeration (NIC down / no IPv4 / different machine) used to crash the screen
// with "There should be exactly one item with [DropdownButton]'s value: …".
// The picker now surfaces it as a "(not connected)" item so the value always
// has a matching entry.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/interface_picker.dart';

const _ifaces = [
  {'name': 'en0', 'ip': '192.168.1.5'},
  {'name': 'en1', 'ip': '10.0.0.2'},
];

Widget _host({
  required List<Map<String, String>> interfaces,
  String? selected,
}) => MaterialApp(
  home: Scaffold(
    body: InterfacePicker(
      interfaces: interfaces,
      selected: selected,
      applied: false,
      onSelect: (_) {},
    ),
  ),
);

void main() {
  testWidgets('never renders an Auto option (mandatory pinning)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(interfaces: _ifaces, selected: null));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Auto'), findsNothing);
  });

  testWidgets(
    'shows a distinct placeholder when nothing has ever been resolved',
    (tester) async {
      await tester.pumpWidget(_host(interfaces: _ifaces, selected: null));
      expect(tester.takeException(), isNull);
      expect(find.text('Select a network…'), findsOneWidget);
      expect(find.textContaining('not connected'), findsNothing);
    },
  );

  testWidgets('renders with an enumerated interface selected', (tester) async {
    await tester.pumpWidget(_host(interfaces: _ifaces, selected: 'en0'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('en0'), findsWidgets);
  });

  testWidgets(
    'does not crash when the saved interface is missing from the list',
    (tester) async {
      // The reported bug: selected 'en10' is not among the enumerated interfaces.
      await tester.pumpWidget(_host(interfaces: _ifaces, selected: 'en10'));
      expect(tester.takeException(), isNull); // no DropdownButton assertion
      // The stale selection is surfaced so it stays visible/editable.
      expect(find.textContaining('en10'), findsOneWidget);
      expect(find.textContaining('not connected'), findsOneWidget);
    },
  );

  testWidgets('does not crash when the interface list is empty', (
    tester,
  ) async {
    await tester.pumpWidget(_host(interfaces: const [], selected: 'en10'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('en10'), findsOneWidget);
  });

  testWidgets('shows a prominent banner while unresolved', (tester) async {
    await tester.pumpWidget(_host(interfaces: _ifaces, selected: null));
    expect(find.textContaining('No network selected'), findsOneWidget);
    expect(find.textContaining('Static peers still work'), findsOneWidget);
  });

  testWidgets('hides the banner once an interface is pinned', (tester) async {
    await tester.pumpWidget(_host(interfaces: _ifaces, selected: 'en0'));
    expect(find.textContaining('No network selected'), findsNothing);
  });
}
