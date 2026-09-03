import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'delivery/customer_track_sheet.dart';  // C629: PART F1 — live tracking
import 'customer/order_edit_sheet.dart';  // CHANGE #408
import 'customer/order_cancel_sheet.dart'; // CMD #452 — gaps #130
import 'customer/order_help_sheet.dart';   // CMD #452 — gaps #132
import 'customer/order_return_sheet.dart'; // CMD #452 — gaps #131
import 'package:http/http.dart' as http;
import 'package:pharma_b2b/utils/toast.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/live_feed.dart';

import '../utils/download_bytes.dart';
import '../utils/render_log.dart';
import '../widgets/animations.dart';
import '../widgets/bill_actions_row.dart';
import '../widgets/bill_viewer.dart';
import '../widgets/cust_pay_panel.dart';
import '../widgets/customer_order_item_card.dart'; // #641: the Items-tab card
import '../widgets/order_card_lean.dart'; // #630: the lean card, its progress line and the change window
import '../services/ui_copy.dart';
import '../design_tokens.dart'; // #173: Ds tokens for the reorder entry points
import '../widgets/delivery_proof_card.dart'; // #691: arrival window + proof of delivery
import '../widgets/customer_surface_widgets.dart'; // CHANGE #745 — Rewards section
import 'reorder_screen.dart'; // #173: reorder suite (suggestions + smart diff)
import '../widgets/substitute_choice.dart'; // #366 row 176: customer picks the substitute

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

  /// CHANGE #408 — the edit window, decided by the backend and carried on the
  /// order row. `can_edit` is the whole affordance; when it is false the
  /// payload also names the reason and the sentence to show.
  final Map<String, dynamic> edit;

  /// CMD #452 — every door this buyer has on this order, decided server-side
  /// and carried on the row: cancel (#130), returns (#131), help (#132). The
  /// card renders the list in payload order, with the payload's own labels,
  /// and never works out for itself whether an action is allowed.
  final List<Map<String, dynamic>> actions;

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
    this.edit = const {},
    this.actions = const [],
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
        edit: row['edit'] is Map
            ? Map<String, dynamic>.from(row['edit'] as Map)
            : const {},
        actions: ((row['actions'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((a) => Map<String, dynamic>.from(a))
            .toList(),
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

  /// CHANGE #298 — the order a notification pointed at. The deep link
  /// `/my-order/<order_code>` lands here, and this is what makes a push open the
  /// EXACT order rather than the app home. The code is the backend's own
  /// order_code, passed through untouched: the app has no opinion about what a
  /// valid one looks like.
  final String? focusOrderCode;

  const OrdersScreen({
    super.key,
    this.viewAsUserId,
    this.refreshSignal = 0,
    this.focusOrderCode,
  });

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  /// CHANGE #298 — deep-link focus. Cleared once the card has been scrolled
  /// to, so a later refresh does not yank the list back.
  String? _focusCode;
  final GlobalKey _focusKey = GlobalKey();

  // ── CHANGE #630 ───────────────────────────────────────────────────────────
  // The tab is ORDERS now. The reorder banner, the Purchases tile, the
  // Saved-lists tile and the per-card help box were shop tools wearing an
  // orders list as a hat; they are registry rows on My Shop and this screen
  // has never heard of them. What is left is one filter row, one search box
  // and a list of cards that each say one true thing and offer one thing to
  // tap.
  List<CustomerOrderCard> _cards = [];

  /// The filter row, as the backend sent it: key, label, count and which one
  /// is selected. The screen does not decide the default, does not count the
  /// buckets and does not word the chips.
  List<Map<String, dynamic>> _filters = const [];
  String _filter = 'active';
  String _searchHint = '';
  final TextEditingController _searchCtl = TextEditingController();
  Timer? _searchDebounce;

  bool _loading = true;
  /// #572 — empty-state copy comes from the payload, not from Dart literals.
  String _emptyTitle = '';
  String _emptyNote = '';
  /// #572 — the ACCOUNT id, as the backend resolved it. Realtime keys on this.
  String _customerId = '';
  LiveFeedHandle? _channel;

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
  /// forever. Re-fetch when the ACCOUNT changes, not on one event constant.
  String? _authedUid;
  StreamSubscription<AuthState>? _authSub;

  /// CHANGE #619 — one key, every outcome: ok / threw / badshape, with the
  /// attempt number, whether a session was attached, and what came back.
  static const kC622Fetch = 'c622_orders_fetch';
  static const int _kMaxFetchRetries = 3;
  Timer? _retryTimer;

  /// CHANGE #622 — true only when the RPC never gave us an answer (threw, or
  /// returned a shape that is not the payload). Kept strictly apart from
  /// `_hasOrders == false`, which the SERVER said.
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _focusCode = widget.focusOrderCode;
    _authedUid = Supabase.instance.client.auth.currentUser?.id;
    _authSub =
        Supabase.instance.client.auth.onAuthStateChange.listen(_onAuthState);
    _fetch();
  }

  /// CHANGE #298 — scroll the deep-linked order into view after first paint.
  void _revealFocusedOrder() {
    if (_focusCode == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _focusKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 260), alignment: 0.1);
      RenderLog.write('c298_order_deeplink', 1);
      _focusCode = null;
    });
  }

  void _onAuthState(AuthState _) {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == _authedUid) return;
    _authedUid = uid;
    _channel?.unsubscribe();
    _channel = null;
    _customerId = '';
    if (!mounted) return;
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
    _searchDebounce?.cancel();
    _searchCtl.dispose();
    _channel?.unsubscribe();
    super.dispose();
  }

  /// CHANGE #630 — ONE RPC for the whole tab: the filter row with its counts,
  /// the search hint, the empty-state copy and the cards, each already carrying
  /// its own stage sentence, its own money string and the single action it
  /// offers. Nothing on this screen is computed, worded, counted, sorted or
  /// chosen in Dart.
  Future<void> _fetch({int attempt = 0}) async {
    final client = Supabase.instance.client;
    final hasSession = client.auth.currentSession != null;
    final query = _searchCtl.text.trim();
    try {
      final raw = await client.rpc('my_orders_screen_v2', params: {
        'p_filter': _filter,
        if (query.isNotEmpty) 'p_query': query,
        if (widget.viewAsUserId != null) 'p_view_as_user': widget.viewAsUserId,
      });
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
          .map((r) => CustomerOrderCard.fromPayload(r.cast<String, dynamic>()))
          .toList();
      final hasOrders = payload['has_orders'] == true;
      final noCust = payload['no_customer_account'] == true;
      final custId = (payload['customer_id'] ?? '').toString();

      RenderLog.write(
          kC622Fetch,
          'ok;try:$attempt;sess:${hasSession ? 1 : 0};count:${parsed.length}'
          ';has:${hasOrders ? 1 : 0};nocust:${noCust ? 1 : 0}'
          ';cust:${custId.isEmpty ? 0 : 1}');
      // CHANGE #630 — proof the new tab rendered: which bucket, how many
      // cards, how many carried a progress line, and how many DIFFERENT
      // primary actions the backend chose across them. One action per card is
      // the whole point, so `acts` naming more than one key is the evidence
      // that the choice is the backend's and not a constant.
      RenderLog.write(
          'c630_orders_tab',
          'filter:$_filter;cards:${parsed.length}'
          ';prog:${parsed.where((o) => o.progressSteps.isNotEmpty).length}'
          ';acts:${parsed.map((o) => o.actionKey).where((k) => k.isNotEmpty).toSet().length}'
          ';q:${query.isEmpty ? 0 : 1}');

      if (noCust && hasSession && attempt < _kMaxFetchRetries) {
        _retryOrSettle(attempt);
        return;
      }

      setState(() {
        _cards = parsed;
        _filters = ((payload['filters'] as List<dynamic>?) ?? const [])
            .whereType<Map>()
            .map((f) => Map<String, dynamic>.from(f))
            .toList();
        _filter = (payload['filter'] ?? _filter).toString();
        _searchHint =
            ((payload['search'] as Map?)?['hint'] ?? '').toString();
        _emptyTitle = (payload['empty_title'] ?? '').toString();
        _emptyNote = (payload['empty_note'] ?? '').toString();
        _customerId = custId;
        _hasOrders = hasOrders;
        _isAdminSession = payload['is_admin_session'] == true;
        _noCustomerAccount = noCust;
        _loading = false;
        _loadFailed = false;
      });
      _revealFocusedOrder();
      if (_channel == null) _subscribeRealtime();
    } catch (e) {
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
  void _retryOrSettle(int attempt, {bool failed = false}) {
    if (!mounted) return;
    if (attempt >= _kMaxFetchRetries) {
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

  /// #572 — keyed to the ACCOUNT, like the fetch.
  void _subscribeRealtime() {
    if (widget.viewAsUserId != null) return; // no realtime in view-as mode
    final accountId = _customerId;
    if (accountId.isEmpty) return;
    _channel?.unsubscribe();
    // CHANGE #643: `orders` is the highest-churn table in the app and no longer
    // publishes to Realtime — LiveFeed reads realtime_plan() and puts this on
    // the backend's own interval instead. The callback is unchanged: this was
    // always a refetch trigger, never a row parser.
    LiveFeed.instance
        .watch(
          channelPrefix: 'customer_orders_$accountId',
          tables: const ['orders'],
          filters: {
            'orders': PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'customer_id',
              value: accountId,
            ),
          },
          onChange: (_) => _fetch(),
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _channel?.unsubscribe();
      _channel = h;
    });
  }

  /// PART A5/A6 — everything that used to be a chip on the row is inside the
  /// order now, so tapping the card is the way in.
  Future<void> _openOrder(CustomerOrderCard o, {String? tab}) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CustomerOrderDetailScreen(
          orderId: o.id, orderCode: o.orderCode, initialTab: tab),
    ));
    await _fetch();
  }

  /// PART A4 — the card offers ONE action and the BACKEND named it. This
  /// routes that key; it never decides which action an order deserves. A key
  /// this build has never heard of opens the order rather than throwing, so a
  /// new action is an UPDATE on the backend and not a deploy.
  Future<void> _runCardAction(CustomerOrderCard o, String key) async {
    switch (key) {
      case 'track':
        await showCustomerTrackSheet(context, o.id);
        return;
      case 'pay':
        await _openOrder(o, tab: 'payment');
        return;
      case 'reorder':
        await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ReorderScreen(orderId: o.id)));
        await _fetch();
        return;
      case 'edit':
        final saved = await showOrderEditSheet(context, o.id);
        if (saved) await _fetch();
        return;
      default:
        await _openOrder(o);
    }
  }

  void _selectFilter(String key) {
    if (key == _filter) return;
    setState(() {
      _filter = key;
      _loading = true;
    });
    _fetch();
  }

  /// PART A8 — search by order code or medicine name. The matching is the
  /// backend's (it reaches into order_items.product_name, which the client
  /// does not hold); this only debounces the typing.
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), _fetch);
  }

  @override
  Widget build(BuildContext context) {
    // An admin login has no pharmacy account; the backend says so and words
    // it. There is nothing to filter or search, so the chrome stays away.
    if (!_loading && _noCustomerAccount && _isAdminSession) {
      return _OrdersEmpty(
          icon: Icons.receipt_long_outlined,
          title: _emptyTitle,
          note: _emptyNote,
          onRefresh: _fetch);
    }
    return Column(
      children: [
        _OrdersHeader(
          filters: _filters,
          selected: _filter,
          onSelect: _selectFilter,
          controller: _searchCtl,
          hint: _searchHint,
          onChanged: _onSearchChanged,
          onClear: () {
            _searchCtl.clear();
            _fetch();
          },
        ),
        // CHANGE #745 — Rewards belongs to purchases, so it sits on the Orders
        // tab instead of the profile dropdown. It is a placement row
        // ('orders_section'), not a line this file owns: points, slab and the
        // referral code are loyalty_my_rewards()'s own strings, and the card
        // is absent entirely when the backend placed nothing here.
        const CustomerRewardsSection(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    // CHANGE #622 — the RPC never answered and the retries are spent. Say
    // THAT. Borrowing the empty state's words here is how a signed-in customer
    // with orders was told they had none.
    if (_loadFailed) {
      return _OrdersEmpty(
          icon: Icons.cloud_off_outlined,
          title: c('orders.load_failed_title'),
          note: c('orders.load_failed_note'),
          onRefresh: _fetch);
    }
    // CHANGE #614 — `has_orders` is the backend's answer for the bucket that
    // was asked for; the screen does not re-derive it from the array.
    if (!_hasOrders) {
      return _OrdersEmpty(
          icon: Icons.receipt_long_outlined,
          title: _emptyTitle,
          note: _emptyNote,
          onRefresh: _fetch);
    }
    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView.separated(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x24),
        physics: platformScrollPhysics(),
        itemCount: _cards.length,
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
        itemBuilder: (context, i) {
          final o = _cards[i];
          final focused = _focusCode != null && o.orderCode == _focusCode;
          return OrderCardLean(
            key: focused ? _focusKey : null,
            card: o,
            onOpen: () => _openOrder(o),
            onAction: (key) => _runCardAction(o, key),
          );
        },
      ),
    );
  }
}

