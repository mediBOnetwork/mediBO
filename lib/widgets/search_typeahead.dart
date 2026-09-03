import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';

/// CHANGE #790 — the catalogue typeahead.
///
/// The panel decides NOTHING. `search_suggest()` returns groups in the order
/// they should be drawn, each with its own title, and every item with its own
/// label, sub-label and count sentence. There is no grouping, no counting, no
/// pluralising and no "N variants" built here — a string this file invents is
/// a bug. The Hinglish line ("bukhar → Paracetamol") is the payload's
/// `expanded.label`, printed under the backend's own prefix.
///
/// Tapping an item hands back its `query`: the text the BACKEND wants searched
/// for that suggestion, which for a Hindi word is the salt and not the word.
class SearchSuggestions extends StatelessWidget {
  const SearchSuggestions({
    super.key,
    required this.payload,
    required this.onPick,
    this.maxHeight = 420,
  });

  /// A `search_suggest()` payload, rendered verbatim.
  final Map<String, dynamic> payload;

  /// Called with the backend's own `query` for the tapped suggestion.
  final ValueChanged<String> onPick;

  final double maxHeight;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> m, String k) =>
      ((m[k] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);

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
                  onTap: () => onPick(_s(it, 'query')),
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

  Timer? _timer;
  int _seq = 0;

  void close() {
    _timer?.cancel();
    if (!_open && _payload.isEmpty) return;
    _open = false;
    _payload = const {};
    notifyListeners();
  }

  void onQueryChanged(String q, {bool zoneOnly = true}) {
    _timer?.cancel();
    if (q.trim().isEmpty) {
      close();
      return;
    }
    _timer = Timer(debounce, () => _fetch(q, zoneOnly));
  }

  Future<void> _fetch(String q, bool zoneOnly) async {
    final mine = ++_seq;
    try {
      final res =
          await _rpc('search_suggest', {'p_q': q, 'p_zone': zoneOnly});
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
