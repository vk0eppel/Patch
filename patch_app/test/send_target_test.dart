import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/selection.dart';
import 'package:patch/models/send_target.dart';

PatchChannel ch(String id, [String? name]) => PatchChannel(
  id: id,
  displayName: name ?? id.toUpperCase(),
  color: Colors.red,
);

void main() {
  group('SendTarget.of', () {
    test('a DM Selection resolves to the open Peer', () {
      final t = SendTarget.of(
        const DmSelection('peer-1'),
        selectedChannels: const [],
        dmPeerName: 'Stage Manager',
      );
      expect(t, isA<DmTarget>());
      expect((t as DmTarget).peerId, 'peer-1');
    });

    test('an ALL Selection resolves to the one-shot broadcast', () {
      final t = SendTarget.of(
        const AllSelection({'rf'}),
        selectedChannels: const [],
      );
      expect(t, isA<AllTarget>());
    });

    test('a Channel Selection resolves to the selected Channels', () {
      final t = SendTarget.of(
        const ChannelSelection({'rf', 'audio'}),
        selectedChannels: [ch('rf'), ch('audio')],
      );
      expect((t as ChannelsTarget).channels.map((c) => c.id), ['rf', 'audio']);
    });
  });

  group('exportKey', () {
    test('DM exports that thread; ALL and multi export everything; '
        'single exports that Channel', () {
      expect(const DmTarget('peer-1').exportKey, 'dm:peer-1');
      expect(const AllTarget().exportKey, isNull);
      expect(ChannelsTarget([ch('rf'), ch('audio')]).exportKey, isNull);
      expect(ChannelsTarget([ch('rf')]).exportKey, 'rf');
    });
  });

  group('clearKeys', () {
    test('DM clears its thread; ALL clears everything', () {
      expect(const DmTarget('peer-1').clearKeys, ['dm:peer-1']);
      expect(const AllTarget().clearKeys, [null]);
    });

    test('multi-Channel clears each selected Channel — not everything', () {
      expect(ChannelsTarget([ch('rf'), ch('audio')]).clearKeys, [
        'rf',
        'audio',
      ]);
    });
  });

  group('labels', () {
    test('exportFileLabel names the export file by target', () {
      expect(
        const DmTarget('p', peerName: 'Stage Manager').exportFileLabel,
        'dm_stage manager',
      );
      expect(const DmTarget('p').exportFileLabel, 'dm_');
      expect(const AllTarget().exportFileLabel, 'all_channels');
      expect(ChannelsTarget([ch('rf', 'RF')]).exportFileLabel, 'rf');
      expect(
        ChannelsTarget([ch('rf'), ch('audio')]).exportFileLabel,
        'all_channels',
      );
    });

    test('clearDescription names what the confirm dialog will wipe', () {
      expect(const DmTarget('p').clearDescription, 'this conversation');
      expect(const AllTarget().clearDescription, 'all channels');
      expect(ChannelsTarget([ch('rf', 'RF')]).clearDescription, 'RF');
      expect(
        ChannelsTarget([ch('rf'), ch('audio')]).clearDescription,
        '2 channels',
      );
    });
  });
}
