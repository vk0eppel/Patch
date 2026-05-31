import 'package:flutter/material.dart';

class MacroMessage {
  final String label;
  final String payload;
  final String? keyBinding;
  final int priority;

  const MacroMessage({
    required this.label,
    required this.payload,
    this.keyBinding,
    this.priority = 1,
  });

  factory MacroMessage.fromJson(Map<String, dynamic> j) => MacroMessage(
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
  final List<MacroMessage> macros;
  final bool flashOnCritical;
  final bool flashOnMessage;
  /// Per-channel pulse count override. null = use global setting.
  final int? flashCount;

  const PatchChannel({
    required this.id,
    required this.displayName,
    required this.color,
    this.macros = const [],
    this.flashOnCritical = true,
    this.flashOnMessage = false,
    this.flashCount,
  });

  factory PatchChannel.fromJson(Map<String, dynamic> j) {
    final colorHex = (j['color'] as String?)?.replaceFirst('#', '') ?? '607D8B';
    return PatchChannel(
      id: j['id'] as String,
      displayName: j['display_name'] as String,
      color: Color(int.parse('FF$colorHex', radix: 16)),
      macros: (j['macros'] as List<dynamic>? ?? [])
          .map((s) => MacroMessage.fromJson(s as Map<String, dynamic>))
          .toList(),
      flashOnCritical: (j['flash_on_critical'] as bool?) ?? true,
      flashOnMessage:  (j['flash_on_message']  as bool?) ?? false,
      flashCount:      (j['flash_count'] as int?),
    );
  }
}
