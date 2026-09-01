import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../order_hours_state.dart';
import '../inquiry_lock_state.dart';
import '../utils/order_code.dart';
import 'bulk_upload_screen.dart';
import '../utils/render_log.dart';
import '../models/cart_model.dart';
import '../models/product.dart';
import '../design_tokens.dart';
import '../theme.dart';
import '../user_state.dart';
import '../util.dart';
import '../services/ui_copy.dart';
import '../view_as_state.dart';
import '../widgets/animations.dart';
import '../widgets/checkout_pay_sheet.dart';
import 'auth/login_screen.dart';
import 'profile_screen.dart';
import 'customer/profile_edit_screen.dart'; // CHANGE #572 — the notice's action

class CartScreen extends StatefulWidget {
  final VoidCallback? onOrderPlaced;
  final String? externalSearchQuery;
  const CartScreen({super.key, this.onOrderPlaced, this.externalSearchQuery});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _orderInProgress = false;

  // ── CHANGE #553 — cart availability, straight from cart_availability() ─────
  // Every string and colour below is rendered by the backend. The client
  // decides nothing: it shows blocking_label when there is one, blocks Place
  // Order while it is there, and shows unresolved_note as a quiet note that
  // deliberately does NOT block (those are lines the backend could not check
  // and kept on purpose).
  /// CHANGE #639 — lets _placeOrder scroll the list to the first line
  /// cart_render() flagged when place_order_v2() rejects the cart. Only one
  /// _ItemList is ever mounted (the wide and narrow layouts are exclusive
  /// branches of the same LayoutBuilder), so one key is enough.
  final GlobalKey<_ItemListState> _itemListKey = GlobalKey<_ItemListState>();

  final Map<String, Availability> _lineAvailability = {};
  String? _blockingLabel;
  String? _unresolvedNote;
  bool _stripping = false;

  // CHANGE #175 — scheme data: free lines + savings + nudges
  List<Map<String, dynamic>> _freeLines = [];
  String _totalSavingsDisplay = '';
  List<Map<String, dynamic>> _schemeNudges = [];

  /// Product-id signature of the cart the last availability fetch covered —
  /// a change means the cart moved and the verdicts need re-reading.
  String? _availSignature;

  static String _signatureOf(List<CartLine> lines) {
    final ids = lines.map((l) => l.product.id).toList()..sort();
    return ids.join(',');
  }

  Future<void> _refreshAvailability(List<CartLine> lines) async {
    final signature = _signatureOf(lines);
    _availSignature = signature;
    if (lines.isEmpty) {
      if (!mounted) return;
      setState(() {
        _lineAvailability.clear();
        _blockingLabel = null;
        _unresolvedNote = null;
      });
      return;
    }
    try {
      final res = await Supabase.instance.client.rpc('cart_availability');
      if (!mounted || _availSignature != signature) return;
      final m = Map<String, dynamic>.from(res as Map);
      final items = (m['items'] as List?) ?? const [];
      final next = <String, Availability>{};
      for (final raw in items) {
        final row = Map<String, dynamic>.from(raw as Map);
        final id = row['product_id']?.toString();
        final av = Availability.fromMap(row['availability']);
        if (id != null && av != null) next[id] = av;
      }
      RenderLog.write('c553_cart_avail',
          'gated=${m['gated']};unavailable=${m['unavailable_count']};unresolved=${m['unresolved_count']}');
      setState(() {
        _lineAvailability
          ..clear()
          ..addAll(next);
        _blockingLabel = m['blocking_label']?.toString();
        _unresolvedNote = m['unresolved_note']?.toString();
      });
    } catch (_) {
      // Fail open: a failed check never invents a block.
      if (!mounted || _availSignature != signature) return;
      setState(() {
        _lineAvailability.clear();
        _blockingLabel = null;
        _unresolvedNote = null;
      });
    }
    _refreshSchemes();
  }

