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
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../services/masked_call_service.dart';
import '../../widgets/masked_call_button.dart';
import '../admin/admin_fulfillment_screen_web.dart';
import '../admin/admin_supplier_screen_web.dart';
import '../admin/order_alerts_screen.dart' show OrderAlertCard;
import 'partner_statement_screen.dart';
import 'zone_pnl_screen.dart';
import 'partner_expense_screen.dart';
import 'partner_staff_screen.dart';
import 'partner_tasks_screen.dart';
import 'partner_workers_screen.dart';
import '../worker/worker_tasks_screen.dart';
import 'partner_supplier_payment_screen.dart';
import 'partner_returns_screen.dart';

/// Backend `icon_key` -> a glyph. The KEY is the backend's; only the glyph is
/// local, because an IconData cannot travel in JSON. An unknown key renders the
/// neutral tile icon rather than nothing.
IconData partnerIcon(String key) {
  switch (key) {
    case 'forum':     return Icons.forum_outlined;
    case 'receipt':   return Icons.receipt_long_outlined;
    case 'rupee':     return Icons.currency_rupee;
    case 'handshake': return Icons.handshake_outlined;
    case 'store':     return Icons.storefront_outlined;
    case 'inventory': return Icons.inventory_2_outlined;
    case 'bag':       return Icons.shopping_bag_outlined;
    case 'package':   return Icons.local_shipping_outlined;
    case 'truck':     return Icons.local_shipping_outlined;
    case 'people':    return Icons.groups_outlined;
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
///
/// CHANGE #528 (feature_gaps rows 142 + 143) — `tabs` is `partner_open().tabs`:
/// the tab list the BACKEND says this grant opens, straight from
/// `partner_screen_tab` joined to the caller's own permissions. The screens
/// below render only those indexes, so one grant no longer opens all six
/// fulfilment tabs, and `partner.inquiry` no longer hands over supplier orders.
/// An empty/absent list means unbounded — that is the admin call path.
Widget? partnerDestination(String routeKey, {List<dynamic>? tabs}) {
  final allowed = (tabs == null || tabs.isEmpty)
      ? null
      : tabs
          .map((t) => (t is Map) ? t['index'] : null)
          .whereType<num>()
          .map((n) => n.toInt())
          .toSet();
  switch (routeKey) {
    case 'inquiry':
    case 'supplier_orders':
      return AdminSupplierScreen(allowedTabs: allowed);
    // CHANGE #399 — supplier payment gets its OWN partner surface. It used to
    // land on AdminSupplierScreen, whose pay panel calls sup_record_payment,
    // which raises for anyone but a super_admin: a partner could open the
    // screen and never record anything. partner_sup_record_payment is the
    // partner's door onto the same writer, zone-clamped, so the row it writes
    // is the row the office's own path writes.
    case 'supplier_payment': return const PartnerSupplierPaymentScreen();
    // CHANGE #710 — stock going BACK to a supplier, and the debit note it
    // raises. supplier_debits_list only ever listed money already taken off a
    // bill; this is the door that puts it there.
    case 'supplier_returns': return const PartnerReturnsScreen();
    // CHANGE #399 — the partner's own staff, and its own expenses.
    case 'partner_staff':    return const PartnerStaffScreen();
    case 'partner_expenses': return const PartnerExpenseScreen();
    case 'partner_workers':  return const PartnerWorkersScreen();
    // CHANGE #707 — the fulfil stages get an owner. The board is the partner's
    // (assign, reassign, auto-assign); 'my_tasks' is the same feature read from
    // the other end, by the worker it was assigned to.
    case 'fulfil_tasks':     return const PartnerTasksScreen();
    case 'my_tasks':         return const WorkerTasksScreen();
    case 'collect':         return AdminFulfillmentScreen(initialTab: 0, allowedTabs: allowed);
    case 'count':           return AdminFulfillmentScreen(initialTab: 1, allowedTabs: allowed);
    case 'bag_mapping':     return AdminFulfillmentScreen(initialTab: 2, allowedTabs: allowed);
    case 'pack':            return AdminFulfillmentScreen(initialTab: 3, allowedTabs: allowed);
    case 'assign_delivery': return AdminFulfillmentScreen(initialTab: 5, allowedTabs: allowed);
    // CHANGE #323 — the partner's own settlement statement. Zone-clamped like
    // every surface above it: partner_statement() resolves the zone from the
    // partner's own row and refuses anything else.
    // CHANGE #528 row 142 — 'partner.disputes' is a registered feature now,
    // so a grant can govern the tab that had no key at all.
    case 'disputes':        return AdminFulfillmentScreen(initialTab: 4, allowedTabs: allowed);
    case 'settlement':      return const PartnerStatementScreen();
    // CHANGE #694 — the same Zone P&L screen the office reads, zone-clamped:
    // zone_pnl() resolves the partner's own zone from its row and filters the
    // lines by pnl_line_type.partner_visible, so this door needs no argument.
    case 'partner_zone_pnl': return const ZonePnlScreen();
    default:                return null;
  }
}

// CHANGE #657 — PartnerHomeScreen (the ROUTED old Partner page) is deleted.
//
// It was reachable three ways — the `/partner` route, the `_AppRoot` surface
// branch and HomeShell's own branch — and #653 removed none of them, so a
// partner login that the backend had already moved to the admin interface kept
// landing on "Partner / Your zone, your work". All three entry points are gone
// with it; nothing in the app constructs this page any more.
//
// What stays in this file is what the SHARED admin interface still uses:
// partnerDestination() (the zone-scoped route_key -> screen resolver),
// PartnerFeaturePage (the Scaffold every partner feature screen renders inside),
// and PartnerWorkQueue / PartnerRing (the work board). Deleting those would
// remove working features, not a route.

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
  const PartnerHomeView({
    super.key,
    required this.payload,
    required this.onOpen,
    this.queue,
    this.ring = const [],
    this.ringBadge = '',
    this.ringBusy = false,
    this.onRingAct,
    this.failed = false,
    this.onRetry,
    this.onSignOut,
  });

  final Map<String, dynamic> payload;

  /// CHANGE #398 — partner_work_queue()'s payload, or null when the board did
  /// not answer. Null draws nothing: absence is explicit, never an empty board
  /// that reads as "no work".
  final Map<String, dynamic>? queue;

  /// CHANGE #398 — order_alert_feed()'s ringing items for THIS partner's zone.
  /// Empty is the normal state; every word on the card, including whether
  /// Accept may be offered at all, is the backend's.
  final List<Map<String, dynamic>> ring;

  /// order_alert_feed().badge_label — the backend's own count sentence. Empty
  /// when nothing is ringing, and never assembled from ring.length here.
  final String ringBadge;
  final bool ringBusy;
  final void Function(String orderId, String action)? onRingAct;
  final void Function(String featureKey) onOpen;

  /// CHANGE #326 — the partner_home() call itself threw. Distinct from a clean
  /// `is_partner:false` answer, which is the backend saying something true.
  final bool failed;
  final VoidCallback? onRetry;
  final VoidCallback? onSignOut;

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final groups = (payload['groups'] as List?) ?? const [];
    try {
      RenderLog.write('c307_partner_home',
          'features=${payload['feature_count'] ?? 0},zone=${payload['zone_id'] ?? ''}');
    } catch (_) {}

    // CHANGE #326 — a thrown RPC gets backend copy and a Retry, not a blank
    // card. The words come from ui_copy (cached at boot) precisely because the
    // call that would have carried them is the one that failed.
    if (failed) {
      return _Shell(
        title: c('partner.error_title'),
        zoneChip: '',
        onSignOut: onSignOut,
        child: _Empty(
          title: '',
          message: c('partner.error_message'),
          actionLabel: c('partner.retry_label'),
          onAction: onRetry,
        ),
      );
    }

    if (payload['is_partner'] != true) {
      return _Shell(
        title: _s('title'),
        zoneChip: '',
        onSignOut: onSignOut,
        child: _Empty(title: _s('message'), message: ''),
      );
    }

    return _Shell(
      title: _s('title'),
      subtitle: _s('subtitle'),
      zoneChip: _s('zone_chip'),
      partnerName: _s('partner_name'),
      ringBadge: ringBadge,
      onSignOut: onSignOut,
      child: payload['has_features'] == true
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (ring.isNotEmpty)
                  PartnerRing(
                    items: ring,
                    busy: ringBusy,
                    onAct: onRingAct,
                  ),
                if (queue != null && queue!['ok'] == true)
                  PartnerWorkQueue(payload: queue!, onOpen: onOpen),
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
    this.ringBadge = '',
    this.onSignOut,
  });

  final String title, subtitle, zoneChip, partnerName, ringBadge;
  final Widget child;

  /// CHANGE #326 — a partner never reaches the customer shell's profile menu,
  /// so without this there is no way out of the app at all. The word is the
  /// backend's.
  final VoidCallback? onSignOut;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Ds.space.x16),
          // Full width on a phone, centred and capped on a desktop.
          child: Center(
              child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: Ds.space.x48 * 16),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(title, style: Ds.t.title)),
                  if (onSignOut != null && c('partner.sign_out_label').isNotEmpty)
                    TextButton(
                      onPressed: onSignOut,
                      style: TextButton.styleFrom(
                        foregroundColor: Ds.c.textSecondary,
                        minimumSize: Size(
                            Ds.touch.minTarget, Ds.touch.minTarget),
                      ),
                      child: Text(c('partner.sign_out_label'),
                          style: Ds.t.caption),
                    ),
                ],
              ),
              if (partnerName.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(partnerName, style: Ds.t.bodyStrong),
              ],
              if (subtitle.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(subtitle, style: Ds.t.caption),
              ],
              if (zoneChip.isNotEmpty || ringBadge.isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: [
                    if (zoneChip.isNotEmpty) _Chip(label: zoneChip),
                    // CHANGE #398 — the ring badge, in the backend's words.
                    if (ringBadge.isNotEmpty)
                      _Chip(label: ringBadge, tone: 'danger'),
                  ],
                ),
              ],
              SizedBox(height: Ds.space.x24),
              child,
              SizedBox(height: Ds.space.x32),
              // (the whole column is capped to a readable measure below)
            ],
          ),
          )),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.tone = ''});
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    final t = partnerTone(tone);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: t.bg,
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label,
          style: tone.isEmpty ? Ds.t.caption : Ds.t.caption.copyWith(color: t.fg)),
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
  const _Empty({
    required this.title,
    required this.message,
    this.actionLabel = '',
    this.onAction,
  });
  final String title, message, actionLabel;
  final VoidCallback? onAction;

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
          if (actionLabel.isNotEmpty && onAction != null) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: onAction,
                child: Text(actionLabel),
              ),
            ),
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

