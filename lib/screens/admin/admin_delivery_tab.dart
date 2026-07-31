// lib/screens/admin/admin_delivery_tab.dart — CHANGE #629 (PART A)
//
// The admin Delivery tab, sixth in Fulfillment beside Supplier Shop / Warehouse
// / Bag / Pack / Disputes.
//
// A2 — IT BUILDS NO PICKERS. The date comes from AdminDateScope (the ONE admin
// date picker, #545) and the zone from AdminZoneScope (#609). Both are passed
// EXPLICITLY on every call in this file, because admin_delivery_queue() and
// admin_delivery_dashboard() each expose a (p_date) overload and a
// (p_date, p_zone) overload — sending both keys is what selects the zone-aware
// one. Sibling fulfillment RPCs omit p_date deliberately (they default to
// admin_active_date()); these two do not, and the spec is explicit: both
// filters, every call.
//
// A3 — zone_label is printed in the header so it is never ambiguous which zone
// is on screen. Zones behave as separate shops and must never mix.
//
// A4/A5 — THE ASSIGN GATE IS THE BACKEND'S. `eligibility.can_assign` enables the
// checkbox; `eligibility.blocked_label` is printed verbatim when it does not.
// This is a prepaid-only business, so "Payment pending" / "Bill not sent" are
// real refusals — and not one of them is computed, reworded or re-ordered here.
// delivery_assign()'s `blocked[]` is ALWAYS rendered, including its cross-zone
// reason ("Different zone — this partner works another zone"), which is exactly
// the message that must never be swallowed.
//
// Nothing on this screen is counted, sorted, coloured or phrased in Dart:
// ready_count, the dashboard tiles, status_label, status_colors, success_label,
// the missing-location title and every partner label arrive finished.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_date_scope.dart';
import '../../services/admin_zone_scope.dart';
import '../../utils/render_log.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBad => FulfillLookups.instance.color('c_ffb42318', const Color(0xFFB42318));

String _ui(String k) => FulfillLookups.instance.ui(k);

/// Parses a backend `#RRGGBB`. Null when absent — the caller then renders no
/// chip rather than choosing a colour of its own.
Color? _hex(String? h) {
  final s = (h ?? '').trim().replaceFirst('#', '');
  if (s.length != 6 && s.length != 8) return null;
  final v = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16);
  return v == null ? null : Color(v);
}

class AdminDeliveryTab extends StatefulWidget {
  const AdminDeliveryTab({super.key});

  @override
  State<AdminDeliveryTab> createState() => AdminDeliveryTabState();
}

