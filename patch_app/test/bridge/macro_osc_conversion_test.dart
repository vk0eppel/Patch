import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/src/rust/osc/types.dart' as rust_osc;

/// #181: `MacroOsc` is the single currency across the seam; this converter is
/// the one place the empty-collapse rule lives (a target missing its
/// address/port/path is no target at all — never a half-built OscTarget).
void main() {
  group('oscTargetFromMacroOsc', () {
    test('null stays null', () {
      expect(oscTargetFromMacroOsc(null), isNull);
    });

    test('a complete MacroOsc maps field-for-field', () {
      final t = oscTargetFromMacroOsc(const MacroOsc(
        address: '10.0.0.9',
        port: 53000,
        path: '/cue/1/start',
        arg: '42',
        argType: MacroOscArgType.int,
      ));
      expect(t, isNotNull);
      expect(t!.address, '10.0.0.9');
      expect(t.port, 53000);
      expect(t.path, '/cue/1/start');
      expect(t.arg, '42');
      expect(t.argType, rust_osc.OscArgKind.int);
    });

    test('an incomplete target collapses to null (empty address, empty path, '
        'port 0)', () {
      const base = MacroOsc(
        address: '10.0.0.9',
        port: 53000,
        path: '/cue/1/start',
        arg: null,
        argType: MacroOscArgType.string,
      );
      expect(
        oscTargetFromMacroOsc(const MacroOsc(
          address: '',
          port: 53000,
          path: '/cue/1/start',
          arg: null,
          argType: MacroOscArgType.string,
        )),
        isNull,
      );
      expect(
        oscTargetFromMacroOsc(const MacroOsc(
          address: '10.0.0.9',
          port: 0,
          path: '/cue/1/start',
          arg: null,
          argType: MacroOscArgType.string,
        )),
        isNull,
      );
      expect(
        oscTargetFromMacroOsc(const MacroOsc(
          address: '10.0.0.9',
          port: 53000,
          path: '',
          arg: null,
          argType: MacroOscArgType.string,
        )),
        isNull,
      );
      // and the untouched base still maps
      expect(oscTargetFromMacroOsc(base), isNotNull);
    });

    test('an empty arg collapses to null', () {
      final t = oscTargetFromMacroOsc(const MacroOsc(
        address: '10.0.0.9',
        port: 53000,
        path: '/cue/1/start',
        arg: '',
        argType: MacroOscArgType.string,
      ));
      expect(t!.arg, isNull);
    });
  });
}