// ── CHANGE #398 — THE WORK QUEUE BOARD ──────────────────────────────────────
//
// partner_home() answers "what may I open?". This answers "what is waiting?" —
// today's zone, every fulfilment stage, its count, its oldest orders and the
// next action for each. Nothing here is computed: the stage list, its order,
// the counts, the plural forms, the money, the ages and the action words are
// all fields of partner_work_queue(). A stage the partner has no permission
// for is not in the payload, so it cannot be drawn.

/// Backend `tone` -> a colour pair. Same contract as [partnerIcon]: the WORD is
/// the backend's, only the swatch is local, because a Color cannot travel in
/// JSON. An unknown tone renders neutral rather than nothing.
({Color bg, Color fg}) partnerTone(String tone) {
  switch (tone) {
    case 'success': return (bg: Ds.c.successSoft, fg: Ds.c.success);
    case 'warning': return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':  return (bg: Ds.c.dangerSoft,  fg: Ds.c.danger);
    case 'info':    return (bg: Ds.c.infoSoft,    fg: Ds.c.info);
    default:        return (bg: Ds.c.brandSoft,   fg: Ds.c.brand);
  }
}

class PartnerWorkQueue extends StatefulWidget {
  const PartnerWorkQueue({super.key, required this.payload, required this.onOpen});

