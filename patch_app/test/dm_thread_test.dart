import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/dm_thread.dart';

void main() {
  group('DmThread', () {
    test('key carries the dm: prefix and the peer id', () {
      const t = DmThread('6ba7b810-9dad-11d1-80b4-00c04fd430c8');
      expect(t.key, 'dm:6ba7b810-9dad-11d1-80b4-00c04fd430c8');
    });

    test('tryParse round-trips a key and rejects Channel ids', () {
      const t = DmThread('peer-1');
      expect(DmThread.tryParse(t.key), t);
      expect(DmThread.tryParse('foh-audio'), isNull);
      expect(DmThread.tryParse(''), isNull);
    });

    test('isKey distinguishes DM thread keys from Channel ids', () {
      expect(DmThread.isKey('dm:peer-1'), isTrue);
      expect(DmThread.isKey('foh-audio'), isFalse);
    });
  });
}
