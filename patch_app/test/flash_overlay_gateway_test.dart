import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/util/flash_overlay_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.patch.app/flash_overlay');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('pulse sends the resolved ARGB color and pulse count', () async {
    await FlashOverlayGateway.pulse(const Color(0xFFAABBCC), 5);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'pulse');
    expect(calls.single.arguments, {'argb': 0xFFAABBCC, 'pulseCount': 5});
  });
}
