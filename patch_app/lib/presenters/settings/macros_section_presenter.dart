import '../../models/channel.dart';
import 'macro_osc_validator.dart';

/// Owns the Channels & Macros / Global Macros sections' validate → bridge
/// call loop (#145): ADR-0002's "live UI edits reject an invalid OSC target
/// immediately, before any bridge call" — thrown as [FormatException] so
/// `runGuarded` surfaces the message to the Operator. Presentation (the
/// macro-edit dialog, list rendering) stays in the section widgets per
/// ADR-0005.
class MacrosSectionPresenter {
  MacrosSectionPresenter({
    required this.upsertChannelMacro,
    required this.upsertGlobalMacro,
  });

  final Future<void> Function({
    required String channelId,
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) upsertChannelMacro;

  final Future<void> Function({
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) upsertGlobalMacro;

  Future<void> saveChannelMacro({
    required String channelId,
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) async {
    _guardOsc(osc);
    await upsertChannelMacro(
      channelId: channelId,
      originalLabel: originalLabel,
      label: label,
      payload: payload,
      keyBinding: keyBinding,
      priority: priority,
      midiNote: midiNote,
      midiCc: midiCc,
      osc: osc,
    );
  }

  Future<void> saveGlobalMacro({
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) async {
    _guardOsc(osc);
    await upsertGlobalMacro(
      originalLabel: originalLabel,
      label: label,
      payload: payload,
      keyBinding: keyBinding,
      priority: priority,
      midiNote: midiNote,
      midiCc: midiCc,
      osc: osc,
    );
  }
}

/// ADR-0002: a live UI edit rejects an invalid OSC target immediately —
/// before any bridge call. Thrown as [FormatException] so `runGuarded`
/// surfaces the message to the Operator.
void _guardOsc(MacroOsc? osc) {
  if (osc == null) return;
  final err = validateMacroOscTarget(
    address: osc.address,
    port: osc.port,
    path: osc.path,
    arg: osc.arg,
    argType: osc.argType,
  );
  if (err != null) throw FormatException(err);
}