/// CHANGE #630 — the filter row and the search box, both drawn from the
/// payload. The chips are whatever `filters[]` holds, in payload order, with
/// the backend's own labels and counts; an unknown key tomorrow needs no
/// deploy.
class _OrdersHeader extends StatelessWidget {
  final List<Map<String, dynamic>> filters;
  final String selected;
  final ValueChanged<String> onSelect;
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  const _OrdersHeader({
    required this.filters,
    required this.selected,
    required this.onSelect,
    required this.controller,
    required this.hint,
    required this.onChanged,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: Ds.touch.minTarget,
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: Ds.t.body,
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle: Ds.t.caption,
                prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary),
                suffixIcon: controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: Icon(Icons.close, color: Ds.c.textSecondary),
                        onPressed: onClear),
                filled: true,
                fillColor: Ds.c.bg,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: Ds.space.x12),
                border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.brand)),
              ),
            ),
          ),
          if (filters.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: Row(
                children: [
                  for (final f in filters) ...[
                    OrdersFilterChip(
                      label: (f['label'] ?? '').toString(),
                      count: (f['count'] as num?)?.toInt() ?? 0,
                      selected: (f['key'] ?? '').toString() == selected,
                      onTap: () => onSelect((f['key'] ?? '').toString()),
                    ),
                    SizedBox(width: Ds.space.x8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One empty/failed state, so the three of them cannot drift apart. The words
/// are always the caller's — this widget writes none.
class _OrdersEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String note;
  final Future<void> Function() onRefresh;
  const _OrdersEmpty(
      {required this.icon,
      required this.title,
      required this.note,
      required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x24),
        children: [
          SizedBox(height: MediaQuery.of(context).size.height * 0.2),
          Icon(icon, size: Ds.space.x48, color: Ds.c.textSecondary),
          SizedBox(height: Ds.space.x12),
          Center(child: Text(title, style: Ds.t.subtitle)),
          SizedBox(height: Ds.space.x4),
          Center(
            child: Text(note,
                textAlign: TextAlign.center, style: Ds.t.caption),
          ),
        ],
      ),
    );
  }
}
/// CMD #452 — the customer's action row on an order card: cancel (#130),
/// returns (#131) and help (#132). Every label, tone, badge and disabled
/// explanation is the payload's; the only thing decided here is which sheet a
/// key opens.
class _CustomerActionsRow extends StatelessWidget {
  final String orderId;
  final List<Map<String, dynamic>> actions;
  final Future<void> Function()? onChanged;

  const _CustomerActionsRow({
    required this.orderId,
    required this.actions,
    this.onChanged,
  });

  Future<void> _open(BuildContext context, String key) async {
    var changed = false;
    switch (key) {
      case 'cancel':
        changed = await showOrderCancelSheet(context, orderId);
        break;
      case 'returns':
        changed = await showOrderReturnSheet(context, orderId);
        break;
      case 'help':
        changed = await showOrderHelpSheet(context, orderId);
        break;
      // CHANGE #630 — the edit door arrives in this same list now, because
      // ONE gate decides both doors. It is present only while the window is
      // open, so there is no closed-window branch to write here.
      case 'edit':
        changed = await showOrderEditSheet(context, orderId);
        break;
      default:
        // Forward compatibility: a key this build does not know is not an
        // error, it is a button a newer backend added. Skip it.
        return;
    }
    if (changed && onChanged != null) await onChanged!();
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c452_order_actions', actions.length);
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final a in actions)
          _ActionChip(
            label: (a['label'] ?? '').toString(),
            badge: (a['badge'] ?? '').toString(),
            danger: (a['tone'] ?? '') == 'danger',
            enabled: a['enabled'] == true,
            note: (a['note'] ?? '').toString(),
            onTap: () => _open(context, (a['key'] ?? '').toString()),
          ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final String label;
  final String badge;
  final bool danger;
  final bool enabled;
  final String note;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.badge,
    required this.danger,
    required this.enabled,
    required this.note,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final fg = !enabled
        ? Ds.c.textSecondary
        : danger
            ? Ds.c.danger
            : Ds.c.brand;
    return Tooltip(
      // The backend's own sentence for why a closed window is closed.
      message: enabled ? '' : note,
      child: OutlinedButton(
        onPressed: enabled
            ? onTap
            : (note.isEmpty
                ? null
                : () => showToast(context, note)),
        style: OutlinedButton.styleFrom(
          foregroundColor: fg,
          side: BorderSide(color: fg.withValues(alpha: 0.35)),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          minimumSize: Size(0, Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis, style: Ds.t.body.copyWith(color: fg))),
          if (badge.isNotEmpty) ...[
            SizedBox(width: Ds.space.x8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                  color: fg.withValues(alpha: 0.12),
                  borderRadius: Ds.r.rChip),
              child: Text(badge, style: Ds.t.caption.copyWith(color: fg)),
            ),
          ],
        ]),
      ),
    );
  }
}

