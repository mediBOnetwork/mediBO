// CHANGE #307 — the partner home.
//
// A fulfilment partner signs in with the SAME WhatsApp-OTP / Google login every
// other role uses and lands here. The screen computes nothing: the title, the
// zone chip, the groups, the tiles, their order, their access words and the
// empty state are all fields of `partner_home()`.
//
// THE ZONE IS NEVER PICKED. It comes from the partner's region_partners row,
// the backend clamps it into every zone-aware RPC, and this screen therefore
// renders no selector at all — `show_zone_picker` is sent as false so the rule
// is stated by the backend rather than remembered by the widget.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../utils/render_log.dart';
import '../admin/admin_fulfillment_screen_web.dart';
import '../admin/admin_supplier_screen_web.dart';

/// Backend `icon_key` -> a glyph. The KEY is the backend's; only the glyph is
/// local, because an IconData cannot travel in JSON. An unknown key renders the
/// neutral tile icon rather than nothing.
IconData partnerIcon(String key) {
  switch (key) {
    case 'forum':     return Icons.forum_outlined;
    case 'receipt':   return Icons.receipt_long_outlined;
    case 'rupee':     return Icons.currency_rupee;
    case 'store':     return Icons.storefront_outlined;
    case 'inventory': return Icons.inventory_2_outlined;
    case 'bag':       return Icons.shopping_bag_outlined;
    case 'package':   return Icons.local_shipping_outlined;
    case 'truck':     return Icons.local_shipping_outlined;
    default:          return Icons.widgets_outlined;
  }
}

/// Backend `route_key` -> the screen it opens. Navigation is the one decision
/// that cannot live in SQL; everything the screen then shows is still the
/// backend's, and every one of these surfaces is already zone-clamped.
///
/// These screens are TAB BODIES: inside the admin shell they are handed a
/// bounded box and bring no Scaffold of their own, so a partner pushes them
/// inside [PartnerFeaturePage] rather than as a bare route.
Widget? partnerDestination(String routeKey) {
  switch (routeKey) {
    case 'inquiry':
    case 'supplier_orders':
    case 'supplier_payment':
      return AdminSupplierScreen();
    case 'collect':         return AdminFulfillmentScreen(initialTab: 0);
    case 'count':           return AdminFulfillmentScreen(initialTab: 1);
    case 'bag_mapping':     return AdminFulfillmentScreen(initialTab: 2);
    case 'pack':            return AdminFulfillmentScreen(initialTab: 3);
    case 'assign_delivery': return AdminFulfillmentScreen(initialTab: 5);
    default:                return null;
  }
}

class PartnerHomeScreen extends StatefulWidget {
  const PartnerHomeScreen({super.key, this.rpc});

  /// Test seam. Null in production -> the real RPCs.
  final PartnerRpc? rpc;

  @override
  State<PartnerHomeScreen> createState() => _PartnerHomeScreenState();
}

class _PartnerHomeScreenState extends State<PartnerHomeScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> p;
    try {
      p = await _rpc('partner_home', const {});
    } catch (_) {
      p = <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _loading = false;
    });
  }

  Future<void> _open(String featureKey) async {
    Map<String, dynamic> r;
    try {
      r = await _rpc('partner_open', {'p_feature': featureKey});
    } catch (_) {
      return;
    }
    if (!mounted) return;
    if (r['ok'] != true) {
      final msg = (r['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      // The grant changed under them — refetch so the tile disappears too.
      _load();
      return;
    }
    final dest = partnerDestination((r['route_key'] ?? '').toString());
    if (dest == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PartnerFeaturePage(
        // The page title is the backend's own label for the feature.
        title: (r['label'] ?? '').toString(),
        child: dest,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PartnerHomeSkeleton();
    return PartnerHomeView(payload: _payload ?? const {}, onOpen: _open);
  }
}

/// A skeleton, not a bare spinner (design QA rule 6).
class PartnerHomeSkeleton extends StatelessWidget {
  const PartnerHomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: ListView.separated(
          padding: EdgeInsets.all(Ds.space.x16),
          itemCount: 5,
          separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
          itemBuilder: (_, __) => Container(
            height: Ds.touch.listRowMinHeight,
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
            ),
          ),
        ),
      ),
    );
  }
}

