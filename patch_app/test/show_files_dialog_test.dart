import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/message.dart';
import 'package:patch/widgets/show_files_dialog.dart';

/// A fake bridge adapter (#177): the second adapter at the command seam.
/// Screens depend on BridgeClient's implicit interface, so a test can stand
/// in for the engine without booting FFI.
class _FakeBridge extends Fake implements BridgeClient {
  final List<ShowFileMeta> showFiles;
  final deletedSlugs = <String>[];

  _FakeBridge(this.showFiles);

  @override
  Future<List<ShowFileMeta>> listShowFiles() async => showFiles;

  @override
  Future<void> deleteShowFile({required String slug}) async {
    deletedSlugs.add(slug);
  }
}

void main() {
  final festival = ShowFileMeta(
    slug: 'festival-day-1',
    name: 'Festival Day 1',
    createdAt: DateTime(2026, 7, 1),
    channelCount: 4,
  );

  Future<void> pumpDialog(WidgetTester tester, _FakeBridge bridge) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ShowFilesDialog(bridge: bridge))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('deleting a Show File issues the command through the bridge',
      (tester) async {
    final bridge = _FakeBridge([festival]);
    await pumpDialog(tester, bridge);
    expect(find.text('Festival Day 1'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(bridge.deletedSlugs, ['festival-day-1']);
  });

  testWidgets('cancelling the confirm dialog deletes nothing', (tester) async {
    final bridge = _FakeBridge([festival]);
    await pumpDialog(tester, bridge);

    await tester.tap(find.byTooltip('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(bridge.deletedSlugs, isEmpty);
  });
}
