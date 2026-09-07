// PROTECTED — CHANGE #1867. The paging contract behind Customers > S Leads
// and Customers > Routes.
//
// What this holds down, and why each one was a real bug:
//   • "Is there another page?" is the BACKEND's has_more. The screen used to
//     load all 1702 rows because nothing on the client ever said stop.
//   • The next page starts at the BACKEND's next_offset, never rows.length.
//     A filtered page that comes back short would otherwise re-read rows the
//     list already holds, duplicating them forever as you scroll.
//   • A filter change / a keystroke RESETS to page 1 and replaces the list;
//     it must never append page 2 of the old query onto the new one.
//   • Rows are appended in payload order. No client-side sort, ever.
//   • Every string on screen — the count, the empty state, "Loading more…",
//     the end-of-list line — is the envelope's own, printed verbatim. The
//     end line appears only when the backend says nothing is left.
//   • A list row is drawn from the LIST payload alone (SLeadRow). It never
//     needs scrape_lead_card(); that call belongs to the tapped-open card.
//     A field neither payload carries stays null so the line is not drawn.
//
// Pure Dart: no network, no Supabase, no widgets. Runs in milliseconds.

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/leads_paging.dart';

Map<String, dynamic> _env({
  required List<Map<String, dynamic>> rows,
  required int total,
  required int offset,
  required bool hasMore,
  int? nextOffset,
  String? endLabel,
}) =>
    {
      'ok': true,
      'rows': rows,
      'total': total,
      'offset': offset,
      'page_size': 50,
      'has_more': hasMore,
      'next_offset': nextOffset,
      'count_label': '$total leads',
      'empty_label': '0 leads match these filters',
      'more_label': 'Loading more…',
      'end_label': endLabel,
    };

List<Map<String, dynamic>> _rows(Iterable<int> ids) =>
    [for (final i in ids) {'id': i, 'title': 'Lead $i'}];

