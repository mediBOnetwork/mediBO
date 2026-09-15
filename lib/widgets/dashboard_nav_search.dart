// CMD #1892 — the Dashboard's search field.
//
// The spec puts ONE search control on the admin home, directly under today's
// KPI cards, and names the RPC behind it: `nav_search(q)`. This is that field.
// It is inline rather than a sheet — you type where you are looking — and it
// owns nothing but the debounce and the layout: every group heading, every
// title, every subtitle and the empty line come down in the payload.
//
// The two doors #813 and #325 opened stay open: the entity search sheet and
// the command palette are the field's trailing icons, so nothing that was
// reachable before this change stopped being reachable.
//
// No Supabase import: the RPC is injected, so the widget pumps on the Dart VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/admin/nav_registry_view.dart';
import '../utils/render_log.dart';

/// `nav_search(q)`.
typedef DashboardSearchRpc = Future<Map<String, dynamic>> Function(String query);

/// A result was chosen — the backend's own map, handed back untouched.
typedef DashboardSearchPick = void Function(Map<String, dynamic> item);

class DashboardNavSearchField extends StatefulWidget {
  const DashboardNavSearchField({
    super.key,
    required this.search,
    required this.onPick,
    required this.hint,
    this.entityLabel = '',
    this.onEntitySearch,
    this.paletteLabel = '',
    this.onPalette,
  });

  final DashboardSearchRpc search;
  final DashboardSearchPick onPick;

  /// The placeholder — the backend's copy, never a Dart literal.
  final String hint;

  /// #813's entity-search sheet, kept as a trailing door.
  final String entityLabel;
  final VoidCallback? onEntitySearch;

  /// #325's command palette, kept as a trailing door.
  final String paletteLabel;
  final VoidCallback? onPalette;

  @override
  State<DashboardNavSearchField> createState() =>
      _DashboardNavSearchFieldState();
}

class _DashboardNavSearchFieldState extends State<DashboardNavSearchField> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;

  List<Map<String, dynamic>> _groups = const [];
  String _emptyLabel = '';
  bool _loading = false;
  bool _asked = false;

  /// An older, slower reply must never overwrite a newer one.
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    if (q.trim().isEmpty) {
      _seq++;
      setState(() {
        _groups = const [];
        _emptyLabel = '';
        _asked = false;
        _loading = false;
      });
      return;
    }
    // Repaint now so the clear button appears with the first character, not
    // when the reply lands 250ms later.
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 250), () => _run(q));
  }

  Future<void> _run(String q) async {
    final mine = ++_seq;
    setState(() => _loading = true);
    try {
      final reply = await widget.search(q);
      if (!mounted || mine != _seq) return;
      final groups = (reply['groups'] as List?)
              ?.whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList() ??
          const <Map<String, dynamic>>[];
      setState(() {
        _groups = groups;
        // `hint` is what the backend says when the query is too short; the
        // widget never decides which of the two lines applies.
        _emptyLabel = (reply['empty_label'] ?? reply['hint'] ?? '').toString();
        _asked = true;
        _loading = false;
      });
      RenderLog.write('c1892_search_groups', groups.length);
    } catch (_) {
      if (!mounted || mine != _seq) return;
      setState(() => _loading = false);
    }
  }

  void _clear() {
    _ctrl.clear();
    _onChanged('');
  }

  void _pick(Map<String, dynamic> item) {
    _clear();
    widget.onPick(item);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c325_palette_button', 1);
    return Column(
      key: const Key('c1892_search'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(
            child: TextField(
              key: const Key('c1892_search_field'),
              controller: _ctrl,
              onChanged: _onChanged,
              textInputAction: TextInputAction.search,
              style: Ds.t.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hint,
                hintStyle: Ds.t.bodySecondary,
                filled: true,
                fillColor: Ds.c.bg,
                contentPadding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x16, vertical: Ds.space.x12),
                prefixIcon:
                    Icon(Icons.search, size: Ds.space.x24, color: Ds.c.textSecondary),
                suffixIcon: _loading
                    ? Padding(
                        padding: EdgeInsets.all(Ds.space.x12),
                        child: SizedBox(
                          width: Ds.space.x16,
                          height: Ds.space.x16,
                          child: const CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_ctrl.text.isEmpty
                        ? null
                        : IconButton(
                            key: const Key('c1892_search_clear'),
                            onPressed: _clear,
                            iconSize: Ds.space.x24,
                            icon: Icon(Icons.close, color: Ds.c.textSecondary),
                          )),
                border: OutlineInputBorder(
                  borderRadius: Ds.r.rButton,
                  borderSide: BorderSide(color: Ds.c.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: Ds.r.rButton,
                  borderSide: BorderSide(color: Ds.c.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: Ds.r.rButton,
                  borderSide: BorderSide(color: Ds.c.brand),
                ),
              ),
            ),
          ),
          if (widget.onEntitySearch != null) ...[
            SizedBox(width: Ds.space.x8),
            Tooltip(
              message: widget.entityLabel,
              child: IconButton(
                key: const Key('c812_search_button'),
                onPressed: widget.onEntitySearch,
                iconSize: Ds.space.x24,
                constraints: BoxConstraints(
                    minWidth: Ds.space.x48, minHeight: Ds.space.x48),
                icon: Icon(Icons.manage_search, color: Ds.c.textSecondary),
              ),
            ),
          ],
          if (widget.onPalette != null) ...[
            SizedBox(width: Ds.space.x8),
            Tooltip(
              message: widget.paletteLabel,
              child: IconButton(
                key: const Key('c813_palette_button'),
                onPressed: widget.onPalette,
                iconSize: Ds.space.x24,
                constraints: BoxConstraints(
                    minWidth: Ds.space.x48, minHeight: Ds.space.x48),
                icon: Icon(Icons.bolt_outlined, color: Ds.c.textSecondary),
              ),
            ),
          ],
        ]),
        if (_asked) ...[
          SizedBox(height: Ds.space.x8),
          _Results(groups: _groups, emptyLabel: _emptyLabel, onPick: _pick),
        ],
      ],
    );
  }
}