  Future<void> _refreshSchemes() async {
    try {
      final res = await Supabase.instance.client.rpc('cart_apply_schemes');
      final nudgeRes = await Supabase.instance.client.rpc('cart_scheme_nudge');
      if (!mounted) return;
      final m = Map<String, dynamic>.from(res as Map);
      final nm = Map<String, dynamic>.from(nudgeRes as Map);
      setState(() {
        _freeLines = ((m['free_lines'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _totalSavingsDisplay = (m['total_savings_display'] ?? '').toString();
        _schemeNudges = ((nm['nudges'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      });
    } catch (_) {
      // Scheme display is advisory — never block on failure.
    }
  }

  /// Removes the unavailable lines server-side, then re-reads both the cart
  /// and the verdicts. The backend's own message is shown verbatim.
  Future<void> _stripUnavailable(CartModel cart) async {
    if (_stripping) return;
    setState(() => _stripping = true);
    try {
      // No arguments — the RPC cleans the signed-in user's own cart.
      final res = await Supabase.instance.client.rpc('cart_strip_unavailable');
      final m = Map<String, dynamic>.from(res as Map);
      final message = m['message']?.toString();
      RenderLog.write('c553_strip', 'removed=${m['removed_count']};kept=${m['unresolved_kept']}');
      await cart.reloadFromServer();
      if (!mounted) return;
      _availSignature = null;
      await _refreshAvailability(cart.lines);
      if (!mounted) return;
      if (message != null && message.isNotEmpty) showToast(context, message);
    } catch (e) {
      if (mounted) showToast(context, c('cart.strip_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _stripping = false);
    }
  }

  @override
  void initState() {
    super.initState();
    // CHANGE #455 D2 — belt-and-braces: re-fetch the moment the cart/checkout
    // screen opens, alongside the realtime subscription and the app-resume
    // hook in OrderHoursModel. A dropped socket must never leave a customer
    // stuck on a stale message here specifically.
    OrderHoursState.read(context).refresh();
    // CHANGE #456 D1 — call inquiry_lock_state() alongside order_hours_state()
    // on the cart/checkout screen.
    InquiryLockState.read(context).refresh();
    // CHANGE #293 — the button word and the pay-at-checkout decision.
    _fetchCheckoutAction();
  }

  // CHANGE #324/#435: ViewAs checkbox state — admin-added items checked, customer
  // items unchecked, by default. Re-applied on EVERY build (not just once) so rows
  // that arrive in a later rebuild (partial load, then full load) also get defaulted
  // correctly — the #324 bug was that the default only ran once, so admin rows that
  // showed up after the first non-empty build stayed unchecked forever.
  // _viewAsManualOverride tracks ids the user has explicitly toggled this session —
  // those keep the user's choice across rebuilds; everything else re-derives from
  // added_by every time.
  final Set<String> _viewAsChecked = {};

  /// CHANGE #597 — the View As selected-line subtotal, computed AND formatted
  /// by cart_selected_total(). It used to be summed in build() from
  /// product.b2bPrice * quantity and then run through rupees() — the app both
  /// pricing the selection and formatting it.
  ///
  /// CHANGE #615 — the caption comes from the same call, so the ticked-lines
  /// footer reads exactly like the whole-cart one and cannot word its own
  /// "N items • MRP worth …".
  String _selectedTotalDisplay = '';
  String _selectedSubtotalLine = '';

  Future<void> _refreshSelectedTotal() async {
    if (!mounted) return;
    try {
      final raw = await Supabase.instance.client.rpc('cart_selected_total',
          params: {'p_product_ids': _viewAsChecked.toList()});
      final m = (raw is List ? raw.first : raw) as Map;
      if (mounted) {
        setState(() {
          _selectedTotalDisplay = (m['subtotal_display'] ?? '').toString();
          _selectedSubtotalLine = (m['subtotal_line'] ?? '').toString();
        });
      }
    } catch (_) {}
  }
  final Set<String> _viewAsManualOverride = {};

  void _applyViewAsDefaults(List<CartLine> lines) {
    var adminCount = 0;
    var checkedCount = 0;
    for (final line in lines) {
      final id = line.product.id;
      if (line.addedByAdmin) adminCount++;
      if (!_viewAsManualOverride.contains(id)) {
        // user's explicit choice (if any) wins — everything else re-derives from added_by.
        if (line.addedByAdmin) {
          _viewAsChecked.add(id);
          _refreshSelectedTotal();
        } else {
          _viewAsChecked.remove(id);
          _refreshSelectedTotal();
        }
      }
      if (_viewAsChecked.contains(id)) checkedCount++;
    }
    RenderLog.write('c435_cart_defaults',
        'rows=${lines.length};admin=$adminCount;checked=$checkedCount');
  }

  void _toggleViewAsChecked(String productId) {
    setState(() {
      _viewAsManualOverride.add(productId);
      if (_viewAsChecked.contains(productId)) {
        _viewAsChecked.remove(productId);
        _refreshSelectedTotal();
      } else {
        _viewAsChecked.add(productId);
        _refreshSelectedTotal();
      }
    });
  }

  // ── CHANGE #293 — which of the three placement paths am I on? ──────────
  // checkout_action() answers it server-side: the collection mode, whether
  // this session is an admin acting as a customer (never a client flag), and
  // the button word itself. Empty until the backend has spoken — the old
  // ui_copy label stands in until then, so a slow RPC never blanks the button.
  Map<String, dynamic> _checkout = const <String, dynamic>{};

  String get _placeOrderLabel =>
      (_checkout['button_label'] ?? '').toString();

  /// CHANGE #572 — the ONE notice's inline action.
  ///
  /// `render.notice.action` is a descriptor, not a route: the payload says
  /// there IS an action, what it is called and which profile field it is
  /// about. Only the navigation is ours. An action kind this build has never
  /// heard of opens nothing, in silence — the same forward-compat rule the
  /// home feed follows for an unknown layout.
  Future<void> _openNoticeAction(Map<String, dynamic> action) async {
    if ((action['kind'] ?? '').toString() != 'profile_edit') return;
    RenderLog.write('c572_notice_action', (action['field'] ?? '').toString());
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ProfileEditScreen()));
    if (!mounted) return;
    // The licence may now be on file, so the gate has to be asked again.
    await AppState.of(context).reloadFromServer();
  }

  Future<void> _fetchCheckoutAction() async {
    try {
      final raw = await Supabase.instance.client.rpc('checkout_action');
      if (!mounted) return;
      if (raw is Map) {
        setState(() => _checkout = raw.cast<String, dynamic>());
        RenderLog.write('c293_checkout_action',
            'mode=${_checkout['collection_mode']};pay=${_checkout['pay_now']}');
      }
    } catch (_) {
      // An absent payload is an absence: the button keeps its ui_copy label.
    }
  }

  /// The gateway payment sheet for an order the CUSTOMER just placed for
  /// themselves.
  ///
  /// CHANGE #304 — `razorpay-checkout-create` decides the branch server-side
  /// (`rzp_pay_mode()`): a real customer paying on the phone in their hand gets
  /// Razorpay Checkout, which opens PhonePe/GPay; a payer who is on a DIFFERENT
  /// phone still gets the QR. Either way the call REUSES an open attempt, so
  /// reopening this sheet never mints a second payable object for one order —
  /// that is what "Resume payment" is.
  Future<void> _showCheckoutQr(String orderId, String code, String amount) async {
    final rzpCopy = await _fetchRazorpayCopy(orderId);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (sheetCtx) => CheckoutPaySheet(
        orderId: orderId,
        checkout: _checkout,
        razorpayCopy: rzpCopy,
        orderCode: code,
        amountDisplay: amount,
        createPayment: (id) async {
          final res = await Supabase.instance.client.functions.invoke(
              'razorpay-checkout-create',
              body: {'order_id': id, 'kind': 'advance'});
          final d = res.data;
          final m = d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
          RenderLog.write('c304_checkout_create',
              'mode=${m['pay_mode']};ok=${m['ok']};reused=${m['reused']}');
          return m;
        },
        checkPaid: (id) async {
          final d = await Supabase.instance.client.rpc('rzp_checkout_state',
              params: {'p_order_id': id, 'p_kind': 'advance'});
          return d is Map ? d.cast<String, dynamic>() : <String, dynamic>{};
        },
        openUrl: (url) async {
          // externalApplication is what makes Android hand the UPI intent to
          // PhonePe/GPay instead of burying checkout in a webview; on web it is
          // a new tab. Never launched from inside the widget — see the sheet.
          RenderLog.write('c304_checkout_open', 'launched');
          return launchUrl(Uri.parse(url),
              mode: LaunchMode.externalApplication, webOnlyWindowName: '_blank');
        },
        onDone: () => Navigator.of(sheetCtx).pop(),
      ),
    );
  }

  /// The sheet's loading / error / retry words, from the same block the My
  /// Orders payment panel reads — one source, so the two sheets cannot drift.
  Future<Map<String, dynamic>> _fetchRazorpayCopy(String orderId) async {
    try {
      final d = await Supabase.instance.client
          .rpc('customer_order_payment_panel_v2', params: {'p_order_id': orderId});
      if (d is Map) {
        final upi = d['upi'];
        if (upi is Map && upi['razorpay'] is Map) {
          return (upi['razorpay'] as Map).cast<String, dynamic>();
        }
      }
    } catch (_) {/* absence, not a default */}
    return const <String, dynamic>{};
  }

  Future<void> _placeOrder() async {
    if (_orderInProgress) return;

    // CHANGE #309 (5) — the backend already said this address is outside the
    // delivery area. Refused here with the backend's own words, before the
    // order exists, so nothing has to be cancelled afterwards.
    if (_checkout['can_order'] == false) {
      final srv = _checkout['serviceability'] is Map
          ? Map<String, dynamic>.from(_checkout['serviceability'] as Map)
          : const <String, dynamic>{};
      RenderLog.write('c309_checkout_blocked', srv['pincode']?.toString() ?? '');
      _showOrderGate(
        title: srv['title']?.toString() ?? '',
        message: srv['message']?.toString() ?? '',
      );
      return;
    }

    final cart = AppState.of(context);
    final viewAs = ViewAsState.of(context);

    // ── ViewAs: place a real order for the impersonated customer ────────────
    if (cart.isViewAs && viewAs.isActive && viewAs.role == ViewAsRole.customer) {
      if (cart.lines.isEmpty) return;

      // CHANGE #456 C8 — inquiry lock gates ADMIN ordering only (this
      // includes acting-as-customer). Customers are never gated by it — they
      // are governed by Order Hours only. Do NOT check this outside ViewAs.
      final inquiryLock = InquiryLockState.read(context);
      if (inquiryLock.locked) {
        RenderLog.write('c456_viewas_blocked', 'true');
        _showOrderGate(
          title: c('cart.inquiry_lock_title'),
          message: inquiryLock.message ?? c('cart.inquiry_lock_message'),
        );
        return;
      }

      // Approval gate: mirrors the real customer path — unapproved accounts cannot order.
      if (viewAs.identity?.isApproved != true) {
        RenderLog.write('view_as_order_blocked',
            'unapproved:${viewAs.identity?.userId ?? 'unknown'}');
        if (mounted) {
          showToast(
              context,
              cf('cart.viewas_pending_approval', {
                'name': viewAs.identity?.name ?? c('cart.viewas_this_customer')
              }),
              isError: true);
        }
        return;
      }

      final name = viewAs.identity?.name ?? c('cart.viewas_this_customer');
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(c('cart.viewas_confirm_title'),
              style: const TextStyle(fontWeight: FontWeight.w700)),
          content: Text(cf('cart.viewas_confirm_body', {'name': name})),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(c('cart.viewas_confirm_cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD97706)),
              child: Text(c('cart.viewas_confirm_place')),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;

      setState(() => _orderInProgress = true);
      try {
        final customerId = viewAs.identity?.userId;
        if (customerId == null) {
          showToast(context, c('cart.viewas_missing_customer_id'), isError: true);
          return;
        }
        // CHANGE #598 — the client sends WHO and WHICH LINES. Prices, totals,
        // the address and the order number all come from the server, exactly
        // as place_order_v2() does for the customer path. This used to build
        // the items array with price/mrp/gst/line_total per line and fold its
        // own netPayable, so an admin-placed order could be priced by whatever
        // the browser happened to hold.
        if (_viewAsChecked.isEmpty) {
          if (mounted) showToast(context, c('cart.viewas_select_one_item'), isError: true);
          return;
        }
        RenderLog.write('actas_order_fix_374', 'userId:$customerId,approved:${viewAs.identity?.isApproved}');
        final placedRaw = await Supabase.instance.client.rpc(
          'admin_writeas_place_order_v2',
          params: {
            'p_customer_id': viewAs.identity!.id,
            'p_product_ids': _viewAsChecked.toList(),
          },
        );
        final placed = (placedRaw is List ? placedRaw.first : placedRaw) as Map;
        final orderId = placed['id'];
        final netPayableDisplay = (placed['amount_display'] ?? '').toString();
        RenderLog.write('c324_place_selected',
            'order:$orderId:customer:$customerId:checked:${_viewAsChecked.length}');
        // CHANGE #323/#324: WhatsApp convert finalize — stamp source='whatsapp'
        // and mark image done.  No-op when no WA session is active.
        if (orderId != null && BulkUploadScreen.onWaOrderPlaced != null) {
          RenderLog.write('c324_wa_finalize', 'orderId:$orderId');
          await BulkUploadScreen.onWaOrderPlaced!(orderId.toString());
        }
        if (!mounted) return;
        // #598 — the order code comes back in the same payload; no read-back.
        final String viewAsDisplayCode = (placed['order_code'] ?? '').toString();
        if (!mounted) return;
        // CHANGE #324: remove ONLY the ordered (checked) rows; leave unchecked
        // customer-added rows in the cart. Defaults re-apply automatically on the
        // next build (CHANGE #435) — no manual reinit needed.
        // #598 — the server already removed the ordered lines; re-read rather
        // than mutating the local cart optimistically.
        await cart.refresh();
        _viewAsChecked.clear();
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => _OrderPlacedDialog(
            orderNumber: viewAsDisplayCode,
            amount: netPayableDisplay,
            onDone: () {
              Navigator.of(context).pop();
              widget.onOrderPlaced?.call();
            },
          ),
        );
      } catch (e) {
        // CHANGE #374 — surface the RPC's specific gate errors with friendly text.
        final msg = e.toString();
        if (mounted) {
          if (msg.contains('account_pending_approval')) {
            showToast(context, c('cart.viewas_customer_not_approved'), isError: true);
          } else if (msg.contains('forbidden') && msg.contains('super_admin')) {
            showToast(context, c('cart.viewas_super_admin_only'), isError: true);
          } else if (msg.contains('inquiry_in_progress')) {
            // CHANGE #456 C8 belt-and-braces — the trigger gates admin-as-
            // customer orders (placed_by_admin=true) even if the UI's cached
            // lock state is stale. Re-fetch and show the gate.
            RenderLog.write('c456_viewas_blocked', 'true');
            final il = InquiryLockState.read(context);
            await il.refresh();
            if (mounted) {
              _showOrderGate(
                title: c('cart.inquiry_lock_title'),
                message: il.message ?? c('cart.inquiry_lock_message'),
              );
            }
          } else {
            showToast(context, cf('cart.viewas_place_failed', {'error': '$e'}),
                isError: true);
          }
        }
      } finally {
        if (mounted) setState(() => _orderInProgress = false);
      }
      return;
    }
    // ── Normal (non-ViewAs) flow ─────────────────────────────────────────────

    final auth = UserState.read(context);
    if (!auth.isAuthenticated) {
      await Navigator.push(context,
          MaterialPageRoute(builder: (_) => const LoginScreen()));
      return;
    }
    // #571 — ONE gate. The backend decided whether this account may order and
    // wrote the exact words for the case where it may not. The four-step Dart
    // ladder this replaces (isRegistered -> suspended -> canOrder, with seven
    // hardcoded strings) re-derived answers my_session() already held.
    //
    // has_blocker is what closes the gate. An empty title must never be read
    // as "there is no problem".
    final gate = auth.orderGate;
    if (gate.hasBlocker) {
      RenderLog.write('order_blocked', gate.reason);
      _showOrderGate(
        title: gate.title,
        message: gate.message,
        actionLabel: gate.actionLabel.isEmpty ? null : gate.actionLabel,
        // #402: the action must actually open the registration screen.
        onAction: gate.actionLabel.isEmpty
            ? null
            : () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const ProfileScreen())),
      );
      return;
    }
    RenderLog.write('order_approval_passed', 'approved:true');

    // CHANGE #446/455: block placing an order while order hours are closed.
    // Belt-and-braces primary gate — the DB also enforces this (order_hours_closed).
    // C2 — popup_title/popup_message/reopen_hint printed VERBATIM, exactly as
    // order_hours_state() sends them. Never composed/prefixed in Dart.
    final orderHours = OrderHoursState.read(context);
    if (!orderHours.canOrder) {
      RenderLog.write('c444_cust_blocked', 'true');
      if (mounted) {
        _showOrderGate(
          title: orderHours.popupTitle ?? '',
          message: orderHours.popupMessage ?? '',
          secondLine: orderHours.reopenHint,
        );
      }
      return;
    }

    // CHANGE #553 — ordering is blocked by the backend's blocking_label and
    // nothing else. No local supplier comparison, no locally-worded message:
    // cart_availability() decides, and its own label is what the buyer reads.
    final blockingLabel = _blockingLabel;
    if (blockingLabel != null) {
      RenderLog.write('c553_order_blocked', blockingLabel);
      if (mounted) showToast(context, blockingLabel, isError: true);
      return;
    }

    setState(() => _orderInProgress = true);

    try {
      // #571 — place_order_v2() takes NOTHING from the client.
      //
      // What this replaces: a direct INSERT into `orders` where the app sent
      // the items array *including price, mrp and line_total*, a
      // client-computed net payable, an address it joined together from
      // profile fields, and user_id — the LOGIN, not the account. A buyer
      // could name their own price, a client total could disagree with the
      // cart it came from, and orders keyed to a credential disappeared the
      // moment someone signed in another way.
      //
      // Now the server reads its own cart, prices it, totals it, resolves the
      // account's address, stamps customer_id, and empties the cart itself.
      // The response is render-ready; nothing below formats anything.
      final raw = await Supabase.instance.client.rpc('place_order_v2');
      final res = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (res is! Map) throw StateError('place_order_v2 returned no payload');
      final placed = res.cast<String, dynamic>();

      // CHANGE #639 — place_order_v2() refuses a cart that still holds
      // unavailable lines. Its own message is shown verbatim (this file words
      // nothing), the cart is re-read so the red flags and the chip match what
      // the server just decided, and the list scrolls to the first offending
      // line so the buyer can see what to remove.
      final refusal = CartOrderRefusal.from(placed);
      if (refusal.isUnavailableInCart) {
        RenderLog.write('c639_order_blocked_unavailable', refusal.count);
        await cart.refresh();
        if (!mounted) return;
        if (refusal.message.isNotEmpty) {
          showToast(context, refusal.message, isError: true);
        }
        _itemListKey.currentState?.scrollToFirstUnavailable();
        return;
      }

      // CHANGE #461/#170 — a basket holding prescription stock is refused when
      // the pharmacy has no valid drug licence on file and the gate is set to
      // 'block'. The backend's own title and message are shown verbatim; this
      // file words nothing and never decides what "valid" means.
      if (placed['error'] == 'rx_licence_required') {
        RenderLog.write('c461_order_blocked_rx', '1');
        await cart.refresh();
        if (!mounted) return;
        final rxMsg = (placed['message'] ?? '').toString();
        if (rxMsg.isNotEmpty) showToast(context, rxMsg, isError: true);
        return;
      }

      final displayCode = (placed['order_code'] ?? '').toString();
      final amountDisplay = (placed['amount_display'] ?? '').toString();

      if (!mounted) return;

      // The SERVER already emptied the cart. This re-reads it rather than
      // clearing a local copy optimistically — send, await, render.
      cart.refresh();
      cart.fetchOrders(); // refresh order list from Supabase (fire and forget)

      // CHANGE #293 — "Pay & Place Order": in Payment Gateway mode a customer
      // paying for their OWN order sees the QR immediately and the sheet flips
      // itself when the webhook confirms. The decision is the backend's
      // (checkout_action().pay_now), never a client guess about roles.
      final orderId = (placed['id'] ?? '').toString();
      if (_checkout['pay_now'] == true && orderId.isNotEmpty) {
        RenderLog.write('c293_checkout_pay_now', 1);
        await _showCheckoutQr(orderId, displayCode, amountDisplay);
        if (!mounted) return;
        widget.onOrderPlaced?.call();
        return;
      }

      // Acting-as in gateway mode: the server already pushed the QR to the
      // customer on WhatsApp. Its sentence, printed verbatim.
      final actingNote = (_checkout['actingas_note'] ?? '').toString();
      if (actingNote.isNotEmpty) showToast(context, actingNote);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _OrderPlacedDialog(
          orderNumber: displayCode,
          // #571 — the backend formats the money. No rupees() in Dart here.
          amount: amountDisplay,
          onDone: () {
            Navigator.of(context).pop();
            widget.onOrderPlaced?.call();
          },
        ),
      );
    } on PostgrestException catch (e) {
      if (!mounted) return;
      // CHANGE #446/455 belt-and-braces: a stale tab can still hit the DB gate
      // even with the button disabled. Re-fetch order_hours_state() (the
      // realtime subscription may simply not have delivered yet) and show the
      // SAME popup as the pre-check — popup_title/popup_message/reopen_hint,
      // VERBATIM. The DB exception's HINT field is no longer read: after
      // refresh() the model's own fields are already current.
      // CHANGE #456 — the inquiry lock does NOT gate real customer orders
      // (trg_orders_inquiry_lock_gate exempts placed_by_admin=false rows), so
      // this normal-flow catch only ever needs to handle order_hours_closed.
      final isOrderHoursClosed =
          e.message.contains('order_hours_closed') || (e.code ?? '').contains('order_hours_closed');
      if (isOrderHoursClosed) {
        RenderLog.write('c444_cust_blocked', 'true');
        final oh = OrderHoursState.read(context);
        await oh.refresh();
        if (!mounted) return;
        _showOrderGate(
          title: oh.popupTitle ?? '',
          message: oh.popupMessage ?? '',
          secondLine: oh.reopenHint,
        );
      } else {
        showToast(context, c('cart.place_order_failed'), isError: true);
      }
    } catch (e) {
      if (!mounted) return;
      showToast(context, c('cart.place_order_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _orderInProgress = false);
    }
  }

  // CHANGE #548: the order number is stamped by the SERVER (next_order_number),
  // never derived from the device clock — a client-guessed number could
  // disagree with the stored record.
  static Future<String> _generateOrderNumber() async {
    final res = await Supabase.instance.client.rpc('next_order_number');
    return res?.toString() ?? '';
  }

  void _showOrderGate({
    required String title,
    required String message,
    // CHANGE #455 C2 — reopen_hint, printed VERBATIM as a second line when
    // the server sends one. Never composed into `message`.
    String? secondLine,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: secondLine == null
            ? Text(message,
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151)))
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(message,
                      style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
                  const SizedBox(height: 8),
                  Text(secondLine,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                ],
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(c('cart.gate_ok')),
          ),
          if (actionLabel != null && onAction != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                onAction();
              },
              style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B5E20)),
              child: Text(actionLabel),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cart = AppState.of(context);

    // CHANGE #553 — re-read cart_availability() whenever the set of products
    // in the cart changes (first load, add, remove, strip). _refreshAvailability
    // claims the signature immediately, so this fires once per real change.
    if (_signatureOf(cart.lines) != _availSignature) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final lines = cart.lines;
        if (_signatureOf(lines) != _availSignature) _refreshAvailability(lines);
      });
    }

