import 'package:flutter/services.dart';

/// Dart-to-native bridge for the desktop whole-screen Flash overlay
/// (macOS/Windows) — a pure OS/UI concern with no engine state, so it rides a
/// plain platform channel rather than the Rust FFI bridge. Contains no
/// platform-detection logic itself: the caller (home_screen's `_applyFlash`)
/// has already decided whether this should fire.
class FlashOverlayGateway {
  static const MethodChannel _channel = MethodChannel(
    'com.patch.app/flash_overlay',
  );

  /// Pulses the native overlay [pulseCount] times in [color] — the same
  /// resolved color/count driving the in-app Flash pulse for this Flash.
  static Future<void> pulse(Color color, int pulseCount) {
    return _channel.invokeMethod<void>('pulse', <String, Object?>{
      'argb': color.toARGB32(),
      'pulseCount': pulseCount,
    });
  }
}
