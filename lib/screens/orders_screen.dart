import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/date_labels.dart';
import 'package:http/http.dart' as http;
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/download_bytes.dart';
import '../utils/order_code.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';
import '../widgets/bill_actions_row.dart';
import '../widgets/bill_viewer.dart';
import '../widgets/cust_pay_panel.dart';

// ─── Data models ─────────────────────────────────────────────────────────────

class _DbOrder {
  final String id;
  final String number;
  /// CHANGE #548: RAW backend timestamp, verbatim.
  final String placedAt;
  final List<_DbLine> lines;
  final double total;
  /// #572 — backend-formatted money. Never rupees() in Dart.
  final String totalDisplay;
  final String status;
  /// #572 — the chip's words and colour, both decided by the backend.
  final String statusLabel;
  final String statusColor;
  /// #572 — counted server-side, not folded from lines.
  final int uniqueItemCount;
  final int unitCount;
  final bool placedByAdmin;

  _DbOrder({
    required this.id,
    required this.number,
    required this.placedAt,
    required this.lines,
    required this.total,
    required this.status,
    this.totalDisplay = '',
    this.statusLabel = '',
    this.statusColor = '',
    this.uniqueItemCount = 0,
    this.unitCount = 0,
    this.placedByAdmin = false,
  });

  /// CHANGE #572 — built from my_orders_screen(), which returns every field
  /// already decided and already formatted. Nothing is derived here: the
  /// status label, its colour, the money strings and both counts all arrive
  /// resolved. `placedAt` stays the RAW timestamp because DateLabels/ist_fmt
  /// owns every date string (#548).
  factory _DbOrder.fromPayload(Map<String, dynamic> row) => _DbOrder(
        id: (row['id'] ?? '').toString(),
        number: (row['order_code'] ?? '').toString(),
        placedAt: (row['placed_at'] ?? '').toString(),
        lines: ((row['lines'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((l) => _DbLine.fromPayload(l.cast<String, dynamic>()))
            .toList(),
        total: (row['total'] as num?)?.toDouble() ?? 0.0,
        totalDisplay: (row['total_display'] ?? '').toString(),
        status: (row['status'] ?? '').toString(),
        statusLabel: (row['status_label'] ?? '').toString(),
        statusColor: (row['status_color'] ?? '').toString(),
        uniqueItemCount: (row['unique_item_count'] as num?)?.toInt() ?? 0,
        unitCount: (row['unit_count'] as num?)?.toInt() ?? 0,
        placedByAdmin: row['placed_by_admin'] == true,
      );
}

class _DbLine {
  final String name;
  final double price;
  final int quantity;
  final double lineTotal;
  /// #572 — backend-formatted money strings.
  final String priceDisplay;
  final String lineTotalDisplay;

  const _DbLine({
    required this.name,
    required this.price,
    required this.quantity,
    required this.lineTotal,
    this.priceDisplay = '',
    this.lineTotalDisplay = '',
  });

  /// #572 — line_total arrives resolved. The old parser fell back to
  /// `price * qty` when the stored value was missing, which is the app
  /// deriving one field from two others.
  factory _DbLine.fromPayload(Map<String, dynamic> j) => _DbLine(
        name: (j['name'] ?? '').toString(),
        price: (j['price'] as num?)?.toDouble() ?? 0.0,
        quantity: (j['quantity'] as num?)?.toInt() ?? 1,
        lineTotal: (j['line_total'] as num?)?.toDouble() ?? 0.0,
        priceDisplay: (j['price_display'] ?? '').toString(),
        lineTotalDisplay: (j['line_total_display'] ?? '').toString(),
      );
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class OrdersScreen extends StatefulWidget {
  // When set (View As Customer), fetch orders for this user_id instead of currentUser.
  final String? viewAsUserId;
  // Increment to force a re-fetch (used after write-as order placement).
  final int refreshSignal;
  const OrdersScreen({super.key, this.viewAsUserId, this.refreshSignal = 0});

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<_DbOrder> _orders = [];
  bool _loading = true;
  /// #572 — empty-state copy comes from the payload, not from Dart literals.
  String _emptyTitle = '';
  String _emptyNote = '';
  /// #572 — the ACCOUNT id, as the backend resolved it. Realtime keys on this.
  String _customerId = '';
  RealtimeChannel? _channel;

  // ── CHANGE #614 ───────────────────────────────────────────────────────────
  /// Backend answers, adopted verbatim. `has_orders` decides whether the list
  /// or the empty state renders — the screen no longer decides that itself by
  /// measuring the array it just parsed.
  bool _hasOrders = false;
  bool _isAdminSession = false;
  bool _noCustomerAccount = false;

  /// The login this screen last fetched for.
  ///
  /// CHANGE #614 — this screen lives inside home_shell's IndexedStack, which
  /// keeps its State alive on purpose ("no re-fetch on tab switch"). So
  /// initState ran EXACTLY ONCE, at shell build — which for a cold open is
  /// before the session is resolved. my_customer_id() was null, the payload
  /// came back `no_customer_account: true`, and that empty list was then kept
  /// forever: switching to the tab does not rebuild the State, and realtime
  /// never started because subscribing needs the account id the empty payload
  /// did not carry. A customer with orders saw "no orders" until a full page
  /// reload. That is the bug.
  String? _authedUid;
  StreamSubscription<AuthState>? _authSub;

  @override
  void initState() {
    super.initState();
    _authedUid = Supabase.instance.client.auth.currentUser?.id;
    // CHANGE #614 — refetch whenever the ACCOUNT changes, not when a
    // particular event constant arrives. setSession(refreshToken) — the
    // WhatsApp OTP path — resolves through gotrue's token-refresh branch and
    // emits tokenRefreshed, never signedIn, so a signedIn-only listener would
    // be dead on that login exactly as in #566.
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthState);
    // #572 — subscribe only AFTER the fetch has resolved the account id; the
    // channel filter needs the account, which only the backend can tell us.
    _fetch();
  }

  void _onAuthState(AuthState _) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == _authedUid) return;
    _authedUid = uid;
    // The old channel is keyed to the previous account — drop it, and drop the
    // account id with it so nothing renders against a mismatch.
    _channel?.unsubscribe();
    _channel = null;
    _customerId = '';
    if (!mounted) return;
    setState(() => _loading = true);
    RenderLog.write('c614_orders_auth_refetch', 'uid:${uid == null ? 0 : 1}');
    _fetch();
  }

  @override
  void didUpdateWidget(OrdersScreen old) {
    super.didUpdateWidget(old);
    if (widget.refreshSignal != old.refreshSignal ||
        widget.viewAsUserId != old.viewAsUserId) {
      _fetch();
    }
  }

  @override
  void dispose() {
    _authSub?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  /// CHANGE #572 — ONE RPC, keyed to the ACCOUNT.
  ///
  /// This used to read the `orders` table directly with
  /// `.eq('user_id', currentUser.id)` — the LOGIN. An account reachable by two
  /// login methods saw only the orders placed under one of them; that is the
  /// "orders vanished" report. my_orders_screen() resolves the account itself
  /// and returns rows already sorted, counted and formatted, so there is no
  /// client-side ordering, folding or money formatting left here.
  Future<void> _fetch() async {
    try {
      final raw = await Supabase.instance.client.rpc(
        'my_orders_screen',
        params: {'p_view_as_user': widget.viewAsUserId},
      );
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) {
        if (mounted) setState(() => _loading = false);
        return;
      }
      final payload = map.cast<String, dynamic>();
      if (!mounted) return;
      final parsed = ((payload['orders'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((r) => _DbOrder.fromPayload(r.cast<String, dynamic>()))
          .toList();
      RenderLog.write('orders_fetched',
          'count:${parsed.length}${widget.viewAsUserId != null ? ':viewas' : ''}');
      setState(() {
        _orders = parsed;
        _emptyTitle = (payload['empty_title'] ?? '').toString();
        _emptyNote = (payload['empty_note'] ?? '').toString();
        _customerId = (payload['customer_id'] ?? '').toString();
        // CHANGE #614 — the backend already said whether there are orders and
        // what kind of session this is. Read those; do not re-derive them.
        _hasOrders = payload['has_orders'] == true;
        _isAdminSession = payload['is_admin_session'] == true;
        _noCustomerAccount = payload['no_customer_account'] == true;
        _loading = false;
      });
      RenderLog.write('c614_orders_payload',
          'has:${_hasOrders ? 1 : 0};admin:${_isAdminSession ? 1 : 0};nocust:${_noCustomerAccount ? 1 : 0}');
      if (_channel == null) _subscribeRealtime();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// #572 — keyed to the ACCOUNT, like the fetch. Filtering on user_id meant a
  /// change to an order placed under the account's OTHER login never triggered
  /// a refresh. Realtime is only a refetch trigger: the callback re-runs the
  /// RPC rather than parsing the row, so the backend stays the only answer.
  void _subscribeRealtime() {
    if (widget.viewAsUserId != null) return; // no realtime in view-as mode
    final accountId = _customerId;
    if (accountId.isEmpty) return;
    _channel?.unsubscribe();
    _channel = Supabase.instance.client
        .channel('customer_orders_$accountId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'customer_id',
            value: accountId,
          ),
          callback: (_) => _fetch(),
        )
        .subscribe();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // CHANGE #614 — `has_orders` is the backend's answer; the screen used to
    // decide this itself with `_orders.isEmpty`. Same result on the happy
    // path, but it is not the app's question to answer.
    //
    // This branch also covers the admin login: the backend sends
    // is_admin_session + no_customer_account with empty_title "Admin account"
    // and a note pointing at the admin Orders tab, and both print verbatim —
    // no blank screen, no crash, nothing worded in Dart.
    if (!_hasOrders) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.25),
            Icon(Icons.receipt_long_outlined,
                size: 64, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            // #572 — empty-state copy printed verbatim from the payload.
            Center(child: Text(_emptyTitle)),
            const SizedBox(height: 4),
            Center(
              child: Text(_emptyNote,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        physics: platformScrollPhysics(),
        itemCount: _orders.length,
        itemBuilder: (context, i) => _OrderCard(order: _orders[i]),
      ),
    );
  }
}

// ─── Order card ───────────────────────────────────────────────────────────────
// CHANGE #446 — expands into an Items / Bill / Payment accordion, backed by
// ONE call to cust_order_panel(order_id). The frontend only displays strings
// the RPC returns and sends user input to RPCs — no currency/date/percent formatting here.

class _OrderCard extends StatefulWidget {
  final _DbOrder order;
  const _OrderCard({required this.order});

  @override
  State<_OrderCard> createState() => _OrderCardState();
}

class _OrderCardState extends State<_OrderCard> {
  Map<String, dynamic>? _panel;
  bool _loading = false;
  String? _error;
  // CHANGE #458: null = nothing open (static card, no auto-expand). 0=Items 1=Payment 2=Bill.
  // A single int? enforces "only one section open at once" by construction — never
  // independent per-section booleans that could disagree.
  int? _tab;

  // CHANGE #458 B3: tapping the open button again closes it; tapping a different
  // button switches to it (closing whatever was open) — never two sections at once.
  // CHANGE #463: Bill (tab 2) no longer needs cust_order_panel — _BillTab now
  // fetches customer_bill_file() itself — so skip the shared panel load for it.
  void _toggleTab(int tab) {
    final opening = _tab != tab;
    setState(() => _tab = opening ? tab : null);
    if (opening && tab != 2 && _panel == null && !_loading) _loadPanel();
  }

  // CHANGE #548: backend-formatted (ist_fmt 'dmy_hm2'); no Dart date math.
  String _date(String ts) =>
      DateLabels.instance.label(ts, DateStyle.dmyHm2) ?? '';

  Future<void> _loadPanel() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('cust_order_panel', params: {'p_order_id': widget.order.id});
      final panel = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final items = (panel['items'] as List?) ?? [];
      final bill = Map<String, dynamic>.from(panel['bill'] as Map? ?? {});
      final payment = Map<String, dynamic>.from(panel['payment'] as Map? ?? {});
      final advance = Map<String, dynamic>.from(payment['advance'] as Map? ?? {});
      final upi = Map<String, dynamic>.from(payment['upi'] as Map? ?? {});
      RenderLog.write('c446_expanded', 1);
      RenderLog.write('c446_items', items.length);
      if (items.isNotEmpty) {
        final first = Map<String, dynamic>.from(items.first as Map);
        RenderLog.write('c446_first_item', first['name']?.toString() ?? '');
        RenderLog.write('c446_first_qty', first['qty_label']?.toString() ?? '');
      }
      RenderLog.write('c446_bill_ready', bill['ready'] == true);
      RenderLog.write('c446_bill_reason', bill['reason_label']?.toString() ?? '');
      RenderLog.write('c446_advance_label', advance['expected_label']?.toString() ?? '');
      RenderLog.write('c446_upi_present', (upi['vpa'] != null) ? 1 : 0);
      setState(() {
        _panel = panel;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not load order details.';
          _loading = false;
        });
      }
    }
  }

  // CHANGE #458: static card — no ExpansionTile, no whole-card tap target.
  // B1: header trimmed to Order ID, Date & Time, Status, Total (₹), and
  // "Placed by admin" only when true — no pack count, no MRP.
  // B2: Items | Payment | Bill render as three always-visible equal-width
  // buttons. B3: tapping one opens ONLY that section (closes any other);
  // tapping the open one again closes it; tapping the card body elsewhere
  // does nothing — there is no gesture handler on the body at all.
  // CHANGE #459: header reflow — left column is Date & Time over Order ID;
  // right column is Status chip over "Placed by admin" (admin-placed only,
  // otherwise nothing — no chip, no reserved gap). No total amount and no MRP
  // anywhere on this card (PTR isn't available yet, so no price shows here at
  // all — per Om, remove total from the header).
  // CHANGE #460: left circle restored (same size/style/position as the
  // original receipt-icon avatar).
  // CHANGE #461: circle content is now the count of unique line items
  // (distinct products) in the order — order.lines.length, from the SAME
  // items list already fetched for the orders list (each _DbLine is one
  // distinct product; quantity per line is separate). NOT order.itemCount
  // (that sums quantities — the old "N packs" metric this card dropped in
  // #458). No new query — FittedBox shrinks the text so 1/2/3-digit counts
  // all fit without overflow.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final order = widget.order;
    // #572 — counted by the backend (unique_item_count), not by measuring the
    // lines list on the client.
    final uniqueItemCount = order.uniqueItemCount.toString();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Text(uniqueItemCount,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.onPrimaryContainer)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Date & Time
                Text(_date(order.placedAt), style: const TextStyle(color: Color(0xFF6B7280))),
                const SizedBox(height: 2),
                // Order ID (canonical CPO-format display id) — ellipsize, never overflow.
                Text(order.number,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
            ),
            const SizedBox(width: 8),
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Status
                _StatusChip(
                  status: order.status,
                  label: order.statusLabel,
                  colorHex: order.statusColor,
                ),
                if (order.placedByAdmin) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEF3C7),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('Placed by admin',
                        style: TextStyle(
                            fontSize: 10,
                            color: Color(0xFF92400E),
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ],
            ),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: _TabButton(label: 'Items', selected: _tab == 0, onTap: () => _toggleTab(0)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TabButton(label: 'Payment', selected: _tab == 1, onTap: () => _toggleTab(1)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TabButton(label: 'Bill', selected: _tab == 2, onTap: () => _toggleTab(2)),
            ),
          ]),
          if (_tab != null) ...[
            const SizedBox(height: 12),
            _buildSectionContent(),
          ],
        ]),
      ),
    );
  }

  Widget _buildSectionContent() {
    // CHANGE #463: Bill (tab 2) is independent of cust_order_panel now — it
    // fetches customer_bill_file() itself — so it must not sit behind the
    // _loading/_panel gate below (that's Items/Payment's own loading state,
    // untouched).
    // CHANGE #464: "Upload Bill" moved off this card entirely (now
    // admin-Customer-Orders-tab only) — no upload-triggered refresh needed
    // here anymore, so a plain per-order key is enough.
    if (_tab == 2) {
      return _BillTab(key: ValueKey(widget.order.id), orderId: widget.order.id);
    }
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();
    final header = Map<String, dynamic>.from(panel['header'] as Map? ?? {});
    final items = ((panel['items'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final orderId = (header['order_id'] ?? widget.order.id).toString();

    switch (_tab) {
      case 0:
        return _ItemsTab(items: items);
      case 1:
        return CustPayPanel(key: ValueKey(orderId), orderId: orderId, orderCode: widget.order.number);
      default:
        return const SizedBox.shrink();
    }
  }
}

// CHANGE #458 — Items/Payment/Bill accordion button. Meant to be wrapped in
// Expanded so three of these fill the card width equally; content is centered
// since the box now stretches instead of shrinking to the label.
class _TabButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _TabButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : const Color(0xFF374151))),
      ),
    );
  }
}

