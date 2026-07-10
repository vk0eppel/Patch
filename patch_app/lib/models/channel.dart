import 'package:flutter/material.dart';
import 'package:patch/src/rust/osc/types.dart' as rust_osc;
import 'package:patch/src/rust/state/channel.dart' as rust_channel;

Color _parseHexColor(String hex) =>
    Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

/// Mirrors the Rust `osc::types::OscArgKind` enum — which `OscType` variant a
/// macro's OSC `arg` is parsed into when it fires. Serialized by serde as a
/// plain variant-name string ("String"/"Int"/"Float"), not an int code.
enum MacroOscArgType {
  string,
  int,
  float;

  factory MacroOscArgType.fromRust(rust_osc.OscArgKind kind) => switch (kind) {
        rust_osc.OscArgKind.string => MacroOscArgType.string,
        rust_osc.OscArgKind.int => MacroOscArgType.int,
        rust_osc.OscArgKind.float => MacroOscArgType.float,
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

  factory MacroOsc.fromRust(rust_channel.OscTarget o) => MacroOsc(
        address: o.address,
        port: o.port,
        path: o.path,
        arg: o.arg,
        argType: MacroOscArgType.fromRust(o.argType),
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

  factory MacroMessage.fromRust(rust_channel.MacroMessage s) => MacroMessage(
        label: s.label,
        payload: s.payload,
        keyBinding: s.keyBinding,
        priority: s.priority,
        midiNote: s.midiNote,
        midiCc: s.midiCc,
        osc: s.osc == null ? null : MacroOsc.fromRust(s.osc!),
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

  factory PatchChannel.fromRust(rust_channel.Channel c) => PatchChannel(
        id: c.id,
        displayName: c.displayName,
        color: _parseHexColor(c.color),
        macros: c.macros.map(MacroMessage.fromRust).toList(),
        flashOnCritical: c.flashOnCritical,
        flashOnMessage: c.flashOnMessage,
        flashCount: c.flashCount,
      );
}

/// Outcome of considering one offered Macro for import from a Peer's global
/// Macro set (see `previewGlobalMacros`/`adoptGlobalMacros`) — mirrors Rust's
/// `state::channel::MacroImportOutcome`. The classification (already-have,
/// invalid-OSC-skipped, binding-collision-stripped) is computed Rust-side so
/// the preview dialog and the actual merge can never disagree.
sealed class MacroImportOutcome {
  const MacroImportOutcome();

  factory MacroImportOutcome.fromRust(rust_channel.MacroImportOutcome o) =>
      switch (o) {
        rust_channel.MacroImportOutcome_AlreadyHave(:final label) =>
          MacroAlreadyHave(label),
        rust_channel.MacroImportOutcome_Added(:final msg) =>
          MacroAdded(MacroMessage.fromRust(msg)),
        rust_channel.MacroImportOutcome_AddedBindingDropped(
          :final msg,
          :final reason,
        ) =>
          MacroAddedBindingDropped(MacroMessage.fromRust(msg), reason),
        rust_channel.MacroImportOutcome_Skipped(:final label, :final reason) =>
          MacroSkipped(label, reason),
      };
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
