import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Pins the UI command seam (#177): screens and widgets talk to the engine
/// only through `BridgeClient` — never by importing the FRB-generated
/// bindings (`lib/src/rust/…`) directly. The generated types may appear only
/// in the bridge layer (`lib/bridge/`) and the model layer's `fromRust`
/// factories (`lib/models/`), per ADR-0004.
void main() {
  test('no file under lib/screens or lib/widgets imports the generated FFI bindings',
      () {
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final entity in Directory(dir).listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i].trim();
          final isImport = line.startsWith('import ');
          if (isImport &&
              (line.contains('src/rust/') || line.contains('frb_generated'))) {
            offenders.add('${entity.path}:${i + 1}: $line');
          }
        }
      }
    }
    expect(
      offenders,
      isEmpty,
      reason: 'UI code must issue engine commands through BridgeClient '
          '(issue #177). Offending imports:\n${offenders.join('\n')}',
    );
  });
}
