// CHANGE #536 — MY SHOP, the pharmacy account's own home for the suite.
//
// Every one of these features was registered onto the ADMIN dashboard, where
// the screen behind the tile resolves the caller's OWN pharmacy and so answers
// an admin with "... is available on a pharmacy account". The shop that owns
// the data reached the counter through one row in the account dropdown and
// everything else by chaining app-bar buttons off it. This tab is where they
// live now.
//
// It decides nothing. `customer_shop_home()` sends the sections, their order,
// their labels, every tile's label and caption, its icon key and the route it
// opens; this file walks that payload in the order it arrived. A new tile
// tomorrow is one INSERT into feature_registry — there is no list in this file
// to add it to, and no `switch` on a feature key anywhere below.
//
// Sections after the first arrive collapsed on purpose: a pharmacy that only
// ever places orders opens this tab, sees Billing and four folded headers, and
// is not handed nineteen tiles at once.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/customer_shop_api.dart';
import '../../utils/render_log.dart';
import '../admin/nav_registry_view.dart' show navIcon, navIconLetter, navIconResolves;

String _s(Object? v) => v == null ? '' : v.toString();

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

/// The pharmacy account's shop home.
///
/// [navigate] is HomeShell's own route handler — the same one the admin
/// dashboard tiles use — so a tile opens the screen that is already built
/// rather than a second address that could drift from it.
class MyShopScreen extends StatefulWidget {
  final ValueChanged<String> navigate;
  final CustomerShopRpc? rpc;

  const MyShopScreen({super.key, required this.navigate, this.rpc});

  @override
  State<MyShopScreen> createState() => _MyShopScreenState();
}

class _MyShopScreenState extends State<MyShopScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  bool _failed = false;
  final Set<String> _open = <String>{};

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
      final res = await (widget.rpc != null
          ? widget.rpc!('customer_shop_home', const {})
          : CustomerShopApi.home());
      if (!mounted) return;
      final sections = _rows(res['sections']);
      setState(() {
        _payload = res;
        _loading = false;
        // The first section is the one a shop opens this tab for; the rest
        // stay folded until asked for.
        if (_open.isEmpty && sections.isNotEmpty) {
          _open.add(_s(sections.first['key']));
        }
      });
      RenderLog.write(
        'c536_my_shop',
        'sections:${sections.length};tiles:${sections.fold<int>(0, (n, s) => n + _rows(s['items']).length)}',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Skeleton();

    final res = _payload;

    // A load that never landed: the retry is the whole screen, because there is
    // nothing truthful to draw underneath it.
    if (_failed || res == null) {
      return _Centered(
        message: _s(res?['empty_message']),
        actionLabel: _s(res?['retry_label']),
        onAction: _load,
      );
    }

    // The backend's own refusal — an admin, a supplier, a rider. Its sentence,
    // with nothing of ours added to it.
    if (res['ok'] != true) {
      return _Centered(message: _s(res['message']));
    }

    final sections = _rows(res['sections']);
    if (sections.isEmpty) {
      return _Centered(message: _s(res['empty_message']));
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
        children: [
          Text(_s(res['title']), style: Ds.t.title),
          if (_s(res['subtitle']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(res['subtitle']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x24),
          for (final section in sections) ...[
            _Section(
              label: _s(section['label']),
              iconKey: _s(section['icon_key']),
              items: _rows(section['items']),
              expanded: _open.contains(_s(section['key'])),
              onToggle: () => setState(() {
                final key = _s(section['key']);
                if (!_open.remove(key)) _open.add(key);
              }),
              onOpen: (navKey) {
                if (navKey.isEmpty) return;
                widget.navigate(navKey);
              },
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      ),
    );
  }
}

/// One collapsible group of tiles. The header is a 48 px tap target in its own
/// right, so folding a section never needs a precise tap on the chevron.
class _Section extends StatelessWidget {
  final String label;
  final String iconKey;
  final List<Map<String, dynamic>> items;
  final bool expanded;
  final VoidCallback onToggle;
  final ValueChanged<String> onOpen;

  const _Section({
    required this.label,
    required this.iconKey,
    required this.items,
    required this.expanded,
    required this.onToggle,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: Ds.r.rCard,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x16),
              child: Row(
                children: [
                  Icon(navIcon(iconKey), size: Ds.space.x24, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x12),
                  Expanded(child: Text(label, style: Ds.t.subtitle)),
                  Text('${items.length}', style: Ds.t.caption),
                  SizedBox(width: Ds.space.x8),
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: Ds.space.x24,
                    color: Ds.c.textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: Ds.c.divider),
            for (final item in items)
              _Tile(row: item, onOpen: () => onOpen(_s(item['nav_key']))),
            SizedBox(height: Ds.space.x8),
          ],
        ],
      ),
    );
  }
}

/// One feature. Label, caption and glyph are the payload's; the row knows
/// nothing about which feature it is drawing.
class _Tile extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onOpen;

  const _Tile({required this.row, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final caption = _s(row['caption']);
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        child: Row(
          children: [
            Container(
              width: Ds.space.x48,
              height: Ds.space.x48,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Ds.c.brandSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: navIconResolves(_s(row['icon_key']))
                  ? Icon(navIcon(_s(row['icon_key'])),
                      size: Ds.space.x24, color: Ds.c.brand)
                  : Text(navIconLetter(row), style: Ds.t.bodyStrong),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(row['label']), style: Ds.t.bodyStrong),
                  if (caption.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(caption, style: Ds.t.caption),
                  ],
                ],
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Icon(Icons.chevron_right,
                size: Ds.space.x24, color: Ds.c.textSecondary),
          ],
        ),
      ),
    );
  }
}

/// A one-message state: the backend's sentence, and a Retry when the failure
/// was ours rather than an answer.
class _Centered extends StatelessWidget {
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;

  const _Centered({
    required this.message,
    this.actionLabel = '',
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isNotEmpty)
              Text(message, style: Ds.t.body, textAlign: TextAlign.center),
            if (onAction != null && actionLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The shape of the list, drawn while it loads — never a bare spinner.
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    Widget bar(double width, double height) => Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Ds.c.divider,
            borderRadius: Ds.r.rChip,
          ),
        );

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        bar(Ds.space.x48 * 3, Ds.space.x24),
        SizedBox(height: Ds.space.x24),
        for (var i = 0; i < 4; i++) ...[
          Container(
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
            ),
            child: Row(
              children: [
                bar(Ds.space.x24, Ds.space.x24),
                SizedBox(width: Ds.space.x12),
                Expanded(child: bar(double.infinity, Ds.space.x16)),
              ],
            ),
          ),
          SizedBox(height: Ds.space.x12),
        ],
      ],
    );
  }
}