    if (cart.lines.isEmpty) {
      return const _EmptyCart();
    }

    // CHANGE #324/#435: re-apply ViewAs checkbox defaults (admin-added → checked)
    // on EVERY build, not just once — see _applyViewAsDefaults for why.
    if (cart.isViewAs) {
      _applyViewAsDefaults(cart.lines);
    } else if (_viewAsChecked.isNotEmpty || _viewAsManualOverride.isNotEmpty) {
      // Left ViewAs mode — reset session state so re-entering (same or different
      // customer) starts fresh from the added_by defaults.
      _viewAsChecked.clear();
      _viewAsManualOverride.clear();
    }

    // #597 — the subtotal is the server's; this only decides whether to show it.
    final String? selectedTotal = cart.isViewAs ? _selectedTotalDisplay : null;

    final banner = cart.hasSampleItems ? _SampleBanner(cart: cart) : null;

    // CHANGE #553 — blocking_label blocks ordering; unresolved_note never does.
    final blocking = _blockingLabel;
    final availBanner = blocking == null
        ? null
        : _AvailabilityBanner(
            label: blocking,
            busy: _stripping,
            onStrip: () => _stripUnavailable(cart),
          );
    final unresolvedNote =
        _unresolvedNote == null ? null : _UnresolvedNote(note: _unresolvedNote!);

    // CHANGE #309 (5) — pincode serviceability, answered by checkout_action()
    // before an order exists. Three states, and the app distinguishes none of
    // them itself: it prints the backend's title/message/tone and blocks only
    // when the backend says can_order is false. A pincode we simply have not
    // listed yet warns and still lets a licensed pharmacy order — refusing them
    // outright would lose a real customer over a missing row.
    final srv = _checkout['serviceability'] is Map
        ? Map<String, dynamic>.from(_checkout['serviceability'] as Map)
        : const <String, dynamic>{};
    final srvMode = srv['mode']?.toString() ?? 'serviceable';
    final srvBanner = (srv['checked'] == true && srvMode != 'serviceable')
        ? _ServiceabilityBanner(
            title: srv['title']?.toString() ?? '',
            message: srv['message']?.toString() ?? '',
            tone: srv['tone'] is Map
                ? Map<String, dynamic>.from(srv['tone'] as Map)
                : const <String, dynamic>{},
          )
        : null;

