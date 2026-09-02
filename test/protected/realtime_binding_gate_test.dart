// PROTECTED — the realtime-binding gate (CHANGE #646, verifying CHANGE #643).
//
// #643 moved the decision "does this table deserve a postgres_changes channel?"
// out of the widgets and into the backend: `realtime_table_registry` →
// `realtime_plan()` → `LiveFeed`, which opens a live binding only for the
// tables the plan marks live and polls everything else on the backend's own
// interval. Flipping a table between the two became one UPDATE.
//
// Three surfaces predate that and still call `.onPostgresChanges(` themselves.
// They are listed below with the tables they bind, and today every one of those
// tables is published and live. Nothing enforced that: dropping a table from
// `supabase_realtime` (which is exactly what #643 did to 21 of them) would have
// left these screens holding a channel that can never fire — a dead feed with
// no error, the worst failure shape there is.
//
// So this gate freezes the exception list. It fails when:
//   • a NEW file starts binding postgres_changes directly instead of going
//     through LiveFeed, or
//   • one of the three binds a table that is not on the published set below.
//
// The published set is asserted database-side too, by the rg behaviour
// `c646_registry_matches_publication` — this test is its Dart half, because a
// Flutter test cannot reach Supabase (the suite is Dart-VM-only, no network).
// Changing the publication therefore means touching BOTH, on purpose, in the
// same command. That is the point.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The tables `supabase_realtime` publishes, and that
/// `realtime_table_registry.live` marks live. Kept in step with the database by
/// `c646_registry_matches_publication`.
const _publishedTables = <String>{
  'auth_force_logout',
  'bag_item_counts',
  'bags',
  'cart_items',
  'order_items',
  'pharmacy_profiles',
  'supplier_count_mode',
  'whatsapp_messages',
};

/// The only files allowed to open a postgres_changes binding without asking
/// `LiveFeed`, and the LITERAL table names each one is allowed to bind.
/// Everything else must go through `LiveFeed.watch`, which obeys
/// `realtime_plan()`.
///
/// A binding whose `table:` is a variable is not listed here and cannot be:
/// `live_feed.dart` takes it from `realtime_plan()`, and `user_state.dart`'s
/// force-logout channel takes it from the backend's own watch descriptor. Those
/// are already the behaviour this gate is protecting — the table came from the
/// backend, so the backend can move it. Only a name written into Dart needs
/// freezing, because only a name written into Dart can go stale.
const _directBindings = <String, Set<String>>{
  'lib/services/live_feed.dart': <String>{}, // the router — table comes from the plan
  'lib/user_state.dart': {'pharmacy_profiles'}, // + force_logout, backend-supplied
  'lib/features/whatsapp/ui/wa_chat_screen.dart': {'whatsapp_messages'},
  'lib/features/whatsapp/ui/wa_home_screen.dart': {'whatsapp_messages'},
};

final _tableArg = RegExp(r"""table:\s*'([a-zA-Z0-9_]+)'""");

void main() {
  test('postgres_changes is opened only by LiveFeed or a frozen exception', () {
    expect(Directory('lib').existsSync(), isTrue, reason: 'run from package root');

    final offenders = <String>[];
    final boundTables = <String, Set<String>>{};

    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final path = e.path.replaceAll(r'\', '/');
      final src = e.readAsStringSync();
      if (!src.contains('.onPostgresChanges(')) continue;

      if (!_directBindings.containsKey(path)) {
        offenders.add(
            '  $path opens postgres_changes directly — route it through '
            'LiveFeed.watch() so realtime_table_registry decides, or add it here '
            'on purpose with the tables it binds.');
        continue;
      }
      boundTables[path] =
          _tableArg.allMatches(src).map((m) => m.group(1)!).toSet();
    }

    expect(offenders, isEmpty, reason: '\n${offenders.join('\n')}');

    // Every allowed file must still be there — a rename that quietly drops a
    // binding should be a deliberate edit to this list, not a silent pass.
    for (final path in _directBindings.keys) {
      expect(File(path).existsSync(), isTrue,
          reason: '$path is on the direct-binding list but no longer exists — '
              'update the list in the same change that moved it.');
    }

    // …and none of them may bind a table the database does not publish.
    final dead = <String>[];
    boundTables.forEach((path, tables) {
      for (final t in tables) {
        if (!_publishedTables.contains(t)) {
          dead.add('  $path binds "$t", which supabase_realtime does not '
              'publish — that channel can never fire. Either publish it (and '
              'set live in realtime_table_registry) or move the surface to '
              'LiveFeed.watch(), which polls what is not live.');
        }
      }
    });
    expect(dead, isEmpty, reason: '\n${dead.join('\n')}');
  });

  test('the direct-binding exceptions bind exactly the tables they declare', () {
    for (final entry in _directBindings.entries) {
      if (entry.value.isEmpty) continue; // live_feed.dart binds from the plan
      final src = File(entry.key).readAsStringSync();
      final found = _tableArg.allMatches(src).map((m) => m.group(1)!).toSet();
      expect(found, equals(entry.value),
          reason: '${entry.key} binds $found but this gate declares '
              '${entry.value}. A new table on an already-exempt screen is still '
              'a new standing cost on the WAL — declare it here and confirm it '
              'is published.');
    }
  });
}