  final Map<String, dynamic> payload;
  final void Function(String featureKey) onOpen;

  @override
  State<PartnerWorkQueue> createState() => _PartnerWorkQueueState();
}

class _PartnerWorkQueueState extends State<PartnerWorkQueue> {
  // CHANGE #404 — order_id -> the masked-call buttons this partner gets.
  // A partner may reach the pharmacy and the supplier on an order they are
  // fulfilling; the allow matrix says which, and it says it in SQL. Nothing on
  // this screen holds a phone number.
  Map<String, List<MaskedCallTarget>> _callTargets = const {};

  Map<String, dynamic> get payload => widget.payload;

  @override
  void initState() {
    super.initState();
    _loadCallTargets();
  }

  @override
  void didUpdateWidget(covariant PartnerWorkQueue old) {
    super.didUpdateWidget(old);
    if (!identical(old.payload, widget.payload)) _loadCallTargets();
  }

  Future<void> _loadCallTargets() async {
    final ids = <String>{};
    for (final st in (payload['stages'] as List?) ?? const []) {
      if (st is! Map) continue;
      for (final o in (st['orders'] as List?) ?? const []) {
        if (o is! Map) continue;
        final id = (o['order_id'] ?? '').toString();
        if (id.isNotEmpty) ids.add(id);
      }
    }
    if (ids.isEmpty) {
      if (mounted) setState(() => _callTargets = const {});
      return;
    }
    try {
      final t = await MaskedCallService.targets(ids.toList());
      if (!mounted) return;
      setState(() => _callTargets = t);
    } catch (e) {
      // The queue is the partner's whole console. A masking layer that is down
      // costs them the call buttons, never the work list.
      try {
        RenderLog.write('c404_masked_call_err', e.toString());
      } catch (_) {}
    }
  }

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final stages = (payload['stages'] as List?) ?? const [];
    try {
      RenderLog.write('c398_partner_queue',
          'stages=${stages.length},total=${payload['total'] ?? 0},zone=${payload['zone_id'] ?? ''}');
    } catch (_) {}

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s('title'), style: Ds.t.subtitle)),
              if (_s('total_label').isNotEmpty)
                Text(_s('total_label'), style: Ds.t.caption),
            ],
          ),
          if (_s('subtitle').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s('subtitle'), style: Ds.t.caption),
          ],
          if (_s('today_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s('today_label'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          if (payload['has_any'] == true)
            for (final s in stages)
              _StageCard(
                stage: Map<String, dynamic>.from(s as Map),
                onOpen: widget.onOpen,
                callTargets: _callTargets,
              )
          else
            _Empty(title: _s('empty_title'), message: _s('empty_message')),
        ],
      ),
    );
  }
}

