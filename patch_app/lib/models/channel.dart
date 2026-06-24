import 'package:flutter/material.dart';

/// Mirrors the Rust `osc::types::OscArgKind` enum — which `OscType` variant a
/// macro's OSC `arg` is parsed into when it fires. Serialized by serde as a
/// plain variant-name string ("String"/"Int"/"Float"), not an int code.
enum MacroOscArgType {
  string,
  int,
  float;

  factory MacroOscArgType.fromJson(String? j) => switch (j) {
        'Int' => MacroOscArgType.int,
        'Float' => MacroOscArgType.float,
        _ => MacroOscArgType.string,
      };

  String toJson() => switch (this) {
        MacroOscArgType.string => 'String',
        MacroOscArgType.int => 'Int',
        MacroOscArgType.float => 'Float',
      };
}

/// An outbound OSC target attached to a macro — fired alongside the Patch message
/// (dual action) to trigger external gear (QLab, Companion, vMix…).
class MacroOsc {
  final String address;
  final int port;
  final String path;
  final String? arg;
  final MacroOscArgType argType;

  const MacroOsc({
    required this.address,
    required this.port,
    required this.path,
    this.arg,
    this.argType = MacroOscArgType.string,
  });

  factory MacroOsc.fromJson(Map<String, dynamic> j) => MacroOsc(
        address: j['address'] as String,
        port: (j['port'] as num).toInt(),
        path: j['path'] as String,
        arg: j['arg'] as String?,
        argType: MacroOscArgType.fromJson(j['arg_type'] as String?),
      );
}

class MacroMessage {
  final String label;
  final String payload;
  final String? keyBinding;
  final int priority;

  /// Optional MIDI Note number (0–127) that fires this macro.
  final int? midiNote;

  /// Optional MIDI Control Change number (0–127) that fires this macro.
  final int? midiCc;

  /// Optional outbound OSC target fired alongside the Patch message.
  final MacroOsc? osc;

  const MacroMessage({
    required this.label,
    required this.payload,
    this.keyBinding,
    this.priority = 1,
    this.midiNote,
    this.midiCc,
    this.osc,
  });

  factory MacroMessage.fromJson(Map<String, dynamic> j) => MacroMessage(
        label: j['label'] as String,
        payload: j['payload'] as String,
        keyBinding: j['key_binding'] as String?,
        priority: (j['priority'] as num).toInt(),
        midiNote: (j['midi_note'] as num?)?.toInt(),
        midiCc: (j['midi_cc'] as num?)?.toInt(),
        osc: j['osc'] == null
            ? null
            : MacroOsc.fromJson(j['osc'] as Map<String, dynamic>),
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

/// Outcome of considering one offered Macro for import from a Peer's global
/// Macro set (see `previewGlobalMacros`/`adoptGlobalMacros`) — mirrors Rust's
/// `state::channel::MacroImportOutcome`. The classification (already-have,
/// invalid-OSC-skipped, binding-collision-stripped) is computed Rust-side so
/// the preview dialog and the actual merge can never disagree.
sealed class MacroImportOutcome {
  const MacroImportOutcome();
}

/// Every field matches a Macro we already have — not added.
class MacroAlreadyHave extends MacroImportOutcome {
  final String label;
  const MacroAlreadyHave(this.label);
}

/// Added with no conflict.
class MacroAdded extends MacroImportOutcome {
  final MacroMessage macro;
  const MacroAdded(this.macro);
}

/// Added, but a colliding key/MIDI binding was stripped first — the Macro
/// itself still comes through.
class MacroAddedBindingDropped extends MacroImportOutcome {
  final MacroMessage macro;
  final String reason;
  const MacroAddedBindingDropped(this.macro, this.reason);
}

/// Dropped entirely — invalid OSC target.
class MacroSkipped extends MacroImportOutcome {
  final String label;
  final String reason;
  const MacroSkipped(this.label, this.reason);
}
