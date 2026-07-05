import 'package:flutter_test/flutter_test.dart';
import 'package:patch/presenters/settings/network_presenter.dart';

void main() {
  late List<String> calls;
  late NetworkPresenter p;
  List<({String name, String ip})> interfaces = [];
  Object? interfacesError;

  setUp(() {
    calls = [];
    interfaces = [];
    interfacesError = null;
    p = NetworkPresenter(
      setInterface: (n) async => calls.add('setInterface:$n'),
      setHeartbeatInterval: (s) async => calls.add('setHeartbeat:$s'),
      setOscPort: (port) async => calls.add('setOscPort:$port'),
      refreshConfig: () async => calls.add('refreshConfig'),
      getInterfaces: () async {
        if (interfacesError != null) throw interfacesError!;
        return interfaces;
      },
    );
  });

  group('NetworkPresenter', () {
    test('heartbeat outside 1–60 is rejected before any bridge call',
        () async {
      expect(await p.saveHeartbeatInterval(0), isFalse);
      expect(await p.saveHeartbeatInterval(61), isFalse);
      expect(calls, isEmpty);
    });

    test('valid heartbeat saves then refetches', () async {
      expect(await p.saveHeartbeatInterval(7), isTrue);
      expect(calls, ['setHeartbeat:7', 'refreshConfig']);
    });

    test('OSC port outside 1024–65535 is rejected before any bridge call',
        () async {
      expect(await p.saveOscPort(80), isFalse);
      expect(await p.saveOscPort(70000), isFalse);
      expect(calls, isEmpty);
    });

    test('valid OSC port saves then refetches', () async {
      expect(await p.saveOscPort(9000), isTrue);
      expect(calls, ['setOscPort:9000', 'refreshConfig']);
    });

    test('selecting a named interface saves it', () async {
      await p.selectInterface('en0');
      expect(calls, ['setInterface:en0', 'refreshConfig']);
    });

    test('interface list load failure degrades to an empty picker', () async {
      interfacesError = StateError('engine down');
      expect(await p.loadInterfaces(), isEmpty);
    });

    test('interface list maps name and ip', () async {
      interfaces = [(name: 'en0', ip: '10.0.0.5')];
      final got = await p.loadInterfaces();
      expect(got, [
        {'name': 'en0', 'ip': '10.0.0.5'},
      ]);
    });
  });
}
