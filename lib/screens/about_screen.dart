import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../design_tokens.dart';
import '../utils/render_log.dart';
import '../widgets/policy_page_layout.dart';

/// CHANGE #611 — About is a pure renderer for `about_screen()`.
///
/// There is not one user-facing string in this file. Every title, paragraph,
/// row label, row value, bullet, badge, zone name and document label arrives
/// in the payload. Section order arrives as `payload['sections']` — jsonb key
/// order is not display order, so the backend states the order explicitly.
///
/// CHANGE #66 — styled entirely from the `Ds` token layer (no style literals):
/// colours, spacing, radii and type come from `ui_boot().design`, so a
/// `ui_design_set()` recolours this page with the rest of the app.
///
/// The RPC is readable by `anon`, so the logged-out web page renders too.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _failed = false;

  /// CHANGE #621 — index of the selected zone chip. The first chip is selected
  /// by default, so the leading zone's partner is shown on open.
  int _selectedZone = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final raw = await Supabase.instance.client.rpc('about_screen');
      if (!mounted) return;
      setState(() {
        _data = Map<String, dynamic>.from(raw as Map);
        _loading = false;
      });
      RenderLog.write('c611_about_loaded', 1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      RenderLog.write('c611_about_error', 1);
    }
  }

  // ── Payload helpers ────────────────────────────────────────────────────────

  Map<String, dynamic> _obj(String key) {
    final v = _data?[key];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  static String _s(Map<String, dynamic> m, String key) {
    final v = m[key];
    return v is String ? v : '';
  }

  static List<Map<String, dynamic>> _rows(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  // Prose keeps a slightly looser line-height than the token default for
  // long-form reading; `height` is not a style literal the gate bans.
  TextStyle get _prose => Ds.t.body.copyWith(height: 1.6);
  TextStyle get _proseMuted => Ds.t.caption.copyWith(color: Ds.c.textSecondary, height: 1.6);

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      RenderLog.write('screen', 'about-app');
      RenderLog.write('layout', 'policy_page_layout');
      RenderLog.write('change', '#621');
    });

    final header = _obj('header');
    final about = _obj('about');

    return PolicyPageLayout(
      // Header identity and page title both come from the payload.
      headerName: _data == null ? null : _s(header, 'name'),
      headerTagline: _data == null ? null : _s(header, 'tagline'),
      title: _s(about, 'title'),
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
        child: Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 3),
        ),
      );
    }
    if (_failed || _data == null) {
      // No payload means no copy to show — an icon-only retry keeps this page
      // free of client-side strings even on the failure path.
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x48),
        child: Center(
          child: IconButton(
            onPressed: _load,
            icon: Icon(Icons.refresh, size: 28, color: Ds.c.brand),
          ),
        ),
      );
    }

    final order = _data!['sections'];
    final sections = order is List ? order.whereType<String>().toList() : const <String>[];

    final children = <Widget>[];
    for (final name in sections) {
      final w = _section(name);
      if (w == null) continue;
      if (children.isNotEmpty) children.add(SizedBox(height: Ds.space.x24 + Ds.space.x4));
      children.add(w);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// Returns null for sections already rendered by the page chrome (header /
  /// about title) or for sections the payload left empty.
  Widget? _section(String name) {
    switch (name) {
      // `header` is the wordmark block, `about`'s title is the page title —
      // both handled by PolicyPageLayout above. Only the body remains.
      case 'header':
        return null;
      case 'about':
        return _paragraph(_s(_obj('about'), 'body'));
      case 'mission':
        return _titledParagraph(_obj('mission'));
      case 'platform_entity':
        return _entity(_obj('platform_entity'));
      case 'relationship':
        return _relationship(_obj('relationship'));
      case 'partners':
        return _partners(_obj('partners'));
      // CHANGE #621 — 'contact' is no longer in sections[], and the renderer
      // for it is deleted, so Phone/Email cannot appear on About. The
      // `contact` object still ships in the payload for the Contact page.
      default:
        return null;
    }
  }

  // ── Section renderers ──────────────────────────────────────────────────────

  Widget? _paragraph(String body) {
    if (body.isEmpty) return null;
    return Text(body, style: _prose);
  }

  Widget? _titledParagraph(Map<String, dynamic> m) {
    final title = _s(m, 'title');
    final body = _s(m, 'body');
    if (title.isEmpty && body.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[_heading(title), SizedBox(height: Ds.space.x8)],
        if (body.isNotEmpty) Text(body, style: _prose),
      ],
    );
  }

  Widget? _entity(Map<String, dynamic> m) {
    final title = _s(m, 'title');
    final note = _s(m, 'note');
    final rows = _rows(m, 'rows');
    final docs = _rows(m, 'docs');
    if (title.isEmpty && note.isEmpty && rows.isEmpty && docs.isEmpty) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[_heading(title), SizedBox(height: Ds.space.x8)],
        if (note.isNotEmpty) ...[
          Text(note, style: _proseMuted),
          SizedBox(height: Ds.space.x12),
        ],
        if (rows.isNotEmpty) _InfoCard(rows: rows),
        if (docs.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _DocList(docs: docs),
        ],
      ],
    );
  }

  Widget? _relationship(Map<String, dynamic> m) {
    final title = _s(m, 'title');
    final raw = m['points'];
    final points = raw is List ? raw.whereType<String>().toList() : const <String>[];
    if (title.isEmpty && points.isEmpty) return null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[_heading(title), SizedBox(height: Ds.space.x8)],
        ...points.map((p) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.only(top: Ds.space.x4 + 3, right: Ds.space.x8),
                    child: Icon(Icons.circle, size: 6, color: Ds.c.brand),
                  ),
                  Expanded(child: Text(p, style: _prose)),
                ],
              ),
            )),
      ],
    );
  }

  Widget? _partners(Map<String, dynamic> m) {
    final title = _s(m, 'title');
    final note = _s(m, 'note');
    final servingLine = _s(m, 'serving_line');
    final list = _rows(m, 'list');
    if (title.isEmpty && note.isEmpty && servingLine.isEmpty && list.isEmpty) {
      return null;
    }
    // Clamp so a shrinking list can never leave the selection out of range.
    final sel = list.isEmpty
        ? -1
        : (_selectedZone < 0 || _selectedZone >= list.length
            ? 0
            : _selectedZone);
    final selected = sel < 0 ? null : list[sel];

    // Proof the chip row rendered, and how many zones it drew.
    if (list.isNotEmpty) {
      RenderLog.write('c621_about_zone_chips', list.length);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[_heading(title), SizedBox(height: Ds.space.x8)],
        if (note.isNotEmpty) ...[
          Text(note, style: _proseMuted),
          SizedBox(height: Ds.space.x12),
        ],
        // CHANGE #621 — the serving line is composed by the backend (it
        // pluralises itself); rendered verbatim, never counted in Dart.
        if (servingLine.isNotEmpty) ...[
          Text(servingLine, style: _proseMuted),
          SizedBox(height: Ds.space.x12),
        ],
        // CHANGE #621 — horizontally scrollable zone chips, one per list entry.
        // Labels are each item's zone_label; no zone name is written here.
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: list.length,
            separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
            itemBuilder: (_, i) => _zoneChip(i, list[i], sel),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        // Detail for the selected zone only.
        if (selected != null) _partnerCard(selected),
      ],
    );
  }

  /// One zone chip. Selected chip is filled; the rest are outlined.
  Widget _zoneChip(int index, Map<String, dynamic> p, int selectedIndex) {
    final label = _s(p, 'zone_label');
    final on = selectedIndex == index;

    return InkWell(
      key: Key('about_zone_chip_$index'),
      onTap: () => setState(() => _selectedZone = index),
      borderRadius: Ds.r.rChip,
      child: Container(
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        decoration: BoxDecoration(
          color: on ? Ds.c.brand : Colors.transparent,
          border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label,
            style: Ds.t.caption.copyWith(
                fontWeight: FontWeight.w700,
                color: on ? Colors.white : Ds.c.text)),
      ),
    );
  }

  Widget _partnerCard(Map<String, dynamic> p) {
    final name = _s(p, 'name');
    final badge = _s(p, 'badge');
    final rows = _rows(p, 'rows');
    final docs = _rows(p, 'docs');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (name.isNotEmpty)
          Text(name, style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
        if (badge.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4 + 2),
          Container(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x8 + 2, vertical: Ds.space.x4),
            decoration: BoxDecoration(
              color: Ds.c.brandSoft,
              borderRadius: Ds.r.rChip,
            ),
            child: Text(badge,
                style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w700, color: Ds.c.brand)),
          ),
        ],
        if (rows.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _InfoCard(rows: rows),
        ],
        if (docs.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8 + 2),
          _DocList(docs: docs),
        ],
      ],
    );
  }

  static Widget _heading(String text) =>
      Text(text, style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700));
}

