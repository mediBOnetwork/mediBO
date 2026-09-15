// PROTECTED — CMD #1869. The S Leads archive lane.
//
// What this holds down, permanently:
//   • Every word on the bulk toolbar is a BACKEND string. Dart substitutes
//     {n} into the template it was sent and nothing else — it never composes
//     "Archive 3", never pluralises "3 leads", never names a lead class.
//   • Archive and Restore are ONE button in two states, and the archived view
//     is the only thing that flips it. 'delete' is not an option the UI has.
//   • The archived view is ONE key in CMD #1868's canonical filter map, and a
//     row's own `archived` flag — not the filter — is what puts Restore on a
//     card. Every other call hides archived leads.
//   • Long-press enters multi-select, a tap toggles inside it, and clearing
//     the last lead leaves it, so an empty toolbar can never strand the grid.
//
// Pure Dart: no Flutter, no network, no Supabase.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/sleads_bulk.dart';

/// A lead_leads_summary().bulk payload, shaped exactly like the RPC's.
const _payload = <String, dynamic>{
  'archive_days': 30,
  'archived_count': 4,
  'select_hint': 'Long-press a lead to select',
  'select_all_label': 'Select all',
  'clear_label': 'Clear',
  'selected_one': '1 selected',
  'selected_many': '{n} selected',
  'archive_label': 'Archive {n}',
  'reclassify_label': 'Reclassify {n}',
  'restore_label': 'Restore {n}',
  'confirm_title': 'Archive {n} leads?',
  'confirm_body':
      'They stay in Archived for 30 days, where Restore brings them back.',
  'confirm_ok': 'Archive',
  'confirm_cancel': 'Cancel',
  'class_title': 'Move to class',
  'row_restore': 'Restore',
  'archived_label': 'Archived',
  'archived_chip': 'Archived (4)',
  'classes': [
    {'key': 'medical_store', 'label': 'Medical store'},
    {'key': 'chain', 'label': 'Chain'},
    {'key': 'clinic', 'label': 'Clinic'},
  ],
};

