import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// CHANGE #790 — the catalogue typeahead.
///
/// The panel decides NOTHING. `search_suggest()` returns groups in the order
/// they should be drawn, each with its own title, and every item with its own
/// label, sub-label and count sentence. There is no grouping, no counting, no
/// pluralising and no "N variants" built here — a string this file invents is
/// a bug. The Hinglish line ("bukhar → Paracetamol") is the payload's
/// `expanded.label`, printed under the backend's own prefix.
///
/// CMD #1905 — a suggestion is no longer a STRING. Every item carries its own
/// `kind`, `id` and `nav` block, and a tap hands the WHOLE item back: tapping
/// the company "SUN PHARMACEUTICAL INDUSTRIES LTD" used to paste that name
/// into a product-name search, which matched nothing and then offered to
/// *request* the product the shopper had just been shown 2,461 of. What opens
/// is now the backend's `nav`, never a re-run of the text.
class SearchSuggestions extends StatelessWidget {
  const SearchSuggestions({
    super.key,
    required this.payload,
    required this.onPick,
    this.maxHeight = 420,
  });

  /// A `search_suggest()` payload, rendered verbatim.
  final Map<String, dynamic> payload;

  /// Called with the tapped item — the whole map, so the caller reads the
  /// backend's `nav` rather than re-deciding what the row meant. A group's
  /// "See all" row hands back a synthetic item carrying that group's own
  /// `see_all.nav`, so both taps travel one path.
  final ValueChanged<SearchSuggestion> onPick;

  final double maxHeight;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
      ((m[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

  static Map<String, dynamic> _map(Map<String, dynamic> m, String k) =>
      Map<String, dynamic>.from((m[k] as Map?) ?? const <String, dynamic>{});

  static Iterable<Map<String, dynamic>> _items(Map<String, dynamic> g) =>
      _list(g, 'items');

  @override
  Widget build(BuildContext context) {
    // Not enough letters yet: the backend says so and supplies the sentence.
    if (payload['ready'] != true) {
      final hint = _s(payload, 'hint');
      if (hint.isEmpty) return const SizedBox.shrink();
      return _shell(
          child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(hint, style: Ds.t.caption),
      ));
    }

    final groups = _list(payload, 'groups');
    final expanded = Map<String, dynamic>.from(
        (payload['expanded'] as Map?) ?? const <String, dynamic>{});
    final zone = Map<String, dynamic>.from(
        (payload['zone'] as Map?) ?? const <String, dynamic>{});

    if (groups.isEmpty) {
      final empty = _s(payload, 'empty_label');
      if (empty.isEmpty) return const SizedBox.shrink();
      return _shell(
          child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(empty, style: Ds.t.caption),
      ));
    }

    // CMD #1905 — the render proof. A canvas app cannot be read by a browser
    // tool, so what the panel actually DREW is recorded here: how many rows
    // carry a nav block, and how many still fall back to a text search.
    RenderLog.write(
        'c1905_typed_suggestions',
        'groups=${groups.length};'
        'typed=${groups.expand(_items).where((i) => (i['nav'] as Map?)?.isNotEmpty == true).length};'
        'untyped=${groups.expand(_items).where((i) => (i['nav'] as Map?)?.isNotEmpty != true).length};'
        'see_all=${groups.where((g) => _map(g, 'see_all')['has'] == true).length}');

    return _shell(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
          children: [
            // What a Hindi/Hinglish word was taken to mean. Two backend
            // strings: the prefix and the mapping sentence.
            if (expanded['has'] == true &&
                _s(expanded, 'label').isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x8),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${_s(payload, 'expanded_prefix')} ${_s(expanded, 'label')}'
                            .trim(),
                        style: Ds.t.caption.copyWith(color: Ds.c.brand),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            for (final g in groups) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
                child: Text(_s(g, 'title'),
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              ),
              for (final it in _list(g, 'items'))
                InkWell(
                  onTap: () => onPick(SearchSuggestion.fromMap(it)),
                  child: Container(
                    constraints:
                        BoxConstraints(minHeight: Ds.touch.minTarget),
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x16, vertical: Ds.space.x8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(_s(it, 'label'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Ds.t.body),
                              if (_s(it, 'sub_label').isNotEmpty)
                                Text(_s(it, 'sub_label'),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Ds.t.caption),
                            ],
                          ),
                        ),
                        if (_s(it, 'count_label').isNotEmpty) ...[
                          SizedBox(width: Ds.space.x12),
                          Text(_s(it, 'count_label'), style: Ds.t.caption),
                        ],
                      ],
                    ),
                  ),
                ),
              // CMD #1905 — "See all" is the group's own row. It appears only
              // when the BACKEND says there is more than it sent (`has`), and
              // it opens the group's own list, never a text re-search.
              if (_map(g, 'see_all')['has'] == true &&
                  _s(_map(g, 'see_all'), 'label').isNotEmpty)
                InkWell(
                  onTap: () => onPick(SearchSuggestion.seeAll(g)),
                  child: Container(
                    constraints:
                        BoxConstraints(minHeight: Ds.touch.minTarget),
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x16, vertical: Ds.space.x8),
                    alignment: Alignment.centerLeft,
                    child: Text(_s(_map(g, 'see_all'), 'label'),
                        style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                  ),
                ),
            ],
            // "Suggestions from what your zone can send" — present only when
            // the backend sent it.
            if (_s(zone, 'note').isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x12,
                    Ds.space.x16, Ds.space.x4),
                child: Text(_s(zone, 'note'), style: Ds.t.caption),
              ),
          ],
        ),
      ),
    );
  }

  Widget _shell({required Widget child}) => Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e2,
          ),
          child: child,
        ),
      );
}