// ─── Order card ───────────────────────────────────────────────────────────────
// CHANGE #630 — ONE CARD, ONE TRUTH, ONE THING TO TAP.
//
// What this card used to be: an order code, a status pill, a five-chip row
// that ran off the right edge of a 360 px phone (Items · Payment · Bill ·
// Track · Count), an Edit button, an actions row (Cancel · Returns · Help), a
// Reorder button, and an accordion that opened a whole sub-screen inside a
// list item. A cancelled order still offered Reorder ABOVE a help box; a
// pending one stacked five actions. A list of orders had become a control
// panel per row.
//
// What it is now: what the order IS (code, when, how many, how much), where it
// actually is in plain words, and the single thing worth doing about it. The
// rest lives one tap away, inside the order.

// ─── The order, opened ──────────────────────────────────────────────────────

/// CHANGE #630 — PART A5/A6/B. Items · Payment · Bill · Help are TABS in here
/// now, not chips on a list row, and Help is one of them rather than a box
/// bolted to every card in the list.
///
/// PART B: the edit and cancel doors are drawn from `actions[]`, which the
/// backend builds from ONE gate (`_order_change_gate`). When the window is
/// shut the actions are ABSENT — there is no greyed-out button here to tap and
/// be refused by — and `window_note` carries the backend's sentence saying
/// why. This screen never works out whether a change is still allowed.
class CustomerOrderDetailScreen extends StatefulWidget {
  final String orderId;
  final String orderCode;
  final String? initialTab;

