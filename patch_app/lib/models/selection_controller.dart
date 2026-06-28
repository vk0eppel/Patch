import '../bridge/bridge_client.dart';
import '../store/app_store.dart';
import 'channel.dart';
import 'message.dart' show kAllChannelId;
import 'selection.dart';

/// Owns every Selection transition rule and their side effects — what tapping a
/// channel tab, opening a DM thread, sending in ALL mode, or the channel list
/// changing underneath the current selection should produce. Mirrors the registry
/// split in ADR-0003: this controller mutates its own state, fires
/// `ensureMessages` / `syncSelection` itself, and returns which ids it ensured so
/// callers can verify in tests. `home_screen.dart` calls one method per
/// interaction and does not need to orchestrate the side effects.
///
/// Deliberately excludes DM unread-tracking and open-thread bookkeeping
/// (`_unreadDms`, `_openDms` in `home_screen.dart`) — those stay screen-local
/// per ADR-0005's "unread-DM sets are screen-local UI state."
class SelectionController {
  SelectionController(this._store, this._bridge);

  final AppStore _store;
  final BridgeClient _bridge;

  Selection _selection = const ChannelSelection({});
  Selection get selection => _selection;

  Set<String> get _idsToEnsure => _selection.dmPeerId != null
      ? {'dm:${_selection.dmPeerId}'}
      : _selection.tabIds;

  /// Calls `ensureMessages` for all relevant ids and pushes the current
  /// selection to the engine (setSelectedChannels + setDmTarget). Fire-and-forget
  /// — callers do not await the returned futures.
  void _callSideEffects() {
    for (final id in _idsToEnsure) {
      _store.ensureMessages(id);
    }
    _bridge.setSelectedChannels(_selection.tabIds.toList());
    _bridge.setDmTarget(_selection.dmPeerId);
  }

  /// Tap — toggle a channel tab, the ALL sentinel, or a `dm:`-prefixed id
  /// in/out of selection. At least one channel stays selected. ALL and DM
  /// threads are exclusive selections.
  Set<String> selectTab(String id) {
    final sel = _selection;
    if (id == kAllChannelId) {
      _selection = AllSelection(sel is ChannelSelection ? sel.ids : {});
    } else if (id.startsWith('dm:')) {
      _selection = DmSelection(id.substring(3));
    } else if (sel is AllSelection || sel is DmSelection) {
      _selection = ChannelSelection({id});
    } else if (sel is ChannelSelection && sel.ids.contains(id)) {
      if (sel.ids.length > 1) {
        _selection = ChannelSelection({...sel.ids}..remove(id));
      }
    } else if (sel is ChannelSelection) {
      _selection = ChannelSelection({...sel.ids, id});
    }
    _callSideEffects();
    return _idsToEnsure;
  }

  /// Open (and select) the DM thread with a peer — from the peers panel button.
  Set<String> openDm(String peerId) {
    _selection = DmSelection(peerId);
    _callSideEffects();
    return _idsToEnsure;
  }

  /// After a send in ALL mode, snap back to the channel(s) selected before
  /// ALL — `AllSelection.previous` holds that data; this just restores it.
  Set<String> snapBackFromAll(List<PatchChannel> channels) {
    final sel = _selection;
    if (sel is AllSelection && sel.previous.isNotEmpty) {
      _selection = ChannelSelection(sel.previous);
    } else if (channels.isNotEmpty) {
      _selection = ChannelSelection({channels.first.id});
    }
    _callSideEffects();
    return _idsToEnsure;
  }

  /// Drop stale ids from a Channel selection (or seed the first channel when
  /// empty) after the channel list changes. ALL/DM selections don't depend
  /// on the channel list.
  Set<String> reconcileWithChannels(List<PatchChannel> channels) {
    final sel = _selection;
    if (sel is ChannelSelection) {
      final validIds = channels.map((c) => c.id).toSet();
      final kept = sel.ids.where(validIds.contains).toSet();
      _selection = kept.isNotEmpty
          ? ChannelSelection(kept)
          : (channels.isNotEmpty
              ? ChannelSelection({channels.first.id})
              : const ChannelSelection({}));
    }
    _callSideEffects();
    return _idsToEnsure;
  }
}
