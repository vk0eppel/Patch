// Widget tests for the snackBarTheme default in PatchTheme.dark() — operational
// SnackBars (delivery failure, permission denied, DM-offline warning, generic
// runGuarded errors) must float above the footer-height compose bar instead of
// covering it (issue #70).
//
// Hosts a synthetic Scaffold with a footer-height tappable stand-in for
// MessageInput's send button, rather than the real HomeScreen — kept at the
// smallest seam that exercises the shared theme default. See
// pulsing_peers_button_test.dart / peers_panel_test.dart for the same
// isolated-widget-host style.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/theme/patch_theme.dart';

const _footerKey = Key('footer');

Widget _host({required VoidCallback onFooterTap}) {
  return MaterialApp(
    theme: PatchTheme.dark(),
    home: Scaffold(
      body: Stack(
        children: [
          Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Critical message not delivered'),
                  ),
                ),
                child: const Text('Trigger alert'),
              ),
            ),
          ),
          Positioned(
            key: _footerKey,
            left: 0,
            right: 0,
            bottom: 0,
            height: PatchTheme.footerHeight,
            child: Container(
              color: PatchTheme.surface,
              child: Center(
                child: ElevatedButton(
                  onPressed: onFooterTap,
                  child: const Text('Send'),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('footer control stays tappable while a SnackBar is showing', (
    tester,
  ) async {
    var tapped = false;
    await tester.pumpWidget(_host(onFooterTap: () => tapped = true));

    await tester.tap(find.text('Trigger alert'));
    await tester.pump(); // start the SnackBar's entrance animation
    await tester.pump(const Duration(milliseconds: 300)); // let it settle in

    expect(find.text('Critical message not delivered'), findsOneWidget);

    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(
      tapped,
      isTrue,
      reason:
          'the footer control must remain tappable under a floating SnackBar',
    );
  });

  testWidgets('SnackBar renders clear of the footer, not overlapping it', (
    tester,
  ) async {
    await tester.pumpWidget(_host(onFooterTap: () {}));

    await tester.tap(find.text('Trigger alert'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // SnackBar's own render box includes its (invisible) margin, so its bottom
    // edge always sits at the screen edge regardless of margin — measure the
    // visible text content instead, which is tightly bound by the margin.
    final snackBarTextBottom = tester
        .getBottomLeft(find.text('Critical message not delivered'))
        .dy;
    final footerTop = tester.getTopLeft(find.byKey(_footerKey)).dy;

    expect(snackBarTextBottom, lessThanOrEqualTo(footerTop));
  });
}