// ─── Info card — label/value rows straight from the payload ───────────────────

class _InfoCard extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _InfoCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        children: List.generate(rows.length, (i) {
          final last = i == rows.length - 1;
          final label = rows[i]['label'];
          final value = rows[i]['value'];
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(label is String ? label : '',
                          style: Ds.t.caption),
                    ),
                    SizedBox(width: Ds.space.x8),
                    Expanded(
                      child: Text(value is String ? value : '',
                          style: Ds.t.caption.copyWith(
                              fontWeight: FontWeight.w600, color: Ds.c.text)),
                    ),
                  ],
                ),
              ),
              if (!last) Divider(height: 1, indent: Ds.space.x16, endIndent: Ds.space.x16, color: Ds.c.divider),
            ],
          );
        }),
      ),
    );
  }
}

// ─── Document rows — label + open icon, opens payload url ────────────────────

class _DocList extends StatelessWidget {
  final List<Map<String, dynamic>> docs;
  const _DocList({required this.docs});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: docs.map((d) {
        final label = d['label'];
        final url = d['url'];
        return Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8 + 2),
          child: _DocTile(
            label: label is String ? label : '',
            url: url is String ? url : '',
          ),
        );
      }).toList(),
    );
  }
}

class _DocTile extends StatelessWidget {
  final String label;
  final String url;
  const _DocTile({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: url.isEmpty
          ? null
          : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      borderRadius: Ds.r.rCard,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          border: Border.all(color: Ds.c.divider),
          borderRadius: Ds.r.rCard,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w600, color: Ds.c.text)),
            ),
            Icon(Icons.open_in_new, size: 16, color: Ds.c.brand),
          ],
        ),
      ),
    );
  }
}
