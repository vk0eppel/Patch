import '../../models/channel.dart';
import 'macro_osc_validator.dart';
import 'save_result.dart';

/// Owns the Channels & Macros / Global Macros sections' validate → bridge
/// call loop (#145): ADR-0002's "live UI edits reject an invalid OSC target
/// immediately, before any bridge call" — returned as a [SaveResult] via the
/// shared [validateThenSave] seam (#163) so the section widget branches on
/// the result instead of catching a thrown exception. Presentation (the
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

  Future<SaveResult> saveChannelMacro({
    required String channelId,
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) =>
      validateThenSave(
        validate: () => _validateOsc(osc),
        save: () => upsertChannelMacro(
          channelId: channelId,
          originalLabel: originalLabel,
          label: label,
          payload: payload,
          keyBinding: keyBinding,
          priority: priority,
          midiNote: midiNote,
          midiCc: midiCc,
          osc: osc,
        ),
      );

  Future<SaveResult> saveGlobalMacro({
    String? originalLabel,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    MacroOsc? osc,
  }) =>
      validateThenSave(
        validate: () => _validateOsc(osc),
        save: () => upsertGlobalMacro(
          originalLabel: originalLabel,
          label: label,
          payload: payload,
          keyBinding: keyBinding,
          priority: priority,
          midiNote: midiNote,
          midiCc: midiCc,
          osc: osc,
        ),
      );
}

/// ADR-0002: a live UI edit rejects an invalid OSC target immediately —
/// before any bridge call. Returned as the `validateThenSave` seam's error
/// message rather than thrown.
String? _validateOsc(MacroOsc? osc) =>
    osc == null ? null : validateMacroOscTarget(osc);