  const CustomerOrderDetailScreen({
    super.key,
    required this.orderId,
    this.orderCode = '',
    this.initialTab,
  });

  @override
  State<CustomerOrderDetailScreen> createState() =>
      _CustomerOrderDetailScreenState();
}

class _CustomerOrderDetailScreenState extends State<CustomerOrderDetailScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String _error = '';
  String _tab = '';

  @override
  void initState() {
    super.initState();
    _tab = widget.initialTab ?? '';
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client.rpc('customer_order_detail',
          params: {'p_order_id': widget.orderId});
      final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (!mounted) return;
      if (map is! Map) {
        setState(() {
          _loading = false;
          _error = c('orders.load_failed_title');
        });
        return;
      }
      final p = map.cast<String, dynamic>();
      final tabs = ((p['tabs'] as List<dynamic>?) ?? const [])
          .whereType<Map>()
          .toList();
      setState(() {
        _payload = p;
        _loading = false;
        _error = p['ok'] == true ? '' : (p['message'] ?? '').toString();
        if (_tab.isEmpty && tabs.isNotEmpty) {
          _tab = (tabs.first['key'] ?? '').toString();
        }
      });
      if (p['ok'] == true) {
        RenderLog.write(
            'c630_order_detail',
            'tabs:${tabs.length};acts:${((p['actions'] as List?) ?? const []).length}'
            ';gate:${((p['change_window'] as Map?)?['reason_code'] ?? '')}');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = c('orders.load_failed_title');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    final title = (p?['title'] ?? '').toString();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(widget.orderCode.isNotEmpty
            ? '$title ${widget.orderCode}'.trim()
            : title),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (p == null || p['ok'] != true)
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(_error, style: Ds.t.body),
                  ),
                )
              : _buildBody(p),
    );
  }

  Widget _buildBody(Map<String, dynamic> p) {
    final cardMap = (p['card'] as Map?)?.cast<String, dynamic>();
    final card = cardMap == null ? null : CustomerOrderCard.fromPayload(cardMap);
    final orderMap = (p['order'] as Map?)?.cast<String, dynamic>();
    final order = orderMap == null ? null : _DbOrder.fromPayload(orderMap);
    final tabs = ((p['tabs'] as List<dynamic>?) ?? const [])
        .whereType<Map>()
        .map((t) => Map<String, dynamic>.from(t))
        .toList();
    // PART B — one gate, read verbatim. `window.actions` is empty when the
    // backend shut the window, and `window.note` is its sentence for why. This
    // screen has no branch on order status and no wording of its own.
    final window = OrderChangeWindow.fromDetail(p);
    final actions = window.actions;
    final windowNote = window.note;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
        physics: platformScrollPhysics(),
        children: [
          if (card != null) _DetailHeader(card: card),
          // CHANGE #691 (register rows 122 / 126) — the arrival window while it
          // is on the road, and the proof of delivery once it has landed. Both
          // are finished blocks from customer_order_detail(); each hides itself
          // when the backend says `has:false`.
          DeliveryEtaCard(
              eta: (p['eta'] as Map?)?.cast<String, dynamic>() ?? const {}),
          DeliveryProofCard(
              proof: (p['proof'] as Map?)?.cast<String, dynamic>() ?? const {}),
          // PART B — the sentence that replaces the actions once the window is
          // shut. It is the backend's, verbatim; there is no Dart wording here
          // and no disabled button to explain itself.
          if (windowNote.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                  color: Ds.c.infoSoft, borderRadius: Ds.r.rCard),
              child: Text(windowNote, style: Ds.t.body),
            ),
          ],
          if (actions.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            _CustomerActionsRow(
                orderId: widget.orderId, actions: actions, onChanged: _load),
          ],
          if (tabs.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            _DetailTabBar(
              tabs: tabs,
              selected: _tab,
              onSelect: (k) => setState(() => _tab = k),
            ),
            SizedBox(height: Ds.space.x16),
            _tabBody(p, order),
          ],
        ],
      ),
    );
  }

  Widget _tabBody(Map<String, dynamic> p, _DbOrder? order) {
    switch (_tab) {
      case 'items':
        return order == null
            ? const SizedBox.shrink()
            : _ItemsTab(order: order);
      case 'payment':
        return CustPayPanel(
            key: ValueKey(widget.orderId),
            orderId: widget.orderId,
            orderCode: widget.orderCode);
      case 'bill':
        return _BillTab(key: ValueKey(widget.orderId), orderId: widget.orderId);
      case 'help':
        return _HelpTab(
            orderId: widget.orderId,
            help: (p['help'] as Map?)?.cast<String, dynamic>() ?? const {},
            onChanged: _load);
      default:
        // Forward compatibility: a tab key this build has never heard of
        // renders nothing rather than throwing.
        return const SizedBox.shrink();
    }
  }
}

