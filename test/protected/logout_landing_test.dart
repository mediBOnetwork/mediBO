// CMD #2144 — LOGOUT LANDS ON THE STOREFRONT HOME. EVERY TIME. IN UNDER 3 s.
//
// #2116 did not fix it. On web and the installed PWA a Logout tap cleared the
// account, pushed a fresh '/' route over the stack — and left the user on an
// endless spinner, the public home never asking for storefront_home_v2. The
// cause, named by a local debug build of the live code: HomeShell carried a STATIC
// GlobalKey, and for the frame in which the fresh '/' mounted over the old one
// there were two HomeShells and one key. "Multiple widgets used the same
// GlobalKey", a half-built tree, a spinner nothing could move. A second cause
// sat beside it: screen caches filled localStorage (storefront_home_v2 alone
// 2.7 M characters) until the SDK's session write threw QuotaExceededError.
//
// What this file holds down, on the Dart VM, with no Supabase:
//   * the landing replaces the WHOLE stack with a FRESH home, even when the
//     user is already on '/', three times in a row, each inside 3 s;
//   * the shell is found through LiveInstance, never a GlobalKey — and the
//     GlobalKey shape is shown to break the very same landing;
//   * the #2116 "already" latch that skipped a landing cannot come back;
//   * every gate that holds the screen gives up at 4 s;
//   * the screen caches stay inside a budget, a full storage is evicted and
//     retried, the session write always has room, and logout clears them —
//     including a landing run with the storage pre-filled.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharma_b2b/app_navigator.dart';
import 'package:pharma_b2b/services/live_instance.dart';
import 'package:pharma_b2b/services/payload_cache.dart';
import 'package:pharma_b2b/user_state.dart';

// ── a stand-in for the app: '/' is a shell that registers itself exactly the
// way HomeShell does, and a pushed account page sits over it.

int _shellInits = 0;
final _live = LiveInstance<_ShellState>();

class _Shell extends StatefulWidget {
  const _Shell({super.key});
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  void initState() {
    super.initState();
    _shellInits++;
    _live.attach(this);
  }

  @override
  void dispose() {
    _live.detach(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('storefront home'));
}

// The shape #2116 shipped: one static key for every instance.
final _sharedKey = GlobalKey<_ShellState>();

Widget _app({required Widget Function() home}) => MaterialApp(
      navigatorKey: appNavigatorKey,
      home: home(),
      onGenerateRoute: (s) => s.name == '/'
          ? MaterialPageRoute<void>(builder: (_) => home(), settings: s)
          : MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('my account')),
              settings: s),
    );

/// Storage with a quota, like a browser origin's localStorage.
class _QuotaDisk implements PayloadDisk {
  _QuotaDisk(this.quota);
  final int quota;
  final Map<String, String> data = {};
  int get used => data.entries.fold(0, (a, e) => a + e.key.length + e.value.length);

  @override
  Future<Set<String>> keys() async => data.keys.toSet();
  @override
  Future<String?> get(String key) async => data[key];
  @override
  Future<void> set(String key, String value) async {
    final after = used - (data[key]?.length ?? 0) + (data.containsKey(key) ? 0 : key.length) + value.length;
    if (after > quota) throw StateError('QuotaExceededError: $key');
    data[key] = value;
  }

  @override
  Future<void> remove(String key) async => data.remove(key);

  int cacheChars() => data.entries
      .where((e) => PayloadStore.cachePrefixes.any(e.key.startsWith))
      .fold(0, (a, e) => a + e.value.length);
}

String _blob(int n, {int savedAt = 1}) =>
    '{"saved_at_ms":$savedAt,"data":{"x":"${'x' * n}"}}';

const _authKey = 'sb-swojhmarmaijkshsbeih-auth-token';

/// Fill a disk the way a real phone was found: one oversized home payload,
/// a spread of rc: responses, and the non-cache ui_boot copy.
_QuotaDisk _prefilled() {
  final d = _QuotaDisk(5000000);
  d.data['payload_cache_v1.storefront_home_v2'] = _blob(2700000, savedAt: 50);
  for (var i = 0; i < 12; i++) {
    d.data['rc:POST rpc/search_page#$i'] = _blob(80000, savedAt: 10 + i);
  }
  d.data['payload_cache_v1.my_orders'] = _blob(400000, savedAt: 40);
  d.data['ui_boot_cache_v2'] = 'u' * 630000;
  return d;
}

Future<Duration> _landAndTime(WidgetTester tester) async {
  final before = tester.binding.clock.now();
  landOnRoute('/');
  await tester.pumpAndSettle();
  return tester.binding.clock.now().difference(before);
}

