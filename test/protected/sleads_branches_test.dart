// PROTECTED — CMD #1871. Leads that share a phone are ONE row.
//
// A chain publishes one phone number and Maps lists every branch of it, so
// S Leads was showing the same shop three, five, nine times. get_scraped_leads
// now returns the best-scored member of each phone group and puts the group
// size on the row; sleads_page carries it through; the screen prints it.
//
// What this holds down, and why each one is a real way to get it wrong:
//   • The chip's TEXT is the backend's. "3 branches" while collapsed and
//     "1 of 3 branches" once "Show all branches" is on are two different
//     backend strings for the same group size — pluralising or composing
//     either one in Dart would put the wording in a deploy instead of an
//     UPDATE.
//   • Whether tapping the chip opens anything is branches_expandable, a
//     BACKEND flag — never "branches > 1" computed here. With the toggle on,
//     every branch is already its own row, so the backend sends false and the
//     chip is a plain label.
//   • A row with no branch group carries NO label: absence is null, not a
//     Dart-invented "1 branch".
//   • The filter is one key in the same filter map every other S Leads
//     toggle uses, so a saved view carries it and the count RPCs see it.
//
// Pure Dart: no network, no Supabase, no widgets.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/leads_paging.dart';
import 'package:pharma_b2b/screens/admin/sleads_filter_bar.dart';

Map<String, dynamic> _row({
  required int id,
  required String title,
  String? branchesLabel,
  bool? expandable,
}) =>
    {
      'id': id,
      'title': title,
      if (branchesLabel != null) 'branches_label': branchesLabel,
      if (expandable != null) 'branches_expandable': expandable,
    };

void main() {
  group('the branch chip is the backend\'s sentence, not a count', () {
    test('collapsed: the label is carried verbatim and the chip opens', () {
      final r = SLeadRow.from(_row(
          id: 7,
          title: 'Jeevan Medical Store — Shankar Nagar',
          branchesLabel: '3 branches',
          expandable: true));

      expect(r.branchesLabel, '3 branches');
      expect(r.branchesExpandable, isTrue);
    });

    test('toggle on: the SAME group prints the backend\'s other sentence, '
        'and the chip no longer opens anything', () {
      final r = SLeadRow.from(_row(
          id: 7,
          title: 'Jeevan Medical Store — Shankar Nagar',
          branchesLabel: '1 of 3 branches',
          expandable: false));

      // Not "3 branches" with a prefix bolted on in Dart — a different string.
      expect(r.branchesLabel, '1 of 3 branches');
      expect(r.branchesExpandable, isFalse);
    });

    test('a lead with no branch group carries no label at all', () {
      final r = SLeadRow.from(_row(id: 9, title: 'Sharma Medical Store'));

      expect(r.branchesLabel, isNull);
      expect(r.branchesExpandable, isFalse);
    });

    test('an unknown branch label is still printed, never re-worded', () {
      // The day the copy row changes, the screen must follow without a deploy.
      final r = SLeadRow.from(_row(
          id: 11, title: 'X', branchesLabel: '7 shops on this number',
          expandable: true));

      expect(r.branchesLabel, '7 shops on this number');
    });

    test('branches_expandable is the flag, never derived from the label', () {
      // A label that clearly names a group, but the backend said no.
      final r = SLeadRow.from(_row(
          id: 12, title: 'X', branchesLabel: '4 branches', expandable: false));

      expect(r.branchesExpandable, isFalse);
    });
  });

  group('"Show all branches" is one key in the ordinary filter map', () {
    test('the toggle round-trips like every other hidden-by-default switch',
        () {
      const s0 = SLeadsFilterState();
      expect(s0.toggle('show_all_branches'), isFalse);

      final on = s0.setToggle('show_all_branches', true);
      expect(on.toggle('show_all_branches'), isTrue);
      expect(on.value['show_all_branches'], isTrue);

      final off = on.setToggle('show_all_branches', false);
      expect(off.toggle('show_all_branches'), isFalse);
    });

    test('it survives a saved view, because it lives in the same map', () {
      final saved = SLeadsFilterState.fromPayload(
          {'show_all_branches': true, 'min_score': 40});

      expect(saved.toggle('show_all_branches'), isTrue);
      expect(saved.minScore, 40);
    });

    test('setting it leaves the other switches alone', () {
      final s = const SLeadsFilterState()
          .setToggle('show_stale', true)
          .setToggle('show_all_branches', true);

      expect(s.toggle('show_stale'), isTrue);
      expect(s.toggle('show_all_branches'), isTrue);
      expect(s.toggle('show_closed'), isFalse);
    });
  });
}