// ─── Items tab ──────────────────────────────────────────────────────────────

class _ItemsTab extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  const _ItemsTab({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('No items.', style: TextStyle(color: Color(0xFF9CA3AF))),
      );
    }
    return Column(children: items.map((it) => _itemRow(it)).toList());
  }

  Widget _itemRow(Map<String, dynamic> it) {
    final imageUrl = it['image_url']?.toString();
    final name = it['name']?.toString() ?? '';
    final company = it['company']?.toString();
    final packLabel = it['pack_label']?.toString();
    final qtyLabel = it['qty_label']?.toString();
    final rateLabel = it['rate_label']?.toString();
    final lineLabel = it['line_label']?.toString();
    final statusLabel = it['status_label']?.toString();
    final statusOk = it['status_ok'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _itemPhoto(imageUrl),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name,
                maxLines: 2, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            if (company != null && company.isNotEmpty)
              Text(company,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            if (packLabel != null && packLabel.isNotEmpty)
              Text(packLabel,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
            const SizedBox(height: 6),
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 4, children: [
              if (qtyLabel != null && qtyLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(6)),
                  child: Text(qtyLabel, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                ),
              if (rateLabel != null && rateLabel.isNotEmpty)
                Text(rateLabel, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              if (lineLabel != null && lineLabel.isNotEmpty)
                Text(lineLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              if (statusLabel != null && statusLabel.isNotEmpty) _itemStatusChip(statusLabel, statusOk),
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _itemPhoto(String? url) {
    const size = 56.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: size, height: size,
        child: (url == null || url.isEmpty)
            ? Container(
                color: const Color(0xFFF3F4F6),
                alignment: Alignment.center,
                child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
              )
            : Image.network(
                url,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: 112,
                loadingBuilder: (_, child, prog) => prog == null
                    ? child
                    : Container(
                        color: const Color(0xFFF3F4F6),
                        alignment: Alignment.center,
                        child: const SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD1D5DB))),
                      ),
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFFF3F4F6),
                  alignment: Alignment.center,
                  child: const Icon(Icons.medication_outlined, size: 24, color: Color(0xFFD1D5DB)),
                ),
              ),
      ),
    );
  }

  Widget _itemStatusChip(String label, bool ok) {
    final color = ok ? const Color(0xFF16A34A) : const Color(0xFFD97706);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }
}

