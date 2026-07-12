import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart' show MacroOsc, MacroOscArgType;
import 'package:patch/presenters/settings/macro_osc_validator.dart';

void main() {
  group(
    'validateMacroOscTarget (ADR-0002: live UI edits reject immediately)',
    () {
      // #181: the validator takes the MacroOsc object — the same currency the
      // dialog builds and the bridge sends; no scalar explosion at any seam.
      String? v({
        String address = '10.0.0.9',
        int port = 53000,
        String path = '/cue/1/start',
        String? arg,
        MacroOscArgType argType = MacroOscArgType.string,
      }) => validateMacroOscTarget(
        MacroOsc(
          address: address,
          port: port,
          path: path,
          arg: arg,
          argType: argType,
        ),
      );

      test('a well-formed target passes', () {
        expect(v(), isNull);
      });

      test('a non-IP address is rejected', () {
        expect(v(address: 'qlab.local'), isNotNull);
        expect(v(address: ''), isNotNull);
      });

      test('port 0 is rejected', () {
        expect(v(port: 0), isNotNull);
      });

      test('a path not starting with / is rejected', () {
        expect(v(path: 'cue/1/start'), isNotNull);
        expect(v(path: ''), isNotNull);
      });

      test('an int-typed arg must parse as an integer', () {
        expect(v(arg: '42', argType: MacroOscArgType.int), isNull);
        expect(v(arg: 'go', argType: MacroOscArgType.int), isNotNull);
      });

      test('a float-typed arg must parse as a number', () {
        expect(v(arg: '0.5', argType: MacroOscArgType.float), isNull);
        expect(v(arg: 'fast', argType: MacroOscArgType.float), isNotNull);
      });

      test('a string arg is always acceptable', () {
        expect(v(arg: 'anything at all'), isNull);
      });
    },
  );
}
