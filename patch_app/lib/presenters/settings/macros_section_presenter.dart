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
    required this.upsertMacro,
  });

  /// The one macro-save command (#186), keyed on [channelId]: non-null is a
  /// Channel Macro, null is a Global Macro — the same discriminator macro
  /// routing uses (ADR-0009). The Macro itself travels as one [MacroMessage],
  /// not a parameter list.
  final Future<void> Function({
    String? channelId,
    String? originalLabel,
    required MacroMessage macro,
  }) upsertMacro;

  Future<SaveResult> saveMacro({
    String? channelId,
    String? originalLabel,
    required MacroMessage macro,
  }) =>
      validateThenSave(
        validate: () => _validateOsc(macro.osc),
        save: () => upsertMacro(
          channelId: channelId,
          originalLabel: originalLabel,
          macro: macro,
        ),
      );
}

/// ADR-0002: a live UI edit rejects an invalid OSC target immediately —
/// before any bridge call. Returned as the `validateThenSave` seam's error
/// message rather than thrown.
String? _validateOsc(MacroOsc? osc) =>
    osc == null ? null : validateMacroOscTarget(osc);
