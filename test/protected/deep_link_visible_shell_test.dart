// CMD #2141 — a cold /admin/go/<key> link opens on the shell the person SEES.
//
// The URL builds two routes, '/' underneath and the link's own route on top,
// and each mounts a HomeShell. #2144 removed the shell's GlobalKey, so they are
// two states now, and the one underneath mounted first, took the parked link
// and opened the screen out of sight: every admin deep link (push, WhatsApp,
// palette, the feature journeys) landed on the storefront. What must never
// drift:
//  • a cold link is taken by the shell on the CURRENT route, never the one
//    under it;
//  • a lone shell still takes its link at once;
//  • a shell covered by another page leaves the link parked and takes it the
//    moment the page above it pops.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/admin/nav_registry_view.dart';

/// Stands in for HomeShell: consumes the parked link exactly where the shell
/// does, in didChangeDependencies.
class _Shell extends StatefulWidget {
  const _Shell(this.name, this.took);
  final String name;
  final Map<String, List<String>> took;

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final r = PendingAdminNav.takeFor(context);
    if (r != null) widget.took.putIfAbsent(widget.name, () => []).add(r);
  }

  @override
  Widget build(BuildContext context) => Text('SHELL ${widget.name}');
}

Route<void> _page(String name, Widget child) => MaterialPageRoute<void>(
      settings: RouteSettings(name: name),
      builder: (_) => child,
    );

void main() {
  tearDown(() {
    PendingAdminNav.route = null;
    PendingAdminNav.seed = null;
  });

  Future<void> pump(WidgetTester t, List<Route<void>> Function() routes) async {
    await t.pumpWidget(MaterialApp(
      initialRoute: '/admin/go/customers',
      onGenerateInitialRoutes: (_) => routes(),
      onGenerateRoute: (s) => _page(s.name ?? '/', const SizedBox.shrink()),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('a cold link is taken by the shell on top, never the one under it',
      (t) async {
    final took = <String, List<String>>{};
    PendingAdminNav.park('customers');
    await pump(t, () => [
          _page('/', _Shell('under', took)),
          _page('/admin/go/customers', _Shell('top', took)),
        ]);
    expect(took['top'], ['customers']);
    expect(took['under'], isNull, reason: 'the hidden shell must not open it');
    expect(PendingAdminNav.route, isNull, reason: 'a link fires once');
  });

  testWidgets('a lone shell takes its link at once', (t) async {
    final took = <String, List<String>>{};
    PendingAdminNav.park('suppliers');
    await pump(t, () => [_page('/', _Shell('only', took))]);
    expect(took['only'], ['suppliers']);
  });

  testWidgets('a covered shell keeps the link parked until the page above pops',
      (t) async {
    final took = <String, List<String>>{};
    PendingAdminNav.park('money');
    await pump(t, () => [
          _page('/', _Shell('under', took)),
          _page('/admin/dev-queue', const Text('A PAGE THAT IS NOT A SHELL')),
        ]);
    expect(took, isEmpty);
    expect(PendingAdminNav.route, 'money');

    t.state<NavigatorState>(find.byType(Navigator)).pop();
    await t.pumpAndSettle();
    expect(took['under'], ['money']);
    expect(PendingAdminNav.route, isNull);
  });
}
