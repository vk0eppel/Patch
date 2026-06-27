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
  });

  bool get isCritical => priority >= 3;
  bool get isWarning => priority == 2;

  factory PatchMessage.fromJson(Map<String, dynamic> j) => PatchMessage(
        messageId: j['message_id'] as String,
        senderId: j['sender_id'] as String,
        senderName: j['sender_name'] as String,
        channelId: j['channel_id'] as String,
        timestamp: DateTime.parse(j['timestamp'] as String),
        priority: (j['priority'] as num).toInt(),
        payload: j['payload'] as String,
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

  factory MessageDeliveryStatus.fromEvent(Map<String, dynamic> e) =>
      MessageDeliveryStatus(
        delivered: (e['delivered'] as num).toInt(),
        total: (e['total'] as num).toInt(),
        failed: e['failed'] as bool,
        failedPeers:
            ((e['failed_peers'] as List<dynamic>?) ?? const []).cast<String>(),
      );
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

  factory ShowFileMeta.fromJson(Map<String, dynamic> j) => ShowFileMeta(
        slug: j['slug'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
        channelCount: (j['channel_count'] as num).toInt(),
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
}
