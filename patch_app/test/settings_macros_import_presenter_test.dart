import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/presenters/settings/macros_import_presenter.dart';

void main() {
  late List<String> calls;
  late MacrosImportPresenter p;

  setUp(() {
    calls = [];
    p = MacrosImportPresenter(
      requestGlobalMacros: (peerId) async =>
          calls.add('requestGlobalMacros:$peerId'),
      previewGlobalMacros: (offered) async {
        calls.add('previewGlobalMacros:${offered.length}');
        return [MacroAdded(offered.first)];
      },
    );
  });

  group('MacrosImportPresenter', () {
    test('request marks awaiting and calls the bridge with the peer id',
        () async {
      await p.request('peer-1');
      expect(calls, ['requestGlobalMacros:peer-1']);
    });

    test('handleOffer ignores an unsolicited offer (never requested)', () {
      expect(p.handleOffer(), isFalse);
    });

    test('handleOffer accepts and clears the flag after a request', () async {
      await p.request('peer-1');
      expect(p.handleOffer(), isTrue);
      // A second offer must not pop a stale dialog.
      expect(p.handleOffer(), isFalse);
    });

    test('timeout clears the flag and reports it fired, if still awaiting',
        () async {
      await p.request('peer-1');
      expect(p.timeout(), isTrue);
      expect(p.handleOffer(), isFalse);
    });

    test('timeout is a no-op if an offer already arrived', () async {
      await p.request('peer-1');
      p.handleOffer();
      expect(p.timeout(), isFalse);
    });

    test('preview delegates to the injected classifier', () async {
      const macro = MacroMessage(label: 'Standby', payload: 'standby');
      final outcomes = await p.preview([macro]);
      expect(calls, ['previewGlobalMacros:1']);
      expect(outcomes, [isA<MacroAdded>()]);
    });
  });
}
