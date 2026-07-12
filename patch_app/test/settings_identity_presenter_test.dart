import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/config.dart';
import 'package:patch/presenters/settings/identity_presenter.dart';

AppConfig cfg({String name = 'FOH Audio', String? role}) => AppConfig(
  clientName: name,
  role: role,
  nameIsDefault: false,
  oscPort: 9000,
  flashOnCritical: true,
  flashOnMessage: false,
  audibleAlert: false,
  flashCount: 3,
  macrosColumns: 2,
  hideKeyboard: false,
  heartbeatIntervalSecs: 7,
);

void main() {
  late List<String> calls;
  late IdentityPresenter p;

  setUp(() {
    calls = [];
    p = IdentityPresenter(
      setClientName: (n) async => calls.add('setClientName:$n'),
      setRole: (r) async => calls.add('setRole:$r'),
      refreshConfig: () async => calls.add('refreshConfig'),
    );
  });

  group('IdentityPresenter', () {
    test('saveName rejects blank input before any bridge call', () async {
      expect(await p.saveName('   '), isFalse);
      expect(calls, isEmpty);
    });

    test('saveName trims and saves', () async {
      expect(await p.saveName('  Monitors  '), isTrue);
      expect(calls, ['setClientName:Monitors']);
    });

    test(
      'saveRole saves then refetches config (no push echoes back)',
      () async {
        await p.saveRole('PM');
        expect(calls, ['setRole:PM', 'refreshConfig']);
      },
    );

    test('seedOnce yields config values exactly once', () {
      expect(p.seedOnce(null), isNull); // not loaded yet — keep waiting
      final seed = p.seedOnce(cfg(name: 'FOH', role: 'Audio'));
      expect((seed!.name, seed.role), ('FOH', 'Audio'));
      // A later config notify must not clobber the Operator's edits.
      expect(p.seedOnce(cfg(name: 'Other')), isNull);
    });

    test(
      'resetIdentity restores the default name and clears the role',
      () async {
        final seed = await p.resetIdentity(defaultName: 'crew');
        expect(seed, 'crew');
        expect(calls, ['setClientName:crew', 'setRole:null', 'refreshConfig']);
      },
    );
  });
}
