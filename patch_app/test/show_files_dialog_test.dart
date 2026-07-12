import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/widgets/show_files_dialog.dart';

import 'support/fake_bridge.dart';

void main() {
  final festival = ShowFileMeta(
    slug: 'festival-day-1',
    name: 'Festival Day 1',
    createdAt: DateTime(2026, 7, 1),
    channelCount: 4,
  );

  Future<void> pumpDialog(WidgetTester tester, FakeBridge bridge) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ShowFilesDialog(bridge: bridge)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('deleting a Show File issues the command through the bridge', (
    tester,
  ) async {
    final bridge = FakeBridge()..showFilesToReturn = [festival];
    await pumpDialog(tester, bridge);
    expect(find.text('Festival Day 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(bridge.deletedShowFileSlugs, ['festival-day-1']);
  });

  testWidgets('cancelling the confirm dialog deletes nothing', (tester) async {
    final bridge = FakeBridge()..showFilesToReturn = [festival];
    await pumpDialog(tester, bridge);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(bridge.deletedShowFileSlugs, isEmpty);
  });
}