/// One stage: its count chip, its oldest orders and the way in. A stage with
/// nothing in it still shows — an empty Pack queue is information — but it
/// carries no rows and no button.
class _StageCard extends StatelessWidget {
  const _StageCard({
    required this.stage,
    required this.onOpen,
    required this.callTargets,
  });

  final Map<String, dynamic> stage;
  final void Function(String featureKey) onOpen;
  final Map<String, List<MaskedCallTarget>> callTargets;

  @override
  Widget build(BuildContext context) {
    final orders = (stage['orders'] as List?) ?? const [];
    final feature = (stage['feature_key'] ?? '').toString();
    final tone = partnerTone((stage['tone'] ?? '').toString());
    final hasAny = stage['has_any'] == true;
    final canOpen = stage['can_open'] == true && feature.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text((stage['label'] ?? '').toString(),
                        style: Ds.t.bodyStrong)),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                      color: hasAny ? tone.bg : Ds.c.bg,
                      borderRadius: Ds.r.rChip),
                  child: Text((stage['count_label'] ?? '').toString(),
                      style: Ds.t.caption.copyWith(
                          color: hasAny ? tone.fg : Ds.c.textSecondary)),
                ),
              ],
            ),
            for (final o in orders)
              _OrderRow(
                order: Map<String, dynamic>.from(o as Map),
                callTargets:
                    callTargets[(o as Map?)?['order_id']?.toString() ?? ''] ??
                        const [],
              ),
            if ((stage['more_label'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text((stage['more_label'] ?? '').toString(), style: Ds.t.caption),
            ],
            if (hasAny && canOpen) ...[
              SizedBox(height: Ds.space.x12),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: () => onOpen(feature),
                  child: Text((stage['open_label'] ?? '').toString()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One waiting order. Every field is printed: the money is the backend's ₹
/// string, the age is the backend's phrase, and the next action is the stage's
/// own sentence rather than a word this widget picked.
class _OrderRow extends StatelessWidget {
  const _OrderRow({required this.order, this.callTargets = const []});

  final Map<String, dynamic> order;

  /// CHANGE #404 — the masked-call buttons for THIS order, decided by
  /// call_mask_targets. Empty means nobody on this order is callable by this
  /// partner, and an empty row draws nothing.
  final List<MaskedCallTarget> callTargets;

  String _s(String k) => (order[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s('order_code'), style: Ds.t.body),
                if (_s('customer').isNotEmpty)
                  Text(_s('customer'), style: Ds.t.caption),
                if (_s('next_action').isNotEmpty)
                  Text(_s('next_action'), style: Ds.t.caption),
                if (callTargets.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x8),
                  MaskedCallRow(targets: callTargets, dense: true),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_s('amount_display'), style: Ds.t.bodyStrong),
              Text(_s('age_label'), style: Ds.t.caption),
            ],
          ),
        ],
      ),
    );
  }
}

