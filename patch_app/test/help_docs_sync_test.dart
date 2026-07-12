import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Flutter can't reliably bundle assets declared outside the package root
// (`../docs/...`) — it works on macOS but fails to resolve on Windows at
// runtime (see ERRORS.md). So the help docs are committed as a copy under
// assets/docs/, sourced from the repo's top-level docs/. This test catches
// drift between the two copies.
void main() {
  test('assets/docs mirrors the repo docs/ source of truth', () {
    const files = [
      'quick-start.md',
      'networking.md',
      'channels-and-show-files.md',
      'osc-integration.md',
      'integrations.md',
      'troubleshooting.md',
    ];

    for (final name in files) {
      final source = File('../docs/$name').readAsStringSync();
      final bundled = File('assets/docs/$name').readAsStringSync();
      expect(
        bundled,
        source,
        reason:
            '$name is out of sync with docs/$name — copy it into assets/docs/',
      );
    }
  });
}
