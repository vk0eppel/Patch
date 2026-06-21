import 'package:flutter/material.dart';

import '../theme/patch_theme.dart';

/// Runs a bridge command, surfacing a thrown failure as a SnackBar and
/// returning null. Replaces the legacy global `'error'` event for commands that
/// now throw instead of swallowing their failure (ADR-0004) — keeping error
/// display in one place while giving the caller real control flow.
///
/// The messenger is captured before the await so it stays valid across the
/// async gap. In the store-extraction candidate this becomes a store method
/// backed by an error sink the UI observes.
Future<T?> runGuarded<T>(
  BuildContext context,
  Future<T> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    return await action();
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('$e'),
        backgroundColor: PatchTheme.critical,
        duration: const Duration(seconds: 5),
      ),
    );
    return null;
  }
}
