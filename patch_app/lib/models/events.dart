import 'channel.dart';
import 'message.dart';

/// A typed engine push, delivered to the UI across the FFI seam.
///
/// This is the model-layer replacement for the legacy stringly-typed
/// `{'event': ...}` map. The engine originates these (a Message arrived, a
/// Channel was Flashed, a Peer left); consumers switch over the sealed type, so
/// a renamed or unhandled variant is a compile error rather than a silent miss.
///
/// Hand-written over the app's own models (not the FFI-generated structs) so the
/// model layer stays free of any FFI import — see ADR-0004. The wire→model
/// mapping lives in `bridge_client.dart` (`patchEventFromRust`).
///
/// Two kinds of variant:
/// - **data-carrying** — the consumer acts on the payload.
/// - **refetch signals** ([PeersChanged], [ChannelsChanged]) — carry no payload;
///   they only say "something changed, refetch", which is honestly how the UI
///   uses them today.
sealed class PatchEvent {
  const PatchEvent();
}

/// A Message arrived (Channel, ALL, or Direct Message — keyed by its channel id).
class MessageReceived extends PatchEvent {
  final PatchMessage message;
  const MessageReceived(this.message);
}

/// Delivery progress/result for a Critical Message *we* sent.
class DeliveryUpdated extends PatchEvent {
  final String messageId;
  final MessageDeliveryStatus status;
  const DeliveryUpdated(this.messageId, this.status);
}

/// A Channel (or Direct Message thread) was Flashed by a Peer.
class Flashed extends PatchEvent {
  final String channelId;
  final String senderId;
  final String senderName;
  const Flashed({
    required this.channelId,
    required this.senderId,
    required this.senderName,
  });
}

/// A specific Peer was removed from the registry — drop exactly that Peer.
class PeerExpired extends PatchEvent {
  final String peerId;
  const PeerExpired(this.peerId);
}

/// A Peer offered its Channel layout (reply to our request). Surfaced for an
/// adopt/merge prompt — never auto-applied.
class ChannelsOffered extends PatchEvent {
  final String fromPeerId;
  final String fromName;
  final List<PatchChannel> channels;
  const ChannelsOffered({
    required this.fromPeerId,
    required this.fromName,
    required this.channels,
  });
}

/// A Peer offered its global Macros (reply to our request). Surfaced for an
/// adopt/merge prompt — never auto-applied. The UI classifies these via
/// `previewGlobalMacros` before showing the dialog, rather than carrying the
/// classification here, so the same Rust-only validation (OSC target, binding
/// collision) backs both the preview and the eventual `adoptGlobalMacros` call.
class GlobalMacrosOffered extends PatchEvent {
  final String fromPeerId;
  final String fromName;
  final List<MacroMessage> globalMacros;
  const GlobalMacrosOffered({
    required this.fromPeerId,
    required this.fromName,
    required this.globalMacros,
  });
}

/// The local Operator's display name changed.
class ClientNameChanged extends PatchEvent {
  final String name;
  const ClientNameChanged(this.name);
}

/// The OS denied network access (iOS/macOS Local Network permission).
class PermissionDenied extends PatchEvent {
  final String context;
  const PermissionDenied(this.context);
}

/// The peer set changed — refetch the peers list. Payload-free on purpose: the
/// engine's presence payload lacks a resolved address and computed status, so
/// the UI refetches regardless (carrying it would be interface bloat).
class PeersChanged extends PatchEvent {
  const PeersChanged();
}

/// The Channel list changed — refetch channels.
class ChannelsChanged extends PatchEvent {
  const ChannelsChanged();
}
