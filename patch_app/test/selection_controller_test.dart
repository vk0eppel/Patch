// Unit tests for SelectionController — the Selection-transition rules
// extracted from home_screen.dart's _toggleChannel/_openDm/_snapBackFromAll/
// _reconcileSelectionWithChannels (#62, #63).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/message.dart';
import 'package:patch/models/selection.dart';
import 'package:patch/models/selection_controller.dart';
import 'package:patch/store/app_store.dart';

import 'support/fake_bridge.dart';

// ── Fakes ──────────────────────────────────────────────────────────────────

class _FakeStore extends AppStore {
  _FakeStore() : super(FakeBridge());

  final List<String> ensuredIds = [];

  @override
  Future<void> ensureMessages(String channelId) async {
    ensuredIds.add(channelId);
  }
}

SelectionController _ctrl({_FakeStore? store, FakeBridge? bridge}) =>
    SelectionController(store ?? _FakeStore(), bridge ?? FakeBridge());

// ── Helpers ─────────────────────────────────────────────────────────────────

PatchChannel _ch(String id) =>
    PatchChannel(id: id, displayName: id, color: Colors.blue);

// ── Transition-rule tests (unchanged assertions, updated constructor) ────────

void main() {
  group('selectTab', () {
    test('tapping the ALL sentinel from a ChannelSelection stashes the current ids', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.selectTab(kAllChannelId);

      expect(c.selection, const AllSelection({'rf', 'audio'}));
      expect(toFetch, {kAllChannelId});
    });

    test('tapping a dm:-prefixed id produces DmSelection regardless of prior state', () {
      final c = _ctrl();
      c.selectTab('rf');
      final toFetch = c.selectTab('dm:p1');

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });

    test('tapping a plain id from AllSelection cancels ALL and selects just that channel', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab(kAllChannelId);
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('tapping a plain id from DmSelection cancels DM mode and selects just that channel', () {
      final c = _ctrl();
      c.selectTab('dm:p1');
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('toggling an already-selected id out of a multi-channel selection removes it', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.selectTab('rf');

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('toggling the last remaining selected id is a no-op — never an empty selection', () {
      final c = _ctrl();
      c.selectTab('rf');
      final toFetch = c.selectTab('rf');

      expect(c.selection, const ChannelSelection({'rf'}));
      expect(toFetch, {'rf'});
    });

    test('tapping a new id while in ChannelSelection adds it', () {
      final c = _ctrl();
      c.selectTab('rf');
      final toFetch = c.selectTab('audio');

      expect(c.selection, const ChannelSelection({'rf', 'audio'}));
      expect(toFetch, {'rf', 'audio'});
    });
  });

  group('openDm', () {
    test('always produces DmSelection(peerId), regardless of prior selection', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.openDm('p1');

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });

    test('opening a different DM thread replaces the previous one', () {
      final c = _ctrl();
      c.openDm('p1');
      final toFetch = c.openDm('p2');

      expect(c.selection, const DmSelection('p2'));
      expect(toFetch, {'dm:p2'});
    });
  });

  group('snapBackFromAll', () {
    test('restores AllSelection.previous when non-empty', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab('audio');
      c.selectTab(kAllChannelId);
      final toFetch = c.snapBackFromAll([_ch('rf'), _ch('audio')]);

      expect(c.selection, const ChannelSelection({'rf', 'audio'}));
      expect(toFetch, {'rf', 'audio'});
    });

    test('falls back to the first given channel when previous is empty', () {
      final c = _ctrl();
      c.selectTab(kAllChannelId); // no prior ChannelSelection -> previous == {}
      final toFetch = c.snapBackFromAll([_ch('rf'), _ch('audio')]);

      expect(c.selection, const ChannelSelection({'rf'}));
      expect(toFetch, {'rf'});
    });

    test('leaves the selection untouched when both previous and channels are empty', () {
      final c = _ctrl();
      c.selectTab(kAllChannelId);
      final toFetch = c.snapBackFromAll(const []);

      expect(c.selection, const AllSelection({}));
      expect(toFetch, {kAllChannelId});
    });
  });

  group('reconcileWithChannels', () {
    test('drops stale ids from a ChannelSelection, keeping ids still present', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab('audio');
      final toFetch = c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('reseeds to the first channel when no previously-selected id survives', () {
      final c = _ctrl();
      c.selectTab('rf');
      final toFetch = c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(c.selection, const ChannelSelection({'audio'}));
      expect(toFetch, {'audio'});
    });

    test('reseeds to an empty ChannelSelection when the channel list itself is empty', () {
      final c = _ctrl();
      c.selectTab('rf');
      final toFetch = c.reconcileWithChannels(const []);

      expect(c.selection, const ChannelSelection({}));
      expect(toFetch, isEmpty);
    });

    test('leaves AllSelection untouched regardless of the channel list', () {
      final c = _ctrl();
      c.selectTab('rf');
      c.selectTab(kAllChannelId);
      final toFetch = c.reconcileWithChannels([_ch('audio')]);

      expect(c.selection, const AllSelection({'rf'}));
      expect(toFetch, {kAllChannelId});
    });

    test('leaves DmSelection untouched regardless of the channel list', () {
      final c = _ctrl();
      c.selectTab('dm:p1');
      final toFetch = c.reconcileWithChannels([_ch('audio')]);

      expect(c.selection, const DmSelection('p1'));
      expect(toFetch, {'dm:p1'});
    });
  });

  group('_idsToEnsure rule', () {
    test('a ChannelSelection returns its tab ids', () {
      final c = _ctrl();
      expect(c.selectTab('rf'), {'rf'});
    });

    test('AllSelection returns the ALL sentinel', () {
      final c = _ctrl();
      expect(c.selectTab(kAllChannelId), {kAllChannelId});
    });

    test('DmSelection returns the dm:<peer> key', () {
      final c = _ctrl();
      expect(c.selectTab('dm:p1'), {'dm:p1'});
    });
  });

  // ── Side-effect tests (#94) ─────────────────────────────────────────────────

  group('side effects — ensureMessages', () {
    test('selectTab(channelId) calls ensureMessages for the selected channel', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());

      c.selectTab('rf');

      expect(store.ensuredIds, contains('rf'));
    });

    test('selectTab(dm:peer) calls ensureMessages for the dm key', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());

      c.selectTab('dm:p1');

      expect(store.ensuredIds, contains('dm:p1'));
    });

    test('selectTab(kAllChannelId) calls ensureMessages for the ALL sentinel', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());

      c.selectTab(kAllChannelId);

      expect(store.ensuredIds, contains(kAllChannelId));
    });

    test('openDm calls ensureMessages for the dm key', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());

      c.openDm('p1');

      expect(store.ensuredIds, contains('dm:p1'));
    });

    test('snapBackFromAll calls ensureMessages for the restored channel ids', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());
      c.selectTab('rf');
      c.selectTab(kAllChannelId);
      store.ensuredIds.clear();

      c.snapBackFromAll([_ch('rf'), _ch('audio')]);

      expect(store.ensuredIds, contains('rf'));
    });

    test('reconcileWithChannels calls ensureMessages for the surviving channel', () {
      final store = _FakeStore();
      final c = SelectionController(store, FakeBridge());
      c.selectTab('rf');
      c.selectTab('audio');
      store.ensuredIds.clear();

      c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(store.ensuredIds, contains('audio'));
    });
  });

  group('side effects — syncSelection', () {
    test('selectTab(channelId) pushes channelId to setSelectedChannels and null to setDmTarget', () {
      final bridge = FakeBridge();
      final c = SelectionController(_FakeStore(), bridge);

      c.selectTab('rf');

      expect(bridge.selectedChannelsCalls.last, ['rf']);
      expect(bridge.dmTargetCalls.last, isNull);
    });

    test('selectTab(dm:peer) pushes empty channel list and peerId to setDmTarget', () {
      final bridge = FakeBridge();
      final c = SelectionController(_FakeStore(), bridge);

      c.selectTab('dm:p1');

      expect(bridge.selectedChannelsCalls.last, isEmpty);
      expect(bridge.dmTargetCalls.last, 'p1');
    });

    test('selectTab(kAllChannelId) pushes the ALL sentinel to setSelectedChannels and null DM target', () {
      final bridge = FakeBridge();
      final c = SelectionController(_FakeStore(), bridge);

      c.selectTab(kAllChannelId);

      expect(bridge.selectedChannelsCalls.last, [kAllChannelId]);
      expect(bridge.dmTargetCalls.last, isNull);
    });

    test('openDm pushes empty channel list and peerId to setDmTarget', () {
      final bridge = FakeBridge();
      final c = SelectionController(_FakeStore(), bridge);

      c.openDm('p2');

      expect(bridge.selectedChannelsCalls.last, isEmpty);
      expect(bridge.dmTargetCalls.last, 'p2');
    });

    test('reconcileWithChannels syncs the post-reconcile selection', () {
      final bridge = FakeBridge();
      final c = SelectionController(_FakeStore(), bridge);
      c.selectTab('rf');
      c.selectTab('audio');
      bridge.selectedChannelsCalls.clear();
      bridge.dmTargetCalls.clear();

      c.reconcileWithChannels([_ch('audio'), _ch('lx')]);

      expect(bridge.selectedChannelsCalls.last, ['audio']);
      expect(bridge.dmTargetCalls.last, isNull);
    });
  });
}
