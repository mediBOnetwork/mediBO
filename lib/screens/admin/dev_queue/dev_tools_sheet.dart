// CHANGE #349 — the Dev Queue's tools, labelled.
//
// What it replaces: nine `IconButton`s in the AppBar's `actions:` list. An
// AppBar action list is a Row — it does not wrap and it does not scroll — so on
// a phone the last tools ran straight past the right edge and were simply
// unreachable. The ones that did fit were bare glyphs with no label, and a
// tooltip is not an affordance on a touch screen. Om's report was exact:
// "mail/bug/map/clock/key/cloud/chip and more running past the right edge with
// no scroll affordance, unreachable and unlabelled."
//
// What it is instead: ONE entry point that opens ONE scrollable sheet, where
// every tool is a full-width row with a name, a one-line description and its
// own glyph, grouped under headings. Nothing can be off-screen, because the
// sheet scrolls and every row is the width of the sheet.
//
// The gate is doubled on purpose:
//   * `dev_tools()` decides what MAY appear — an unregistered tool is not in
//     the payload, so it cannot render. That is the registry gate the spec
//     asks for, and it is enforced in SQL, not here.
//   * [DevToolsSheet.available] decides what CAN open — a tool_key this build
//     has no screen for is dropped rather than drawn as a dead row.
// Neither half can smuggle a tool onto this surface alone.
//
// Every string below arrives in the payload. This file writes none.
import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/render_log.dart';
import '../nav_registry_view.dart';

/// `dev_tools()`. Injected so the sheet stays Supabase-free and pumps on the
/// Dart VM in a widget test, like every other protected surface here.
typedef DevToolsLoad = Future<Map<String, dynamic>> Function();

/// A tool row was tapped. The backend's own map is handed back untouched; the
/// caller reads `tool_key` / `feature_key` from it.
typedef DevToolPick = void Function(Map<String, dynamic> tool);

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Future<void> showDevToolsSheet(
  BuildContext context, {
  required DevToolsLoad load,
  required Set<String> available,
  required DevToolPick onOpen,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => DevToolsSheet(
      load: load,
      available: available,
      onOpen: (tool) {
        Navigator.of(context).pop();
        onOpen(tool);
      },
    ),
  );
}

class DevToolsSheet extends StatefulWidget {
  final DevToolsLoad load;

  /// The tool keys THIS build can actually open. A payload row whose
  /// `tool_key` is not in here is dropped — a labelled row that does nothing
  /// is worse than no row.
  final Set<String> available;
  final DevToolPick onOpen;

  const DevToolsSheet({
    super.key,
    required this.load,
    required this.available,
    required this.onOpen,
  });

  @override
  State<DevToolsSheet> createState() => _DevToolsSheetState();
}

class _DevToolsSheetState extends State<DevToolsSheet> {
  Map<String, dynamic>? _payload;
  bool _failed = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final p = await widget.load();
      if (!mounted) return;
      setState(() => _payload = p);
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  /// Groups, in payload order, holding only the tools this build can open and
  /// (when the admin has typed) only those the filter matches. A group left
  /// with nothing is dropped rather than drawn as an empty heading.
  List<Map<String, dynamic>> get _groups {
    final raw = (_payload?['groups'] as List?) ?? const [];
    final q = _filter.trim().toLowerCase();
    final out = <Map<String, dynamic>>[];
    for (final g in raw.whereType<Map>()) {
      final group = Map<String, dynamic>.from(g);
      final items = ((group['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((t) => widget.available.contains(_s(t, 'tool_key')))
          .where((t) =>
              q.isEmpty ||
              _s(t, 'label').toLowerCase().contains(q) ||
              _s(t, 'description').toLowerCase().contains(q) ||
              _s(group, 'label').toLowerCase().contains(q))
          .toList();
      if (items.isEmpty) continue;
      group['items'] = items;
      out.add(group);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final groups = _groups;
    final shown = groups.fold<int>(
        0, (a, g) => a + ((g['items'] as List?)?.length ?? 0));
    RenderLog.write('c349_dev_tools', shown);

    return SafeArea(
      child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x4),
              child: Text(_s(p ?? const {}, 'title'), style: Ds.t.title),
            ),
            if (_s(p ?? const {}, 'subtitle').isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                child:
                    Text(_s(p!, 'subtitle'), style: Ds.t.caption),
              ),
            SizedBox(height: Ds.space.x16),
            if (p != null && (p['groups'] as List?)?.isNotEmpty == true)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                child: TextField(
                  decoration: InputDecoration(
                    hintText: _s(p, 'search_hint'),
                    prefixIcon: Icon(Icons.search, size: Ds.space.x24),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ),
            SizedBox(height: Ds.space.x12),
            Flexible(child: _body(p, groups)),
            SizedBox(height: Ds.space.x8),
          ],
        ),
      ),
    );
  }