// ── CHANGE #398 — THE RING, ON THE PARTNER'S OWN PHONE ──────────────────────
//
// #306 built the full-screen new-order alert and addressed it to admin devices.
// The admin does not fulfil the order; the zone partner does. order_alert_push
// now rings the partner's own staff devices first (resolved through
// partner_users, never through push_tokens.role — get_my_role() deliberately
// calls a partner 'admin', so the token's word cannot tell them apart) and
// escalates to admin only when nobody accepts inside the escalation window.
//
// This is the in-app half of that ring: the SAME OrderAlertCard the admin
// screen draws, fed by the SAME order_alert_feed() — which is now zone-clamped,
// so a partner is shown their own zone's alerts and nothing else. The prepaid
// rule is unchanged and lives where it always did: a paid order never rings.
class PartnerRing extends StatelessWidget {
  const PartnerRing({
    super.key,
    required this.items,
    this.busy = false,
    this.onAct,
  });

  final List<Map<String, dynamic>> items;
  final bool busy;
  final void Function(String orderId, String action)? onAct;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    try {
      RenderLog.write('c398_partner_ring', '${items.length}');
    } catch (_) {}

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final raw in items)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Builder(builder: (_) {
                final item = Map<String, dynamic>.from(raw);
                final orderId = (item['order_id'] ?? '').toString();
                return OrderAlertCard(
                  item: item,
                  busy: busy,
                  onAccept: item['can_accept'] == true && onAct != null
                      ? () => onAct!(orderId, 'accept')
                      : null,
                  onReject: item['can_reject'] == true && onAct != null
                      ? () => onAct!(orderId, 'reject')
                      : null,
                );
              }),
            ),
        ],
      ),
    );
  }
}