/// CMD #1905 — one tapped suggestion, exactly as the backend described it.
///
/// This class holds NO opinion about what a suggestion means. `navKind` and
/// `navId` are read straight out of the payload's `nav` block, `chipLabel` is
/// the sentence the search box prints instead of the raw text, and `query` is
/// kept only so a payload from before this change still opens something.
class SearchSuggestion {
  /// 'product' | 'company' | 'salt' | 'category' — the backend's word for the
  /// row, used for nothing but reporting; routing reads [navKind].
  final String kind;

  /// Where this opens: 'product' | 'company' | 'salt' | 'category' |
  /// 'search' | 'tab'.
  final String navKind;

  /// The id that surface is opened with — a product id, a company key, a salt
  /// key, a class key, or the words a 'search'/'tab' nav searches for.
  final String navId;

  /// For navKind 'tab': which catalogue tab, and what to filter it by.
  final String navTab;
  final String navQuery;

  /// "Company: Sun Pharmaceutical Industries Ltd" — the backend's own chip
  /// sentence for the search box. Never assembled here.
  final String chipLabel;

  final String label;

  /// The old string contract. Kept ONLY as the fallback for a payload that
  /// predates `nav`; a tap never prefers it.
  final String query;

  const SearchSuggestion({
    required this.kind,
    required this.navKind,
    required this.navId,
    required this.navTab,
    required this.navQuery,
    required this.chipLabel,
    required this.label,
    required this.query,
  });

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  factory SearchSuggestion.fromMap(Map<String, dynamic> m) {
    final nav = Map<String, dynamic>.from((m['nav'] as Map?) ?? const {});
    final query = _s(m, 'query');
    return SearchSuggestion(
      kind: _s(m, 'kind'),
      // A payload with no `nav` is one from before this change. It only ever
      // knew how to search for text, so that is what it still does — the app
      // does not invent a route the backend did not name.
      navKind: nav.isEmpty ? 'search' : _s(nav, 'kind'),
      navId: nav.isEmpty ? query : _s(nav, 'id'),
      navTab: _s(nav, 'tab'),
      navQuery: _s(nav, 'query'),
      chipLabel: _s(m, 'chip_label'),
      label: _s(m, 'label'),
      query: query,
    );
  }

