import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart' show kAllChannelId;
import 'package:patch/models/selection.dart';
import 'package:patch/util/macro_dispatch.dart';
import 'package:patch/widgets/macros_panel.dart' show ChannelMacro;

ChannelMacro _perChannel(String channelId) => ChannelMacro(
      channelId: channelId,
      channelColor: Colors.white,
      macro: const MacroMessage(label: 'GO', payload: 'GO', priority: 1),
    );

ChannelMacro _global() => ChannelMacro(
      channelId: '',
      channelColor: Colors.white,
      macro: const MacroMessage(label: 'GO', payload: 'GO', priority: 1),
    );

void main() {
  test('per-channel macro routes to its own channel regardless of channel selection', () {
    final result = resolveMacroTarget(_perChannel('rf'), const ChannelSelection({'audio'}));
    expect(result, isA<ChannelTarget>());
    expect((result as ChannelTarget).channelIds, ['rf']);
  });

  test('global macro + ChannelSelection routes to all selected channel ids', () {
    final result = resolveMacroTarget(_global(), const ChannelSelection({'rf', 'audio'}));
    expect(result, isA<ChannelTarget>());
    expect((result as ChannelTarget).channelIds, containsAll(['rf', 'audio']));
    expect((result).channelIds, hasLength(2));
  });

  test('global macro + AllSelection routes to kAllChannelId', () {
    final result = resolveMacroTarget(_global(), const AllSelection({}));
    expect(result, isA<ChannelTarget>());
    expect((result as ChannelTarget).channelIds, [kAllChannelId]);
  });

  test('per-channel macro + DmSelection routes to DM peer', () {
    final result = resolveMacroTarget(_perChannel('rf'), const DmSelection('p1'));
    expect(result, isA<DmTarget>());
    expect((result as DmTarget).peerId, 'p1');
  });

  test('global macro + DmSelection routes to DM peer', () {
    final result = resolveMacroTarget(_global(), const DmSelection('p2'));
    expect(result, isA<DmTarget>());
    expect((result as DmTarget).peerId, 'p2');
  });
}
