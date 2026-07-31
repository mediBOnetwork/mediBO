import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../utils/render_log.dart';
import '../widgets/policy_page_layout.dart';

/// CHANGE #611 — About is a pure renderer for `about_screen()`.
///
/// There is not one user-facing string in this file. Every title, paragraph,
/// row label, row value, bullet, badge, zone name and document label arrives
/// in the payload. Section order arrives as `payload['sections']` — jsonb key
/// order is not display order, so the backend states the order explicitly.
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
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: CircularProgressIndicator(color: Brand.green, strokeWidth: 3),
        ),
      );
    }
    if (_failed || _data == null) {
      // No payload means no copy to show — an icon-only retry keeps this page
      // free of client-side strings even on the failure path.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 28, color: Brand.green),
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
      if (children.isNotEmpty) children.add(const SizedBox(height: 28));
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
    return Text(body,
        style: const TextStyle(fontSize: 15, height: 1.65, color: Brand.ink));
  }

  Widget? _titledParagraph(Map<String, dynamic> m) {
    final title = _s(m, 'title');
    final body = _s(m, 'body');
    if (title.isEmpty && body.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty) ...[_heading(title), const SizedBox(height: 10)],
        if (body.isNotEmpty)
          Text(body,
              style:
                  const TextStyle(fontSize: 15, height: 1.65, color: Brand.ink)),
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
        if (title.isNotEmpty) ...[_heading(title), const SizedBox(height: 10)],
        if (note.isNotEmpty) ...[
          Text(note,
              style: const TextStyle(
                  fontSize: 14, height: 1.6, color: Brand.inkMuted)),
          const SizedBox(height: 12),
        ],
        if (rows.isNotEmpty) _InfoCard(rows: rows),
        if (docs.isNotEmpty) ...[
          const SizedBox(height: 12),
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
        if (title.isNotEmpty) ...[_heading(title), const SizedBox(height: 10)],
        ...points.map((p) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 7, right: 10),
                    child: Icon(Icons.circle, size: 6, color: Brand.green),
                  ),
                  Expanded(
                    child: Text(p,
                        style: const TextStyle(
                            fontSize: 14, height: 1.6, color: Brand.ink)),
                  ),
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
        if (title.isNotEmpty) ...[_heading(title), const SizedBox(height: 10)],
        if (note.isNotEmpty) ...[
          Text(note,
              style: const TextStyle(
                  fontSize: 14, height: 1.6, color: Brand.inkMuted)),
          const SizedBox(height: 14),
        ],
        // CHANGE #621 — the serving line is composed by the backend (it
        // pluralises itself); rendered verbatim, never counted in Dart.
        if (servingLine.isNotEmpty) ...[
          Text(servingLine,
              style: const TextStyle(
                  fontSize: 14, height: 1.6, color: Brand.inkMuted)),
          const SizedBox(height: 12),
        ],
        // CHANGE #621 — horizontally scrollable zone chips, one per list entry.
        // Labels are each item's zone_label; no zone name is written here.
        SizedBox(
          height: 38,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.zero,
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) => _zoneChip(i, list[i], sel),
          ),
        ),
        const SizedBox(height: 16),
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
      borderRadius: BorderRadius.circular(20),
      child: Container(
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: on ? Brand.green : Colors.transparent,
          border: Border.all(color: on ? Brand.green : Brand.border),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: on ? Colors.white : Brand.ink)),
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
            Text(name,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Brand.ink)),
          if (badge.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: Brand.green.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(badge,
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Brand.green)),
            ),
          ],
          if (rows.isNotEmpty) ...[
            const SizedBox(height: 12),
            _InfoCard(rows: rows),
          ],
          if (docs.isNotEmpty) ...[
            const SizedBox(height: 10),
            _DocList(docs: docs),
          ],
      ],
    );
  }

  static Widget _heading(String text) => Text(text,
      style: const TextStyle(
          fontSize: 18, fontWeight: FontWeight.w800, color: Brand.ink));
}

// ─── Info card — label/value rows straight from the payload ───────────────────

class _InfoCard extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  const _InfoCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Brand.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: List.generate(rows.length, (i) {
          final last = i == rows.length - 1;
          final label = rows[i]['label'];
          final value = rows[i]['value'];
          return Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 130,
                      child: Text(label is String ? label : '',
                          style: const TextStyle(
                              fontSize: 13, color: Brand.inkMuted)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(value is String ? value : '',
                          style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Brand.ink)),
                    ),
                  ],
                ),
              ),
              if (!last) const Divider(height: 1, indent: 16, endIndent: 16),
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
          padding: const EdgeInsets.only(bottom: 10),
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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: Brand.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Brand.ink)),
            ),
            const Icon(Icons.open_in_new, size: 16, color: Brand.green),
          ],
        ),
      ),
    );
  }
}