/// The order's own summary at the top of its detail — the same card the list
/// drew, minus the action (you are already inside the order).
class _DetailHeader extends StatelessWidget {
  final CustomerOrderCard card;
  const _DetailHeader({required this.card});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(card.orderCode, style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x8),
              Text(card.dateLabel, style: Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(child: Text(card.itemCountLabel, style: Ds.t.caption)),
              SizedBox(width: Ds.space.x8),
              Text(card.amountLabel,
                  style: card.amountIsMoney ? Ds.t.bodyStrong : Ds.t.caption),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(card.stageLabel, style: Ds.t.body),
          if (card.progressShow && card.progressSteps.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            OrderProgressLine(steps: card.progressSteps),
          ],
        ],
      ),
    );
  }
}

/// PART A5 — the tabs, from the payload, in payload order.
class _DetailTabBar extends StatelessWidget {
  final List<Map<String, dynamic>> tabs;
  final String selected;
  final ValueChanged<String> onSelect;
  const _DetailTabBar(
      {required this.tabs, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const ClampingScrollPhysics(),
      child: Row(
        children: [
          for (final t in tabs) ...[
            OrdersFilterChip(
              label: (t['label'] ?? '').toString(),
              count: 0,
              selected: (t['key'] ?? '').toString() == selected,
              onTap: () => onSelect((t['key'] ?? '').toString()),
            ),
            SizedBox(width: Ds.space.x8),
          ],
        ],
      ),
    );
  }
}