/// The pure render half — every word below comes out of [payload].
class PartnerHomeView extends StatelessWidget {
  const PartnerHomeView({super.key, required this.payload, required this.onOpen});

  final Map<String, dynamic> payload;
  final void Function(String featureKey) onOpen;

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final groups = (payload['groups'] as List?) ?? const [];
    try {
      RenderLog.write('c307_partner_home',
          'features=${payload['feature_count'] ?? 0},zone=${payload['zone_id'] ?? ''}');
    } catch (_) {}

    if (payload['is_partner'] != true) {
      return _Shell(
        title: _s('title'),
        zoneChip: '',
        child: _Empty(title: _s('message'), message: ''),
      );
    }

    return _Shell(
      title: _s('title'),
      subtitle: _s('subtitle'),
      zoneChip: _s('zone_chip'),
      partnerName: _s('partner_name'),
      child: payload['has_features'] == true
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final g in groups)
                  _Group(group: Map<String, dynamic>.from(g as Map), onOpen: onOpen),
              ],
            )
          : _Empty(title: _s('empty_title'), message: _s('empty_message')),
    );
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.title,
    required this.zoneChip,
    required this.child,
    this.subtitle = '',
    this.partnerName = '',
  });

  final String title, subtitle, zoneChip, partnerName;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Ds.t.title),
              if (partnerName.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(partnerName, style: Ds.t.bodyStrong),
              ],
              if (subtitle.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(subtitle, style: Ds.t.caption),
              ],
              if (zoneChip.isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                _Chip(label: zoneChip),
              ],
              SizedBox(height: Ds.space.x24),
              child,
              SizedBox(height: Ds.space.x32),
            ],
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: Ds.c.brandSoft,
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.group, required this.onOpen});

  final Map<String, dynamic> group;
  final void Function(String featureKey) onOpen;

  @override
  Widget build(BuildContext context) {
    final features = (group['features'] as List?) ?? const [];
    final label = (group['label'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (label.isNotEmpty) ...[
            Text(label, style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
          ],
          for (final f in features)
            _FeatureTile(
              feature: Map<String, dynamic>.from(f as Map),
              onOpen: onOpen,
            ),
        ],
      ),
    );
  }
}

class _FeatureTile extends StatelessWidget {
  const _FeatureTile({required this.feature, required this.onOpen});

  final Map<String, dynamic> feature;
  final void Function(String featureKey) onOpen;

  @override
  Widget build(BuildContext context) {
    final key = (feature['feature_key'] ?? '').toString();
    final label = (feature['label'] ?? '').toString();
    final accessLabel = (feature['access_label'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () => onOpen(key),
          child: Container(
            constraints:
                BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
              color: Ds.c.surface,
            ),
            child: Row(
              children: [
                Icon(partnerIcon((feature['icon_key'] ?? '').toString()),
                    color: Ds.c.brand),
                SizedBox(width: Ds.space.x12),
                Expanded(child: Text(label, style: Ds.t.bodyStrong)),
                if (accessLabel.isNotEmpty)
                  Text(accessLabel, style: Ds.t.caption),
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

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.message});
  final String title, message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) Text(title, style: Ds.t.subtitle),
          if (message.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(message, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}


/// The frame a partner's feature screen is pushed inside.
///
/// The admin fulfilment and supplier screens are tab bodies — they expect a
/// bounded box and no Scaffold of their own — so this supplies the route's
/// Scaffold, its title (the backend's word for the feature) and a back button.
class PartnerFeaturePage extends StatelessWidget {
  const PartnerFeaturePage({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(title, style: Ds.t.subtitle)),
      body: SafeArea(child: child),
    );
  }
}
