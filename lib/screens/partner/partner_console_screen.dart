// CHANGE #399 — the partner's own console.
//
// The backend already knew how to describe a partner's world (partner_home()
// returns the feature groups this login may open, with its access level and the
// route key for each). Nothing in the app ever asked. This screen is that ask:
// it prints partner_home() verbatim and routes each tile by the BACKEND's
// route_key. A route_key this build does not recognise is skipped in silence,
// so the office can add a partner feature without shipping an app.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import 'partner_expense_screen.dart';
import 'partner_staff_screen.dart';
import 'partner_supplier_payment_screen.dart';

/// The route keys this build can open. Anything else is ignored — never
/// rendered as a dead tile.
Widget? partnerRouteScreen(String routeKey) {
  switch (routeKey) {
    case 'partner_staff':
      return const PartnerStaffScreen();
    case 'partner_expenses':
      return const PartnerExpenseScreen();
    case 'supplier_payment':
      return const PartnerSupplierPaymentScreen();
    default:
      return null;
  }
}

class PartnerConsoleScreen extends StatefulWidget {
  const PartnerConsoleScreen({super.key});

  @override
  State<PartnerConsoleScreen> createState() => _PartnerConsoleScreenState();
}

class _PartnerConsoleScreenState extends State<PartnerConsoleScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    try {
      final res = await Supabase.instance.client.rpc('partner_home');
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('partner_console',
          'ok=${map['ok']} groups=${(map['groups'] as List?)?.length ?? 0}');
      if (!mounted) return;
      setState(() { _data = map; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  void _open(String routeKey, String label) {
    final screen = partnerRouteScreen(routeKey);
    if (screen == null) return;
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        title: Text((d?['title'] as String?) ?? '', style: Ds.t.title),
      ),
      body: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  text: (d?['message'] as String?) ?? _error,
                  onRetry: _load,
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (((d['subtitle'] as String?) ?? '').isNotEmpty)
                        Text(d['subtitle'] as String, style: Ds.t.bodySecondary),
                      if (((d['zone_chip'] as String?) ?? '').isNotEmpty) ...[
                        SizedBox(height: Ds.space.x12),
                        PartnerChip(text: d['zone_chip'] as String, tone: 'info'),
                      ],
                      SizedBox(height: Ds.space.x24),
                      if (d['has_features'] != true)
                        PartnerNotice(
                          text: (d['empty_message'] as String?) ?? '',
                          title: (d['empty_title'] as String?) ?? '',
                        )
                      else
                        ..._groups(d['groups']),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _groups(Object? groups) {
    final out = <Widget>[];
    for (final g in (groups as List? ?? const [])) {
      final gm = Map<String, dynamic>.from(g as Map);
      final tiles = <Widget>[];
      for (final f in (gm['features'] as List? ?? const [])) {
        final fm = Map<String, dynamic>.from(f as Map);
        final routeKey = (fm['route_key'] as String?) ?? '';
        // Forward compatibility: a feature this build cannot open is not shown.
        if (partnerRouteScreen(routeKey) == null) continue;
        tiles.add(_tile(fm, routeKey));
      }
      if (tiles.isEmpty) continue;
      out.add(Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Text((gm['label'] as String?) ?? '', style: Ds.t.caption),
      ));
      out.addAll(tiles);
      out.add(SizedBox(height: Ds.space.x24));
    }
    return out;
  }

  Widget _tile(Map<String, dynamic> fm, String routeKey) {
    final label = (fm['label'] as String?) ?? '';
    final accessLabel = (fm['access_label'] as String?) ?? '';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () => _open(routeKey, label),
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
            padding: EdgeInsets.all(Ds.space.x16),
            child: Row(
              children: [
                Expanded(child: Text(label, style: Ds.t.body)),
                if (accessLabel.isNotEmpty)
                  PartnerChip(text: accessLabel, tone: 'neutral'),
                SizedBox(width: Ds.space.x8),
                Icon(Icons.chevron_right, color: Ds.c.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── shared partner-surface pieces ──────────────────────────────────────────
// Kept here so the three partner screens look like one screen, and so a tone
// string from the backend has exactly one meaning in the app.

Color partnerToneColor(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color partnerToneBg(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

class PartnerChip extends StatelessWidget {
  const PartnerChip({super.key, required this.text, this.tone});

  final String text;
  final String? tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: partnerToneBg(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text,
          style: Ds.t.caption.copyWith(color: partnerToneColor(tone))),
    );
  }
}

class PartnerCard extends StatelessWidget {
  const PartnerCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      child: child,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: onTap == null
            ? body
            : InkWell(borderRadius: Ds.r.rCard, onTap: onTap, child: body),
      ),
    );
  }
}

/// Loading is a skeleton, never a bare spinner (DESIGN.md).
class PartnerSkeleton extends StatelessWidget {
  const PartnerSkeleton({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < rows; i++)
          Container(
            height: Ds.touch.listRowMinHeight + Ds.space.x16,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.surface, borderRadius: Ds.r.rCard),
          ),
      ],
    );
  }
}

/// Every empty / denied / failed state on the partner surface, printing the
/// BACKEND's own sentence. Nothing here composes English.
class PartnerNotice extends StatelessWidget {
  const PartnerNotice(
      {super.key, required this.text, this.title = '', this.onRetry, this.retryLabel = ''});

  final String text;
  final String title;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x8),
            ],
            Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            if (onRetry != null && retryLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
