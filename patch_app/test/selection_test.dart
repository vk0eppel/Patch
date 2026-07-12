// Unit tests for the Selection sealed type — the ALL one-shot snap-back and
// DM-exclusivity rules now live here instead of being re-inferred from the
// shape of a raw Set<String> at every call site in home_screen.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:patch/models/message.dart';
import 'package:patch/models/selection.dart';

void main() {
  group('ChannelSelection', () {
    test('tabIds is the channel id set itself', () {
      const sel = ChannelSelection({'rf', 'audio'});
      expect(sel.tabIds, {'rf', 'audio'});
      expect(sel.isAllMode, isFalse);
      expect(sel.isDmMode, isFalse);
      expect(sel.dmPeerId, isNull);
    });

    test('isMultiChannel reflects the channel count', () {
      expect(const ChannelSelection({'rf'}).isMultiChannel, isFalse);
      expect(const ChannelSelection({'rf', 'audio'}).isMultiChannel, isTrue);
    });

    test('containsRawId matches only ids in the set', () {
      const sel = ChannelSelection({'rf'});
      expect(sel.containsRawId('rf'), isTrue);
      expect(sel.containsRawId('audio'), isFalse);
      expect(sel.containsRawId(kAllChannelId), isFalse);
      expect(sel.containsRawId('dm:p1'), isFalse);
    });
  });

  group('AllSelection', () {
    test(
      'tabIds is just the ALL sentinel, carries the prior selection for snap-back',
      () {
        const sel = AllSelection({'rf', 'audio'});
        expect(sel.tabIds, {kAllChannelId});
        expect(sel.isAllMode, isTrue);
        expect(sel.isMultiChannel, isFalse); // exclusive — never "multi"
        expect(sel.previous, {'rf', 'audio'});
      },
    );

    test('containsRawId matches only the ALL sentinel', () {
      const sel = AllSelection({'rf'});
      expect(sel.containsRawId(kAllChannelId), isTrue);
      expect(sel.containsRawId('rf'), isFalse);
    });
  });

  group('DmSelection', () {
    test('tabIds is empty — DM tabs never appear in the channel strip', () {
      const sel = DmSelection('p1');
      expect(sel.tabIds, isEmpty);
      expect(sel.isDmMode, isTrue);
      expect(sel.dmPeerId, 'p1');
    });

    test('containsRawId matches only this peer\'s dm: key', () {
      const sel = DmSelection('p1');
      expect(sel.containsRawId('dm:p1'), isTrue);
      expect(sel.containsRawId('dm:p2'), isFalse);
      expect(sel.containsRawId('p1'), isFalse);
    });
  });

  group('value equality', () {
    test('ChannelSelection compares by set contents, not identity', () {
      expect(
        const ChannelSelection({'rf', 'audio'}),
        const ChannelSelection({'audio', 'rf'}),
      ); // order-independent
      expect(
        const ChannelSelection({'rf'}),
        isNot(const ChannelSelection({'audio'})),
      );
      expect(
        const ChannelSelection({'rf'}).hashCode,
        const ChannelSelection({'rf'}).hashCode,
      );
    });

    test('AllSelection compares by previous contents', () {
      expect(const AllSelection({'rf'}), const AllSelection({'rf'}));
      expect(const AllSelection({'rf'}), isNot(const AllSelection({'audio'})));
      expect(const AllSelection({'rf'}), isNot(const ChannelSelection({'rf'})));
    });

    test('DmSelection compares by peerId', () {
      expect(const DmSelection('p1'), const DmSelection('p1'));
      expect(const DmSelection('p1'), isNot(const DmSelection('p2')));
    });
  });
}