class AdminDeliveryTabState extends State<AdminDeliveryTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _loading = true;

  // admin_delivery_queue()
  bool _allowed = true;
  String _zoneLabel = '';
  int _readyCount = 0;
  List<Map<String, dynamic>> _orders = const [];
  List<Map<String, dynamic>> _partners = const [];

  // admin_delivery_dashboard()
  Map<String, dynamic> _tiles = const {};
  List<Map<String, dynamic>> _riders = const [];

  // admin_missing_locations()
  int _missingCount = 0;
  String _missingTitle = '';
  String _missingNote = '';
  List<Map<String, dynamic>> _missingRows = const [];

  /// order_id -> selected. Only ever holds ids the backend said can_assign.
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    AdminDateScope.instance.addListener(_onScopeChanged);
    AdminZoneScope.instance.addListener(_onScopeChanged);
    AdminZoneScope.instance.ensureLoaded();
    _load();
  }

  @override
  void dispose() {
    AdminDateScope.instance.removeListener(_onScopeChanged);
    AdminZoneScope.instance.removeListener(_onScopeChanged);
    super.dispose();
  }

  /// Refetch, for the host tab bar when this tab is opened.
  Future<void> reload() => _load();

  void _onScopeChanged() {
    // The date or the zone moved — everything on screen belongs to the old
    // scope. Drop the selection with it; an order selected under Raipur must
    // never be assigned while Bilaspur is on screen.
    _selected.clear();
    _load();
  }

  /// The two filters, sent on EVERY call in this file.
  Map<String, dynamic> get _scope => {
        'p_date': AdminDateScope.instance.dateYmd,
        'p_zone': AdminZoneScope.instance.selectedZoneId,
      };

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final client = Supabase.instance.client;
    try {
      final results = await Future.wait([
        client.rpc('admin_delivery_queue', params: _scope),
        client.rpc('admin_delivery_dashboard', params: _scope),
        client.rpc('admin_missing_locations'),
      ]);
      if (!mounted) return;

      final q = results[0] is Map ? Map<String, dynamic>.from(results[0] as Map) : <String, dynamic>{};
      final d = results[1] is Map ? Map<String, dynamic>.from(results[1] as Map) : <String, dynamic>{};
      final m = results[2] is Map ? Map<String, dynamic>.from(results[2] as Map) : <String, dynamic>{};

      setState(() {
        _allowed = q['allowed'] != false;
        _zoneLabel = q['zone_label']?.toString() ?? '';
        _readyCount = (q['ready_count'] as num?)?.toInt() ?? 0;
        _orders = _list(q['orders']);
        _partners = _list(q['partners']);

        _tiles = d['tiles'] is Map ? Map<String, dynamic>.from(d['tiles'] as Map) : const {};
        _riders = _list(d['riders']);

        _missingCount = (m['missing_count'] as num?)?.toInt() ?? 0;
        _missingTitle = m['title']?.toString() ?? '';
        _missingNote = m['note']?.toString() ?? '';
        _missingRows = _list(m['rows']);

        // Anything no longer assignable in this payload leaves the selection.
        _selected.removeWhere((id) => !_canAssign(id));
        _loading = false;
      });

      RenderLog.write('c629_delivery',
          'zone=$_zoneLabel;date=${AdminDateScope.instance.dateYmd ?? ''};'
          'orders=${_orders.length};ready=$_readyCount;partners=${_partners.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c629_delivery_err', e.toString());
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  bool _canAssign(String orderId) {
    for (final o in _orders) {
      if (o['order_id']?.toString() == orderId) {
        final e = o['eligibility'];
        return e is Map && e['can_assign'] == true && o['delivery'] == null;
      }
    }
    return false;
  }

  // ── A5: assign ────────────────────────────────────────────────────────────

  Future<void> _assign(String partnerId) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    try {
      final res = await Supabase.instance.client.rpc('delivery_assign', params: {
        'p_order_ids': ids,
        'p_partner_id': partnerId,
      });
      if (!mounted) return;
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        RenderLog.write('c629_delivery_assign',
            'assigned=${m['assigned'] ?? 0};blocked=${(m['blocked'] as List?)?.length ?? 0}');
        _selected.clear();
        await _load();
        if (!mounted) return;
        // ALWAYS shown — blocked[] carries the cross-zone refusal, and a
        // swallowed refusal is how an order silently goes nowhere.
        await _showAssignResult(m);
      }
    } catch (e) {
      RenderLog.write('c629_delivery_assign_err', e.toString());
    }
  }

  Future<void> _showAssignResult(Map<String, dynamic> m) async {
    final blocked = _list(m['blocked']);
    final title = m['title']?.toString() ?? '';
    final message = m['message']?.toString() ?? '';
    if (title.isEmpty && message.isEmpty && blocked.isEmpty) return;

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title.isNotEmpty ? title : message,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        content: blocked.isEmpty
            ? (title.isNotEmpty && message.isNotEmpty ? Text(message) : null)
            : SizedBox(
                width: 380,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (message.isNotEmpty) ...[
                      Text(message, style: TextStyle(fontSize: 13, color: _kSub)),
                      const SizedBox(height: 10),
                    ],
                    Text(_ui('dlv_blocked_heading'),
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800, color: _kBad)),
                    const SizedBox(height: 6),
                    for (final b in blocked)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('• ', style: TextStyle(color: _kBad)),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_orderCodeOf(b['order_id']?.toString() ?? ''),
                                      style: TextStyle(
                                          fontSize: 12.5,
                                          fontWeight: FontWeight.w700,
                                          color: _kText)),
                                  // Verbatim, including the cross-zone reason.
                                  Text(b['reason']?.toString() ?? '',
                                      style: TextStyle(fontSize: 12.5, color: _kBad)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(_ui('dlv_close')),
          ),
        ],
      ),
    );
  }

  /// The code the queue already printed for that order, so a blocked line is
  /// identifiable. Falls back to '' — never to a synthesised label.
  String _orderCodeOf(String orderId) {
    for (final o in _orders) {
      if (o['order_id']?.toString() == orderId) {
        return o['order_code']?.toString() ?? '';
      }
    }
    return '';
  }

  // ── A6: suggested partner + the picker ────────────────────────────────────

  Future<void> _openPartnerPicker() async {
    if (_selected.isEmpty) return;

    // One-tap default for the first selected order. The admin may still pick
    // anyone in the zone — this is an offer, not a decision.
    Map<String, dynamic>? suggested;
    try {
      final res = await Supabase.instance.client.rpc('delivery_suggest_partner',
          params: {'p_order_id': _selected.first});
      if (res is Map && res['partner_id'] != null) {
        suggested = Map<String, dynamic>.from(res);
      }
    } catch (_) {
      // No suggestion -> the full list still stands.
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _PartnerPicker(
        partners: _partners,
        suggested: suggested,
        zoneLabel: _zoneLabel,
        count: _selected.length,
      ),
    );
    if (picked != null && picked.isNotEmpty) await _assign(picked);
  }

  // ── A7: reassign + returned-parcel check-in ───────────────────────────────

  Future<void> _reassign(String deliveryId) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _PartnerPicker(
        partners: _partners,
        suggested: null,
        zoneLabel: _zoneLabel,
        count: 1,
      ),
    );
    if (picked == null || picked.isEmpty) return;
    try {
      final res = await Supabase.instance.client.rpc('delivery_reassign',
          params: {'p_delivery_id': deliveryId, 'p_partner_id': picked});
      if (!mounted) return;
      await _load();
      if (res is Map) _toast(res['message']?.toString() ?? '');
    } catch (_) {}
  }

  Future<void> _rtoReceive(String deliveryId) async {
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_rto_receive', params: {'p_delivery_id': deliveryId});
      if (!mounted) return;
      await _load();
      if (res is Map) _toast(res['message']?.toString() ?? '');
    } catch (_) {}
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── A9: missing locations ─────────────────────────────────────────────────

  Future<void> _openMissingLocations() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MissingLocationsSheet(
        title: _missingTitle,
        note: _missingNote,
        rows: _missingRows,
      ),
    );
    await _load();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (!_allowed) return const SizedBox.shrink();

    return Stack(children: [
      RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(16, 12, 16, _selected.isEmpty ? 24 : 96),
          children: [
            _zoneHeader(),
            if (_missingCount > 0) ...[
              const SizedBox(height: 12),
              _missingBanner(),
            ],
            const SizedBox(height: 12),
            _dashboardStrip(),
            if (_riders.isNotEmpty) ...[
              const SizedBox(height: 12),
              _ridersStrip(),
            ],
            const SizedBox(height: 16),
            if (_orders.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Center(
                  child: Text(_ui('dlv_no_orders'),
                      style: TextStyle(fontSize: 13, color: _kSub)),
                ),
              )
            else
              for (final o in _orders) _orderRow(o),
          ],
        ),
      ),
      if (_selected.isNotEmpty)
        Positioned(
          left: 0, right: 0, bottom: 0,
          child: _assignBar(),
        ),
    ]);
  }

  /// A3 — the zone is never ambiguous.
  Widget _zoneHeader() {
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_zoneLabel,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 2),
          Text(AdminDateScope.instance.longLabel,
              style: TextStyle(fontSize: 12, color: _kSub)),
        ]),
      ),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _kGreen.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text('$_readyCount',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kGreen)),
      ),
      const SizedBox(width: 8),
      IconButton(
        tooltip: _ui('dlv_refresh'),
        onPressed: _load,
        icon: Icon(Icons.refresh, size: 20, color: _kSub),
      ),
    ]);
  }

  Widget _missingBanner() {
    return InkWell(
      onTap: _openMissingLocations,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFF59E0B)),
        ),
        child: Row(children: [
          const Icon(Icons.location_off_outlined, size: 20, color: Color(0xFF92400E)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_missingTitle,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF92400E))),
              if (_missingNote.isNotEmpty)
                Text(_missingNote,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
            ]),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFF92400E)),
        ]),
      ),
    );
  }

  /// A8 — tiles, counted by admin_delivery_dashboard(). The labels are the
  /// payload's own keys; no total is added up here.
  Widget _dashboardStrip() {
    const order = ['assigned', 'out', 'delivered', 'failed', 'rto', 'unaccepted', 'total'];
    final tiles = <Widget>[];
    for (final k in order) {
      if (!_tiles.containsKey(k)) continue;
      tiles.add(Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${(_tiles[k] as num?)?.toInt() ?? 0}',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText)),
          // dlv_tile_<key> in the copy catalog. Empty renders nothing — the raw
          // payload key is a column name, not a label, and printing it would be
          // writing English in Dart.
          Text(_ui('dlv_tile_$k'), style: TextStyle(fontSize: 11, color: _kSub)),
        ]),
      ));
    }
    if (tiles.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: tiles),
    );
  }

  Widget _ridersStrip() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final r in _riders)
          Container(
            width: 190,
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: _kBorder),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
              Text(r['type_label']?.toString() ?? '',
                  style: TextStyle(fontSize: 11, color: _kSub)),
              const SizedBox(height: 6),
              Row(children: [
                _miniStat('${(r['delivered'] as num?)?.toInt() ?? 0}', _kGreen),
                const SizedBox(width: 6),
                _miniStat('${(r['failed'] as num?)?.toInt() ?? 0}', _kBad),
                const SizedBox(width: 6),
                _miniStat('${(r['pending'] as num?)?.toInt() ?? 0}', _kSub),
                const Spacer(),
                Text(r['success_label']?.toString() ?? '',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kText)),
              ]),
            ]),
          ),
      ]),
    );
  }

  Widget _miniStat(String v, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(v, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );

  Widget _orderRow(Map<String, dynamic> o) {
    final orderId = o['order_id']?.toString() ?? '';
    final elig = o['eligibility'] is Map
        ? Map<String, dynamic>.from(o['eligibility'] as Map)
        : const <String, dynamic>{};
    final delivery = o['delivery'] is Map
        ? Map<String, dynamic>.from(o['delivery'] as Map)
        : null;

    // A4 — the gate, and only the gate.
    final canAssign = elig['can_assign'] == true;
    final blockedLabel = elig['blocked_label']?.toString() ?? '';
    final selected = _selected.contains(orderId);
    final selectable = canAssign && delivery == null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: selected ? _kGreen : _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (delivery == null)
            SizedBox(
              width: 34,
              child: Checkbox(
                value: selected,
                // Disabled EXACTLY when the backend says so.
                onChanged: !selectable
                    ? null
                    : (v) => setState(() {
                          if (v == true) {
                            _selected.add(orderId);
                          } else {
                            _selected.remove(orderId);
                          }
                        }),
                activeColor: _kGreen,
                visualDensity: VisualDensity.compact,
              ),
            ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o['pharmacy_name']?.toString() ?? '',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
              const SizedBox(height: 2),
              Text(o['order_code']?.toString() ?? '',
                  style: TextStyle(fontSize: 12, color: _kSub)),
              if ((o['address']?.toString() ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(o['address']!.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _kSub)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(o['total_display']?.toString() ?? '',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            Text('${(o['item_count'] as num?)?.toInt() ?? 0}',
                style: TextStyle(fontSize: 11, color: _kSub)),
            if (o['has_location'] != true)
              Icon(Icons.location_off_outlined, size: 15, color: _kBad),
          ]),
        ]),

        // A4 — the refusal, in the backend's words.
        if (delivery == null && !canAssign && blockedLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFFFBE9E7),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(blockedLabel,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kBad)),
          ),
        ],

        // A7 — assigned rows.
        if (delivery != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            _statusChip(delivery),
            const SizedBox(width: 8),
            Expanded(
              child: Text(delivery['partner_name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
            ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: _kBorder),
                foregroundColor: _kText,
              ),
              onPressed: () => _reassign(delivery['delivery_id']?.toString() ?? ''),
              child: Text(_ui('dlv_reassign'), style: const TextStyle(fontSize: 12.5)),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: _kBorder),
                foregroundColor: _kText,
              ),
              onPressed: () => _rtoReceive(delivery['delivery_id']?.toString() ?? ''),
              child: Text(_ui('dlv_rto_receive'), style: const TextStyle(fontSize: 12.5)),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget _statusChip(Map<String, dynamic> delivery) {
    final label = delivery['status_label']?.toString() ?? '';
    if (label.isEmpty) return const SizedBox.shrink();
    final colors = delivery['status_colors'] is Map
        ? Map<String, dynamic>.from(delivery['status_colors'] as Map)
        : const <String, dynamic>{};
    final bg = _hex(colors['bg']?.toString());
    final fg = _hex(colors['fg']?.toString());
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg ?? Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11.5, fontWeight: FontWeight.w700, color: fg ?? _kText)),
    );
  }

  Widget _assignBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: _kBorder)),
      ),
      child: Row(children: [
        Text('${_selected.length}',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
        const SizedBox(width: 12),
        Expanded(
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 13),
            ),
            onPressed: _openPartnerPicker,
            child: Text(_ui('dlv_assign_selected'),
                style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ]),
    );
  }
}

