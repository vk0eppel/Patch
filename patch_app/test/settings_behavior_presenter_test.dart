import 'package:flutter_test/flutter_test.dart';
import 'package:patch/presenters/settings/behavior_presenter.dart';

void main() {
  late List<String> calls;
  late BehaviorPresenter p;

  setUp(() {
    calls = [];
    p = BehaviorPresenter(
      patch:
          ({
            bool? flashOnMessage,
            bool? flashOnCritical,
            bool? audibleAlert,
            bool? flashWholeScreen,
            bool? hideKeyboard,
            int? flashCount,
            int? macrosColumns,
          }) async {
            final fields = <String>[
              if (flashOnMessage != null) 'flashOnMessage:$flashOnMessage',
              if (flashOnCritical != null) 'flashOnCritical:$flashOnCritical',
              if (audibleAlert != null) 'audibleAlert:$audibleAlert',
              if (flashWholeScreen != null)
                'flashWholeScreen:$flashWholeScreen',
              if (hideKeyboard != null) 'hideKeyboard:$hideKeyboard',
              if (flashCount != null) 'flashCount:$flashCount',
              if (macrosColumns != null) 'macrosColumns:$macrosColumns',
            ];
            calls.add('patch(${fields.join(',')})');
          },
      resetBehavior: () async => calls.add('resetBehavior'),
      refreshConfig: () async => calls.add('refreshConfig'),
    );
  });

  group('BehaviorPresenter', () {
    test('a toggle saves one single-field patch then refetches', () async {
      await p.saveFlashOnMessage(true);
      expect(calls, ['patch(flashOnMessage:true)', 'refreshConfig']);
    });

    test('flash count outside the picker options is rejected before any '
        'bridge call', () async {
      expect(await p.saveFlashCount(2), isFalse);
      expect(await p.saveFlashCount(8), isFalse);
      expect(calls, isEmpty);
      expect(await p.saveFlashCount(4), isTrue);
      expect(calls, ['patch(flashCount:4)', 'refreshConfig']);
    });

    test(
      'macros columns outside 1–3 is rejected before any bridge call',
      () async {
        expect(await p.saveMacrosColumns(0), isFalse);
        expect(await p.saveMacrosColumns(4), isFalse);
        expect(calls, isEmpty);
        expect(await p.saveMacrosColumns(2), isTrue);
        expect(calls, ['patch(macrosColumns:2)', 'refreshConfig']);
      },
    );

    test('reset issues the engine reset command — no values cross the seam, '
        'the engine owns the defaults (#180)', () async {
      await p.resetDefaults();
      expect(calls, ['resetBehavior', 'refreshConfig']);
    });
  });
}