    // A blocked pincode blocks placement exactly the way an unavailable line
    // does, so there is ONE disabled-button rule rather than two.
    final blocked = blocking != null || _checkout['can_order'] == false;

    // CHANGE #639 — the chip cart_render() worded for its flagged lines. It
    // appears only while the BACKEND reports a non-zero count, and its text is
    // printed verbatim: nothing here counts lines or pluralises "item(s)".
    // After a removal the next payload carries a smaller count (or drops the
    // badge entirely), so re-rendering clears it with no local bookkeeping.
    final unavailableChip =
        cart.unavailableCount > 0 && cart.unavailableBadge.isNotEmpty
            ? _UnavailableChip(text: cart.unavailableBadge)
            : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 600;

        if (wide) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (banner != null) banner,
              ?availBanner,
            ?srvBanner,
              ?srvBanner,
              ?unresolvedNote,
              ?unavailableChip,
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 3,
                            child: _ItemList(
                              key: _itemListKey,
                              cart: cart,
                              externalSearchQuery: widget.externalSearchQuery,
                              viewAsChecked: cart.isViewAs ? _viewAsChecked : null,
                              onViewAsToggle: cart.isViewAs ? _toggleViewAsChecked : null,
                              lineAvailability: _lineAvailability,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            flex: 2,
                            child: _OrderSummaryPanel(
                              cart: cart,
                              onPlaceOrder: _placeOrder,
                              placeOrderLabel: _placeOrderLabel,
                              onNoticeAction: _openNoticeAction,
                              selectedTotal: selectedTotal,
                              selectedSubtotalLine: _selectedSubtotalLine,
                              availabilityBlocked: blocked,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        final schemeSection = (_freeLines.isNotEmpty || _schemeNudges.isNotEmpty)
            ? _SchemeSection(
                freeLines: _freeLines,
                totalSavingsDisplay: _totalSavingsDisplay,
                nudges: _schemeNudges,
              )
            : null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (banner != null) banner,
            ?availBanner,
            ?unresolvedNote,
            ?unavailableChip,
            Expanded(
              child: _ItemList(
                key: _itemListKey,
                cart: cart,
                externalSearchQuery: widget.externalSearchQuery,
                viewAsChecked: cart.isViewAs ? _viewAsChecked : null,
                onViewAsToggle: cart.isViewAs ? _toggleViewAsChecked : null,
                lineAvailability: _lineAvailability,
              ),
            ),
            if (schemeSection != null) schemeSection,
            _CheckoutBar(
              cart: cart,
              onPlaceOrder: _placeOrder,
              placeOrderLabel: _placeOrderLabel,
              onNoticeAction: _openNoticeAction,
              selectedTotal: selectedTotal,
              selectedSubtotalLine: _selectedSubtotalLine,
              availabilityBlocked: blocked,
            ),
          ],
        );
      },
    );
  }
}

// ─── CHANGE #553 — availability banner + unresolved note ─────────────────────

/// Shows `cart_availability().blocking_label` verbatim and offers the one
/// action that clears it: `cart_strip_unavailable()`. While this is on screen
/// Place Order is blocked. The wording is the backend's, not ours.
// CHANGE #309 (5) — the serviceability notice. Colours arrive as the backend's
// own tone pair, so 'warn' is amber and 'blocked' is red without this file
// knowing which is which.
class _ServiceabilityBanner extends StatelessWidget {
  final String title;
  final String message;
  final Map<String, dynamic> tone;
  const _ServiceabilityBanner({
    required this.title,
    required this.message,
    required this.tone,
  });

  static Color? _hex(String? h) {
    final v = (h ?? '').trim().replaceFirst('#', '');
    if (v.length != 6) return null;
    final n = int.tryParse('FF$v', radix: 16);
    return n == null ? null : Color(n);
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c309_serviceability_banner', title);
    // The tone pair is the BACKEND's; the token layer supplies the fallback,
    // so an older payload with no tone still paints inside the design system.
    final fg = _hex(tone['fg']?.toString()) ?? Ds.c.warning;
    return Container(
      width: double.infinity,
      color: _hex(tone['bg']?.toString()) ?? Ds.c.warningSoft,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.local_shipping_outlined, size: 18, color: fg),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (title.isNotEmpty)
              Text(title,
                  style: Ds.t.body.copyWith(
                      fontWeight: FontWeight.w700, color: fg)),
            if (message.isNotEmpty) ...[
              if (title.isNotEmpty) SizedBox(height: Ds.space.x4),
              Text(message, style: Ds.t.caption.copyWith(color: fg)),
            ],
          ]),
        ),
      ]),
    );
  }
}

class _AvailabilityBanner extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback onStrip;
  const _AvailabilityBanner({
    required this.label,
    required this.busy,
    required this.onStrip,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c553_blocking_label', label);
    return Container(
      width: double.infinity,
      color: const Color(0xFFFEF2F2),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.error_outline, size: 18, color: Color(0xFFB91C1C)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFFB91C1C),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: busy ? null : onStrip,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              textStyle: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
            child: busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(c('cart.remove_unavailable')),
          ),
        ],
      ),
    );
  }
}

/// `unresolved_note` — items the backend could not verify and deliberately
/// kept. Quiet, grey, and never a blocker.
class _UnresolvedNote extends StatelessWidget {
  final String note;
  const _UnresolvedNote({required this.note});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c553_unresolved_note', note);
    return Container(
      width: double.infinity,
      color: const Color(0xFFF9FAFB),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        note,
        style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280)),
      ),
    );
  }
}

// ─── Sample banner ────────────────────────────────────────────────────────────