void main() {
  const bulk = SLeadsBulk(_payload);

  group('labels are the backend\'s, with {n} substituted', () {
    test('the count goes into the template the backend sent', () {
      expect(bulk.label('archive_label', n: 3), 'Archive 3');
      expect(bulk.reclassifyLabel(7), 'Reclassify 7');
      expect(bulk.confirmTitle(2), 'Archive 2 leads?');
    });

    test('singular and plural are two backend strings, not Dart grammar', () {
      expect(bulk.selectedLabel(1), '1 selected');
      expect(bulk.selectedLabel(5), '5 selected');
    });

    test('a wording change is an UPDATE, never a deploy', () {
      const hi = SLeadsBulk(<String, dynamic>{'archive_label': '{n} हटाएँ'});
      expect(hi.label('archive_label', n: 9), '9 हटाएँ');
    });

    test('a label the backend did not send is not drawn', () {
      const empty = SLeadsBulk(<String, dynamic>{});
      expect(empty.label('archive_label', n: 3), '');
      expect(empty.selectedLabel(2), '');
      expect(empty.reclassifyLabel(1), '');
    });

    test('no count means no substitution', () {
      expect(bulk.label('confirm_ok'), 'Archive');
      expect(bulk.label('archive_label'), 'Archive {n}');
    });
  });

  group('Archive and Restore are one button in two states', () {
    test('the default view archives', () {
      expect(bulk.primaryActionKey(false), 'archive');
      expect(bulk.primaryActionLabel(false, 3), 'Archive 3');
    });

    test('the archived view restores — the UI never hard-deletes', () {
      expect(bulk.primaryActionKey(true), 'restore');
      expect(bulk.primaryActionLabel(true, 3), 'Restore 3');
      expect(bulk.primaryActionKey(true), isNot('delete'));
      expect(bulk.primaryActionKey(false), isNot('delete'));
    });
  });

  group('the archived view is a FILTER, not a screen mode', () {
    test('it lives under one key in the canonical filter map', () {
      expect(SLeadsBulk.archivedKey, 'archived');
      expect(SLeadsBulk.isArchivedView(const {'archived': true}), isTrue);
      expect(SLeadsBulk.isArchivedView(const {'archived': false}), isFalse);
    });

    test('an absent key is the default view — never a guess', () {
      expect(SLeadsBulk.isArchivedView(const {}), isFalse);
      expect(SLeadsBulk.isArchivedView(const {'archived': null}), isFalse);
      expect(SLeadsBulk.isArchivedView(const {'archived': 'true'}), isFalse);
    });

    test('a row says whether IT is archived; the filter never decides that',
        () {
      expect(SLeadsBulk.rowArchived(const {'id': 1, 'archived': true}), isTrue);
      expect(SLeadsBulk.rowArchived(const {'id': 1, 'archived': false}), isFalse);
      expect(SLeadsBulk.rowArchived(const {'id': 1}), isFalse);
    });
  });

  group('classes come from the payload, in its order', () {
    test('order is the backend\'s, never re-sorted in Dart', () {
      expect(bulk.classes.map((c) => c['key']).toList(),
          ['medical_store', 'chain', 'clinic']);
    });

    test('labels are the backend\'s', () {
      expect(bulk.classLabel('medical_store'), 'Medical store');
      expect(bulk.classLabel('clinic'), 'Clinic');
    });

    test('an unknown class prints its key verbatim — never an invented name',
        () {
      expect(bulk.classLabel('wholesaler'), 'wholesaler');
    });

    test('a class with no label falls back to its own key', () {
      const c = SLeadsBulk(<String, dynamic>{
        'classes': [
          {'key': 'lab', 'label': ''}
        ]
      });
      expect(c.classLabel('lab'), 'lab');
    });

    test('a malformed classes block degrades to empty, never throws', () {
      expect(const SLeadsBulk(<String, dynamic>{'classes': 'nope'}).classes,
          isEmpty);
      expect(
          const SLeadsBulk(<String, dynamic>{
            'classes': [
              {'label': 'no key'}
            ]
          }).classes,
          isEmpty);
    });
  });

  group('the archive window is read, not assumed', () {
    test('the backend says how many days', () {
      expect(bulk.archiveDays, 30);
      expect(bulk.archivedCount, 4);
    });

    test('a silent backend gives 0, and the copy still comes from it', () {
      const empty = SLeadsBulk(<String, dynamic>{});
      expect(empty.archiveDays, 0);
      expect(empty.archivedCount, 0);
    });
  });

  group('multi-select', () {
    test('long-press enters select mode with that lead picked', () {
      final s = SLeadsSelection();
      expect(s.isActive, isFalse);
      s.enter(11);
      expect(s.isActive, isTrue);
      expect(s.contains(11), isTrue);
      expect(s.length, 1);
    });

    test('long-pressing an already-picked lead never deselects it', () {
      final s = SLeadsSelection()..enter(11);
      s.enter(11);
      expect(s.contains(11), isTrue);
      expect(s.length, 1);
    });

    test('a tap toggles inside select mode', () {
      final s = SLeadsSelection()..enter(11);
      s.toggle(12);
      expect(s.length, 2);
      s.toggle(12);
      expect(s.length, 1);
      expect(s.contains(11), isTrue);
    });

    test('clearing the last lead leaves select mode', () {
      final s = SLeadsSelection()..enter(11);
      s.toggle(11);
      expect(s.length, 0);
      expect(s.isActive, isFalse);
    });

    test('Select all picks the page and stays in select mode', () {
      final s = SLeadsSelection()..selectAll([1, 2, 3]);
      expect(s.length, 3);
      expect(s.isActive, isTrue);
    });

    test('Clear empties it', () {
      final s = SLeadsSelection()..selectAll([1, 2, 3]);
      s.clear();
      expect(s.length, 0);
      expect(s.isActive, isFalse);
    });

    test('rows that moved leave the selection after a bulk call', () {
      final s = SLeadsSelection()..selectAll([1, 2, 3]);
      s.removeAll([1, 2]);
      expect(s.ids, {3});
      expect(s.isActive, isTrue);
      s.removeAll([3]);
      expect(s.isActive, isFalse);
    });
  });
}
