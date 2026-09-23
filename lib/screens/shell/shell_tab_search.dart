part of '../home_shell.dart';

// CMD #2175 · shard — the search row EVERY customer tab wears, and the one
// place that knows which surface answers a typed query.
//
// Om: "Search per tab — Home, Catalogue, Bulk → products + companies. Orders →
// orders, items, any date. Profile → settings and features." Before this the
// tabs without a box of their own showed a DEAD bar ([_shellSearchJump]) that
// could not be typed into: tapping it left the tab and reopened the box on
// Home. A bar that answers a different question on every tab is not five bars
// — it is one bar and a backend row that says what the tab's question is.
//
// The scope and the placeholder are `shell_style().search.tabs.<key>`, so
// adding a tab or rewording a placeholder is an UPDATE, never a deploy. This
// file decides nothing about what the words are; it decides only WHERE the
// query goes, and that is a switch on the backend's own `scope` string.
//
// It is a `part` for the shell's usual reason: every widget it touches is
// library-private, and it gives the concern its own leasable path.

/// `shell_style()`, fetched once per session and shared by every consumer.
/// A shell-wide payload, so a tab switch never re-asks for it.
Future<Map<String, dynamic>>? _shellStyleFuture;

Future<Map<String, dynamic>> shellStyleLoad() => _shellStyleFuture ??=
    Supabase.instance.client.rpc('shell_style').then((v) {
      final m = v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
      final band = (m['band'] as Map?) ?? const {};
      if (band['every_tab'] is bool) {
        shellHeaderBandEveryTab.value = band['every_tab'] as bool;
      }
      // CMD #2187 — one thing animates at a time, and the BACKEND says which.
      // `motion.one_at_a_time` and `search.placeholder_rotate_when` are handed
      // to the gate the pill and the placeholder both read; flipping either
      // key is an UPDATE, never a deploy.
      shellMotionPublish(
        Map<String, dynamic>.from((m['motion'] as Map?) ?? const {}),
        Map<String, dynamic>.from((m['search'] as Map?) ?? const {}),
      );
      RenderLog.write('c2175_shell_style', m.isEmpty ? 0 : 1);
      return m;
    }).catchError((_) => <String, dynamic>{});

/// The shell page → the backend's own tab key. The NUMBERS are Flutter's
/// ([ShellPage] and the shell's own page list); the key is what the backend
/// rows are addressed by, so the backend never learns an index.
String shellTabKey(int index) {
  switch (index) {
    case 0:
      return 'home';
    case 1:
      return 'orders';
    case 2:
      return 'bulk';
    case 12:
      return 'catalogue';
    case 15:
      return 'profile';
    default:
      return 'home';
  }
}

/// One controller per scope, so leaving Orders and coming back finds the
/// words still in the box — the same promise the storefront's box keeps.
final Map<String, TextEditingController> _shellScopeCtrl =
    <String, TextEditingController>{};

TextEditingController _shellScopeController(String scope) =>
    _shellScopeCtrl[scope] ??= TextEditingController();

/// THE search row of the customer shell, for any tab.
///
/// Home keeps [_shellSearchHeader] — the full storefront chrome (filter chips,
/// the idle rail, the result count), which is a search SURFACE and not just a
/// box. The Catalogue keeps its own copy of that same chrome inside its page,
/// pinned above its grid exactly as this row is. Every other tab gets this
/// bar, wired to the scope the backend named for it.
Widget _shellTabSearch(_HomeShellState s, bool isAdmin) {
  if (isAdmin) {
    return s._index == 0 ? _shellSearchHeader(s) : const SizedBox.shrink();
  }
  if (s._index == 0) return _shellSearchHeader(s, sticky: true);
  // The Catalogue's own SearchChrome is this row on that tab: same widget,
  // same geometry, already outside its scroll view. Two boxes would be two
  // answers to one question.
  if (s._index == ShellPage.catalogue) return const SizedBox.shrink();
  return _ShellTabSearchBar(state: s, tabKey: shellTabKey(s._index));
}

class _ShellTabSearchBar extends StatefulWidget {
  const _ShellTabSearchBar({required this.state, required this.tabKey});
  final _HomeShellState state;
  final String tabKey;

  @override
  State<_ShellTabSearchBar> createState() => _ShellTabSearchBarState();
}

class _ShellTabSearchBarState extends State<_ShellTabSearchBar> {
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _push(String scope, String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      shellScopeQuery(scope).value = q.trim();
      RenderLog.write('c2175_tab_search', scope);
    });
  }

  /// A `catalog` scope has no list on this tab to narrow, so the query is the
  /// storefront's: the shopper lands on Home with it already run. Om's rule —
  /// "Home, Catalogue, Bulk → products + companies" — is one search, reached
  /// from three places.
  void _catalog(String q) {
    final t = q.trim();
    if (t.isEmpty) return;
    final s = widget.state;
    s._setIndex(0);
    s._searchCtrl.text = t;
    s._handleSearchSubmit(t);
    RenderLog.write('c2175_tab_search', 'catalog');
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: shellStyleLoad(),
      builder: (context, snap) {
        final tabs = (snap.data?['search'] as Map?)?['tabs'] as Map?;
        final row = (tabs?[widget.tabKey] as Map?) ?? const {};
        final scope = (row['scope'] ?? 'catalog').toString();
        final placeholder = (row['placeholder'] ?? '').toString();
        final ctrl = _shellScopeController(scope);
        return Semantics(
          identifier: 'c2175_tab_search',
          child: SearchHeaderBar(
            controller: ctrl,
            focusNode: _focus,
            placeholder: placeholder,
            banded: true,
            leading: _StickyLead(
                state: widget.state,
                focus: _focus,
                onBack: () {
                  ctrl.clear();
                  if (scope != 'catalog') shellScopeQuery(scope).value = '';
                }),
            onChanged: (q) {
              if (scope == 'catalog') return;
              _push(scope, q);
            },
            onSubmit: (q) {
              if (scope == 'catalog') {
                _catalog(q);
                return;
              }
              _debounce?.cancel();
              shellScopeQuery(scope).value = q.trim();
            },
            onClear: () {
              ctrl.clear();
              if (scope != 'catalog') shellScopeQuery(scope).value = '';
            },
          ),
        );
      },
    );
  }
}