/// CHANGE #639 — the chip for `unavailable_badge`. It prints ONE backend
/// string and holds no logic: no count, no pluralisation, no wording. It is
/// built only when cart_render() reported a non-zero `unavailable_count`.
class _UnavailableChip extends StatelessWidget {
  final String text;
  const _UnavailableChip({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey('c639_unavailable_badge'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFFEE2E2),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFCA5A5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline,
                  size: 15, color: Color(0xFF991B1B)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF991B1B),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// CHANGE #175 — scheme section: free lines + savings banner + nudge cards
class _SchemeSection extends StatelessWidget {
  final List<Map<String, dynamic>> freeLines;
  final String totalSavingsDisplay;
  final List<Map<String, dynamic>> nudges;
  const _SchemeSection({
    required this.freeLines,
    required this.totalSavingsDisplay,
    required this.nudges,
  });

  @override
  Widget build(BuildContext context) {
    final successBg = Ds.c.successSoft;
    final successFg = Ds.c.success;
    return Container(
      color: successBg,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (freeLines.isNotEmpty) ...[
            for (final line in freeLines)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Row(
                  children: [
                    Icon(Icons.card_giftcard_outlined,
                        size: 16, color: successFg),
                    SizedBox(width: Ds.space.x8),
                    Expanded(
                      child: Text(
                        (line['label'] ?? '').toString(),
                        style: Ds.t.caption.copyWith(
                            color: successFg,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            if (totalSavingsDisplay.isNotEmpty)
              Text(
                totalSavingsDisplay,
                style: Ds.t.caption.copyWith(
                    color: successFg, fontWeight: FontWeight.w700),
              ),
          ],
          if (nudges.isNotEmpty) ...[
            if (freeLines.isNotEmpty) SizedBox(height: Ds.space.x8),
            for (final nudge in nudges)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Text(
                  (nudge['label'] ?? '').toString(),
                  style: Ds.t.caption.copyWith(color: successFg),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _SampleBanner extends StatelessWidget {
  final CartModel cart;
  const _SampleBanner({required this.cart});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: const Color(0xFFFFF7ED),
      child: Row(
        children: [
          const Icon(Icons.timer_outlined, color: Color(0xFFEA580C), size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              cf('cart.sample_banner', {'seconds': '${cart.sampleCountdown}'}),
              style: const TextStyle(fontSize: 13, color: Color(0xFF9A3412)),
            ),
          ),
          TextButton(
            onPressed: cart.clearSampleItems,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFEA580C),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(c('cart.sample_dismiss'),
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

// ─── Fuzzy cart search ────────────────────────────────────────────────────────

bool _cartFuzzyMatch(String text, String query) {
  final hay = text.toLowerCase();
  final tokens = query.toLowerCase().trim().split(RegExp(r'\s+'));
  for (final token in tokens) {
    if (token.isEmpty) continue;
    if (hay.contains(token)) continue; // fast path: substring match
    // Typo-tolerance: check edit-distance ≤ 1 against any word in haystack
    final words = hay.split(RegExp(r'[\s,.\-/()]+'));
    bool hit = false;
    for (final word in words) {
      if (token.length >= 3 && word.length >= 3 &&
          _editDistance(token, word) <= 1) {
        hit = true;
        break;
      }
    }
    if (!hit) return false;
  }
  return true;
}

int _editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  if ((a.length - b.length).abs() > 2) return 3;
  final d = List.generate(
      a.length + 1, (i) => List.filled(b.length + 1, 0));
  for (int i = 0; i <= a.length; i++) d[i][0] = i;
  for (int j = 0; j <= b.length; j++) d[0][j] = j;
  for (int i = 1; i <= a.length; i++) {
    for (int j = 1; j <= b.length; j++) {
      d[i][j] = a[i - 1] == b[j - 1]
          ? d[i - 1][j - 1]
          : 1 +
              [d[i - 1][j], d[i][j - 1], d[i - 1][j - 1]]
                  .reduce((x, y) => x < y ? x : y);
    }
  }
  return d[a.length][b.length];
}

// ─── Item list ────────────────────────────────────────────────────────────────

class _ItemList extends StatefulWidget {
  final CartModel cart;
  final String? externalSearchQuery;
  // CHANGE #324: ViewAs checkbox state — null means not ViewAs (show X button).
  final Set<String>? viewAsChecked;
  final void Function(String productId)? onViewAsToggle;

  /// CHANGE #553 — product_id → the backend's verdict for that cart line,
  /// from cart_availability(). Empty until the first fetch answers.
  final Map<String, Availability> lineAvailability;
  const _ItemList({
    super.key,
    required this.cart,
    this.externalSearchQuery,
    this.viewAsChecked,
    this.onViewAsToggle,
    this.lineAvailability = const {},
  });

  @override
  State<_ItemList> createState() => _ItemListState();
}

class _ItemListState extends State<_ItemList> {
  String get _effectiveQuery =>
      widget.externalSearchQuery ?? '';

  bool _showRemoved = false;

  /// CHANGE #639 — used to bring the first line cart_render() flagged into
  /// view when place_order_v2() refuses the cart.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _firstUnavailableKey = GlobalKey();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Scrolls to the first unavailable line. Which line that is comes from the
  /// payload's own flag — this never re-derives availability.
  ///
  /// Two steps because the list is lazily built: an approximate jump first, so
  /// the target actually gets built when it started far off-screen, then
  /// ensureVisible on the real element to land it exactly.
  Future<void> scrollToFirstUnavailable() async {
    final lines = _filteredLines;
    final idx = lines.indexWhere((l) => l.unavailable);
    if (idx < 0) return;

    if (_scrollController.hasClients) {
      const approxCardExtent = 132.0;
      final target = (idx * approxCardExtent)
          .clamp(0.0, _scrollController.position.maxScrollExtent);
      await _scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final ctx = _firstUnavailableKey.currentContext;
    if (ctx != null) {
      await Scrollable.ensureVisible(
        ctx,
        alignment: 0.1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    }
    RenderLog.write('c639_scrolled_to_unavailable', idx);
  }

  List<CartLine> get _filteredLines {
    final q = _effectiveQuery.trim();
    if (q.isEmpty) return widget.cart.lines;
    return widget.cart.lines.where((l) {
      final text =
          '${l.product.name} ${l.product.genericName} ${l.product.manufacturer}';
      return _cartFuzzyMatch(text, q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filteredLines;
    final searchActive = _effectiveQuery.trim().isNotEmpty;

    if (searchActive && filtered.isEmpty) {
      return ListView(
        physics: platformScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.search_off,
                      size: 40, color: Color(0xFF9CA3AF)),
                  const SizedBox(height: 12),
                  Text(
                    cf('cart.search_no_results', {'query': _effectiveQuery.trim()}),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF374151),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    final removed = widget.cart.adminRemovedLines;
    final hasRemoved = removed.isNotEmpty && !searchActive;

    int afterCount = 0;
    if (hasRemoved) {
      afterCount += 1;
      if (_showRemoved) afterCount += removed.length;
    }

    // CHANGE #639 — index of the first line the BACKEND flagged, so the
    // scroll-to target can be tagged as it is built.
    final firstUnavailable = filtered.indexWhere((l) => l.unavailable);

    return ListView.builder(
      physics: platformScrollPhysics(),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      cacheExtent: 400,
      itemCount: filtered.length + afterCount,
      itemBuilder: (context, i) {
        if (i < filtered.length) {
          final line = filtered[i];
          return RepaintBoundary(
            key: ValueKey(line.product.id),
            child: _CartItemCard(
              key: i == firstUnavailable ? _firstUnavailableKey : null,
              line: line,
              cart: widget.cart,
              viewAsChecked: widget.viewAsChecked != null
                  ? widget.viewAsChecked!.contains(line.product.id)
                  : null,
              onViewAsToggle: widget.onViewAsToggle != null
                  ? () => widget.onViewAsToggle!(line.product.id)
                  : null,
              availability: widget.lineAvailability[line.product.id],
            ),
          );
        }

        int extra = i - filtered.length;

        if (hasRemoved) {
          if (extra == 0) {
            return _RemovedByAdminHeader(
              count: removed.length,
              expanded: _showRemoved,
              onToggle: () => setState(() => _showRemoved = !_showRemoved),
            );
          }
          extra -= 1;
          if (_showRemoved && extra < removed.length) {
            return _RemovedItemCard(line: removed[extra], cart: widget.cart);
          }
        }

        return const SizedBox();
      },
    );
  }
}

// ─── Cart item card ───────────────────────────────────────────────────────────

class _CartItemCard extends StatelessWidget {
  final CartLine line;
  final CartModel cart;
  // CHANGE #324: ViewAs checkbox — null = normal mode (show X remove button).
  final bool? viewAsChecked;
  final VoidCallback? onViewAsToggle;

  /// CHANGE #553 — this line's verdict from cart_availability(). Null until
  /// the fetch answers, or when the RPC failed (fail open — no local guess).
  final Availability? availability;
  const _CartItemCard({
    super.key,
    required this.line,
    required this.cart,
    this.viewAsChecked,
    this.onViewAsToggle,
    this.availability,
  });

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    // CHANGE #553 — the line's availability is whatever cart_availability()
    // said about this product_id. Nothing here re-derives it.
    final av = availability;

    // Parse scheme "X+Y" for free-qty calculation
    final schemeParts = p.scheme.split('+');
    final int buyX = schemeParts.length == 2 ? (int.tryParse(schemeParts[0]) ?? 0) : 0;
    final int getY = schemeParts.length == 2 ? (int.tryParse(schemeParts[1]) ?? 0) : 0;
    final int freeQty = (buyX > 0 && getY > 0) ? (line.quantity ~/ buyX) * getY : 0;
    final String unit = _CartStepper._unit(p.packSize);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x06000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── TOP ROW: image | name + pack size + manufacturer | remove ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ProductImage(product: p, size: 64),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Expanded(
                            child: Text(
                              p.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Color(0xFF111827),
                                height: 1.3,
                              ),
                            ),
                          ),
                          if (p.scheme.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFEF08A),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                p.scheme,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF92400E),
                                ),
                              ),
                            ),
                          ],
                          const SizedBox(width: 6),
                          // CHANGE #324: ViewAs → checkbox; normal → X remove.
                          if (viewAsChecked != null)
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: viewAsChecked,
                                onChanged: (_) => onViewAsToggle?.call(),
                                activeColor: const Color(0xFF1B7A43),
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                            )
                          // CHANGE #639 — a line cart_render() flagged gets a
                          // prominent RED remove control instead of the quiet
                          // grey one. Same remove flow, same RPC; only the
                          // emphasis changes, because this is the one action
                          // that clears the block.
                          else if (line.unavailable)
                            GestureDetector(
                              key: const ValueKey('c639_remove_unavailable'),
                              onTap: () => cart.remove(p),
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFFFEE2E2),
                                  border: Border.all(
                                      color: const Color(0xFFDC2626),
                                      width: 1.2),
                                ),
                                child: const Center(
                                  child: Icon(Icons.close,
                                      size: 17, color: Color(0xFFDC2626)),
                                ),
                              ),
                            )
                          else
                            GestureDetector(
                              onTap: () => cart.remove(p),
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: const Color(0xFFD1D5DB)),
                                  color: const Color(0xFFF9FAFB),
                                ),
                                child: const Center(
                                  child: Icon(Icons.close,
                                      size: 11, color: Color(0xFF6B7280)),
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        p.packSize.isNotEmpty ? p.packSize : '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF374151),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.manufacturer,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                      // CHANGE #553 — the backend's verdict for this line,
                      // printed in the backend's own label and colours. Shown
                      // only when it says the line cannot be ordered.
                      if (av != null && !av.canAdd) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: av.bg == null ? null : Color(av.bg!),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            av.note ?? av.ctaLabel,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: av.fg == null ? null : Color(av.fg!),
                            ),
                          ),
                        ),
                      ],
                      if (line.isSample) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF7ED),
                            borderRadius: BorderRadius.circular(4),
                            border:
                                Border.all(color: const Color(0xFFFED7AA)),
                          ),
                          child: Text(c('cart.badge_sample'),
                              style: const TextStyle(
                                  fontSize: 9, color: Color(0xFFEA580C))),
                        ),
                      ],
                      // CHANGE #325 label rules:
                      // "Added by Admin"   → both customer's own cart AND ViewAs.
                      // "Added by customer"→ ViewAs only (never shown to the customer).
                      if (line.addedByAdmin) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFD1FAE5),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFF6EE7B7)),
                          ),
                          child: Text(
                            c('cart.badge_added_by_admin'),
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF065F46),
                            ),
                          ),
                        ),
                      ] else if (viewAsChecked != null) ...[
                        const SizedBox(height: 3),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFFFDE68A)),
                          ),
                          child: Text(
                            c('cart.badge_added_by_customer'),
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF92400E),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ── BOTTOM ROW: line price (left) | qty selector (right) ──
            //
            // CHANGE #615 — one price, one source. The struck-through MRP, the
            // black sale price beneath it and the "N% GST (₹x input credit)"
            // badge are all gone: there is no sale price, no discount and no
            // GST in the cart any more, so a second number here could only
            // ever be a number the backend never sent.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Left: the line total and how it was reached — both printed
                // verbatim from cart_render(). Nothing multiplied in Dart.
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // CHANGE #572 — ONE PRICE TRUTH PER LINE. `price_line` is
                    // the amount and `price_note` the caption under it, and
                    // the BACKEND decides which of them exists. A line with no
                    // trade rate yet sends an EMPTY price_line and folds its
                    // MRP into the caption ("MRP ₹260.38 · trade rate on
                    // confirmation"), so a rupee figure can never sit above the
                    // words that say the rate is not known. CMD #452's absent
                    // MRP (feature_gaps #182) is the same mechanism: the
                    // caption says so instead of a ₹0.00 nobody printed.
                    if (line.ds('price_line').isNotEmpty)
                      Text(
                        line.ds('price_line'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF111827),
                          height: 1.1,
                        ),
                      ),
                    if (line.ds('price_line').isNotEmpty)
                      const SizedBox(height: 3),
                    Text(
                      line.ds('price_note'),
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF6B7280),
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
                const Spacer(),
                // Right: free-qty label (when earned) + qty stepper
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (freeQty > 0) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDCFCE7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          cf(
                              freeQty == 1
                                  ? 'cart.free_qty_one'
                                  : 'cart.free_qty_many',
                              {'qty': '$freeQty', 'unit': unit}),
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF15803D),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                    ],
                    // CHANGE #615 — the stepper shows cart.quantityOf(), which
                    // is the user's own unsent tap when there is one and the
                    // server's number otherwise. This used to pass
                    // line.quantity — the SERVER quantity — so #610's
                    // optimistic echo and 300ms debounce were built but never
                    // seen HERE: every tap on the cart screen sat unchanged
                    // until the RPC came back, which is the lag being
                    // reported. The product card already read quantityOf(),
                    // which is why the catalog stepper felt instant and this
                    // one did not.
                    // CHANGE #639 — qty_locked comes from cart_render(); the
                    // stepper is disabled and tinted red on the strength of
                    // the backend's flag, never on a local stock check.
                    _CartStepper(
                      product: p,
                      quantity: cart.quantityOf(p.id),
                      cart: cart,
                      locked: line.qtyLocked,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Product image with category-icon fallback ────────────────────────────────

class _ProductImage extends StatelessWidget {
  final Product product;
  final double size;
  const _ProductImage({required this.product, this.size = 64});

  @override
  Widget build(BuildContext context) {
    final style = categoryStyle(product.therapeuticClass);
    final iconSize = size * 0.45;
    final radius = size * 0.125;
    final Widget fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: style.bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Icon(style.icon, size: iconSize,
          color: style.fg.withValues(alpha: 0.6)),
    );

    if (product.imageUrl.isEmpty) return fallback;

    final cache = (size * 2).round();
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        width: size,
        height: size,
        color: const Color(0xFFF9FAFB),
        child: Image.network(
          product.imageUrl,
          width: size,
          height: size,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cache,
          cacheHeight: cache,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : fallback,
          errorBuilder: (_, __, ___) => fallback,
        ),
      ),
    );
  }
}

