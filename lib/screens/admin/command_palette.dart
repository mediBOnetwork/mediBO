// CHANGE #325 — the command palette. One search box that jumps to any screen,
// order, customer, supplier or medicine.
//
// The search itself is `nav_search(q)`: it ranks the registry's own labels and
// synonyms (typing "gst" finds the GST ledger because the registry says so,
// not because this file knows what GST is) alongside real records. Every group
// heading, every subtitle and the empty state come down in the payload; this
// widget owns nothing but the debounce and the layout.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'nav_registry_view.dart';

/// `nav_search(q)`. Injected so the sheet stays Supabase-free and pumps on the
/// Dart VM.
typedef NavSearchRpc = Future<Map<String, dynamic>> Function(String query);

/// A result was chosen. The backend's own map is handed back untouched — the
/// caller reads `route_key`, `deep_link`, `feature_key` and `seed` from it.
typedef NavSearchPick = void Function(Map<String, dynamic> item);

/// Opens the palette as a sheet. Returns when it closes.
Future<void> showCommandPalette(
  BuildContext context, {
  required NavSearchRpc search,
  required NavSearchPick onPick,
  required String hint,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => CommandPaletteSheet(
      search: search,
      onPick: onPick,
      hint: hint,
      title: title,
    ),
  );
}

class CommandPaletteSheet extends StatefulWidget {
  final NavSearchRpc search;
  final NavSearchPick onPick;
  final String hint;
  final String title;

  const CommandPaletteSheet({
    super.key,
    required this.search,
    required this.onPick,
    required this.hint,
    required this.title,
  });

  @override
  State<CommandPaletteSheet> createState() => _CommandPaletteSheetState();
}

class _CommandPaletteSheetState extends State<CommandPaletteSheet> {
  final TextEditingController _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  List<Map<String, dynamic>> _groups = const [];
  String _emptyLabel = '';
  bool _loading = false;

  /// Guards against an older, slower reply overwriting a newer one — the
  /// classic palette bug where typing fast leaves you looking at results for
  /// three characters ago.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
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
        _emptyLabel = (reply['empty_label'] ?? reply['hint'] ?? '').toString();
        _loading = false;
      });
      RenderLog.write('c325_palette_groups', groups.length);
    } catch (_) {
      if (!mounted || mine != _seq) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final maxH = MediaQuery.sizeOf(context).height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
              child: Text(widget.title, style: Ds.t.title),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                onChanged: _onChanged,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: widget.hint,
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _loading
                      ? Padding(
                          padding: EdgeInsets.all(Ds.space.x12),
                          child: const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : null,
                ),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Flexible(
              child: _groups.isEmpty
                  ? Padding(
                      padding: EdgeInsets.all(Ds.space.x24),
                      child: Text(_emptyLabel, style: Ds.t.caption),
                    )
                  : ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.only(bottom: Ds.space.x24),
                      children: [
                        for (final g in _groups) ...[
                          Padding(
                            padding: EdgeInsets.fromLTRB(Ds.space.x16,
                                Ds.space.x16, Ds.space.x16, Ds.space.x8),
                            child: Text((g['label'] ?? '').toString(),
                                style: Ds.t.caption),
                          ),
                          for (final raw in (g['items'] as List? ?? const []))
                            if (raw is Map)
                              _ResultRow(
                                item: Map<String, dynamic>.from(raw),
                                onPick: (item) {
                                  Navigator.of(context).pop();
                                  widget.onPick(item);
                                },
                              ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final Map<String, dynamic> item;
  final NavSearchPick onPick;

  const _ResultRow({required this.item, required this.onPick});

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
          // CHANGE #349 — the same glyph rule the dashboard uses: a key that
          // does not resolve draws the result's own initial, never a blank.
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