/// The results card. Groups in payload order, rows in payload order.
class _Results extends StatelessWidget {
  const _Results({
    required this.groups,
    required this.emptyLabel,
    required this.onPick,
  });

  final List<Map<String, dynamic>> groups;
  final String emptyLabel;
  final DashboardSearchPick onPick;

  @override
  Widget build(BuildContext context) {
    if (groups.isEmpty && emptyLabel.isEmpty) return const SizedBox.shrink();
    return Container(
      key: const Key('c1892_search_results'),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: groups.isEmpty
          ? Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Text(emptyLabel, style: Ds.t.bodySecondary),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final g in groups) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8,
                        Ds.space.x16, Ds.space.x4),
                    child: Text(
                      (g['label'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(
                        fontWeight: FontWeight.w600,
                        color: Ds.c.textSecondary,
                        letterSpacing: 1.0,
                      ),
                    ),
                  ),
                  for (final raw in (g['items'] as List? ?? const []))
                    if (raw is Map)
                      _ResultRow(
                          item: Map<String, dynamic>.from(raw), onPick: onPick),
                ],
              ],
            ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.item, required this.onPick});

  final Map<String, dynamic> item;
  final DashboardSearchPick onPick;

  @override
  Widget build(BuildContext context) {
    final subtitle = (item['subtitle'] ?? '').toString().trim();
    return InkWell(
      onTap: () => onPick(item),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.space.x48),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        child: Row(children: [
          // The same glyph rule the tiles use: a key that does not resolve
          // draws the row's own initial, never a blank.
          NavGlyph(
              row: item,
              box: Ds.space.x24,
              glyph: Ds.space.x24,
              color: Ds.c.textSecondary),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text((item['title'] ?? '').toString(),
                    style: Ds.t.body,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
                if (subtitle.isNotEmpty)
                  Text(subtitle,
                      style: Ds.t.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          Icon(Icons.north_east, size: Ds.space.x16, color: Ds.c.textSecondary),
        ]),
      ),
    );
  }
}