// ─── Cart quantity stepper ────────────────────────────────────────────────────

class _CartStepper extends StatefulWidget {
  final Product product;
  final int quantity;
  final CartModel cart;

  /// CHANGE #639 — `qty_locked` from cart_render(). When true both tap zones
  /// are dead and the control is tinted red. This is the backend's answer,
  /// carried through; the stepper never decides it.
  final bool locked;

  const _CartStepper({
    required this.product,
    required this.quantity,
    required this.cart,
    this.locked = false,
  });

  static String _unit(String packSize) {
    final s = packSize.toLowerCase();
    if (s.contains('strip')) return c('cart.unit_strip');
    if (s.contains('bottle')) return c('cart.unit_bottle');
    if (s.contains('vial')) return c('cart.unit_vial');
    if (s.contains('tube')) return c('cart.unit_tube');
    if (s.contains('sachet')) return c('cart.unit_sachet');
    if (s.contains('box')) return c('cart.unit_box');
    if (s.contains('ampoule') || s.contains('ampule')) return c('cart.unit_ampoule');
    if (s.contains('pack')) return c('cart.unit_pack');
    return c('cart.unit_default');
  }

  @override
  State<_CartStepper> createState() => _CartStepperState();
}

class _CartStepperState extends State<_CartStepper> {
  bool _increasing = true;

  @override
  void didUpdateWidget(_CartStepper old) {
    super.didUpdateWidget(old);
    if (widget.quantity != old.quantity) {
      _increasing = widget.quantity > old.quantity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = _CartStepper._unit(widget.product.packSize);
    final qty = widget.quantity;
    final increasing = _increasing;

    // CHANGE #639 — the red state for a locked line.
    final locked = widget.locked;
    const lockedBg = Color(0xFFFEE2E2);
    const lockedEdge = Color(0xFFDC2626);
    const lockedInk = Color(0xFF991B1B);
    final ink = locked ? lockedInk : const Color(0xFF1a1a1a);

    return SizedBox(
      width: 150,
      height: 56,
      child: Stack(
        children: [
          // Visual layer
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: locked ? lockedBg : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                    color: locked ? lockedEdge : const Color(0xFFE5E7EB)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Minus visual
                  SizedBox(
                    width: 44,
                    child: Center(
                      child: Text(
                        '−',
                        style: TextStyle(
                          color: ink,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                  // Center: qty + unit with slide animation
                  Expanded(
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ClipRect(
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 200),
                              transitionBuilder: (child, anim) {
                                final isNew =
                                    (child.key as ValueKey<int>).value == qty;
                                final begin = isNew
                                    ? (increasing
                                        ? const Offset(0, -1)
                                        : const Offset(0, 1))
                                    : (increasing
                                        ? const Offset(0, 1)
                                        : const Offset(0, -1));
                                return SlideTransition(
                                  position: Tween<Offset>(
                                          begin: begin, end: Offset.zero)
                                      .animate(anim),
                                  child: child,
                                );
                              },
                              child: Text(
                                '$qty',
                                key: ValueKey<int>(qty),
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: ink,
                                  fontSize: 15,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            unit,
                            style: TextStyle(
                              fontSize: 13,
                              color: ink,
                              fontWeight: FontWeight.w600,
                              height: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Plus visual — green right side, RED when the line is locked
                  Container(
                    width: 44,
                    decoration: BoxDecoration(
                      color: locked ? lockedEdge : Brand.green,
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(7),
                        bottomRight: Radius.circular(7),
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        '+',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                          height: 1,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Invisible 3-zone tap overlay
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Zone 1: minus (44px) — dead while the backend says locked
                SizedBox(
                  width: 44,
                  child: MouseRegion(
                    cursor: locked
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: (locked || widget.cart.isPending(widget.product.id))
                          ? null
                          : () => widget.cart.decrement(widget.product),
                    ),
                  ),
                ),
                // Zone 2: center display (no action)
                const Expanded(child: SizedBox()),
                // Zone 3: plus (44px) — dead while the backend says locked
                SizedBox(
                  width: 44,
                  child: MouseRegion(
                    cursor: locked
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.click,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: (locked || widget.cart.isPending(widget.product.id))
                          ? null
                          : () => widget.cart.increment(widget.product),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Removed-by-admin section ─────────────────────────────────────────────────

class _RemovedByAdminHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  const _RemovedByAdminHeader({required this.count, required this.expanded, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onToggle,
      child: Container(
        margin: const EdgeInsets.only(top: 8, bottom: 2),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFFFFF1F2),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFFECACA)),
        ),
        child: Row(children: [
          const Icon(Icons.remove_circle_outline, size: 14, color: Color(0xFFDC2626)),
          const SizedBox(width: 6),
          Text(
            cf('cart.removed_by_admin_header', {'count': '$count'}),
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626)),
          ),
          const Spacer(),
          Icon(expanded ? Icons.expand_less : Icons.expand_more,
              size: 16, color: const Color(0xFFDC2626)),
        ]),
      ),
    );
  }
}

class _RemovedItemCard extends StatelessWidget {
  final CartLine line;
  final CartModel cart;
  const _RemovedItemCard({required this.line, required this.cart});

  @override
  Widget build(BuildContext context) {
    final p = line.product;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(children: [
        Opacity(opacity: 0.4, child: _ProductImage(product: p, size: 40)),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF9CA3AF),
                      decoration: TextDecoration.lineThrough,
                      decorationColor: Color(0xFF9CA3AF))),
              const SizedBox(height: 2),
              Text(
                cf('cart.removed_line_summary', {
                  'qty': '${line.quantity}',
                  'amount': (p.b2bPrice * line.quantity).toStringAsFixed(0),
                }),
                style: const TextStyle(fontSize: 11, color: Color(0xFFD1D5DB)),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFFEF2F2),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(c('cart.badge_removed'),
              style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFFDC2626),
                  fontWeight: FontWeight.w600)),
        ),
        // Manual X: customer clears the removed item immediately
        if (line.cartItemId != null) ...[
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () => cart.hardDeleteRemovedItem(line.product.id),
            child: Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0xFFD1D5DB)),
                color: const Color(0xFFF9FAFB),
              ),
              child: const Center(
                child: Icon(Icons.close, size: 11, color: Color(0xFF9CA3AF)),
              ),
            ),
          ),
        ],
      ]),
    );
  }
}

// Returns a short gate message when the user cannot place orders, null when they can.
// Pass viewAs when inside a ViewAs session to gate on the impersonated customer's approval.
// orderHoursClosedLabel does NOT apply to ViewAs orders — admin-placed orders
// are never blocked. CHANGE #455 — this is order_hours_state()'s button_label,
// printed VERBATIM, not a hardcoded 'Order hours closed' string.
// #571 — the second copy of the gate is gone. This used to re-run the whole
// ladder (ViewAs approval, authenticated, registered, suspended, canOrder)
// with five more hardcoded strings — a duplicate that could, and did, drift
// out of step with the one in _placeOrder.
//
// my_session().order_gate already covers every one of those cases, including
// the View As one (the backend judges the impersonated customer). All that is
// left here is order hours, which is a different RPC's answer.
String? _orderGateMessage(AuthNotifier auth, [ViewAsNotifier? viewAs, String? orderHoursClosedLabel]) {
  if (orderHoursClosedLabel != null) return orderHoursClosedLabel;
  final gate = auth.orderGate;
  return gate.hasBlocker ? gate.shortLabel : null;
}


// ─── CHANGE #572 — the button's word and its enabled state are the payload's ──
//
// "Pay & Place Order" is a promise about money, and the cart made it on a
// basket where nothing was payable. `cart_render().render.cta` answers both
// questions in one place: the label ("Place order" until an amount exists,
// "Pay & place order" once one does) and whether the button may be pressed at
// all. checkout_action()'s label is the fallback for the moment before the
// cart payload has arrived, and ui_copy is the fallback for that.
Map<String, dynamic> _cta(Map<String, dynamic> render) =>
    (render['cta'] as Map?)?.cast<String, dynamic>() ?? const {};

String c572CtaLabel(Map<String, dynamic> render, String checkoutActionLabel) {
  final fromCart = (_cta(render)['label'] ?? '').toString();
  if (fromCart.isNotEmpty) return fromCart;
  if (checkoutActionLabel.isNotEmpty) return checkoutActionLabel;
  return c('cart.btn_place_order');
}

