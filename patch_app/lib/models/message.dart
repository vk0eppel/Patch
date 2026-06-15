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

  const PatchMessage({
    required this.messageId,
    required this.senderId,
    required this.senderName,
    required this.channelId,
    required this.timestamp,
    required this.priority,
    required this.payload,
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

  const PeerInfo({
    required this.peerId,
    required this.peerName,
    this.role,
    required this.channels,
    required this.address,
    required this.oscPort,
    required this.lastSeen,
    required this.discoveryMode,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        peerId: j['peer_id'] as String,
        peerName: j['peer_name'] as String,
        role: j['role'] as String?,
        channels: List<String>.from(j['channels'] as List),
        address: j['address'] as String? ?? '',
        oscPort: (j['osc_port'] as num).toInt(),
        lastSeen: DateTime.parse(j['last_seen'] as String),
        discoveryMode: j['discovery_mode'] as String? ?? 'unknown',
      );
}