void main() {
  group('PagedList — the two paging decisions', () {
    test('page 1 starts at 0 and replaces whatever was held', () {
      var p = const PagedList();
      expect(p.offsetFor(reset: true), 0);
      expect(p.loaded, isFalse, reason: 'nothing has come back yet');

      p = p.applyPage(
          _env(rows: _rows([1, 2, 3]), total: 7, offset: 0, hasMore: true, nextOffset: 3),
          reset: true);
      expect(p.rows.length, 3);

      // A filter change: page 1 of the NEW query, not page 2 of the old one.
      p = p.applyPage(
          _env(rows: _rows([9]), total: 1, offset: 0, hasMore: false, endLabel: 'All 1 lead shown'),
          reset: true);
      expect(p.rows.map((r) => r['id']), [9]);
      expect(p.total, 1);
    });

    test('the next offset is the backend\'s, never the list length', () {
      // A page that came back SHORT of its limit: rows.length is 2, but the
      // backend says the next page starts at 50. Trusting rows.length here
      // would re-read rows 2..49 and duplicate them.
      final p = const PagedList().applyPage(
          _env(rows: _rows([1, 2]), total: 120, offset: 0, hasMore: true, nextOffset: 50),
          reset: true);
      expect(p.offsetFor(reset: false), 50);
      expect(p.offsetFor(reset: true), 0);
    });

    test('appending keeps payload order and never duplicates', () {
      var p = const PagedList().applyPage(
          _env(rows: _rows([5, 3, 9]), total: 6, offset: 0, hasMore: true, nextOffset: 3),
          reset: true);
      p = p.applyPage(
          _env(rows: _rows([1, 8, 2]), total: 6, offset: 3, hasMore: false,
              endLabel: 'All 6 leads shown'),
          reset: false);
      // Deliberately non-sorted ids: the backend's order is the order.
      expect(p.rows.map((r) => r['id']).toList(), [5, 3, 9, 1, 8, 2]);
    });

    test('canLoadMore is the backend flag, not an arithmetic on total', () {
      // rows.length (3) < total (7) — the old client-side test would say
      // "there is more". The backend says there is not, and it wins.
      final p = const PagedList().applyPage(
          _env(rows: _rows([1, 2, 3]), total: 7, offset: 0, hasMore: false),
          reset: true);
      expect(p.canLoadMore, isFalse);

      // has_more true but no next_offset is not a loadable state either.
      final q = const PagedList().applyPage(
          _env(rows: _rows([1]), total: 7, offset: 0, hasMore: true),
          reset: true);
      expect(q.canLoadMore, isFalse);
    });

    test('empty is a loaded state, not the initial one', () {
      expect(const PagedList().isEmpty, isFalse);
      final p = const PagedList()
          .applyPage(_env(rows: const [], total: 0, offset: 0, hasMore: false), reset: true);
      expect(p.isEmpty, isTrue);
      expect(p.emptyLabel, '0 leads match these filters');
    });
  });

  group('PagedList — labels are the backend\'s, verbatim', () {
    test('count / more / empty print exactly what arrived', () {
      final p = const PagedList().applyPage(
          _env(rows: _rows([1]), total: 1702, offset: 0, hasMore: true, nextOffset: 50),
          reset: true);
      expect(p.countLabel, '1702 leads');
      expect(p.moreLabel, 'Loading more…');
      expect(p.emptyLabel, '0 leads match these filters');
    });

    test('the end line appears only when the backend says nothing is left', () {
      final more = const PagedList().applyPage(
          _env(rows: _rows([1]), total: 1702, offset: 0, hasMore: true, nextOffset: 50,
              endLabel: 'All 1702 leads shown'),
          reset: true);
      expect(more.endLabel, isNull, reason: 'has_more is true — nothing has ended');

      final done = const PagedList().applyPage(
          _env(rows: _rows([1]), total: 1, offset: 0, hasMore: false,
              endLabel: 'All 1 lead shown'),
          reset: true);
      expect(done.endLabel, 'All 1 lead shown');
    });

    test('a label the backend did not send is absent, never invented', () {
      final p = const PagedList()
          .applyPage({'ok': true, 'rows': const [], 'has_more': false}, reset: true);
      expect(p.countLabel, isNull);
      expect(p.emptyLabel, isNull);
      expect(p.moreLabel, isNull);
      expect(p.endLabel, isNull);
    });
  });

  group('SLeadRow — a list row needs no second call', () {
    test('sleads_page fields are carried through verbatim', () {
      final r = SLeadRow.from({
        'id': 42,
        'title': 'Sharma Medical Stores',
        'type_label': 'Pharmacy',
        'rating_label': '4.3 ★ (134)',
        'open_label': 'Open now',
        'open_bg': '#D1FAE5',
        'open_fg': '#065F46',
        'address_label': 'Pandri, Raipur',
        'phone_label': '+91 98765 43210',
      });
      expect(r.id, 42);
      expect(r.title, 'Sharma Medical Stores');
      expect(r.typeLabel, 'Pharmacy');
      expect(r.ratingLabel, '4.3 ★ (134)');
      expect(r.openLabel, 'Open now');
      expect(r.openBg, '#D1FAE5');
      expect(r.openFg, '#065F46');
      expect(r.addressLabel, 'Pandri, Raipur');
      expect(r.phoneLabel, '+91 98765 43210');
    });

    test('a saved run\'s raw columns fall back to the same fields', () {
      final r = SLeadRow.from({
        'id': 7,
        'name': 'Verma Pharma',
        'short_address': 'Shankar Nagar',
        'phone': '9876500007',
      });
      expect(r.title, 'Verma Pharma');
      expect(r.addressLabel, 'Shankar Nagar');
      expect(r.phoneLabel, '9876500007');
    });

    test('address prefers the backend label over the raw columns', () {
      final r = SLeadRow.from({
        'address_label': 'Short one',
        'short_address': 'Shorter',
        'address': 'The very long postal address',
      });
      expect(r.addressLabel, 'Short one');
    });

    test('absent stays absent — no placeholder is composed here', () {
      final r = SLeadRow.from({'id': 1, 'title': 'Only a name'});
      expect(r.typeLabel, isNull);
      expect(r.ratingLabel, isNull);
      expect(r.openLabel, isNull);
      expect(r.openBg, isNull);
      expect(r.openFg, isNull);
      expect(r.addressLabel, isNull);
      expect(r.phoneLabel, isNull);
    });

    test('an empty string is absence, not a blank line', () {
      final r = SLeadRow.from({'id': 1, 'title': 'X', 'phone_label': '', 'phone': '90000'});
      expect(r.phoneLabel, '90000');
    });
  });
}
