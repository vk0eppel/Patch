import 'package:flutter/material.dart';

class ShortcutMessage {
  final String label;
  final String payload;
  final String? keyBinding;
  final int priority;

  const ShortcutMessage({
    required this.label,
    required this.payload,
    this.keyBinding,
    this.priority = 1,
  });

  factory ShortcutMessage.fromJson(Map<String, dynamic> j) => ShortcutMessage(
        label: j['label'] as String,
        payload: j['payload'] as String,
        keyBinding: j['key_binding'] as String?,
        priority: (j['priority'] as num).toInt(),
      );
}

class PatchChannel {
  final String id;
  final String displayName;
  final Color color;
  final List<ShortcutMessage> shortcuts;

  const PatchChannel({
    required this.id,
    required this.displayName,
    required this.color,
    this.shortcuts = const [],
  });

  factory PatchChannel.fromJson(Map<String, dynamic> j) {
    final colorHex = (j['color'] as String?)?.replaceFirst('#', '') ?? '607D8B';
    return PatchChannel(
      id: j['id'] as String,
      displayName: j['display_name'] as String,
      color: Color(int.parse('FF$colorHex', radix: 16)),
      shortcuts: (j['shortcuts'] as List<dynamic>? ?? [])
          .map((s) => ShortcutMessage.fromJson(s as Map<String, dynamic>))
          .toList(),
    );
  }
}