  /// The "See all" row of a group, as the same kind of value a real item is.
  factory SearchSuggestion.seeAll(Map<String, dynamic> group) {
    final see = Map<String, dynamic>.from((group['see_all'] as Map?) ?? const {});
    final nav = Map<String, dynamic>.from((see['nav'] as Map?) ?? const {});
    return SearchSuggestion(
      kind: _s(group, 'kind'),
      navKind: _s(nav, 'kind'),
      navId: _s(nav, 'id'),
      navTab: _s(nav, 'tab'),
      navQuery: _s(nav, 'query'),
      // A "See all" is a scope, not one named thing: the box keeps whatever
      // the shopper typed rather than claiming a chip the backend did not send.
      chipLabel: '',
      label: _s(see, 'label'),
      query: _s(nav, 'id'),
    );
  }
}

/// CMD #1905 — what the search box is currently showing instead of raw text.
///
/// A chip is the backend's own `chip_label` plus the nav it came from, so the
/// box can print "Company: Sun Pharmaceutical Industries Ltd ×" and the ×
/// can put the shopper back where they were. An empty [label] means there is
/// no chip and the field shows its text as usual.
class SearchChip {
  final String label;
  final String clearLabel;
  const SearchChip({required this.label, required this.clearLabel});

  static const SearchChip none = SearchChip(label: '', clearLabel: '');

  bool get has => label.isNotEmpty;
}

/// CMD #1905 — the chip the search box shows once a suggestion was tapped.
///
/// It sits where the raw text used to, because the raw text was a lie: the box
/// said "SUN PHARMACEUTICAL INDUSTRIES LTD" while the screen below was a
/// company page, not a search for that phrase. Both strings are the payload's
/// — `chip_label` on the item and `clear_label` on the payload — so this
/// widget only lays them out.
class SearchBoxChip extends StatelessWidget {
  const SearchBoxChip({super.key, required this.chip, required this.onClear});

  final SearchChip chip;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
          child: Material(
            color: Ds.c.brandSoft,
            borderRadius: Ds.r.rChip,
            child: InkWell(
              onTap: onClear,
              borderRadius: Ds.r.rChip,
              child: Container(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(chip.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                    ),
                    SizedBox(width: Ds.space.x8),
                    Tooltip(
                      message: chip.clearLabel,
                      child: Icon(Icons.close, color: Ds.c.brand),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}

/// Fetches suggestions as the shopper types, and holds the last payload.
///
/// Debounce and the minimum length are the only client-side behaviours here,
/// and even the minimum is only used to avoid a pointless round trip — the
/// BACKEND decides what "not enough letters" means and supplies the sentence
/// for it, which is why a short query still renders the payload it returns.
class SearchSuggestController extends ChangeNotifier {
  SearchSuggestController({this.debounce = const Duration(milliseconds: 180)});

  final Duration debounce;

  /// Injected in tests so the widget pumps on the Dart VM with no Supabase.
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  Map<String, dynamic> _payload = const {};
  Map<String, dynamic> get payload => _payload;

  bool _open = false;
  bool get isOpen => _open && _payload.isNotEmpty;

  /// The backend's word for the × on the chip, carried on every payload.
  String get clearLabel => (_payload['clear_label'] ?? '').toString();

  Timer? _timer;
  int _seq = 0;

  void close() {
    _timer?.cancel();
    if (!_open && _payload.isEmpty) return;
    _open = false;
    _payload = const {};
    notifyListeners();
  }

  void onQueryChanged(String q) {
    _timer?.cancel();
    if (q.trim().isEmpty) {
      close();
      return;
    }
    _timer = Timer(debounce, () => _fetch(q));
  }

  Future<void> _fetch(String q) async {
    final mine = ++_seq;
    try {
      // CMD #1909 — `p_zone` is gone with the switch it belonged to. Suggestions
      // cover the whole catalogue, the same as the list they open.
      final res = await _rpc('search_suggest', {'p_q': q});
      if (mine != _seq) return; // a later keystroke already won
      _payload = res is Map ? Map<String, dynamic>.from(res) : const {};
      _open = true;
      notifyListeners();
    } catch (_) {
      if (mine != _seq) return;
      // An outage closes the panel rather than inventing an error line: the
      // shopper can still press search, which is the full-catalogue path.
      _payload = const {};
      _open = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
