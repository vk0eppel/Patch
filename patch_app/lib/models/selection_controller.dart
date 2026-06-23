import 'channel.dart';
import 'message.dart' show kAllChannelId;
import 'selection.dart';

/// Owns every Selection transition rule — what tapping a channel tab, opening
/// a DM thread, sending in ALL mode, or the channel list changing underneath
/// the current selection should produce. Mirrors the registry split in
/// ADR-0003: this controller mutates its own state and reports what changed;
/// it never touches `BuildContext`. `home_screen.dart` is the only thing that
/// calls `ensureMessages`/`runGuarded`, using what each method returns.
///
/// Deliberately excludes DM unread-tracking and open-thread bookkeeping
/// (`_unreadDms`, `_openDms` in `home_screen.dart`) — those stay screen-local
/// per ADR-0005's "unread-DM sets are screen-local UI state."
class SelectionController {
  Selection _selection = const ChannelSelection({});
  Selection get selection => _selection;

  /// Buffer keys (a channel id, [kAllChannelId], or `dm:<peer>`) the caller
  /// should `ensureMessages` for, given the current selection. One rule for
  /// every transition — `AppStore.ensureMessages` already no-ops on a cache
  /// hit, so calling it for an id that's already loaded is harmless.
  Set<String> get _idsToEnsure => _selection.dmPeerId != null
      ? {'dm:${_selection.dmPeerId}'}
      : _selection.tabIds;

  /// Tap — toggle a channel tab, the ALL sentinel, or a `dm:`-prefixed id
  /// in/out of selection. At least one channel stays selected. ALL and DM
  /// threads are exclusive selections.
  Set<String> selectTab(String id) {
    final sel = _selection;
    if (id == kAllChannelId) {
      // Stash the current Channel selection for snap-back after send.
      _selection = AllSelection(sel is ChannelSelection ? sel.ids : {});
    } else if (id.startsWith('dm:')) {
      _selection = DmSelection(id.substring(3));
    } else if (sel is AllSelection || sel is DmSelection) {
      // Tapping a channel cancels ALL compose / DM mode.
      _selection = ChannelSelection({id});
    } else if (sel is ChannelSelection && sel.ids.contains(id)) {
      if (sel.ids.length > 1) {
        _selection = ChannelSelection({...sel.ids}..remove(id));
      }
    } else if (sel is ChannelSelection) {
      _selection = ChannelSelection({...sel.ids, id});
    }
    return _idsToEnsure;
  }

  /// Open (and select) the DM thread with a peer — from the peers panel button.
  Set<String> openDm(String peerId) {
    _selection = DmSelection(peerId);
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
    return _idsToEnsure;
  }
}