void main() {
  setUp(() {
    _shellInits = 0;
    PayloadStore.diskEnabled = true;
    PayloadStore.debugClear();
  });
  tearDown(() {
    PayloadStore.diskEnabled = true;
    PayloadStore.debugClear();
  });

  group('logout lands on a fresh storefront home', () {
    testWidgets('login → logout → storefront, 3 times in a row, each < 3 s',
        (tester) async {
      await tester.pumpWidget(_app(home: () => const _Shell()));
      expect(_shellInits, 1);

      for (var round = 1; round <= 3; round++) {
        // "logged in": an account page pushed over the shell.
        appNavigatorKey.currentState!.pushNamed('/profile');
        await tester.pumpAndSettle();
        expect(find.text('my account'), findsOneWidget);

        final took = await _landAndTime(tester);

        expect(tester.takeException(), isNull, reason: 'round $round');
        expect(find.text('storefront home'), findsOneWidget, reason: 'round $round');
        expect(find.text('my account'), findsNothing, reason: 'round $round');
        expect(took, lessThan(const Duration(seconds: 3)), reason: 'round $round');
        // A FRESH shell each time — the old one is gone, the registry names
        // the new one, and nothing pushed survived.
        expect(_shellInits, 1 + round, reason: 'round $round');
        expect(_live.current, isNotNull);
        expect(appNavigatorKey.currentState!.canPop(), isFalse);
      }
    });

    testWidgets('already on "/" still rebuilds — "already" never skips',
        (tester) async {
      await tester.pumpWidget(_app(home: () => const _Shell()));
      final first = _live.current;
      await _landAndTime(tester);
      expect(tester.takeException(), isNull);
      expect(_shellInits, 2);
      expect(identical(_live.current, first), isFalse);
      expect(find.text('storefront home'), findsOneWidget);
    });

    testWidgets('the #2116 shape — one static GlobalKey — breaks that landing',
        (tester) async {
      // Why HomeShell may never carry a GlobalKey again: the very same
      // landing, with the shell keyed the way it was, throws.
      await tester.pumpWidget(_app(home: () => _Shell(key: _sharedKey)));
      appNavigatorKey.currentState!.pushNamed('/profile');
      await tester.pumpAndSettle();
      landOnRoute('/');
      await tester.pump();
      expect(tester.takeException(), isNotNull);
    });

    testWidgets('storage pre-filled: evicted at boot, then logout still lands',
        (tester) async {
      final disk = _prefilled();
      PayloadStore.disk = disk;
      PayloadStore.debugSeed('storefront_home_v2', {'who': 'previous account'});
      await tester.runAsync(() => PayloadStore.enforceBudget());
      expect(disk.cacheChars(), lessThanOrEqualTo(PayloadStore.maxTotalChars));
      // the session write has room
      await tester.runAsync(() => disk.set(_authKey, 's' * 4000));
      expect(disk.data.containsKey(_authKey), isTrue);

      await tester.pumpWidget(_app(home: () => const _Shell()));
      appNavigatorKey.currentState!.pushNamed('/profile');
      await tester.pumpAndSettle();
      await tester.runAsync(() => PayloadStore.clearAll()); // what signOut does
      final took = await _landAndTime(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('storefront home'), findsOneWidget);
      expect(took, lessThan(const Duration(seconds: 3)));
      expect(disk.cacheChars(), 0);
      expect(await tester.runAsync(() => PayloadStore.read('storefront_home_v2')), isNull);
      expect(disk.data.containsKey(_authKey), isTrue);
      expect(disk.data.containsKey('ui_boot_cache_v2'), isTrue);
    });
  });

  group('LiveInstance — the newest mounted instance wins', () {
    test('an old instance leaving never clears the new one', () {
      final r = LiveInstance<Object>();
      final a = Object(), b = Object();
      r.attach(a);
      r.attach(b); // the fresh shell mounts first …
      r.detach(a); // … the old one is torn down after
      expect(identical(r.current, b), isTrue);
      expect(r.isCurrent(b), isTrue);
      r.detach(b);
      expect(r.current, isNull);
    });
  });

  group('the source keeps the fix', () {
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();
    final auth = File('lib/user_state.dart').readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();
    final rider = File('lib/services/delivery_role_state.dart').readAsStringSync();

    test('HomeShell has no GlobalKey and registers through LiveInstance', () {
      expect(shell.contains('GlobalKey<_HomeShellState>'), isFalse);
      expect(shell.contains('LiveInstance<_HomeShellState>'), isTrue);
      expect(shell.contains('HomeShell.live.attach(this)'), isTrue);
      expect(shell.contains('HomeShell.live.detach(this)'), isTrue);
    });

    test('no latch skips a landing; signOut lands after the credential', () {
      expect(auth.contains('_landedSignedOut'), isFalse);
      expect(auth.contains("'already'"), isFalse);
      final body = auth.substring(auth.indexOf('Future<void> signOut() async {'));
      final cred = body.indexOf('.signOut(scope: SignOutScope.local)');
      final land = body.indexOf("_landPublicHome('tap')");
      expect(cred, greaterThan(0));
      expect(land, greaterThan(cred));
      // …and the credential step is bounded, so the landing always comes.
      expect(body.substring(cred, land).contains('.timeout(_signOutBudget)'), isTrue);
      // an SDK-originated sign-out lands too
      expect(auth.contains("_landPublicHome('sdk_signed_out')"), isTrue);
    });

    test('every gate that holds the screen gives up at 4 s', () {
      expect(AuthNotifier.gateBudget, const Duration(seconds: 4));
      expect(main.contains('Timer(AuthNotifier.gateBudget'), isTrue);
      // the boot splash and the role-resolving spinner await the BOUNDED load
      expect(auth.contains('_initDone = true;\n          await _loadSessionBounded();'), isTrue);
      expect(auth.contains('_profileLoading = true;\n          notifyListeners();\n          await _loadSessionBounded();'), isTrue);
      expect('await _loadSessionBounded();'.allMatches(auth).length, greaterThanOrEqualTo(4),
          reason: 'a gate awaiting the unbounded fetch can hold the splash forever');
      expect(rider.contains(".rpc('my_delivery_run')\n          .timeout(const Duration(seconds: 4))"), isTrue);
    });

    test('the cache budget runs at boot, before Supabase starts', () {
      final budget = main.indexOf('PayloadStore.enforceBudget()');
      final init = main.indexOf('await Supabase.initialize(');
      expect(budget, greaterThan(0));
      expect(budget, lessThan(init));
    });
  });

  group('cache budget and quota', () {
    test('an oversized payload stays in memory only', () async {
      final disk = _QuotaDisk(5000000);
      PayloadStore.disk = disk;
      await PayloadStore.write('big', {'x': 'y' * (PayloadStore.maxEntryChars + 1)});
      expect(disk.data.keys.where((k) => k.contains('big')), isEmpty);
      expect(await PayloadStore.read('big'), isNotNull);
    });

    test('a full storage is evicted and the write retried once', () async {
      final disk = _QuotaDisk(1200000);
      final savedTotal = PayloadStore.maxTotalChars;
      PayloadStore.maxTotalChars = 1 << 30; // let the cache fill the origin
      try {
        for (var i = 0; i < 5; i++) {
          disk.data['rc:k$i'] = _blob(230000);
        }
        PayloadStore.disk = disk;
        await PayloadStore.write('home', {'x': 'z' * 100000});
        expect(disk.data.containsKey('payload_cache_v1.home'), isTrue);
        expect(disk.data.keys.where((k) => k.startsWith('rc:')), isEmpty);
      } finally {
        PayloadStore.maxTotalChars = savedTotal;
      }
    });

    test('writes keep every cache key inside the budget, oldest out first', () async {
      final disk = _QuotaDisk(5000000);
      PayloadStore.disk = disk;
      disk.data['payload_cache_v1.old'] = _blob(500000, savedAt: 1);
      disk.data['payload_cache_v1.mid'] = _blob(500000, savedAt: 2);
      disk.data['payload_cache_v1.new'] = _blob(400000, savedAt: 3);
      await PayloadStore.write('fresh', {'x': 'f' * 300000});
      expect(disk.cacheChars(), lessThanOrEqualTo(PayloadStore.maxTotalChars));
      expect(disk.data.containsKey('payload_cache_v1.old'), isFalse);
      expect(disk.data.containsKey('payload_cache_v1.fresh'), isTrue);
    });

    test('logout clears the previous account\'s cached screens only', () async {
      final disk = _prefilled();
      disk.data[_authKey] = 's' * 3000;
      PayloadStore.disk = disk;
      PayloadStore.debugSeed('my_orders', {'orders': 3});
      await PayloadStore.clearAll();
      expect(disk.cacheChars(), 0);
      expect(await PayloadStore.read('my_orders'), isNull);
      expect(disk.data.containsKey('ui_boot_cache_v2'), isTrue);
      expect(disk.data.containsKey(_authKey), isTrue);
    });
  });
}
