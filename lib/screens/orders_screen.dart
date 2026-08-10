import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../fulfill/fulfill_lookups.dart'; // C629: backend-owned button copy
import '../services/date_labels.dart';
import 'delivery/customer_track_sheet.dart'; // C629: PART F1 — live tracking
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
import '../widgets/customer_order_item_card.dart'; // #641: the Items-tab card
import '../services/ui_copy.dart';

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

  // ── CHANGE #625 — the items we could not source ───────────────────────────
  /// Items separated out when the inquiry finished. They are never deleted —
  /// the customer still sees them — but they no longer go to Pack or the bill,
  /// and the order total already excludes them. Every field below is decided
  /// and worded server-side; `has_unfulfilled` is the ONLY thing that decides
  /// whether the section exists, and the app does not re-derive it by
  /// measuring `unfulfilledLines`.
  final List<_DbLine> unfulfilledLines;
  final bool hasUnfulfilled;
  final int unfulfilledCount;
  final String unfulfilledTitle;
  final String unfulfilledLabel;
  final String unfulfilledNote;
  final bool unfulfilledCollapsed;
  /// Every item on the order, fulfilled or not. Counted server-side.
  final int totalItemCount;

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
    this.unfulfilledLines = const [],
    this.hasUnfulfilled = false,
    this.unfulfilledCount = 0,
    this.unfulfilledTitle = '',
    this.unfulfilledLabel = '',
    this.unfulfilledNote = '',
    this.unfulfilledCollapsed = true,
    this.totalItemCount = 0,
  });

  /// One parser for both arrays — they carry identical row shapes, so there is
  /// exactly one place that can get a line wrong.
  static List<_DbLine> _linesOf(dynamic raw) =>
      ((raw as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((l) => _DbLine.fromPayload(l.cast<String, dynamic>()))
          .toList();

  /// CHANGE #572 — built from my_orders_screen(), which returns every field
  /// already decided and already formatted. Nothing is derived here: the
  /// status label, its colour, the money strings and both counts all arrive
  /// resolved. `placedAt` stays the RAW timestamp because DateLabels/ist_fmt
  /// owns every date string (#548).
  factory _DbOrder.fromPayload(Map<String, dynamic> row) => _DbOrder(
        id: (row['id'] ?? '').toString(),
        number: (row['order_code'] ?? '').toString(),
        placedAt: (row['placed_at'] ?? '').toString(),
        lines: _linesOf(row['lines']),
        total: (row['total'] as num?)?.toDouble() ?? 0.0,
        totalDisplay: (row['total_display'] ?? '').toString(),
        status: (row['status'] ?? '').toString(),
        statusLabel: (row['status_label'] ?? '').toString(),
        statusColor: (row['status_color'] ?? '').toString(),
        uniqueItemCount: (row['unique_item_count'] as num?)?.toInt() ?? 0,
        unitCount: (row['unit_count'] as num?)?.toInt() ?? 0,
        placedByAdmin: row['placed_by_admin'] == true,
        // #625 — adopted verbatim, including the decision to show the section
        // at all and the decision to start it collapsed.
        unfulfilledLines: _linesOf(row['unfulfilled_lines']),
        hasUnfulfilled: row['has_unfulfilled'] == true,
        unfulfilledCount: (row['unfulfilled_count'] as num?)?.toInt() ?? 0,
        unfulfilledTitle: (row['unfulfilled_title'] ?? '').toString(),
        unfulfilledLabel: (row['unfulfilled_label'] ?? '').toString(),
        unfulfilledNote: (row['unfulfilled_note'] ?? '').toString(),
        unfulfilledCollapsed: row['unfulfilled_collapsed'] != false,
        totalItemCount: (row['total_item_count'] as num?)?.toInt() ?? 0,
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
  /// #625 — the item chip's words and both its colours, all decided by the
  /// backend. On a fulfilled line this is the inquiry status ("Available"); on
  /// an unfulfilled one it is the reason we could not source it ("No supplier
  /// available"). Dart never maps a status to a colour or rewrites the words.
  final String statusText;
  final String statusBg;
  final String statusFg;

  // ── CHANGE #641 — the rich item fields ────────────────────────────────────
  /// Everything the Items card renders: image, company, pack, qty/rate/line
  /// labels and the status chip, all decided and formatted server-side. Parsed
  /// by `CustomerOrderItem.fromPayload`, which is the single parser for both
  /// `lines` and `unfulfilled_lines`.
  final CustomerOrderItem item;

  const _DbLine({
    required this.name,
    required this.price,
    required this.quantity,
    required this.lineTotal,
    this.priceDisplay = '',
    this.lineTotalDisplay = '',
    this.statusText = '',
    this.statusBg = '',
    this.statusFg = '',
    this.item = const CustomerOrderItem(),
  });

  /// #572 — line_total arrives resolved. The old parser fell back to
  /// `price * qty` when the stored value was missing, which is the app
  /// deriving one field from two others.
  factory _DbLine.fromPayload(Map<String, dynamic> j) {
    final colors = j['status_colors'] is Map
        ? (j['status_colors'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return _DbLine(
      name: (j['name'] ?? '').toString(),
      price: (j['price'] as num?)?.toDouble() ?? 0.0,
      quantity: (j['quantity'] as num?)?.toInt() ?? 1,
      lineTotal: (j['line_total'] as num?)?.toDouble() ?? 0.0,
      priceDisplay: (j['price_display'] ?? '').toString(),
      lineTotalDisplay: (j['line_total_display'] ?? '').toString(),
      statusText: (j['status_text'] ?? '').toString(),
      statusBg: (colors['bg'] ?? '').toString(),
      statusFg: (colors['fg'] ?? '').toString(),
      // #641 — the rich half of the same row, parsed in exactly one place.
      item: CustomerOrderItem.fromPayload(j),
    );
  }
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

  /// CHANGE #619 — one key, every outcome: ok / threw / badshape, with the
  /// attempt number, whether a session was attached, and what came back.
  /// #614 logged only success, so the failure that actually shipped was
  /// invisible in the render-log.
  static const kC622Fetch = 'c622_orders_fetch';
  static const int _kMaxFetchRetries = 3;
  Timer? _retryTimer;

  /// CHANGE #622 — true only when the RPC never gave us an answer (threw, or
  /// returned a shape that is not the payload). Kept strictly apart from
  /// `_hasOrders == false`, which the SERVER said. One means "we don't know",
  /// the other means "there are none"; showing the second for the first is
  /// exactly the bug customers reported.
  bool _loadFailed = false;

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
    // CHANGE #629: the Track button's label lives in the copy catalog like
    // every other string. Load it, then repaint — the button is never given a
    // hardcoded fallback, so an unloaded catalog shows no word rather than an
    // English one written here.
    FulfillLookups.instance.ensureLoaded().then((_) {
      if (mounted) setState(() {});
    });
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
    // #622 — a new account deserves a clean slate: the previous account's
    // failure must not colour what this one sees.
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
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
    _retryTimer?.cancel();
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
  /// CHANGE #619 — every exit is now recorded, and the one answer that cannot
  /// be true is re-asked instead of believed.
  ///
  /// #614 made this re-fetch when the account arrives, and production proved
  /// the re-fetch fires: the render-log carried `c614_orders_auth_refetch=uid:1`
  /// on a `auth_role=customer` session. It also carried
  /// `c614_orders_payload=has:0;admin:0;nocust:1` — and `my_customer_id()` was
  /// verified server-side to resolve that exact account. So the request that
  /// answered "no account" reached the server WITHOUT its token.
  ///
  /// The reason it stuck: of the three ways out of the old body, only the
  /// happy path wrote anything. A throw and a non-Map response both returned
  /// silently, leaving the cold-boot (signed-out) payload on screen as though
  /// the server had confirmed it. An authed re-fetch could fail and look
  /// exactly like "you have no orders".
  ///
  /// `no_customer_account: true` while a session is live is a contradiction,
  /// not an answer. Ask again. Never fabricate the list.
  Future<void> _fetch({int attempt = 0}) async {
    final client = Supabase.instance.client;
    final hasSession = client.auth.currentSession != null;
    try {
      final raw = await client.rpc(
        'my_orders_screen',
        // #619 — a normal customer sends NO argument. p_view_as_user belongs to
        // the admin view-as path alone; the backend defaults it to null.
        params: widget.viewAsUserId == null
            ? const <String, dynamic>{}
            : {'p_view_as_user': widget.viewAsUserId},
      );
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (map is! Map) {
        RenderLog.write(kC622Fetch,
            'badshape:${raw.runtimeType};try:$attempt;sess:${hasSession ? 1 : 0}');
        _retryOrSettle(attempt, failed: true);
        return;
      }
      if (!mounted) return;
      final payload = map.cast<String, dynamic>();
      final parsed = ((payload['orders'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .map((r) => _DbOrder.fromPayload(r.cast<String, dynamic>()))
          .toList();
      final hasOrders = payload['has_orders'] == true;
      final noCust = payload['no_customer_account'] == true;
      final custId = (payload['customer_id'] ?? '').toString();

      RenderLog.write(
          kC622Fetch,
          'ok;try:$attempt;sess:${hasSession ? 1 : 0};count:${parsed.length}'
          ';has:${hasOrders ? 1 : 0};nocust:${noCust ? 1 : 0}'
          ';cust:${custId.isEmpty ? 0 : 1}');
      RenderLog.write('orders_fetched',
          'count:${parsed.length}${widget.viewAsUserId != null ? ':viewas' : ''}');
      // CHANGE #625 — written where the PAYLOAD lands, not where the Items tab
      // renders, so the key proves the new contract arrived without anyone
      // having to tap a card open first. `dup` is the check that matters for
      // the duplicate bug: distinct names vs rows, per order. dup:0 across the
      // board means no order is carrying a repeated line.
      if (parsed.isNotEmpty) {
        var rows = 0, distinct = 0, unfOrders = 0, unfRows = 0;
        for (final o in parsed) {
          rows += o.lines.length;
          distinct += o.lines.map((l) => l.name).toSet().length;
          if (o.hasUnfulfilled) unfOrders++;
          unfRows += o.unfulfilledLines.length;
        }
        RenderLog.write(
            'c625_unfulfilled_items',
            'orders:${parsed.length};lines:$rows;dup:${rows - distinct}'
            ';unf_orders:$unfOrders;unf_lines:$unfRows'
            ';src:my_orders_screen');
      }

      // Signed in, yet the server resolved no account — re-ask rather than
      // render a signed-out empty state at a customer who has orders. On the
      // last attempt the payload is adopted as-is: a genuinely account-less
      // login (a fresh admin) must still get its own copy, not a spinner.
      if (noCust && hasSession && attempt < _kMaxFetchRetries) {
        _retryOrSettle(attempt);
        return;
      }

      setState(() {
        _orders = parsed;
        _emptyTitle = (payload['empty_title'] ?? '').toString();
        _emptyNote = (payload['empty_note'] ?? '').toString();
        _customerId = custId;
        // CHANGE #614 — the backend already said whether there are orders and
        // what kind of session this is. Read those; do not re-derive them.
        _hasOrders = hasOrders;
        _isAdminSession = payload['is_admin_session'] == true;
        _noCustomerAccount = noCust;
        _loading = false;
        _loadFailed = false; // the server answered; whatever it said stands
      });
      if (_channel == null) _subscribeRealtime();
    } catch (e) {
      // CHANGE #622 — record WHAT was thrown, not merely that something was.
      // #619 logged the bare word "threw", which proved a failure existed but
      // named nothing; the answer turned out to be a PostgrestException
      // carrying SQLSTATE 25006, and that message is what identified the bug.
      RenderLog.write(
          kC622Fetch,
          'threw:${e.runtimeType}:${_short(e)}'
          ';try:$attempt;sess:${hasSession ? 1 : 0}');
      _retryOrSettle(attempt, failed: true);
    }
  }

  /// First 60 characters of an error, flattened onto one line so it survives
  /// the render-log's key=value format.
  static String _short(Object e) {
    final s = e.toString().replaceAll(RegExp(r'[\r\n;=]+'), ' ').trim();
    return s.length <= 60 ? s : s.substring(0, 60);
  }

  /// Backs off and asks again, or stops pretending and shows what we have.
  /// A fetch that failed must never leave a stale payload looking authoritative.
  void _retryOrSettle(int attempt, {bool failed = false}) {
    if (!mounted) return;
    if (attempt >= _kMaxFetchRetries) {
      // CHANGE #622 — a transport failure must NEVER settle into the empty
      // state. "No orders" is a thing only the server may say; when it never
      // answered, saying it for them is the app inventing the one fact the
      // customer cares about. Retries exhausted on a throw => error state.
      setState(() {
        _loading = false;
        if (failed) _loadFailed = true;
      });
      return;
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(
      Duration(milliseconds: 400 * (attempt + 1)),
      () => _fetch(attempt: attempt + 1),
    );
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
    // CHANGE #622 — the RPC never answered (threw, or returned a shape that is
    // not the payload), and the retries are spent. Say THAT. Borrowing the
    // empty state's words here is how a signed-in customer with orders was
    // told they had none. "You have no orders" is the server's sentence to
    // pronounce, never the app's guess when the server is unreachable.
    //
    // This is the one screen state whose copy is written in Dart rather than
    // fetched: there is no payload to take it from, because the payload is
    // exactly what failed to arrive.
    if (_loadFailed) {
      return RefreshIndicator(
        onRefresh: _fetch,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.25),
            Icon(Icons.cloud_off_outlined,
                size: 64, color: Theme.of(context).hintColor),
            const SizedBox(height: 12),
            Center(child: Text(c('orders.load_failed_title'))),
            const SizedBox(height: 4),
            Center(
              child: Text(c('orders.load_failed_note'),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).hintColor)),
            ),
          ],
        ),
      );
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
  // CHANGE #458: null = nothing open (static card, no auto-expand). 0=Items 1=Payment 2=Bill.
  // A single int? enforces "only one section open at once" by construction — never
  // independent per-section booleans that could disagree.
  int? _tab;

  // CHANGE #458 B3: tapping the open button again closes it; tapping a different
  // button switches to it (closing whatever was open) — never two sections at once.
  //
  // CHANGE #625: nothing is fetched on open any more. See _buildSectionContent.
  void _toggleTab(int tab) {
    setState(() => _tab = _tab == tab ? null : tab);
  }

  // CHANGE #548: backend-formatted (ist_fmt 'dmy_hm2'); no Dart date math.
  String _date(String ts) =>
      DateLabels.instance.label(ts, DateStyle.dmyHm2) ?? '';

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
                // #619 — the order total, printed from the backend's own
                // total_display. No rupee prefix, rounding or grouping is
                // applied here; the string arrives finished.
                if (order.totalDisplay.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(order.totalDisplay,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, color: Color(0xFF374151))),
                ],
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
                    child: Text(c('orders.placed_by_admin'),
                        style: const TextStyle(
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
              child: _TabButton(label: c('orders.tab_items'), selected: _tab == 0, onTap: () => _toggleTab(0)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TabButton(label: c('orders.tab_payment'), selected: _tab == 1, onTap: () => _toggleTab(1)),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _TabButton(label: c('orders.tab_bill'), selected: _tab == 2, onTap: () => _toggleTab(2)),
            ),
            const SizedBox(width: 8),
            // CHANGE #629 (PART F1): Track. This opens a sheet rather than a
            // fourth accordion section, because customer_track_order() answers
            // for itself whether there is anything to track — including
            // 'Preparing your order' when no delivery row exists yet. The card
            // never works that out from order.status.
            Expanded(
              child: _TabButton(
                label: FulfillLookups.instance.ui('dlv_track'),
                selected: false,
                onTap: () => showCustomerTrackSheet(context, order.id),
              ),
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

  /// CHANGE #625 — the Items list is the payload this card was BUILT from.
  ///
  /// It used to be a second RPC. Opening Items called `cust_order_panel()`,
  /// whose `items` array answers exactly the question `my_orders_screen().lines`
  /// already answered — "what is in this order" — and the two disagreed. The
  /// panel builds its array with `LEFT JOIN inquiry i ON i.product_id =
  /// oi.product_id`, unqualified by order or by date, so an order_item whose
  /// product carries N inquiry rows is emitted N times. Verified on live order
  /// CPO310726PAL124O1: 8 order_items, 18 rows out of that join — Rozustat 20
  /// Tablet three times, Pinkgums Dental Gel twice. That is the duplicate the
  /// customer saw, and it was never in the data.
  ///
  /// `lines` is grouped by product_id server-side and takes its inquiry status
  /// through a `limit 1` lateral, so it cannot fan out. One payload, one
  /// answer, and nothing left that could disagree with itself.
  ///
  /// Bill and Payment already fetch for themselves (#463 / CustPayPanel), so
  /// with Items served from the payload this card makes no call of its own at
  /// all — there is no load state left to render.
  Widget _buildSectionContent() {
    switch (_tab) {
      case 0:
        return _ItemsTab(order: widget.order);
      case 1:
        return CustPayPanel(
            key: ValueKey(widget.order.id),
            orderId: widget.order.id,
            orderCode: widget.order.number);
      case 2:
        // CHANGE #464: "Upload Bill" moved off this card entirely (now
        // admin-Customer-Orders-tab only) — no upload-triggered refresh needed
        // here anymore, so a plain per-order key is enough.
        return _BillTab(key: ValueKey(widget.order.id), orderId: widget.order.id);
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

/// CHANGE #625 — the order's items, straight off the payload the card already
/// holds. Two lists arrive already separated by the backend: `lines` (what we
/// will supply) and `unfulfilled_lines` (what we could not source). The app
/// splits nothing, counts nothing and words nothing — it renders two arrays and
/// obeys one boolean.
class _ItemsTab extends StatefulWidget {
  final _DbOrder order;
  const _ItemsTab({required this.order});

  @override
  State<_ItemsTab> createState() => _ItemsTabState();
}

class _ItemsTabState extends State<_ItemsTab> {
  /// Seeded from `unfulfilled_collapsed`, so whether the section starts open is
  /// a config row, not a Dart constant. After that it is ordinary UI state: the
  /// customer's own tap, which is the one thing the backend cannot know.
  late bool _unfulfilledOpen = !widget.order.unfulfilledCollapsed;

  @override
  Widget build(BuildContext context) {
    final order = widget.order;
    RenderLog.write(
        'c625_unfulfilled_items',
        'order:${order.number};lines:${order.lines.length}'
        ';has_unf:${order.hasUnfulfilled ? 1 : 0}'
        ';unf:${order.unfulfilledCount};unf_rows:${order.unfulfilledLines.length}'
        ';total_items:${order.totalItemCount};open:${_unfulfilledOpen ? 1 : 0}');

    // CHANGE #641 — prove the RICH fields actually arrived, on the real device,
    // from the real payload. Counting rows is not enough: the regression was a
    // card rendering without image/company/pack, which a row count cannot see.
    // Reports the first line's field presence plus how many lines carry each.
    if (order.lines.isNotEmpty) {
      final f = order.lines.first.item;
      RenderLog.write(
          'c641_rich_items',
          'order:${order.number};rows:${order.lines.length}'
          ';uniq_names:${order.lines.map((l) => l.item.name).toSet().length}'
          ';img:${order.lines.where((l) => l.item.imageUrl.isNotEmpty).length}'
          ';co:${order.lines.where((l) => l.item.company.isNotEmpty).length}'
          ';pack:${order.lines.where((l) => l.item.packLabel.isNotEmpty).length}'
          ';qty:${order.lines.where((l) => l.item.qtyLabel.isNotEmpty).length}'
          ';first_qty:${f.qtyLabel};first_rate:${f.rateLabel}'
          ';first_line:${f.lineLabel};first_status:${f.statusLabel}'
          ';first_tone:${f.statusTone}');
    }

    // #641 — stretch, not start: the tab body is the card's full content width,
    // and every item card fills it. `start` was what let the cards shrink-wrap
    // to their text on desktop.
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // B1 — the items we WILL supply.
      ...order.lines.map(_itemRow),
      // B2/B3 — the section exists only because the backend said so. When
      // has_unfulfilled is false nothing at all renders here: no header, no
      // divider, no reserved gap.
      if (order.hasUnfulfilled) _unfulfilledSection(order),
    ]);
  }

  // ── B2 — the collapsed "Unfulfilled items (N)" section ────────────────────

  Widget _unfulfilledSection(_DbOrder order) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFFDF8F7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFF0DCD8)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => _unfulfilledOpen = !_unfulfilledOpen),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(children: [
              const Icon(Icons.info_outline, size: 15, color: Color(0xFFB42318)),
              const SizedBox(width: 8),
              // The header is unfulfilled_label, printed verbatim — the count
              // inside it was formatted server-side. Dart never builds "(N)".
              Expanded(
                child: Text(order.unfulfilledLabel,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF8A2B22))),
              ),
              Icon(_unfulfilledOpen ? Icons.expand_less : Icons.expand_more,
                  size: 20, color: const Color(0xFF8A2B22)),
            ]),
          ),
        ),
        if (_unfulfilledOpen)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (order.unfulfilledNote.isNotEmpty) ...[
                Text(order.unfulfilledNote,
                    style: const TextStyle(
                        fontSize: 11.5, height: 1.35, color: Color(0xFF6B7280))),
                const SizedBox(height: 10),
              ],
              ...order.unfulfilledLines.map(_itemRow),
            ]),
          ),
      ]),
    );
  }

  // ── One row shape for both lists ──────────────────────────────────────────
  // B4 — the status chip rides on the main lines too, coloured by the
  // status_colors that came with the line. On an unfulfilled line the same
  // field already carries the reason ("No supplier available"), so there is no
  // second code path and no chance of the two drifting apart.

  /// CHANGE #641 — the rich card, restored on EVERY width.
  ///
  /// The regression this fixes was not the styling, it was the sizing: the card
  /// Container carried no width, so inside a `CrossAxisAlignment.start` Column
  /// it shrank to its widest child. On a phone the name is wide enough that the
  /// card looked full-bleed anyway; on desktop the same widget visibly
  /// collapsed to a stub. The card now states `width: double.infinity` and
  /// lives in its own file so a widget test can drive it directly.
  Widget _itemRow(_DbLine l) => CustomerOrderItemCard(item: l.item);
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
      if (mounted) setState(() { _error = c('orders.bill_load_failed'); _loading = false; });
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
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(children: [
            const Icon(Icons.receipt_long_outlined, size: 48, color: Color(0xFFD1D5DB)),
            const SizedBox(height: 12),
            Text(c('orders.bill_processing'),
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
          ]),
        ),
        Row(children: [
          Expanded(
              child: BillActionButton(
                  icon: Icons.download_outlined,
                  label: c('orders.bill_download'),
                  enabled: false,
                  onTap: () {})),
          const SizedBox(width: 8),
          Expanded(
              child: BillActionButton(
                  icon: Icons.chat_bubble_outline,
                  label: c('orders.bill_whatsapp'),
                  enabled: false,
                  onTap: () {})),
          const SizedBox(width: 8),
          Expanded(
              child: BillActionButton(
                  icon: Icons.share_outlined,
                  label: c('orders.bill_share'),
                  enabled: false,
                  onTap: () {})),
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
      if (seller['gstin'] != null && seller['gstin'].toString().isNotEmpty)
        cf('orders.invoice_gstin', {'value': seller['gstin'].toString()}),
      if (seller['dl'] != null && seller['dl'].toString().isNotEmpty)
        cf('orders.invoice_dl', {'value': seller['dl'].toString()}),
    ];
    final buyerLine = [buyer['address'], buyer['phone']]
        .where((e) => e != null && e.toString().isNotEmpty)
        .toList();
    final buyerMeta = <String>[
      if (buyer['gstin'] != null && buyer['gstin'].toString().isNotEmpty)
        cf('orders.invoice_gstin', {'value': buyer['gstin'].toString()}),
      if (buyer['dl'] != null && buyer['dl'].toString().isNotEmpty)
        cf('orders.invoice_dl', {'value': buyer['dl'].toString()}),
    ];

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(c('orders.invoice_title'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
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
            Text(cf('orders.invoice_date', {'value': invoice['date'].toString()}),
                style: const TextStyle(fontSize: 11.5, color: Color(0xFF6B7280))),
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
          Text(cf('orders.invoice_billed_to', {'value': buyer['name'].toString()}),
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
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
      // CHANGE #676 — the caption is the backend's word now. mediBO quotes MRP,
      // not PTR, and what this row is called is a business decision, so it may
      // never be a Dart literal again.
      row(totals['ptr_total_caption']?.toString() ?? '', totals['ptr_total_label']),
      row(totals['discount_label']?.toString() ?? c('orders.total_discount'), totals['discount_amount_label']),
      row(c('orders.total_net_taxable'), totals['taxable_label'], bold: true),
      row(c('orders.total_cgst'), totals['cgst_label']),
      row(c('orders.total_sgst'), totals['sgst_label']),
      row(c('orders.total_round_off'), totals['round_off_label']),
      const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1)),
      row(c('orders.total_net_payable'), totals['net_payable_label'], bold: true, size: 15),
      row(c('orders.total_advance_paid'), totals['paid_label']),
      row(c('orders.total_balance_due'), totals['remaining_label'], bold: true, size: 15),
      if (inWords != null && inWords.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(cf('orders.total_amount_in_words', {'value': inWords}),
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
        columns: [
          DataColumn(label: Text(c('orders.gst_col_rate'))),
          DataColumn(label: Text(c('orders.gst_col_taxable')), numeric: true),
          DataColumn(label: Text(c('orders.gst_col_cgst')), numeric: true),
          DataColumn(label: Text(c('orders.gst_col_sgst')), numeric: true),
          DataColumn(label: Text(c('orders.gst_col_total')), numeric: true),
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
        String message = c('orders.bill_load_failed');
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
      if (mounted) showToast(context, c('orders.bill_load_failed'), isError: true);
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
          label: _downloading ? c('orders.bill_downloading') : c('orders.bill_download'),
          enabled: widget.ready && !_downloading,
          loading: _downloading,
          onTap: _download,
        ),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Builder(builder: (btnContext) => _BillActionButton(
              icon: Icons.chat_bubble_outline,
              label: c('orders.bill_whatsapp'),
              enabled: widget.ready,
              onTap: () => _showWaPopup(btnContext),
            )),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: _BillActionButton(
          icon: Icons.share_outlined,
          label: _sharing ? c('orders.bill_sharing') : c('orders.bill_share'),
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
      if (mounted) setState(() => _error = c('orders.wa_numbers_load_failed'));
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
        message = cf('orders.wa_sent', {'phone': phone});
        isError = false;
      } else if (res['error'] == 'no_bill_uploaded') {
        // #463: send_customer_bill_wa now gates on the uploaded file
        // (orders.cust_bill_path), not the old computed-invoice readiness.
        message = c('orders.wa_no_bill_uploaded');
        isError = true;
      } else if (res['error'] == 'bill_not_ready') {
        message = c('orders.wa_bill_not_ready');
        isError = true;
      } else if (res['error'] == 'bad_phone') {
        message = c('orders.wa_bad_phone');
        isError = true;
      } else {
        message = c('orders.wa_send_failed');
        isError = true;
      }
    } catch (_) {
      message = c('orders.wa_send_failed');
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(c('orders.wa_picker_title'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
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
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(c('orders.wa_no_saved_number'),
                  style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
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
                              child: Text(c('orders.wa_last_used'),
                                  style: const TextStyle(
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

/// Parses '#RRGGBB' from the backend. Not a decision — a hex string is not a
/// Dart Color until something converts it. #625 lifted this out of _StatusChip
/// so the order chip and the per-line chip parse backend colours identically.
Color _hexColor(String hex, {required Color fallback}) {
  final h = hex.replaceFirst('#', '').trim();
  if (h.length != 6) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

class _StatusChip extends StatelessWidget {
  final String status;
  final String label;
  final String colorHex;
  const _StatusChip({
    required this.status,
    required this.label,
    required this.colorHex,
  });

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