/// PART A6 — Help, inside the order. It used to be a box on every card in the
/// list, which made a list of orders read like a complaint form.
class _HelpTab extends StatelessWidget {
  final String orderId;
  final Map<String, dynamic> help;
  final Future<void> Function() onChanged;
  const _HelpTab(
      {required this.orderId, required this.help, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final title = (help['title'] ?? '').toString();
    final label = (help['label'] ?? '').toString();
    final openCount = (help['open_count'] as num?)?.toInt() ?? 0;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1),
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) Text(title, style: Ds.t.body),
          if (openCount > 0) ...[
            SizedBox(height: Ds.space.x4),
            Text('$openCount', style: Ds.t.caption),
          ],
          if (label.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: () async {
                  final changed = await showOrderHelpSheet(context, orderId);
                  if (changed) await onChanged();
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape:
                      RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(label),
              ),
            ),
          ],
        ],
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
              // CMD #366 row 176 — the buyer's own say. Until now the split
              // was silent: order_items.unfulfillable was set server-side and
              // this block only reported the outcome. Now every open offer on
              // this order renders the SAME chooser the admin sees and the
              // WhatsApp page shows, so "the customer approved it" means one
              // thing wherever it was recorded.
              ..._offersFor(order.id).map((offer) => Padding(
                    padding: EdgeInsets.only(top: Ds.space.x12),
                    child: SubstituteChoice(
                      offer: offer,
                      onDecided: (fresh) => setState(() {
                        final list = _subOffers[order.id];
                        if (list == null) return;
                        final i = list.indexWhere((e) =>
                            e['offer_id'] == fresh['offer_id']);
                        if (i >= 0) list[i] = fresh;
                      }),
                    ),
                  )),
            ]),
          ),
      ]),
    );
  }

  /// CMD #366 row 176 — substitute offers, keyed by order id. Loaded lazily
  /// the first time an order with a shortage is drawn, so an account with no
  /// shortage never pays for the call.
  final Map<String, List<Map<String, dynamic>>> _subOffers = {};
  final Set<String> _subOffersLoading = {};

  List<Map<String, dynamic>> _offersFor(String orderId) {
    final cached = _subOffers[orderId];
    if (cached != null) return cached;
    if (_subOffersLoading.add(orderId)) {
      // ignore: discarded_futures — fire-and-forget; the setState redraws.
      SubstituteChoice.rpc('sub_offers_for_order', {'p_order_id': orderId})
          .then((res) {
        if (!mounted) return;
        final rows = (res is Map ? (res['offers'] as List?) : null) ?? const [];
        setState(() {
          _subOffers[orderId] = rows
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
        });
      }).catchError((_) {
        // A failed lookup leaves the shortage block exactly as it was. It must
        // never take the order card down with it.
        if (mounted) setState(() => _subOffers[orderId] = const []);
      });
    }
    return const [];
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


