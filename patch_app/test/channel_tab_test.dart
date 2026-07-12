// Regression test for #193: ChannelTab's tap target must cover its full
// slot, including the margin band around the decorated interior — a plain
// Padding never self-hit-tests, so GestureDetector's default
// HitTestBehavior.deferToChild left that band a dead zone.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/widgets/channel_tab.dart';

void main() {
  testWidgets('tapping near the very edge of a ChannelTab still registers',
      (tester) async {
    var tapped = false;

    await tester.pumpWidget(MaterialApp(
      home: SizedBox(
        width: 80,
        height: 60,
        child: ChannelTab(
          channel: const PatchChannel(
            id: 'audio',
            displayName: 'AUDIO',
            color: Colors.red,
          ),
          isSelected: false,
          onTap: () => tapped = true,
        ),
      ),
    ));

    // 1px from the top-left corner of the tab's allotted slot — inside the
    // margin band, not the decorated interior.
    await tester.tapAt(tester.getTopLeft(find.byType(ChannelTab)) + const Offset(1, 1));
    await tester.pump();

    expect(tapped, isTrue);
  });
}