// ─── Bill tab ───────────────────────────────────────────────────────────────

// CHANGE #451 — schema-driven GST invoice table. Every string on screen comes
// straight from cust_order_panel().bill; nothing is formatted or computed here.
// CHANGE #463 Part B: the Bill tab's data source — customer_bill_file(), the
// admin-uploaded file, instead of #462's computed customer_bill() invoice.
// Self-fetching (StatefulWidget) since it no longer rides on _OrderCardState's
// cust_order_panel load.
class _BillTab extends StatefulWidget {
  final String orderId;
  const _BillTab({super.key, required this.orderId});

  @override
  State<_BillTab> createState() => _BillTabState();
}

class _BillTabState extends State<_BillTab> {
  Map<String, dynamic>? _fileInfo;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_bill_file', params: {'p_order_id': widget.orderId});
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (mounted) setState(() { _fileInfo = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Could not load the bill.'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final info = _fileInfo ?? const <String, dynamic>{};
    final hasFile = info['has_file'] == true;

    if (!hasFile) {
      // #463 Part B: has_file==false — do NOT collapse; show the message and
      // the same three actions, all disabled. #466: message (the "preview"
      // slot when there's nothing to preview yet) above the disabled actions,
      // matching the has_file layout's preview-then-buttons order.
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Column(children: [
            Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFFD1D5DB)),
            SizedBox(height: 12),
            Text("We're processing your order — the bill will appear shortly.",
                textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
          ]),
        ),
        Row(children: [
          Expanded(
              child: BillActionButton(
                  icon: Icons.download_outlined, label: 'Download', enabled: false, onTap: () {})),
          const SizedBox(width: 8),
          Expanded(
              child: BillActionButton(
                  icon: Icons.chat_bubble_outline, label: 'WhatsApp', enabled: false, onTap: () {})),
          const SizedBox(width: 8),
          Expanded(
              child:
                  BillActionButton(icon: Icons.share_outlined, label: 'Share', enabled: false, onTap: () {})),
        ]),
      ]);
    }

    final bucket = info['bucket']?.toString() ?? 'customer-bills';
    final path = info['path']?.toString() ?? '';
    final name = info['name']?.toString() ?? 'Bill';

    // #466: preview ABOVE, actions BELOW (was reversed in #465 — the actions
    // rendered first with the (blank-on-load-failure) preview underneath).
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      BillFilePreview(key: ValueKey('$bucket/$path'), bucket: bucket, path: path, name: name),
      const SizedBox(height: 14),
      UploadedBillActionsRow(orderId: widget.orderId, bucket: bucket, path: path, fileName: name),
    ]);
  }
}

