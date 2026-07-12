// Widget tests for MessageSearchBar — the in-channel search field + priority
// toggles. Bridge-free; verifies it emits the right callbacks and reflects the
// active category set.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/widgets/message_search_bar.dart';

Widget _host({
  String query = '',
  Set<String> categories = const {},
  ValueChanged<String>? onQueryChanged,
  ValueChanged<String>? onToggleCategory,
  VoidCallback? onClose,
}) => MaterialApp(
  home: Scaffold(
    body: MessageSearchBar(
      query: query,
      categories: categories,
      onQueryChanged: onQueryChanged ?? (_) {},
      onToggleCategory: onToggleCategory ?? (_) {},
      onClose: onClose ?? () {},
    ),
  ),
);

void main() {
  testWidgets('renders the field and the three priority chips', (tester) async {
    await tester.pumpWidget(_host());
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Info'), findsOneWidget);
    expect(find.text('Warning'), findsOneWidget);
    expect(find.text('Critical'), findsOneWidget);
  });

  testWidgets('typing reports the query', (tester) async {
    String? q;
    await tester.pumpWidget(_host(onQueryChanged: (v) => q = v));
    await tester.enterText(find.byType(TextField), 'foh');
    expect(q, 'foh');
  });

  testWidgets('tapping a chip toggles its category', (tester) async {
    String? toggled;
    await tester.pumpWidget(_host(onToggleCategory: (c) => toggled = c));
    await tester.tap(find.text('Critical'));
    await tester.pump();
    expect(toggled, 'critical');
  });

  testWidgets('an active category renders selected', (tester) async {
    await tester.pumpWidget(_host(categories: {'warning'}));
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Warning'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('the close button fires onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(_host(onClose: () => closed = true));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(closed, isTrue);
  });
}
