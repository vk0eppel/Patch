import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/channels_import_presenter.dart';

PatchChannel ch(String id) =>
    PatchChannel(id: id, displayName: id, color: Colors.red);

void main() {
  late List<String> calls;
  late ChannelsImportPresenter p;

  setUp(() {
    calls = [];
    p = ChannelsImportPresenter(
      requestChannels: (peerId) async => calls.add('requestChannels:$peerId'),
    );
  });

  group('ChannelsImportPresenter', () {
    test('request marks awaiting and calls the bridge with the peer id',
        () async {
      await p.request('peer-1');
      expect(calls, ['requestChannels:peer-1']);
    });

    test('handleOffer ignores an unsolicited offer (never requested)', () {
      final fresh = p.handleOffer(offered: [ch('a')], existing: const []);
      expect(fresh, isNull);
    });

    test('handleOffer after a request returns only channels not already held',
        () async {
      await p.request('peer-1');
      final fresh = p.handleOffer(
        offered: [ch('a'), ch('b'), ch('c')],
        existing: [ch('b')],
      );
      expect(fresh!.map((c) => c.id), ['a', 'c']);
    });

    test('handleOffer clears the awaiting flag — a second offer is ignored',
        () async {
      await p.request('peer-1');
      p.handleOffer(offered: [ch('a')], existing: const []);
      final second = p.handleOffer(offered: [ch('a')], existing: const []);
      expect(second, isNull);
    });

    test('timeout clears the flag and reports it fired, if still awaiting',
        () async {
      await p.request('peer-1');
      expect(p.timeout(), isTrue);
      // A later unsolicited offer must not pop a stale dialog.
      expect(p.handleOffer(offered: [ch('a')], existing: const []), isNull);
    });

    test('timeout is a no-op if an offer already arrived', () async {
      await p.request('peer-1');
      p.handleOffer(offered: [ch('a')], existing: const []);
      expect(p.timeout(), isFalse);
    });
  });
}
