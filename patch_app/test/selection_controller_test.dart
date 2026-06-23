// Unit tests for SelectionController — the Selection-transition rules
// extracted from home_screen.dart's _toggleChannel/_openDm/_snapBackFromAll/
// _reconcileSelectionWithChannels (#62, #63). Pure Dart: no widget pump, no
// BuildContext, no BridgeClient/AppStore mock.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart';
import 'package:patch/models/selection.dart';
import 'package:patch/models/selection_controller.dart';

PatchChannel _ch(String id) =>
    PatchChannel(id: id, displayName: id, color: Colors.blue);

void main() {
  group('selectTab', () {
    test('tapping the ALL sentinel from a ChannelSelection stashes the current ids', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.selectTab(kAllChannelId);

      expect(c.selection, const AllSelection({'rf', 'audio'}));
      expect(toFetch, {kAllChannelId});
    });

    test('tapping a dm:-prefixed id produces DmSelection regardless of prior state', () {
      final c = SelectionController();
      c.selectTab('rf');
      final toFetch = c.selectTab('dm:p1');

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });

    test('tapping a plain id from AllSelection cancels ALL and selects just that channel', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab(kAllChannelId);
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('tapping a plain id from DmSelection cancels DM mode and selects just that channel', () {
      final c = SelectionController();
      c.selectTab('dm:p1');
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('toggling an already-selected id out of a multi-channel selection removes it', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.selectTab('rf');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('toggling the last remaining selected id is a no-op — never an empty selection', () {
      final c = SelectionController();
      c.selectTab('rf');
      final toFetch = c.selectTab('rf');

      expect(c.selection, const ChannelSelection({'rf'}));
      expect(toFetch, {'rf'});
    });

    test('tapping a new id while in ChannelSelection adds it', () {
      final c = SelectionController();
      c.selectTab('rf');
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'rf', 'audio'}));
      expect(toFetch, {'rf', 'audio'});
    });
  });

  group('openDm', () {
    test('always produces DmSelection(peerId), regardless of prior selection', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.openDm('p1');

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });

    test('opening a different DM thread replaces the previous one', () {
      final c = SelectionController();
      c.openDm('p1');
      final toFetch = c.openDm('p2');

      expect(c.selection, const DmSelection('p2'));
      expect(toFetch, {'dm:p2'});
    });
  });

  group('snapBackFromAll', () {
    test('restores AllSelection.previous when non-empty', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab('audio');
      c.selectTab(kAllChannelId);
      final toFetch = c.snapBackFromAll([_ch('rf'), _ch('audio')]);

      expect(c.selection, const ChannelSelection({'rf', 'audio'}));
      expect(toFetch, {'rf', 'audio'});
    });

    test('falls back to the first given channel when previous is empty', () {
      final c = SelectionController();
      c.selectTab(kAllChannelId); // no prior ChannelSelection -> previous == {}
      final toFetch = c.snapBackFromAll([_ch('rf'), _ch('audio')]);

      expect(c.selection, const ChannelSelection({'rf'}));
      expect(toFetch, {'rf'});
    });

    test('leaves the selection untouched when both previous and channels are empty', () {
      final c = SelectionController();
      c.selectTab(kAllChannelId);
      final toFetch = c.snapBackFromAll(const []);

      expect(c.selection, const AllSelection({}));
      expect(toFetch, {kAllChannelId});
    });
  });

  group('reconcileWithChannels', () {
    test('drops stale ids from a ChannelSelection, keeping ids still present', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('reseeds to the first channel when no previously-selected id survives', () {
      final c = SelectionController();
      c.selectTab('rf');
      final toFetch = c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('reseeds to an empty ChannelSelection when the channel list itself is empty', () {
      final c = SelectionController();
      c.selectTab('rf');
      final toFetch = c.reconcileWithChannels(const []);

      expect(c.selection, const ChannelSelection({}));
      expect(toFetch, isEmpty);
    });

    test('leaves AllSelection untouched regardless of the channel list', () {
      final c = SelectionController();
      c.selectTab('rf');
      c.selectTab(kAllChannelId);
      final toFetch = c.reconcileWithChannels([_ch('audio')]);

      expect(c.selection, const AllSelection({'rf'}));
      expect(toFetch, {kAllChannelId});
    });

    test('leaves DmSelection untouched regardless of the channel list', () {
      final c = SelectionController();
      c.selectTab('dm:p1');
      final toFetch = c.reconcileWithChannels([_ch('audio')]);

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });
  });

  group('_idsToEnsure rule', () {
    test('a ChannelSelection returns its tab ids', () {
      final c = SelectionController();
      expect(c.selectTab('rf'), {'rf'});
    });

    test('AllSelection returns the ALL sentinel', () {
      final c = SelectionController();
      expect(c.selectTab(kAllChannelId), {kAllChannelId});
    });

    test('DmSelection returns the dm:<peer> key', () {
      final c = SelectionController();
      expect(c.selectTab('dm:p1'), {'dm:p1'});
    });
  });
}
