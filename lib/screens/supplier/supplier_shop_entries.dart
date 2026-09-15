import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../pages/supplier_availability_page.dart';
import '../../pages/supplier_companies_page.dart';
import '../../utils/render_log.dart';
import '../kyc/kyc_panel.dart';

/// The two "about my shop" entry points on the supplier's Home tab (cmd #401).
///
/// They live here rather than as two more bottom-nav tabs: seven items on a
/// 360px phone leaves under 52px each, below the touch floor, and both screens
/// are occasional settings rather than daily work.
///
/// The availability row carries a live status line so a supplier who left his
/// shop marked closed sees it on the tab he lands on, not two taps deep — that
/// is the one state where being wrong costs him orders. The sentence and its
/// tone are `supplier_closure_state`'s, never composed here.
class SupplierShopEntries extends StatefulWidget {
  const SupplierShopEntries({super.key});

  @override
  State<SupplierShopEntries> createState() => _SupplierShopEntriesState();
}

class _SupplierShopEntriesState extends State<SupplierShopEntries> {
  Map<String, dynamic> _avail = const {};
  Map<String, dynamic> _cov = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final a = await Supabase.instance.client.rpc('supplier_availability_get');
      final c = await Supabase.instance.client.rpc('supplier_coverage_get');
      if (!mounted) return;
      setState(() {
        _avail = a is Map ? Map<String, dynamic>.from(a) : const {};
        _cov = c is Map ? Map<String, dynamic>.from(c) : const {};
      });
      RenderLog.write('c401_entries', _avail['closed'] == true ? 'closed' : 'open');
    } catch (_) {/* the cards degrade to their titles */}
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SupplierShopEntriesView(
            avail: _avail,
            cov: _cov,
            onOpenAvailability: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => const SupplierAvailabilityPage()))
                .then((_) => _load()),
            onOpenCompanies: () => Navigator.of(context)
                .push(MaterialPageRoute(
                    builder: (_) => const SupplierCompaniesPage()))
                .then((_) => _load()),
          ),
          // CHANGE #705 — the licence-and-documents panel, on the tab the
          // supplier lands on. The same widget the pharmacy sees: kyc_my_panel()
          // resolves which account is asking and words every line. It stays out
          // of SupplierShopEntriesView so that pure, widget-tested half keeps
          // needing no Supabase.
          const KycPanel(),
        ],
      );
}

/// The pure layout half, split out so it can be widget-tested without Supabase.
///
/// It renders two payloads and nothing else — every string here comes from
/// `supplier_availability_get` / `supplier_coverage_get`.
class SupplierShopEntriesView extends StatelessWidget {
  const SupplierShopEntriesView({
    super.key,
    required this.avail,
    required this.cov,
    required this.onOpenAvailability,
    required this.onOpenCompanies,
  });

  final Map<String, dynamic> avail;
  final Map<String, dynamic> cov;
  final VoidCallback onOpenAvailability;
  final VoidCallback onOpenCompanies;

  String _s(Object? v) => v == null ? '' : v.toString();

  @override
  Widget build(BuildContext context) {
    if (_s(avail['screen_title']).isEmpty && _s(cov['screen_title']).isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
      // IntrinsicHeight, not CrossAxisAlignment.stretch: this widget is a direct
      // child of an unbounded Column, so stretch has no height to stretch to and
      // takes the whole supplier Home down with it. IntrinsicHeight measures the
      // taller tile and gives the Row that bounded height, so both cards share
      // one top and one bottom line.
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Expanded(
            child: _tile(
              icon: Icons.storefront_outlined,
              title: _s(avail['screen_title']),
              // The backend's own status sentence, tone included.
              sub: _s(avail['status_label']),
              tone: _s(avail['status_tone']),
              onTap: onOpenAvailability,
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: _tile(
              icon: Icons.business_outlined,
              title: _s(cov['screen_title']),
              // The backend's own short tile line ('None declared yet' / 'N
              // declared'); the full-screen empty sentence truncated mid-word.
              sub: _s(cov['tile_sub']),
              tone: '',
              onTap: onOpenCompanies,
            ),
          ),
        ]),
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String sub,
    required String tone,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rCard,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: tone == 'warning' ? Ds.c.warningSoft : Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: Ds.t.bodySize, color: Ds.c.textSecondary),
            SizedBox(width: Ds.space.x8),
            Expanded(child: Text(title, style: Ds.t.body, maxLines: 1,
                overflow: TextOverflow.ellipsis)),
          ]),
          if (sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(sub, style: Ds.t.caption, maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
        ]),
      ),
    );
  }
}