// CHANGE #463: the customer Bill tab now shows the admin-UPLOADED bill file
// (see the new _BillTab below) instead of this computed tax-invoice preview.
// Per explicit product decision, this class is kept exactly as #462 left it —
// untouched, just renamed and unreferenced — rather than deleted, in case a
// computed-invoice view is wanted again later.
class _ComputedInvoiceTab extends StatelessWidget {
  final Map<String, dynamic> bill;
  final String orderId;
  const _ComputedInvoiceTab({required this.bill, required this.orderId});

  // CHANGE #462: ready==true renders the invoice preview from customer_bill()
  // verbatim — unchanged below. ready==false no longer collapses the area: it
  // shows the returned message AND the same three actions, disabled.
  @override
  Widget build(BuildContext context) {
    final ready = bill['ready'] == true;
    RenderLog.write('c451_bill_ready', ready);

    if (!ready) {
      final message = bill['message']?.toString() ?? '';
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _BillActionsRow(ready: false, orderId: orderId, invoiceNumber: null),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(children: [
            const Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFFD1D5DB)),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
          ]),
        ),
      ]);
    }

    final invoice = Map<String, dynamic>.from(bill['invoice'] as Map? ?? {});
    final columns = ((bill['columns'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final lines = ((bill['lines'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final totals = Map<String, dynamic>.from(bill['totals'] as Map? ?? {});
    final gstSummary = ((bill['gst_summary'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final seller = Map<String, dynamic>.from(invoice['seller'] as Map? ?? {});
    final buyer = Map<String, dynamic>.from(invoice['buyer'] as Map? ?? {});
    final sellerWarning = seller['warning']?.toString();

    RenderLog.write('c451_cols', columns.length);
    RenderLog.write('c451_rows', lines.length);
    RenderLog.write('c451_net', totals['net_payable_label']?.toString() ?? '');
    RenderLog.write('c451_remaining', totals['remaining_label']?.toString() ?? '');
    RenderLog.write('c451_seller_warning', (sellerWarning != null && sellerWarning.isNotEmpty) ? 1 : 0);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _BillActionsRow(ready: true, orderId: orderId, invoiceNumber: invoice['number']?.toString()),
      const SizedBox(height: 14),
      _invoiceHeader(invoice, seller, buyer, sellerWarning),
      const SizedBox(height: 14),
      _invoiceTable(columns, lines),
      const SizedBox(height: 16),
      _totalsBlock(totals),
      if (gstSummary.isNotEmpty) ...[
        const SizedBox(height: 16),
        _gstSummaryTable(gstSummary),
      ],
    ]);
  }

  // ── B2: invoice header ──────────────────────────────────────────────────

  Widget _invoiceHeader(
    Map<String, dynamic> invoice,
    Map<String, dynamic> seller,
    Map<String, dynamic> buyer,
    String? sellerWarning,
  ) {
    final sellerLine = [seller['address'], seller['state']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .toList();
    final sellerMeta = <String>[
      if (seller['gstin'] != null && seller['gstin'].toString().isNotEmpty) 'GSTIN: ${seller['gstin']}',
      if (seller['dl'] != null && seller['dl'].toString().isNotEmpty) 'DL: ${seller['dl']}',
    ];
    final buyerLine = [buyer['address'], buyer['phone']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .toList();
    final buyerMeta = <String>[
      if (buyer['gstin'] != null && buyer['gstin'].toString().isNotEmpty) 'GSTIN: ${buyer['gstin']}',
      if (buyer['dl'] != null && buyer['dl'].toString().isNotEmpty) 'DL: ${buyer['dl']}',
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Text('TAX INVOICE', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          if (invoice['number'] != null)
            Text(invoice['number'].toString(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(seller['name']?.toString() ?? '',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
          ),
          if (invoice['date'] != null)
            Text('Date: ${invoice['date']}', style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
        ]),
        if (sellerLine.isNotEmpty || sellerMeta.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text([...sellerLine, ...sellerMeta].join(' | '),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
          ),
        if (sellerWarning != null && sellerWarning.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(color: const Color(0xFFFEF2F2), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFFCA5A5))),
            child: Text(sellerWarning, style: const TextStyle(fontSize: 11.5, color: Color(0xFFB91C1C), fontWeight: FontWeight.w600)),
          ),
        ],
        const SizedBox(height: 10),
        if (buyer['name'] != null)
          Text('Billed to: ${buyer['name']}', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
        if (buyerLine.isNotEmpty || buyerMeta.isNotEmpty)
          Text([...buyerLine, ...buyerMeta].join(' | '), style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
      ]),
    );
  }

  // ── B3: the table ────────────────────────────────────────────────────────

  Widget _invoiceTable(List<Map<String, dynamic>> columns, List<Map<String, dynamic>> lines) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        border: TableBorder.all(color: const Color(0xFFE5E7EB), width: 0.5),
        headingRowColor: const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
        headingTextStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF374151)),
        columnSpacing: 18,
        horizontalMargin: 10,
        columns: columns
            .map((c) => DataColumn(
                  label: Text(c['label']?.toString() ?? ''),
                  numeric: c['align'] == 'right',
                ))
            .toList(),
        rows: List<DataRow>.generate(lines.length, (i) {
          final line = lines[i];
          return DataRow(
            color: WidgetStatePropertyAll(i.isOdd ? const Color(0xFFFAFAFA) : Colors.white),
            cells: columns.map((c) {
              final key = c['key']?.toString() ?? '';
              final value = line[key]?.toString() ?? '';
              if (key == 'product') {
                final company = line['company']?.toString();
                return DataCell(Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(value),
                    if (company != null && company.isNotEmpty)
                      Text(company, style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
                  ],
                ));
              }
              return DataCell(Text(value));
            }).toList(),
          );
        }),
      ),
    );
  }

  // ── B4: totals block ────────────────────────────────────────────────────

  Widget _totalsBlock(Map<String, dynamic> totals) {
    Widget row(String label, dynamic value, {bool bold = false, double size = 12.5}) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          Text(label, style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.normal, color: const Color(0xFF6B7280))),
          const SizedBox(width: 16),
          SizedBox(
            width: 130,
            child: Text(value.toString(),
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w600, color: const Color(0xFF111827))),
          ),
        ]),
      );
    }

    final youSaveLabel = totals['you_save_label']?.toString();
    final inWords = totals['in_words']?.toString();

    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      row('PTR Total', totals['ptr_total_label']),
      row(totals['discount_label']?.toString() ?? 'Discount', totals['discount_amount_label']),
      row('Net Taxable', totals['taxable_label'], bold: true),
      row('CGST', totals['cgst_label']),
      row('SGST', totals['sgst_label']),
      row('Round Off', totals['round_off_label']),
      const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
      row('NET PAYABLE', totals['net_payable_label'], bold: true, size: 15),
      row('Less: Advance paid', totals['paid_label']),
      row('BALANCE DUE', totals['remaining_label'], bold: true, size: 15),
      if (inWords != null && inWords.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text('Amount in words: $inWords',
            textAlign: TextAlign.right,
            style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic, color: Color(0xFF6B7280))),
      ],
      if (youSaveLabel != null && youSaveLabel.isNotEmpty) ...[
        const SizedBox(height: 4),
        Text(youSaveLabel, style: const TextStyle(fontSize: 11.5, color: Color(0xFF16A34A), fontWeight: FontWeight.w600)),
      ],
    ]);
  }

  // ── B5: GST summary ─────────────────────────────────────────────────────

  Widget _gstSummaryTable(List<Map<String, dynamic>> gstSummary) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        border: TableBorder.all(color: const Color(0xFFE5E7EB), width: 0.5),
        headingRowColor: const WidgetStatePropertyAll(Color(0xFFF3F4F6)),
        headingTextStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
        dataTextStyle: const TextStyle(fontSize: 11.5, color: Color(0xFF374151)),
        columnSpacing: 18,
        horizontalMargin: 10,
        columns: const [
          DataColumn(label: Text('Rate')),
          DataColumn(label: Text('Taxable'), numeric: true),
          DataColumn(label: Text('CGST'), numeric: true),
          DataColumn(label: Text('SGST'), numeric: true),
          DataColumn(label: Text('Total'), numeric: true),
        ],
        rows: gstSummary
            .map((g) => DataRow(cells: [
                  DataCell(Text(g['rate']?.toString() ?? '')),
                  DataCell(Text(g['taxable']?.toString() ?? '')),
                  DataCell(Text(g['cgst']?.toString() ?? '')),
                  DataCell(Text(g['sgst']?.toString() ?? '')),
                  DataCell(Text(g['total']?.toString() ?? '')),
                ]))
            .toList(),
      ),
    );
  }
}