  Widget _body(Map<String, dynamic>? p, List<Map<String, dynamic>> groups) {
    if (_failed) return _Retry(onRetry: _load);
    if (p == null) return const _ToolsSkeleton();
    if (p['ok'] == false) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(_s(p, 'message'), style: Ds.t.body),
      );
    }
    if (groups.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(_s(p, 'empty_label'), style: Ds.t.caption),
      );
    }
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      children: [
        for (final g in groups) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
            child: Text(_s(g, 'label'), style: Ds.t.caption),
          ),
          for (final t in (g['items'] as List).cast<Map<String, dynamic>>())
            _ToolRow(tool: t, onOpen: widget.onOpen),
        ],
      ],
    );
  }
}

class _ToolRow extends StatelessWidget {
  final Map<String, dynamic> tool;
  final DevToolPick onOpen;

  const _ToolRow({required this.tool, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final description = _s(tool, 'description');
    final badge = _s(tool, 'badge_label');
    return Semantics(
      button: true,
      label: _s(tool, 'label'),
      child: InkWell(
        onTap: () => onOpen(tool),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x48 + Ds.space.x8),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          child: Row(children: [
            NavGlyph(
              row: tool,
              box: Ds.space.x32 + Ds.space.x8,
              glyph: Ds.space.x16 + Ds.space.x4,
              background: Ds.c.brandSoft,
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(tool, 'label'),
                      style: Ds.t.bodyStrong,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (description.isNotEmpty)
                    Text(description,
                        style: Ds.t.caption,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            if (badge.isNotEmpty) ...[
              SizedBox(width: Ds.space.x8),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: Ds.c.warningSoft,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(badge, style: Ds.t.caption),
              ),
            ],
            SizedBox(width: Ds.space.x8),
            Icon(Icons.chevron_right,
                size: Ds.space.x24, color: Ds.c.textSecondary),
          ]),
        ),
      ),
    );
  }
}

/// A skeleton, not a bare spinner — the sheet's shape is known before its
/// content is.
class _ToolsSkeleton extends StatelessWidget {
  const _ToolsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x8),
            child: Row(children: [
              Container(
                width: Ds.space.x32 + Ds.space.x8,
                height: Ds.space.x32 + Ds.space.x8,
                decoration: BoxDecoration(
                  color: Ds.c.divider,
                  borderRadius: BorderRadius.circular(Ds.r.button),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Container(
                  height: Ds.space.x16,
                  decoration: BoxDecoration(
                    color: Ds.c.divider,
                    borderRadius: BorderRadius.circular(Ds.r.button),
                  ),
                ),
              ),
            ]),
          ),
      ],
    );
  }
}

/// The load failed. The copy is the backend's (`ui_copy`), not a sentence
/// written here — an unknown key stays empty rather than inventing one.
class _Retry extends StatelessWidget {
  final VoidCallback onRetry;
  const _Retry({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(c('dev_tools.load_failed'), style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            height: Ds.space.x48,
            child: OutlinedButton(
                onPressed: onRetry, child: Text(c('dev_tools.retry'))),
          ),
        ],
      ),
    );
  }
}
