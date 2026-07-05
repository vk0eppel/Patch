import 'package:flutter_test/flutter_test.dart';
import 'package:patch/presenters/settings/save_result.dart';

void main() {
  group('validateThenSave', () {
    test('returns SaveError and calls neither save nor refetch when '
        'validate rejects', () async {
      final calls = <String>[];
      final result = await validateThenSave(
        validate: () => 'out of range',
        save: () async => calls.add('save'),
        refetch: () async => calls.add('refetch'),
      );

      expect(result, isA<SaveError>());
      expect((result as SaveError).message, 'out of range');
      expect(calls, isEmpty);
    });

    test('calls save then refetch and returns SaveOk when validate passes',
        () async {
      final calls = <String>[];
      final result = await validateThenSave(
        validate: () => null,
        save: () async => calls.add('save'),
        refetch: () async => calls.add('refetch'),
      );

      expect(result, isA<SaveOk>());
      expect(calls, ['save', 'refetch']);
    });
  });
}
