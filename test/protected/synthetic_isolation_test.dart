// PROTECTED — a synthetic pharmacy is never visible to a real viewer
// (CHANGE #668).
//
// #668 gave test.cust1@medibo.in — the credential CLAUDE.md mandates for every
// customer-side verification — a real pharmacy_profiles row, so the My Shop
// suite can be PROVEN to work instead of only proven to open. That shop is
// marked is_synthetic, and the price of admission is that no real surface may
// ever show it: a test shop offered to a real supplier, printed on the public
// /near page, or counted into an admin list is a worse bug than the gap it
// closed.
//
// The rest of the suite tests widgets, because the rest of the app's decisions
// are payloads. This one cannot be: invisibility is decided in SQL, before a
// payload exists, and a widget test of a mocked payload would assert only that
// the fixture author remembered. So this gate reads the SHIPPED MIGRATIONS —
// the same files the merge worker replays on live — resolves the LAST
// definition of each protected surface, and fails if the synthetic filter is
// not in it.
//
// That is what makes it a ratchet rather than a snapshot: a future migration
// that re-creates near_search() or admin_list_customers() without the filter
// turns this test red in the command that wrote it, not in the incident that
// finds a test pharmacy in a real supplier's waterfall.
//
// If you are here because the gate went red: do not delete the name. Put the
// filter back — `and not coalesce(<alias>.is_synthetic, false)` — or, for the
// two exchange surfaces, the symmetric form that matches the caller's own kind.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The surfaces that ENUMERATE pharmacies for a real human, and therefore may
/// never carry a synthetic row. Audited in #668 out of the 322 functions that
/// read pharmacy_profiles; the rest either bind a unique key (a phone, a
/// customer code, an identity, auth.uid()) or join off an order/delivery that
/// orders.is_synthetic already drops.
const protectedSurfaces = <String>[
  'near_search',              // the public /near listing
  'near_pharmacy',            // a /near poster's own page
  'admin_list_customers',     // admin customer list
  'admin_customer_screen_data', // admin customers console payload
  'admin_missing_locations',  // admin "shops with no pin"
  'admin_alert_new_since',    // the new-registration overlay
  'customer_credit_list',     // admin credit picker
  'nav_search',               // the global search box
  'admin_claim_queue',        // payment claims, resolved by phone
  'khata_admin_overview',     // every shop's khata book, for a super admin
  '_px_browse',               // pharmacy exchange: other shops' listings
  '_px_borrow_search',        // pharmacy exchange: borrow from another shop
];

/// Every `create or replace function public.<name>(` … dollar-quoted body …
/// found in [sql], in file order. Returns the bodies only.
List<String> _bodiesFor(String sql, String fn) {
  final out = <String>[];
  final head = RegExp(
    r'create\s+or\s+replace\s+function\s+(?:public\.)?' +
        RegExp.escape(fn) +
        r'\s*\(',
    caseSensitive: false,
  );
  for (final m in head.allMatches(sql)) {
    // The body is the first dollar-quoted string after the signature.
    final tag = RegExp(r'\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$')
        .firstMatch(sql.substring(m.end));
    if (tag == null) continue;
    final open = m.end + tag.end;
    final close = sql.indexOf(tag.group(0)!, open);
    if (close < 0) continue;
    out.add(sql.substring(open, close));
  }
  return out;
}

void main() {
  final dir = Directory('supabase/migrations');

  test('every protected discovery surface filters is_synthetic', () {
    expect(dir.existsSync(), isTrue, reason: 'run from package root');

    // Migration filenames are numeric-prefixed and replay in name order, so
    // the LAST file that defines a function is the one live ends up with.
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final latest = <String, String>{};   // fn -> body
    final source = <String, String>{};   // fn -> file it came from
    for (final f in files) {
      final sql = f.readAsStringSync();
      for (final fn in protectedSurfaces) {
        final bodies = _bodiesFor(sql, fn);
        if (bodies.isEmpty) continue;
        latest[fn] = bodies.last;
        source[fn] = f.uri.pathSegments.last;
      }
    }

    final missing = <String>[];
    for (final fn in protectedSurfaces) {
      final body = latest[fn];
      if (body == null) {
        missing.add('$fn — no definition found in supabase/migrations');
        continue;
      }
      if (!body.contains('is_synthetic')) {
        missing.add('$fn — last defined in ${source[fn]} with no '
            'is_synthetic filter');
      }
    }

    expect(missing, isEmpty,
        reason: 'a synthetic pharmacy would be visible to a real viewer '
            'through:\n  ${missing.join("\n  ")}');
  });

  test('the shop that owns the test credential is seeded as synthetic', () {
    // The other half of the same contract: the fixture must ASK to be hidden.
    // A seed that forgets is_synthetic=true would sail past the gate above and
    // put a test pharmacy into every real list.
    final seeds = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sql'))
        .map((f) => f.readAsStringSync())
        .where((s) => s.contains('test_customer_shop_ensure'))
        .toList();

    expect(seeds, isNotEmpty,
        reason: 'the test.cust1 shop fixture (#668) has left the repo');

    final seed = seeds.last;
    expect(seed.contains('test.cust1@medibo.in'), isTrue,
        reason: 'the fixture must bind the credential CLAUDE.md mandates');
    expect(seed.contains('is_synthetic'), isTrue,
        reason: 'the seeded shop must be marked synthetic or nothing hides it');
    // It must never carry a map pin: a surface nobody has audited yet cannot
    // draw a shop it has no coordinates for.
    expect(RegExp(r'latitude\s*=\s*null').hasMatch(seed), isTrue,
        reason: 'the synthetic shop must stay off the map');
  });
}