// ── B6: Bill actions — Download / Send to WhatsApp / Share ───────────────────
// CHANGE #462: three equal-width buttons above the preview (was a single
// "Download Bill" button below it). Enabled only when the bill is ready;
// _BillTab passes ready==false with orderItems/invoiceNumber absent so all
// three render disabled instead of the section collapsing entirely.

class _BillActionsRow extends StatefulWidget {
  final bool ready;
  final String orderId;
  final String? invoiceNumber;
  const _BillActionsRow({required this.ready, required this.orderId, required this.invoiceNumber});

  @override
  State<_BillActionsRow> createState() => _BillActionsRowState();
}

class _BillActionsRowState extends State<_BillActionsRow> {
  bool _downloading = false;
  bool _sharing = false;
  // #462: only ONE floating popup at a time — remove any existing entry
  // before creating a new one, and clean up on dispose (an OverlayEntry isn't
  // auto-removed when its host widget is torn down).
  OverlayEntry? _waPopupEntry;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c451_pdf_wired', 1);
  }

  @override
  void dispose() {
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    super.dispose();
  }

  String _filenameFrom(http.Response resp) {
    final cd = resp.headers['content-disposition'];
    if (cd != null) {
      final m = RegExp(r'filename="?([^";]+)"?').firstMatch(cd);
      if (m != null) return m.group(1)!;
    }
    return 'Invoice-${widget.invoiceNumber ?? widget.orderId}.pdf';
  }

  // Shared PDF fetch for ① Download and ③ Share — same bill-pdf endpoint the
  // preview data comes from; the backend renders exactly what customer_bill()
  // returns, no client-side layout/math.
  Future<({List<int> bytes, String filename})?> _fetchBillPdf() async {
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final resp = await http.post(
        Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/bill-pdf'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'order_id': widget.orderId}),
      );
      if (resp.statusCode != 200) {
        String message = 'Could not load the bill.';
        try {
          final decoded = jsonDecode(resp.body);
          if (decoded is Map) {
            message = decoded['message']?.toString() ?? decoded['error']?.toString() ?? message;
          }
        } catch (_) {}
        if (mounted) showToast(context, message, isError: true);
        return null;
      }
      return (bytes: resp.bodyBytes, filename: _filenameFrom(resp));
    } catch (_) {
      if (mounted) showToast(context, 'Could not load the bill.', isError: true);
      return null;
    }
  }

  // ① Download — direct save, no account picker: downloadBytes() is a plain
  // <a download> anchor click, never an OAuth/account-chooser flow.
  Future<void> _download() async {
    if (_downloading || !widget.ready) return;
    setState(() => _downloading = true);
    final file = await _fetchBillPdf();
    if (mounted) setState(() => _downloading = false);
    if (file == null) return;
    downloadBytes(file.bytes, file.filename, 'application/pdf');
  }

  // ③ Share — native OS share sheet (Web Share API) with the SAME PDF file as
  // Download. shareBytes() returns null only when this browser has no
  // file-share support at all (then fall back to a direct download); it
  // returns false on user-cancel, which must stay silent — no fallback, no
  // error toast, matching normal native share-sheet UX.
  Future<void> _share() async {
    if (_sharing || !widget.ready) return;
    setState(() => _sharing = true);
    final file = await _fetchBillPdf();
    if (file == null) {
      if (mounted) setState(() => _sharing = false);
      return;
    }
    final result = await shareBytes(file.bytes, file.filename, 'application/pdf');
    if (mounted) setState(() => _sharing = false);
    if (result == null) downloadBytes(file.bytes, file.filename, 'application/pdf');
  }

  // ② Send Bill to WhatsApp — mini floating popup anchored near this button
  // (never a center/full-screen dialog), dismissed on outside tap.
  void _showWaPopup(BuildContext buttonContext) {
    if (!widget.ready) return;
    _waPopupEntry?.remove();
    _waPopupEntry = null;
    final box = buttonContext.findRenderObject() as RenderBox?;
    if (box == null || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    final screenW = MediaQuery.of(buttonContext).size.width;
    const popupW = 260.0;
    final left = (topLeft.dx + box.size.width / 2 - popupW / 2)
        .clamp(12.0, math.max(12.0, screenW - popupW - 12.0))
        .toDouble();
    final top = topLeft.dy + box.size.height + 6;

    void dismiss() {
      _waPopupEntry?.remove();
      _waPopupEntry = null;
    }

    _waPopupEntry = OverlayEntry(builder: (_) => Stack(children: [
      Positioned.fill(
        child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: dismiss),
      ),
      Positioned(
        top: top,
        left: left,
        width: popupW,
        child: Material(
          borderRadius: BorderRadius.circular(12),
          elevation: 8,
          color: Colors.white,
          child: _WaNumberPicker(
            orderId: widget.orderId,
            onDismiss: dismiss,
            onResult: (message, isError) {
              if (mounted) showToast(context, message, isError: isError);
            },
          ),
        ),
      ),
    ]));
    Overlay.of(buttonContext).insert(_waPopupEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: _BillActionButton(
          icon: Icons.download_outlined,
          label: _downloading ? 'Downloading…' : 'Download',
          enabled: widget.ready && !_downloading,
          loading: _downloading,
          onTap: _download,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Builder(builder: (btnContext) => _BillActionButton(
              icon: Icons.chat_bubble_outline,
              label: 'WhatsApp',
              enabled: widget.ready,
              onTap: () => _showWaPopup(btnContext),
            )),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _BillActionButton(
          icon: Icons.share_outlined,
          label: _sharing ? 'Sharing…' : 'Share',
          enabled: widget.ready && !_sharing,
          loading: _sharing,
          onTap: _share,
        ),
      ),
    ]);
  }
}