/// Absent is NOT disabled: a payload that never mentioned `enabled` leaves the
/// button exactly as the other gates found it.
bool c572CtaEnabled(Map<String, dynamic> render) => _cta(render)['enabled'] != false;

// ─── Fixed checkout bar (narrow layout) ──────────────────────────────────────

class _CheckoutBar extends StatelessWidget {
  final CartModel cart;
  final VoidCallback onPlaceOrder;

  /// CHANGE #293 — checkout_action().button_label. Empty until the backend has
  /// answered, in which case the ui_copy label stands in.
  final String placeOrderLabel;
  // CHANGE #324: when ViewAs, show selected-items total instead of full cart total.
  final String? selectedTotal;

  /// #615 — the caption that goes with [selectedTotal], formatted by
  /// cart_selected_total(). Empty outside View As.
  final String selectedSubtotalLine;

  /// CHANGE #553 — true while cart_availability() reports a blocking_label.
  final bool availabilityBlocked;

  /// CHANGE #572 — what the ONE notice's inline action opens. The payload
  /// says whether there is an action and what it is called; the screen
  /// owns the navigation.
  final void Function(Map<String, dynamic> action)? onNoticeAction;
  const _CheckoutBar({
    required this.cart,
    required this.onPlaceOrder,
    this.placeOrderLabel = '',
    this.selectedTotal,
    this.selectedSubtotalLine = '',
    this.availabilityBlocked = false,
    this.onNoticeAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 14,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // CHANGE #174 — what the pharmacy earns on this basket. Shown
                // only when cart_render() says at least one line is priced;
                // lines with no PTR yet are excluded from the figure and
                // counted in `note`, never silently added as zero. Hidden
                // entirely while nothing is priced, so the footer looks exactly
                // as it did before any pricing was captured.
                if (selectedTotal == null && cart.marginHas) ...[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          cart.marginLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w600,
                            color: Ds.c.success,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        cart.marginTotalDisplay,
                        style: Ds.t.subtitle.copyWith(
                          fontWeight: FontWeight.w800,
                          color: Ds.c.success,
                        ),
                      ),
                    ],
                  ),
                  if (cart.marginNote.isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: Ds.space.x4),
                      child: Text(
                        cart.marginNote,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption,
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
                // CHANGE #615/#355 — the footer is backend strings only: the
                // tax breakup, the line that explains the basket, and the one
                // amount owed. All arrive formatted from cart_render(); the
                // label, the counts, the GST split and the amount are never
                // assembled here. In View As the summary line and the amount
                // come from cart_selected_total() for the ticked lines only.
                //
                // #355 — the big number is net_payable_display (the TRADE
                // payable, taxable + GST). It used to be subtotal_display,
                // which was the MRP total: the cart quoted the printed ceiling
                // as the amount owed, which is feature_gaps #79.
                if (selectedTotal == null && cart.hasTax)
                  _CartTaxBreakup(cart: cart),
                // CHANGE #572 — items → ONE summary line → ONE notice → button.
                // The four repetitions of "Awaiting supplier rates" (the
                // summary line, the big amount, Net payable and Total payable)
                // and the second amber box are gone: cart_render() now decides
                // which line, which rows and which single notice exist, and
                // this footer prints that decision.
                C572TotalsBlock(
                  render: cart.render,
                  selectedTotal: selectedTotal,
                  selectedLine: selectedSubtotalLine,
                ),
                if (selectedTotal == null)
                  C572CartNotice(render: cart.render, onAction: onNoticeAction),
                const SizedBox(height: 12),
                // Place Order (auth-gated)
                Builder(builder: (ctx) {
                  final auth = UserState.of(ctx);
                  final viewAsNotifier = ViewAsState.of(ctx);
                  final orderHours = OrderHoursState.of(ctx);
                  final orderHoursClosed = !cart.isViewAs && !orderHours.canOrder;
                  if (!cart.isViewAs) {
                    RenderLog.write('c444_cust_blocked', orderHoursClosed.toString());
                  }
                  // CHANGE #456 C8 — inquiry lock gates ADMIN ordering only
                  // (acting-as-customer). Real customers are never gated by it.
                  final inquiryLocked = cart.isViewAs && InquiryLockState.of(ctx).locked;
                  final gateMsg = _orderGateMessage(
                      auth, viewAsNotifier, orderHoursClosed ? orderHours.buttonLabel : null);
                  // CHANGE #553 — an availability block greys Place Order
                  // exactly like the existing order gates; the tap then
                  // surfaces the backend's blocking_label.
                  final blocked = gateMsg != null || inquiryLocked || availabilityBlocked ||
                        !c572CtaEnabled(cart.render);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // CHANGE #615 — "View bill" and the sheet it opened are
                      // gone. There is no breakdown left to open: the bill IS
                      // the subtotal printed above.
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: onPlaceOrder,
                              child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 15),
                                decoration: BoxDecoration(
                                  color: blocked
                                      ? const Color(0xFF9CA3AF)
                                      : const Color(0xFF1B5E20),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.shopping_bag_outlined,
                                        color: Colors.white, size: 18),
                                    const SizedBox(width: 8),
                                    Text(
                                      inquiryLocked
                                          ? c('cart.inquiry_lock_title')
                                          : (orderHoursClosed
                                              ? (orderHours.buttonLabel ?? '')
                                              : (auth.isAuthenticated
                                                  ? c572CtaLabel(cart.render, placeOrderLabel)
                                                  : c('cart.btn_login_to_order'))),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.2,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

}

// ─── Order summary sidebar (wide layout) ─────────────────────────────────────

class _OrderSummaryPanel extends StatelessWidget {
  final CartModel cart;
  final VoidCallback onPlaceOrder;

  /// CHANGE #293 — checkout_action().button_label, rendered verbatim.
  final String placeOrderLabel;
  // CHANGE #324: when ViewAs, show selected-items total instead of full cart total.
  final String? selectedTotal;

  /// #615 — the caption that goes with [selectedTotal], formatted by
  /// cart_selected_total(). Empty outside View As.
  final String selectedSubtotalLine;

  /// CHANGE #553 — true while cart_availability() reports a blocking_label.
  final bool availabilityBlocked;

  /// CHANGE #572 — what the ONE notice's inline action opens. The payload
  /// says whether there is an action and what it is called; the screen
  /// owns the navigation.
  final void Function(Map<String, dynamic> action)? onNoticeAction;
  const _OrderSummaryPanel({
    required this.cart,
    required this.onPlaceOrder,
    this.placeOrderLabel = '',
    this.selectedTotal,
    this.selectedSubtotalLine = '',
    this.availabilityBlocked = false,
    this.onNoticeAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x08000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // CHANGE #615 — the sidebar is the same two backend strings as the
          // narrow footer. The Items / Net Total / Discount / GST Input Credit
          // / Delivery Fee ladder and the "View detailed bill →" dialog are
          // gone: none of those figures exist in the payload any more, and the
          // "Items" row was the app counting SKUs and packs and wording the
          // plural itself.
          // CHANGE #572 — the sidebar prints the same three backend blocks as
          // the narrow footer: one summary, one notice, one button.
          C572TotalsBlock(
            render: cart.render,
            selectedTotal: selectedTotal,
            selectedLine: selectedSubtotalLine,
          ),
          if (selectedTotal == null)
            C572CartNotice(render: cart.render, onAction: onNoticeAction),
          const SizedBox(height: 16),
          Builder(builder: (ctx) {
            final auth = UserState.of(ctx);
            final orderHours = OrderHoursState.of(ctx);
            final orderHoursClosed = !cart.isViewAs && !orderHours.canOrder;
            // CHANGE #456 C8 — inquiry lock gates ADMIN ordering only
            // (acting-as-customer). Real customers are never gated by it.
            final inquiryLocked = cart.isViewAs && InquiryLockState.of(ctx).locked;
            final gateMsg = _orderGateMessage(
                auth, ViewAsState.of(ctx), orderHoursClosed ? orderHours.buttonLabel : null);
            // CHANGE #553 — availability block greys Place Order too.
            final blocked = gateMsg != null || inquiryLocked || availabilityBlocked ||
                        !c572CtaEnabled(cart.render);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                GestureDetector(
                  onTap: onPlaceOrder,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    decoration: BoxDecoration(
                      color: blocked
                          ? const Color(0xFF9CA3AF)
                          : const Color(0xFF1B5E20),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.shopping_bag_outlined,
                            color: Colors.white, size: 18),
                        const SizedBox(width: 8),
                        Text(
                          inquiryLocked
                              ? c('cart.inquiry_lock_title')
                              : (orderHoursClosed
                                  ? (orderHours.buttonLabel ?? '')
                                  : (auth.isAuthenticated
                                      ? c572CtaLabel(cart.render, placeOrderLabel)
                                      : c('cart.btn_login_to_order'))),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }),
          const SizedBox(height: 12),
          // CHANGE #615 — the free-delivery / "Add ₹N more for free
          // delivery" pair is gone. There is no delivery fee in the payload,
          // and that second banner hardcoded the ₹999 threshold and did the
          // subtraction in Dart — a rule the backend no longer even has.
          Text(
            c('cart.credit_terms_note'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ],
      ),
    );
  }
}

// ─── Order placed confirmation dialog ─────────────────────────────────────────

class _OrderPlacedDialog extends StatelessWidget {
  final String orderNumber;
  final String amount;
  final VoidCallback onDone;

  const _OrderPlacedDialog({
    required this.orderNumber,
    required this.amount,
    required this.onDone,
  });

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width >= 900;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      backgroundColor: Colors.white,
      insetPadding: isDesktop
          ? const EdgeInsets.symmetric(horizontal: 24, vertical: 24)
          : const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: isDesktop ? 440 : double.infinity),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: Color(0xFFDCFCE7),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.check_circle_rounded,
                    color: Color(0xFF16A34A), size: 44),
              ),
              const SizedBox(height: 20),
              Text(
                c('cart.placed_title'),
                style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF111827)),
              ),
              const SizedBox(height: 8),
              Text(
                cf('cart.placed_summary',
                    {'number': orderNumber, 'amount': amount}),
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151)),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                c('cart.placed_note'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF6B7280), height: 1.5),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: onDone,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B5E20),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: Text(c('cart.placed_view_orders'),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Empty cart ───────────────────────────────────────────────────────────────

class _EmptyCart extends StatelessWidget {
  const _EmptyCart();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(48),
            ),
            child: const Icon(Icons.shopping_cart_outlined,
                size: 48, color: Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 20),
          // CHANGE #559: empty-state copy is whatever cart_state() returned.
          Text(
            AppState.of(context).emptyTitle,
            style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827)),
          ),
          const SizedBox(height: 8),
          Text(
            AppState.of(context).emptyNote,
            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }
}


