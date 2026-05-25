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

class SessionMeta {
  final String slug;
  final String name;
  final DateTime createdAt;
  final int channelCount;

  const SessionMeta({
    required this.slug,
    required this.name,
    required this.createdAt,
    required this.channelCount,
  });

  factory SessionMeta.fromJson(Map<String, dynamic> j) => SessionMeta(
        slug: j['slug'] as String,
        name: j['name'] as String,
        createdAt: DateTime.parse(j['created_at'] as String),
        channelCount: (j['channel_count'] as num).toInt(),
      );
}

class PeerInfo {
  final String peerId;
  final String peerName;
  final List<String> channels;
  final String address;
  final int oscPort;
  final DateTime lastSeen;
  final String discoveryMode;

  const PeerInfo({
    required this.peerId,
    required this.peerName,
    required this.channels,
    required this.address,
    required this.oscPort,
    required this.lastSeen,
    required this.discoveryMode,
  });

  factory PeerInfo.fromJson(Map<String, dynamic> j) => PeerInfo(
        peerId: j['peer_id'] as String,
        peerName: j['peer_name'] as String,
        channels: List<String>.from(j['channels'] as List),
        address: j['address'] as String? ?? '',
        oscPort: (j['osc_port'] as num).toInt(),
        lastSeen: DateTime.parse(j['last_seen'] as String),
        discoveryMode: j['discovery_mode'] as String? ?? 'unknown',
      );
}
