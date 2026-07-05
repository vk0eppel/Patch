import 'package:flutter_test/flutter_test.dart';
import 'package:patch/presenters/settings/save_result.dart';
import 'package:patch/presenters/settings/static_peers_presenter.dart';

void main() {
  late List<String> calls;
  late StaticPeersPresenter p;

  setUp(() {
    calls = [];
    p = StaticPeersPresenter(
      addStaticPeer: (a, port, label) async => calls.add('add:$a:$port:$label'),
      removeStaticPeer: (a, port) async => calls.add('remove:$a:$port'),
      refreshConfig: () async => calls.add('refreshConfig'),
      refreshPeers: () async => calls.add('refreshPeers'),
    );
  });

  group('StaticPeersPresenter', () {
    test('blank address or out-of-range port is rejected before any bridge '
        'call', () async {
      expect(await p.add('  ', 9000, null), isA<SaveError>());
      expect(await p.add('10.0.0.9', 0, null), isA<SaveError>());
      expect(await p.add('10.0.0.9', 70000, null), isA<SaveError>());
      expect(calls, isEmpty);
    });

    test('a valid add saves then refetches config and peers', () async {
      expect(await p.add(' 10.0.0.9 ', 9000, 'QLab'), isA<SaveOk>());
      expect(calls,
          ['add:10.0.0.9:9000:QLab', 'refreshConfig', 'refreshPeers']);
    });

    test('remove refetches config and peers', () async {
      await p.remove('10.0.0.9', 9000);
      expect(calls, ['remove:10.0.0.9:9000', 'refreshConfig', 'refreshPeers']);
    });

    test('removeAll removes every peer with a single refetch pair', () async {
      await p.removeAll([
        (address: '10.0.0.9', port: 9000),
        (address: '10.0.0.10', port: 9000),
      ]);
      expect(calls, [
        'remove:10.0.0.9:9000',
        'remove:10.0.0.10:9000',
        'refreshConfig',
        'refreshPeers',
      ]);
    });
  });
}
