import 'dm_thread.dart';
import 'message.dart' show kAllChannelId;

/// What the main message area is currently showing/targeting: one or more
/// Channels, the one-shot ALL broadcast compose state, or a single Direct
/// Message thread (see CONTEXT.md: Channel, ALL, Direct Message). ALL and a DM
/// are exclusive — never combined with a Channel selection or each other.
///
/// Replaces a bare `Set<String>` (with `__all__`/`dm:<peer>` sentinel ids) plus
/// a separately-tracked "selection before ALL" field. The ALL one-shot
/// snap-back and DM-exclusivity rules live in this type's constructors/getters
/// instead of being re-inferred from the shape of a set at every call site.
sealed class Selection {
  const Selection();

  bool get isAllMode => this is AllSelection;
  bool get isDmMode => this is DmSelection;

  bool get isMultiChannel => switch (this) {
        ChannelSelection(ids: final ids) => ids.length > 1,
        _ => false,
      };

  String? get dmPeerId => switch (this) {
        DmSelection(peerId: final p) => p,
        _ => null,
      };

  /// Channel-strip tab ids to highlight — channel ids, or the ALL tab. Empty
  /// during a DM: DM tabs never appear in the channel strip (CONTEXT.md).
  Set<String> get tabIds => switch (this) {
        ChannelSelection(ids: final ids) => ids,
        AllSelection() => {kAllChannelId},
        DmSelection() => const {},
      };

  /// True when `id` (a raw channel id, `__all__`, or `dm:<peer>`) names what's
  /// currently selected — the one-call replacement for the old
  /// `_selectedIds.contains(id)` shape-sniffing.
  bool containsRawId(String id) => switch (this) {
        ChannelSelection(ids: final ids) => ids.contains(id),
        AllSelection() => id == kAllChannelId,
        DmSelection(peerId: final p) => id == DmThread(p).key,
      };
}

bool _setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

/// One or more Channels selected (never empty once channels have loaded).
final class ChannelSelection extends Selection {
  final Set<String> ids;
  const ChannelSelection(this.ids);

  @override
  bool operator ==(Object other) =>
      other is ChannelSelection && _setEquals(ids, other.ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);
}

/// The one-shot ALL/broadcast compose state. `previous` is the Channel
/// selection to restore on send/cancel (CONTEXT.md: ALL "snaps back to the
/// previous channel state after sending").
final class AllSelection extends Selection {
  final Set<String> previous;
  const AllSelection(this.previous);

  @override
  bool operator ==(Object other) =>
      other is AllSelection && _setEquals(previous, other.previous);

  @override
  int get hashCode => Object.hashAllUnordered(previous);
}

/// A single open Direct Message thread.
final class DmSelection extends Selection {
  final String peerId;
  const DmSelection(this.peerId);

  @override
  bool operator ==(Object other) =>
      other is DmSelection && peerId == other.peerId;

  @override
  int get hashCode => peerId.hashCode;
}