// ── A5/A6: the partner picker ─────────────────────────────────────────────────

class _PartnerPicker extends StatelessWidget {
  final List<Map<String, dynamic>> partners;
  final Map<String, dynamic>? suggested;
  final String zoneLabel;
  final int count;

  const _PartnerPicker({
    required this.partners,
    required this.suggested,
    required this.zoneLabel,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    final s = suggested;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (context, ctrl) => ListView(
        controller: ctrl,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Center(
            child: Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: _kBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(_ui('dlv_pick_partner'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 2),
          // The zone is stated here too — an assignment is a zone-bound act.
          Text(zoneLabel, style: TextStyle(fontSize: 12, color: _kSub)),
          const SizedBox(height: 14),

          if (s != null) ...[
            Text(_ui('dlv_suggested'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _kGreen)),
            const SizedBox(height: 6),
            _tile(
              context,
              id: s['partner_id']?.toString() ?? '',
              name: s['name']?.toString() ?? '',
              // The suggestion carries a reason, not a type label.
              subtitle: s['reason']?.toString() ?? '',
              openStops: (s['open_stops'] as num?)?.toInt(),
              highlight: true,
            ),
            const SizedBox(height: 16),
          ],

          if (partners.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text(_ui('dlv_no_partners'),
                    style: TextStyle(fontSize: 13, color: _kSub)),
              ),
            )
          else
            for (final p in partners)
              _tile(
                context,
                id: p['partner_id']?.toString() ?? '',
                name: p['name']?.toString() ?? '',
                subtitle: [
                  p['type_label']?.toString() ?? '',
                  p['phone']?.toString() ?? '',
                  p['vehicle']?.toString() ?? '',
                ].where((x) => x.isNotEmpty).join(' · '),
                openStops: (p['open_stops'] as num?)?.toInt(),
                highlight: false,
              ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String id,
    required String name,
    required String subtitle,
    required int? openStops,
    required bool highlight,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        border: Border.all(color: highlight ? _kGreen : _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: ListTile(
        dense: true,
        onTap: id.isEmpty ? null : () => Navigator.of(context).pop(id),
        title: Text(name,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
        subtitle: subtitle.isEmpty
            ? null
            : Text(subtitle, style: TextStyle(fontSize: 11.5, color: _kSub)),
        trailing: openStops == null
            ? null
            : Text('$openStops ${_ui('dlv_open_stops')}',
                style: TextStyle(fontSize: 11.5, color: _kSub)),
      ),
    );
  }
}

// ── A9: missing locations ─────────────────────────────────────────────────────

class _MissingLocationsSheet extends StatefulWidget {
  final String title;
  final String note;
  final List<Map<String, dynamic>> rows;

  const _MissingLocationsSheet({
    required this.title,
    required this.note,
    required this.rows,
  });

  @override
  State<_MissingLocationsSheet> createState() => _MissingLocationsSheetState();
}

class _MissingLocationsSheetState extends State<_MissingLocationsSheet> {
  /// pharmacy_id currently being edited.
  String _open = '';
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  /// A9 — p_maps_url takes a PASTED Google Maps link and the backend extracts
  /// the coordinates. No URL is parsed here: this app has no idea what a Maps
  /// link looks like, and must not acquire one.
  Future<void> _save(String pharmacyId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final url = _urlCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('pharmacy_set_location', params: {
        'p_pharmacy_id': pharmacyId,
        'p_lat': double.tryParse(_latCtrl.text.trim()),
        'p_lng': double.tryParse(_lngCtrl.text.trim()),
        'p_maps_url': url.isEmpty ? null : url,
      });
      if (!mounted) return;
      final msg = res is Map ? (res['message']?.toString() ?? '') : '';
      if (res is Map && res['ok'] == true) {
        setState(() {
          _open = '';
          _latCtrl.clear();
          _lngCtrl.clear();
          _urlCtrl.clear();
        });
      }
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(widget.title,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
            if (widget.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(widget.note, style: TextStyle(fontSize: 12.5, color: _kSub)),
            ],
            const SizedBox(height: 14),
            for (final r in widget.rows) _row(r),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final id = r['pharmacy_id']?.toString() ?? '';
    final isOpen = _open == id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['pharmacy_name']?.toString() ?? '',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
              if ((r['address']?.toString() ?? '').isNotEmpty)
                Text(r['address']!.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _kSub)),
            ]),
          ),
          TextButton(
            onPressed: () => setState(() {
              _open = isOpen ? '' : id;
              _latCtrl.clear();
              _lngCtrl.clear();
              _urlCtrl.clear();
            }),
            child: Text(_ui('dlv_fix_location'), style: const TextStyle(fontSize: 12.5)),
          ),
        ]),
        if (isOpen) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              labelText: _ui('dlv_maps_link'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _latCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: _ui('dlv_lat'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lngCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: _ui('dlv_lng'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : () => _save(id),
            child: Text(_ui('dlv_save_location')),
          ),
        ],
      ]),
    );
  }
}
