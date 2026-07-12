import 'package:patch/src/rust/api.dart' as rust;
import 'package:patch/src/rust/osc/types.dart' as rust_osc;
import 'package:patch/src/rust/state/peer.dart' as rust_peer;
import 'package:patch/src/rust/state/show_file.dart' as rust_show_file;

/// Reserved channel id for crew-wide broadcasts (the ALL tab). A message on this
/// id is shown in every peer's channel feeds regardless of their configuration.
const String kAllChannelId = '__all__';

class PatchMessage {
  final String messageId;
  final String senderId;
  final String senderName;
  final String channelId;
  final DateTime timestamp;
  final int priority;
  final String payload;
  final bool isFlash;
  final String? flashSenderName;
  final String? flashSenderRole;

  /// Local arrival-order sequence, stamped by [AppStore] as this client
  /// receives the message — never by the sender. Ordering must not trust
  /// [timestamp], which is the sender's own clock and carried on the wire
  /// as-is: two machines with different clocks would otherwise sort into
  /// the wrong order. Defaults to 0 for messages not yet stored (tests,
  /// freshly-decoded wire messages before `AppStore` stamps them).
  final int localSeq;

  const PatchMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.channelId,
    required this.timestamp,
    required this.priority,
    required this.payload,
    this.isFlash = false,
    this.flashSenderName,
    this.flashSenderRole,
    this.localSeq = 0,
  });

  bool get isCritical => priority >= 3;
  bool get isWarning => priority == 2;

  /// Stamp this message with its local arrival-order sequence. The only
  /// mutation `AppStore` performs on a message after decoding it.
  PatchMessage withLocalSeq(int seq) => PatchMessage(
    messageId: messageId,
    senderId: senderId,
    senderName: senderName,
    channelId: channelId,
    timestamp: timestamp,
    priority: priority,
    payload: payload,
    isFlash: isFlash,
    flashSenderName: flashSenderName,
    flashSenderRole: flashSenderRole,
    localSeq: seq,
  );

  factory PatchMessage.fromRust(rust_osc.PatchMessage m) => PatchMessage(
    messageId: m.messageId.toString(),
    senderId: m.senderId.toString(),
    senderName: m.senderName,
    channelId: m.channelId,
    timestamp: m.timestamp,
    priority: m.priority.index,
    payload: m.payload,
    isFlash: m.isFlash,
    flashSenderName: m.flashSenderName,
    flashSenderRole: m.flashSenderRole,
  );
}

/// Delivery progress/result for a critical message *we* sent (only the sender
/// tracks ACKs, so only the sender's own critical rows carry one of these).
class MessageDeliveryStatus {
  final int delivered;
  final int total;
  final bool failed;
  final List<String> failedPeers;

  const MessageDeliveryStatus({
    required this.delivered,
    required this.total,
    required this.failed,
    this.failedPeers = const [],
  });

  bool get isComplete => !failed && total > 0 && delivered >= total;
  bool get inProgress => !failed && delivered < total;
}

class ShowFileMeta {
  final String slug;
  final String name;
  final DateTime createdAt;
  final int channelCount;

  const ShowFileMeta({
    required this.slug,
    required this.name,
    required this.createdAt,
    required this.channelCount,
  });

  factory ShowFileMeta.fromRust(rust_show_file.ShowFileMeta s) => ShowFileMeta(
    slug: s.slug,
    name: s.name,
    createdAt: s.createdAt,
    channelCount: s.channelCount.toInt(),
  );
}

/// Online/Stale/Offline mirrors `patch_core::state::peer::PeerStatus` — the
/// engine owns the heartbeat-multiplier thresholds (2x/5x) behind this
/// classification so the UI never re-derives them from raw `lastSeen`.
enum PeerStatus { online, stale, offline }

class PeerInfo {
  final String peerId;
  final String peerName;

  /// Self-assigned production role (free text, e.g. "FOH", "PM"); null if unset.
  final String? role;
  final List<String> channels;
  final String address;
  final int oscPort;
  final DateTime lastSeen;
  final String discoveryMode;
  final PeerStatus status;

  /// True when the peer announced a clean departure (`/patch/bye` or mDNS
  /// removal). Rendered distinctly (grey dot + italic name); cleared the moment
  /// the peer is heard from again.
  final bool departed;

  /// A Static Peer — configured by IP rather than discovered. Its id is a
  /// synthetic UUID, so it can't receive Direct Messages; this getter is the
  /// one owner of that classification (widgets must not compare
  /// [discoveryMode] strings themselves).
  bool get isManual => discoveryMode == 'manual_ip';

  const PeerInfo({
    required this.peerId,
    required this.peerName,
    this.role,
    required this.channels,
    required this.address,
    required this.oscPort,
    required this.lastSeen,
    required this.discoveryMode,
    required this.status,
    this.departed = false,
  });

  factory PeerInfo.fromRust(rust.PeerSnapshot p) => PeerInfo(
    peerId: p.peerId.toString(),
    peerName: p.peerName,
    role: p.role,
    channels: p.channels,
    address: p.address,
    oscPort: p.oscPort,
    lastSeen: p.lastSeen,
    departed: p.departed,
    discoveryMode: switch (p.discoveryMode) {
      rust_peer.DiscoveryMode.mdns => 'mdns',
      rust_peer.DiscoveryMode.oscBeacon => 'osc_beacon',
      rust_peer.DiscoveryMode.manualIp => 'manual_ip',
    },
    status: switch (p.status) {
      rust_peer.PeerStatus.online => PeerStatus.online,
      rust_peer.PeerStatus.stale => PeerStatus.stale,
      rust_peer.PeerStatus.offline => PeerStatus.offline,
    },
  );
}
