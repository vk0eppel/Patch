import 'package:flutter_test/flutter_test.dart';
import 'package:patch/presenters/settings/behavior_presenter.dart';

void main() {
  late List<String> calls;
  late BehaviorPresenter p;

  setUp(() {
    calls = [];
    p = BehaviorPresenter(
      setFlashOnMessage: (v) async => calls.add('flashOnMessage:$v'),
      setFlashOnCritical: (v) async => calls.add('flashOnCritical:$v'),
      setAudibleAlert: (v) async => calls.add('audibleAlert:$v'),
      setFlashWholeScreen: (v) async => calls.add('flashWholeScreen:$v'),
      setHideKeyboard: (v) async => calls.add('hideKeyboard:$v'),
      setFlashCount: (v) async => calls.add('flashCount:$v'),
      setMacrosColumns: (v) async => calls.add('macrosColumns:$v'),
      refreshConfig: () async => calls.add('refreshConfig'),
    );
  });

  group('BehaviorPresenter', () {
    test('a toggle saves then refetches', () async {
      await p.saveFlashOnMessage(true);
      expect(calls, ['flashOnMessage:true', 'refreshConfig']);
    });

    test('flash count outside the picker options is rejected before any '
        'bridge call', () async {
      expect(await p.saveFlashCount(2), isFalse);
      expect(await p.saveFlashCount(8), isFalse);
      expect(calls, isEmpty);
      expect(await p.saveFlashCount(4), isTrue);
      expect(calls, ['flashCount:4', 'refreshConfig']);
    });

    test('macros columns outside 1–3 is rejected before any bridge call',
        () async {
      expect(await p.saveMacrosColumns(0), isFalse);
      expect(await p.saveMacrosColumns(4), isFalse);
      expect(calls, isEmpty);
      expect(await p.saveMacrosColumns(2), isTrue);
      expect(calls, ['macrosColumns:2', 'refreshConfig']);
    });

    test('reset restores every default with a single refetch', () async {
      await p.resetDefaults();
      expect(calls.last, 'refreshConfig');
      expect(calls.where((c) => c == 'refreshConfig'), hasLength(1));
      expect(
        calls,
        containsAll([
          'flashOnCritical:true',
          'flashOnMessage:false',
          'flashCount:4',
          'hideKeyboard:true',
          'audibleAlert:false',
          'macrosColumns:1',
        ]),
      );
    });
  });
}