class _BillActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final bool loading;
  final VoidCallback onTap;
  const _BillActionButton({
    required this.icon,
    required this.label,
    required this.enabled,
    this.loading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFF1B7A43) : const Color(0xFF9CA3AF);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFE8F5E9) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: enabled ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading)
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          else
            Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          ),
        ]),
      ),
    );
  }
}

// CHANGE #462 — ② popup content: numbers from customer_bill_numbers (already
// last-used-first), tap one to send via send_customer_bill_wa. Only ONE send
// in flight at a time (_sendingPhone non-null disables every row, not just
// the tapped one). Results are reported back to the parent's onResult AFTER
// onDismiss, using the parent's own (longer-lived) context — this widget's
// own context becomes invalid the instant the popup's OverlayEntry is removed.
class _WaNumberPicker extends StatefulWidget {
  final String orderId;
  final VoidCallback onDismiss;
  final void Function(String message, bool isError) onResult;
  const _WaNumberPicker({required this.orderId, required this.onDismiss, required this.onResult});

  @override
  State<_WaNumberPicker> createState() => _WaNumberPickerState();
}

class _WaNumberPickerState extends State<_WaNumberPicker> {
  List<Map<String, dynamic>>? _numbers;
  String? _error;
  String? _sendingPhone;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_bill_numbers', params: {'p_order_id': widget.orderId});
      final list = (raw is List ? raw : const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (mounted) setState(() => _numbers = list);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not load numbers.');
    }
  }

  Future<void> _send(String phone) async {
    if (_sendingPhone != null) return;
    setState(() => _sendingPhone = phone);
    String message;
    bool isError;
    try {
      final raw = await Supabase.instance.client.rpc('send_customer_bill_wa',
          params: {'p_order_id': widget.orderId, 'p_phone': phone});
      final res = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (res['status'] == 'queued') {
        message = 'Bill sent to $phone on WhatsApp';
        isError = false;
      } else if (res['error'] == 'no_bill_uploaded') {
        // #463: send_customer_bill_wa now gates on the uploaded file
        // (orders.cust_bill_path), not the old computed-invoice readiness.
        message = 'Upload a bill first';
        isError = true;
      } else if (res['error'] == 'bill_not_ready') {
        message = 'Bill not ready yet';
        isError = true;
      } else if (res['error'] == 'bad_phone') {
        message = 'Invalid number';
        isError = true;
      } else {
        message = 'Could not send the bill';
        isError = true;
      }
    } catch (_) {
      message = 'Could not send the bill';
      isError = true;
    }
    widget.onDismiss();
    widget.onResult(message, isError);
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 280),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text('Send bill to',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          ),
          const SizedBox(height: 4),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
            )
          else if (_numbers == null)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Center(
                  child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else if (_numbers!.isEmpty)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text('No saved number for this customer',
                  style: TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
            )
          else
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: _numbers!.asMap().entries.map((e) {
                    final idx = e.key;
                    final phone = e.value['phone']?.toString() ?? '';
                    final busy = _sendingPhone == phone;
                    return InkWell(
                      onTap: _sendingPhone == null ? () => _send(phone) : null,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                        child: Row(children: [
                          const Icon(Icons.chat_bubble, size: 16, color: Color(0xFF1B7A43)),
                          const SizedBox(width: 8),
                          Expanded(
                              child: Text(phone,
                                  style: const TextStyle(fontSize: 13.5, color: Color(0xFF111827)))),
                          if (idx == 0)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                  color: const Color(0xFFE8F5E9), borderRadius: BorderRadius.circular(4)),
                              child: const Text('last used',
                                  style: TextStyle(
                                      fontSize: 9.5, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                            ),
                          if (busy) ...[
                            const SizedBox(width: 8),
                            const SizedBox(
                                width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                          ],
                        ]),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}


// ─── Status chip ──────────────────────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final String status;
  final String label;
  final String colorHex;
  const _StatusChip({
    required this.status,
    required this.label,
    required this.colorHex,
  });

  /// Parses '#RRGGBB' from the backend. Not a decision — a hex string is not a
  /// Dart Color until something converts it.
  static Color _hexColor(String hex, {required Color fallback}) {
    final h = hex.replaceFirst('#', '').trim();
    if (h.length != 6) return fallback;
    final v = int.tryParse(h, radix: 16);
    return v == null ? fallback : Color(0xFF000000 | v);
  }

  @override
  Widget build(BuildContext context) {
    // #572 — the chip no longer switch-cases the status into a label and a
    // colour. Both arrive decided from order_status_config, so adding a status
    // or recolouring one is an UPDATE in app_settings, not a deploy.
    final color = _hexColor(colorHex, fallback: Colors.orange);
    return Container(
      margin: const EdgeInsets.only(top: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