/// CHANGE #355 — the GST breakup, rendered verbatim from cart_render().
///
/// feature_gaps #81: cart_render() carried no GST block at all — a pharmacy
/// could not see the input credit on a basket before paying for it. The rows
/// below are `render.tax_lines` in payload order; this widget knows neither
/// the rate, nor the split, nor the wording, and adds nothing of its own.
class _CartTaxBreakup extends StatelessWidget {
  final CartModel cart;
  const _CartTaxBreakup({required this.cart});

  @override
  Widget build(BuildContext context) {
    final lines = cart.taxLines;
    if (lines.isEmpty) return const SizedBox.shrink();
    final note = cart.gstNote;
    final mrpLabel = cart.mrpWorthLabel;
    final mrpValue = cart.mrpWorthDisplay;

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final l in lines)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text((l['label'] ?? '').toString(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                  ),
                  Text((l['value'] ?? '').toString(), style: Ds.t.caption),
                ],
              ),
            ),
          // The printed ceiling keeps its own row, under the label the backend
          // gives it. It is reference information, never the amount owed.
          if (mrpLabel.isNotEmpty && mrpValue.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: Text(mrpLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.caption),
                  ),
                  Text(mrpValue, style: Ds.t.caption),
                ],
              ),
            ),
          if (note.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x4),
              child: Text(note, style: Ds.t.caption),
            ),
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x8),
            child: Divider(height: 1, color: Ds.c.divider),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANGE #461 — three blocks the cart never showed, all of them printed
// verbatim from cart_render().
//
// #167 the delivery line: the charge, its GST and the grand total that
//      includes it are computed by delivery_charge_block() and stamped on the
//      order by the SAME function, so the amount here is the amount billed.
// #170 the Rx / drug-licence notice: how many prescription lines are in the
//      basket and whether this pharmacy's licence covers them.
// #168 the tier benefit note: whether the margin benefit can bite on THIS
//      cart, which for a cart with no trade-priced line it cannot.
//
// None of the three computes anything. Every string, every count, every plural
// and both tone colours arrive in the payload.
// ─────────────────────────────────────────────────────────────────────────────

/// One `label · amount` row in the totals ladder.
class _C461TotalRow extends StatelessWidget {
  final String label;
  final String amount;
  final bool strong;
  const _C461TotalRow({required this.label, required this.amount, this.strong = false});

  @override
  Widget build(BuildContext context) {
    final style = strong ? Ds.t.subtitle : Ds.t.bodySecondary;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis)),
          SizedBox(width: Ds.space.x8),
          Text(amount, style: strong ? Ds.t.subtitle : Ds.t.body, textAlign: TextAlign.right),
        ],
      ),
    );
  }
}

/// The delivery ladder: delivery, its GST when there is one, then the grand
/// total. Absent from the payload → absent from the screen.
///
/// CHANGE #572 — the cart no longer draws this block. It is kept for the
/// surfaces that still print a raw delivery ladder; the cart's totals are
/// `render.summary.rows`, which the BACKEND assembles (see [C572TotalsBlock]).
class C461DeliveryLines extends StatelessWidget {
  final Map<String, dynamic> render;
  const C461DeliveryLines({super.key, required this.render});

  @override
  Widget build(BuildContext context) {
    final d = (render['delivery'] as Map?)?.cast<String, dynamic>();
    if (d == null || d['has'] != true) return const SizedBox.shrink();

    final note = (d['note'] ?? '').toString();
    final grand = (render['grand_total_display'] ?? '').toString();
    final itemsTotal = (render['items_total_display'] ?? '').toString();
    final labels = (render['labels'] as Map?)?.cast<String, dynamic>() ?? const {};
    final totalLabel = (labels['total'] ?? '').toString();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (itemsTotal.isNotEmpty && totalLabel.isNotEmpty)
          _C461TotalRow(label: totalLabel, amount: itemsTotal),
        _C461TotalRow(
          label: (d['label'] ?? '').toString(),
          amount: (d['amount_display'] ?? '').toString(),
        ),
        if (d['has_gst'] == true)
          _C461TotalRow(
            label: (d['gst_label'] ?? '').toString(),
            amount: (d['gst_display'] ?? '').toString(),
          ),
        if (grand.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: _C461TotalRow(
              label: (labels['grand'] ?? totalLabel).toString(),
              amount: grand,
              strong: true,
            ),
          ),
        if (note.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(note, style: Ds.t.caption),
          ),
      ],
    );
  }
}

/// A backend notice: title, message and the tone the payload chose.
class C461Notice extends StatelessWidget {
  final String title;
  final String message;
  final Map<String, dynamic>? tone;

  /// CHANGE #572 — the notice's own inline action, when the payload sent one
  /// ("Add licence"). Label and existence are the backend's; this widget only
  /// prints the label and calls back.
  final String actionLabel;
  final VoidCallback? onAction;
  const C461Notice({
    super.key,
    required this.title,
    required this.message,
    this.tone,
    this.actionLabel = '',
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (message.isEmpty && title.isEmpty) return const SizedBox.shrink();
    final bg = Ds.hex(tone?['bg'], Ds.c.infoSoft);
    final fg = Ds.hex(tone?['fg'], Ds.c.text);
    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty)
            Text(title, style: Ds.t.subtitle.copyWith(color: fg)),
          if (title.isNotEmpty && message.isNotEmpty) SizedBox(height: Ds.space.x4),
          if (message.isNotEmpty)
            Text(message, style: Ds.t.body.copyWith(color: fg)),
          // The action the backend attached to this notice. It is the way OUT
          // of the block, so it sits inside the block that raised it.
          if (actionLabel.isNotEmpty && onAction != null) ...[
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.space.x48,
              child: OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: fg,
                  side: BorderSide(color: fg),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(actionLabel, style: Ds.t.body.copyWith(color: fg)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// CHANGE #572 — the cart's totals, exactly as `cart_render().render.summary`
/// assembled them.
///
/// The cart used to say "Awaiting supplier rates" four times over: once in the
/// summary line, once as the big amount, once against "Net payable" and once
/// against "Total payable". Which rows exist is now a BACKEND decision:
/// `summary.rows` carries the ladder, and while nothing is payable it carries
/// only Delivery — the one true number on an unpriced basket. Nothing here
/// decides, formats or pluralises; `has_amount` is the payload's answer to
/// "is there an amount?", never a `> 0` computed on this side.
class C572TotalsBlock extends StatelessWidget {
  final Map<String, dynamic> render;

  /// View As substitutes cart_selected_total()'s own two strings for the
  /// ticked lines. Null outside View As.
  final String? selectedTotal;
  final String selectedLine;
  const C572TotalsBlock({
    super.key,
    required this.render,
    this.selectedTotal,
    this.selectedLine = '',
  });

  @override
  Widget build(BuildContext context) {
    final s = (render['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    final line = selectedTotal != null ? selectedLine : (s['line'] ?? '').toString();
    final amount =
        selectedTotal ?? (s['has_amount'] == true ? (s['amount_display'] ?? '').toString() : '');
    final rows = selectedTotal != null
        ? const <Map<String, dynamic>>[]
        : ((s['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(growable: false);
    final deliveryNote =
        selectedTotal != null ? '' : (s['delivery_note'] ?? '').toString();

    if (line.isEmpty && amount.isEmpty && rows.isEmpty) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(line,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.bodySecondary),
            ),
            if (amount.isNotEmpty) ...[
              SizedBox(width: Ds.space.x8),
              Text(amount, style: Ds.t.display),
            ],
          ],
        ),
        for (final r in rows)
          _C461TotalRow(
            label: (r['label'] ?? '').toString(),
            amount: (r['amount'] ?? '').toString(),
            strong: r['strong'] == true,
          ),
        if (deliveryNote.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(deliveryNote, style: Ds.t.caption),
          ),
      ],
    );
  }
}

/// CHANGE #572 — THE cart notice. One, not two.
///
/// `render.notice` is the backend's choice of which single thing the customer
/// has to deal with before ordering — today the drug-licence gate. The tier
/// benefit note is deliberately NOT offered here any more: on a basket that is
/// simply awaiting quotes it read as a defect ("Nothing in the catalogue is
/// trade-priced for you yet"), and it belongs where the benefit applies.
///
/// `note` is the record line ("2 prescription items in this order"), which is
/// a caption and not a second notice.
class C572CartNotice extends StatelessWidget {
  final Map<String, dynamic> render;

  /// What the notice's inline action opens. The screen owns navigation; the
  /// payload owns whether there is an action and what it is called.
  final void Function(Map<String, dynamic> action)? onAction;
  const C572CartNotice({super.key, required this.render, this.onAction});

  @override
  Widget build(BuildContext context) {
    final n = (render['notice'] as Map?)?.cast<String, dynamic>() ?? const {};
    final note = (n['note'] ?? '').toString();

    if (n['has'] != true) {
      if (note.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x8),
        child: Text(note, style: Ds.t.caption),
      );
    }

    final action = (n['action'] as Map?)?.cast<String, dynamic>() ?? const {};
    final actionLabel =
        action['has'] == true ? (action['label'] ?? '').toString() : '';

    return C461Notice(
      title: (n['title'] ?? '').toString(),
      message: (n['message'] ?? '').toString(),
      tone: (n['tone'] as Map?)?.cast<String, dynamic>(),
      actionLabel: actionLabel,
      onAction: (actionLabel.isEmpty || onAction == null)
          ? null
          : () => onAction!(action),
    );
  }
}
