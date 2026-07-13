import 'channel.dart';
import 'dm_thread.dart';
import 'selection.dart';

/// Where an explicit Operator action (typed message, Flash, clear, export)
/// goes — resolved once from the current [Selection] instead of each widget
/// method re-deriving the DM/ALL/Channels branch itself (#146). This is
/// UI-side target resolution for direct actions only; Macro routing stays
/// engine-side per ADR-0009.
sealed class SendTarget {
  const SendTarget();

  static SendTarget of(
    Selection selection, {
    required List<PatchChannel> selectedChannels,
    String? dmPeerName,
  }) {
    return switch (selection) {
      DmSelection(peerId: final p) => DmTarget(p, peerName: dmPeerName),
      AllSelection() => const AllTarget(),
      ChannelSelection() => ChannelsTarget(selectedChannels),
    };
  }

  /// The buffer key `exportMessages` should receive: a DM exports its thread,
  /// a single Channel exports that Channel, ALL / multi-Channel export
  /// everything (null).
  String? get exportKey => switch (this) {
    DmTarget(peerId: final p) => DmThread(p).key,
    AllTarget() => null,
    ChannelsTarget(channels: final cs) => cs.length == 1 ? cs.first.id : null,
  };

  /// The buffer keys `clearMessages` should hit, one call each: a DM clears
  /// its thread, ALL clears everything (null), a Channel selection clears
  /// each selected Channel individually — not everything.
  List<String?> get clearKeys => switch (this) {
    DmTarget(peerId: final p) => [DmThread(p).key],
    AllTarget() => const [null],
    ChannelsTarget(channels: final cs) => [for (final c in cs) c.id],
  };

  /// The filename fragment for an export of this target
  /// (`patch_<exportFileLabel>.csv`).
  String get exportFileLabel => switch (this) {
    DmTarget(peerName: final n) => 'dm_${n ?? ''}'.toLowerCase(),
    AllTarget() => 'all_channels',
    ChannelsTarget(channels: final cs) =>
      cs.length == 1 ? cs.first.displayName.toLowerCase() : 'all_channels',
  };

  /// What the clear-confirmation dialog says it will wipe.
  String get clearDescription => switch (this) {
    DmTarget() => 'this conversation',
    AllTarget() => 'all channels',
    ChannelsTarget(channels: final cs) =>
      cs.length == 1 ? cs.first.displayName : '${cs.length} channels',
  };
}

/// A 1:1 Direct Message thread with one Peer.
final class DmTarget extends SendTarget {
  final String peerId;
  final String? peerName;
  const DmTarget(this.peerId, {this.peerName});
}

/// The one-shot ALL broadcast.
final class AllTarget extends SendTarget {
  const AllTarget();
}

/// The selected Channel(s).
final class ChannelsTarget extends SendTarget {
  final List<PatchChannel> channels;
  const ChannelsTarget(this.channels);
}
