// decideMessageFlash is the single decision point for "should an inbound
// message flash" — previously this rule was inlined three different ways in
// home_screen.dart's _dispatch (channel / __all__ / dm:) with no test surface.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/flash_model.dart';
import 'package:patch/models/message.dart';

PatchMessage _msg({required String channelId, int priority = 1}) =>
    PatchMessage(
      messageId: 'm1',
      senderId: 's1',
      senderName: 'Sender',
      channelId: channelId,
      timestamp: DateTime(2026, 1, 1),
      priority: priority,
      payload: 'hi',
    );

void main() {
  group('channel messages', () {
    const channel = PatchChannel(
      id: 'rf',
      displayName: 'RF',
      color: Colors.red,
    );

    test('no flash when neither global nor per-channel flag is set', () {
      final event = decideMessageFlash(
        msg: _msg(channelId: 'rf'),
        channels: const [channel],
        globalOnCritical: false,
        globalOnMessage: false,
        globalPulseCount: 4,
      );
      expect(event, isNull);
    });

    test('per-channel flashOnMessage flashes even with global flags off', () {
      const ch = PatchChannel(
        id: 'rf',
        displayName: 'RF',
        color: Colors.red,
        flashOnMessage: true,
        flashOnCritical: false,
      );
      final event = decideMessageFlash(
        msg: _msg(channelId: 'rf'),
        channels: const [ch],
        globalOnCritical: false,
        globalOnMessage: false,
        globalPulseCount: 4,
      );
      expect(event, isA<ChannelFlashEvent>());
    });

    test('critical message flashes when global flashOnCritical is set', () {
      final event =
          decideMessageFlash(
                msg: _msg(channelId: 'rf', priority: 3),
                channels: const [channel],
                globalOnCritical: true,
                globalOnMessage: false,
                globalPulseCount: 4,
              )
              as ChannelFlashEvent;
      expect(event.channelId, 'rf');
      expect(event.color, Colors.red);
    });

    test('per-channel flashCount overrides the global pulse count', () {
      const ch = PatchChannel(
        id: 'rf',
        displayName: 'RF',
        color: Colors.red,
        flashOnMessage: true,
        flashCount: 7,
      );
      final event =
          decideMessageFlash(
                msg: _msg(channelId: 'rf'),
                channels: const [ch],
                globalOnCritical: false,
                globalOnMessage: true,
                globalPulseCount: 4,
              )
              as ChannelFlashEvent;
      expect(event.pulseCount, 7);
    });

    test('unknown channel id never flashes', () {
      final event = decideMessageFlash(
        msg: _msg(channelId: 'missing', priority: 3),
        channels: const [channel],
        globalOnCritical: true,
        globalOnMessage: true,
        globalPulseCount: 4,
      );
      expect(event, isNull);
    });
  });

  group('broadcast (__all__) messages', () {
    test('flashes on globalOnMessage regardless of priority', () {
      final event =
          decideMessageFlash(
                msg: _msg(channelId: kAllChannelId),
                channels: const [],
                globalOnCritical: false,
                globalOnMessage: true,
                globalPulseCount: 5,
              )
              as BroadcastFlashEvent;
      expect(event.pulseCount, 5);
    });

    test('no flash when not critical and globalOnMessage is off', () {
      final event = decideMessageFlash(
        msg: _msg(channelId: kAllChannelId),
        channels: const [],
        globalOnCritical: true,
        globalOnMessage: false,
        globalPulseCount: 5,
      );
      expect(event, isNull);
    });
  });

  group('direct messages', () {
    test('critical DM flashes', () {
      final event =
          decideMessageFlash(
                msg: _msg(channelId: 'dm:p1', priority: 3),
                channels: const [],
                globalOnCritical: true,
                globalOnMessage: false,
                globalPulseCount: 4,
              )
              as DmFlashEvent;
      expect(event.peerId, 'p1');
    });

    test('non-critical DM never flashes, even with globalOnMessage set', () {
      final event = decideMessageFlash(
        msg: _msg(channelId: 'dm:p1'),
        channels: const [],
        globalOnCritical: true,
        globalOnMessage: true,
        globalPulseCount: 4,
      );
      expect(
        event,
        isNull,
      ); // caller marks it unread instead — not a flash decision
    });
  });
}
