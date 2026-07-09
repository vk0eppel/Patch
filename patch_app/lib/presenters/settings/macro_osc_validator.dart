import 'dart:io' show InternetAddress;

import '../../models/channel.dart' show MacroOsc, MacroOscArgType;

/// Validate a Macro's OSC dual-action target before any bridge call —
/// ADR-0002's "live UI edits reject immediately" trust level, mirrored
/// Dart-side so the Operator gets the error at the Save button rather than
/// as a thrown engine error. The engine (`validate_osc_target`) remains the
/// authority; this is the same check, one seam earlier.
///
/// Returns an operator-facing error message, or null when valid.
String? validateMacroOscTarget(MacroOsc osc) {
  if (InternetAddress.tryParse(osc.address.trim()) == null) {
    return 'OSC address must be an IP address (e.g. 10.0.0.9)';
  }
  if (osc.port < 1 || osc.port > 65535) {
    return 'OSC port must be 1–65535';
  }
  if (!osc.path.startsWith('/')) {
    return 'OSC path must start with / (e.g. /cue/1/start)';
  }
  final a = osc.arg;
  if (a != null && a.isNotEmpty) {
    switch (osc.argType) {
      case MacroOscArgType.int:
        if (int.tryParse(a) == null) {
          return 'Argument must be a whole number for type Int';
        }
      case MacroOscArgType.float:
        if (double.tryParse(a) == null) {
          return 'Argument must be a number for type Float';
        }
      case MacroOscArgType.string:
        break;
    }
  }
  return null;
}
