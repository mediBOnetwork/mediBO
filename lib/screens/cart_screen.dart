import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../app_state.dart';
import '../design_tokens.dart';
import '../order_hours_state.dart';
import '../inquiry_lock_state.dart';
import '../utils/order_code.dart';
import 'bulk_upload_screen.dart';
import 'product_detail_screen.dart';
import '../utils/render_log.dart';
import '../models/cart_model.dart';
import '../models/product.dart';
import '../models/product_detail.dart' show PdCompanion;
import '../design_tokens.dart';
import '../theme.dart';
import '../user_state.dart';
import '../util.dart';
import '../services/ui_copy.dart';
import '../view_as_state.dart';
import '../widgets/animations.dart';
import '../widgets/cart_bill_summary.dart';
import '../widgets/cart_rail_slot.dart';
import '../widgets/cart_wishlist_rail.dart';
import '../widgets/checkout_pay_sheet.dart';
import '../widgets/companion_rail.dart';
import 'auth/login_screen.dart';
import 'profile_screen.dart';
import 'customer/my_account_screen.dart'; // CMD #1815 — the notice's action
import '../services/idempotency.dart';
import '../widgets/registration_sheet.dart';
import '../widgets/qty_picker.dart';

class CartScreen extends StatefulWidget {
  final VoidCallback? onOrderPlaced;
  final String? externalSearchQuery;
  const CartScreen({super.key, this.onOrderPlaced, this.externalSearchQuery});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _orderInProgress = false;

  /// CHANGE #472 — the key for the order the buyer is currently committing to.
  /// It is minted on the first attempt and REUSED by every retry, so the
  /// server can tell a retry from a second order. `done()` is called only once
  /// an order actually came back, which is what makes the next tap a new one.
  final ActionSlot _placeKey = ActionSlot();

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

  /// Product-id signature of the cart the last availability fetch covered.
  String? _availSignature;

  /// CMD #2025 — cart_availability() is an OPEN-time read (and a Place-order
  /// read). This flips on the first build so it fires exactly once per visit.
  bool _availOpened = false;

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

  // ── CMD #2014/#2047 — the bill summary card and the suggested rail ───────
  // Both blocks arrive on the cart payload itself (cart_render().bill / .rail).
  // #2014 fetched them with a second call, cart_bill_view(), and every one of
  // that call's failure modes is silent — so the blocks were simply never on
  // screen. There is no second request here any more, and therefore nothing
  // left to swallow: if the cart rendered, the bill rendered with it.
  //
  // Nothing below is computed here — the screen holds no bill state at all.

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

  /// CHANGE #572 / CMD #1815 — the notice's (and now the chip's) inline action.
  ///
  /// `action` is a descriptor, not a route: the payload says there IS an
  /// action, what it is called, and which screen, tab and section it is about.
  /// Only the navigation is ours. An action kind this build has never heard of
  /// opens nothing, in silence — the same forward-compat rule the home feed
  /// follows for an unknown layout.
  ///
  /// #705 shipped '/account/kyc' as the route for this and no build ever had a
  /// route by that name, so "Upload licence" opened nothing at all. The
  /// descriptor names the registry key instead, and the customer lands on the
  /// upload section itself.
  Future<void> _openNoticeAction(Map<String, dynamic> action) async {
    final kind = (action['kind'] ?? '').toString();
    if (kind != 'customer_route' && kind != 'profile_edit') return;
    final tab = (action['tab_key'] ?? 'profile').toString();
    final section = (action['section'] ?? '').toString();
    RenderLog.write('c1815_kyc_chip_action', '$tab/$section');
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            MyAccountScreen(initialTab: tab, initialSection: section)));
    if (!mounted) return;
    // A document may now be on file, so the cart's chip has to be asked again.
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

    // CMD #2025 — the OTHER place cart_availability() runs. The taps no longer
    // pay for it, so the verdicts are re-read once, here, immediately before
    // the order is committed — which is the moment they actually decide
    // something. A block found now stops the order and shows the backend's own
    // blocking_label instead of placing an order that would be refused.
    await _refreshAvailability(AppState.of(context).lines);
    if (!mounted) return;
    if (_blockingLabel != null) {
      RenderLog.write('c2025_place_blocked', _blockingLabel!);
      return;
    }

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

    // CMD #2087 — ONE ROUND TRIP DECIDES WHETHER THIS TAP BECOMES AN ORDER.
    //
    // cart_place_gate() answers with an ACTION, never a state to branch on:
    //   'order'  — place it
    //   'popup'  — show the backend's title/body/dismiss verbatim
    //   'route'  — open the named route it sends, at the anchor it sends
    // Logged out, not registered, half-registered and "submitted, waiting for
    // approval" are four answers to the same question, answered in ONE place
    // in the backend's own words. The Dart ladder that used to start here
    // asked three different sources and worded the fourth case itself.
    final gateRes = await _placeGate();
    if (!mounted) return;
    if (gateRes != null) {
      final g = C2087PlaceGate.from(gateRes);
      RenderLog.write('c2087_place_gate', g.logLine);
      if (g.showsPopup) {
        _showOrderGate(
          title: g.popupTitle,
          message: g.popupBody,
          dismissLabel: g.popupDismiss,
        );
        return;
      }
      if (g.opensRoute) {
        // The route is the backend's; only the push is ours. The anchor rides
        // along as route arguments, so a screen that knows how to resume at a
        // section can, and one that does not simply opens at the top.
        await Navigator.of(context).pushNamed(g.route,
            arguments: <String, dynamic>{'anchor': g.anchor});
        if (!mounted) return;
        await auth.refreshSession();
        if (!mounted) return;
        setState(() {});
        return;
      }
      // An action with nothing to open, and anything this build does not
      // recognise, stops here rather than placing an order on a guess.
      if (!g.placesOrder) return;
      // 'order' — fall through to the placement path below.
    } else if (!auth.isAuthenticated) {
      // The gate could not be reached at all. The one thing the screen may
      // still decide by itself is that a signed-out person needs to sign in.
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
      // CMD #2059 — ordering is the one thing registration gates, and the
      // BACKEND says how that gate is answered. 'registration_sheet' opens the
      // form over this cart; saving it closes the sheet and leaves the buyer
      // exactly where they were, with the basket still on screen.
      if (gate.actionKind == 'registration_sheet') {
        final saved = await showRegistrationSheet(context);
        if (!mounted) return;
        if (saved) {
          await auth.refreshSession();
          if (!mounted) return;
          setState(() {});
        }
        return;
      }
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
      // CHANGE #472 — ONE key per order the buyer committed to. Placing used
      // to be unkeyed: a double tap made two orders, and a retry after a
      // timeout on a request that had actually committed found the cart empty
      // and showed 'empty_cart' for an order that exists. The key is minted
      // when the buyer confirms and reused for every retry, so the server
      // hands back the first order instead of creating a second.
      final raw = await Supabase.instance.client
          .rpc('place_order_v2', params: {'p_client_action_id': _placeKey.key});
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
      // The order exists, so this intent is finished: the next Place Order is
      // a genuinely different action and gets a key of its own.
      _placeKey.done();
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
          // CMD #1848 — both keys exist only on a test-session order.
          testBadge: (placed['test_badge'] ?? '').toString(),
          testNote: (placed['test_note'] ?? '').toString(),
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
      // CMD #1848 — a test order from a login that is not inside a live test
      // session is refused by enforce_order_approval with its OWN reason
      // (test_mode.needs_session), never account_pending_approval. The copy
      // shown is that key's ui_copy sentence — this file words nothing.
      final needsSession = e.message.contains('test_mode.needs_session') ||
          (e.hint ?? '').isNotEmpty && e.message.contains('needs_session');
      if (needsSession) {
        RenderLog.write('c1848_needs_session', 'true');
        showToast(context, c('test_mode.needs_session'), isError: true);
      } else if (isOrderHoursClosed) {
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

  /// CMD #2087 — the Place order gate, asked ON THE TAP.
  ///
  /// Null means the call itself failed (offline, a timeout): the caller then
  /// falls back to the gates it already had rather than placing an order on an
  /// unanswered question.
  Future<Map<String, dynamic>?> _placeGate() async {
    try {
      final raw = await Supabase.instance.client.rpc('cart_place_gate');
      final res = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (res is Map) return res.cast<String, dynamic>();
    } catch (_) {
      // An absent answer is not a refusal.
    }
    return null;
  }

  void _showOrderGate({
    required String title,
    required String message,
    // CHANGE #455 C2 — reopen_hint, printed VERBATIM as a second line when
    // the server sends one. Never composed into `message`.
    String? secondLine,
    String? actionLabel,
    VoidCallback? onAction,
    /// CMD #2087 — the backend's own word for "close". Empty keeps the ui_copy
    /// fallback, so every existing caller is unchanged.
    String dismissLabel = '',
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
            child: Text(
                dismissLabel.isNotEmpty ? dismissLabel : c('cart.gate_ok')),
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

    // CMD #2025 — cart_availability() runs ON OPEN and before Place order, and
    // nowhere else. It used to re-run on every change to the set of products,
    // which put a second 0.9 s round trip behind a tap that had already paid
    // for a full cart_render(). The verdicts it produces gate ORDERING, and
    // ordering is exactly where they are re-read.
    if (!_availOpened) {
      _availOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _refreshAvailability(cart.lines);
      });
    }

    // CMD #2039 — an unread cart is not an empty cart. Until the first payload
    // lands, `lines` is empty for the same reason a page is blank before it is
    // fetched, and drawing the empty state there told the customer their cart
    // was empty while it was still being read. The skeleton holds the shape of
    // the summary row and the first rows so the row the backend already sends
    // ON OPEN has somewhere to land the moment it arrives.
    if (!cart.hasLoaded && cart.lines.isEmpty) {
      return const C2039CartSkeleton();
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

    // CMD #2014/#2047 — both blocks live INSIDE the page scroll, below the
    // items, and both are read straight off the cart payload:
    // they are handed to _ItemList as trailing rows rather than stacked around
    // it, so neither is sticky and neither sits under the header. Each returns
    // null when the backend says it has nothing to draw.
    final bill = CartBillSummary.fromPayload(cart.billBlock);
    void openProduct(Product p) =>
        Navigator.of(context).pushNamed('/product/${p.id}');
    final rail = CartWishlistRail.fromPayload(cart.railBlock, openProduct);
    // CMD #2087 — the SECOND rail: what pharmacies buy together with this
    // basket, off the same order-history evidence the companion strip reads.
    // It is one more `{has, title, items}` block, so it is the same widget.
    final alsoLike =
        CartWishlistRail.fromPayload(cart.alsoLikeBlock, openProduct);
    if (bill != null) RenderLog.write('c2014_bill_rows', bill.rows.length);
    if (rail != null) RenderLog.write('c2014_rail_cards', rail.items.length);
    if (alsoLike != null) {
      RenderLog.write('c2087_also_like_cards', alsoLike.items.length);
    }
    // CMD #2090 — the two rails are the page's own blocks, in the order the
    // spec names: the wishlist rail first, "You may also like" second, and
    // the bill after both. A rail the backend had nothing for is skipped —
    // never drawn as an empty band. Nothing below them moves when a line is
    // added or removed: see [C2090ScrollComp].
    final rails = CartRailSlot.blocks([rail, alsoLike]);
    RenderLog.write('c2079_cart_blocks',
        'rail=${rail?.items.length ?? 0};bill=${bill?.rows.length ?? 0}'
        ';also=${alsoLike?.items.length ?? 0};order=rows_rails_bill');

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
                            // CMD #2013 — the header is a title and nothing
                            // else. The item count and the advance used to be
                            // repeated here, three centimetres above the list
                            // that shows them and again above Place order.
                            child: _C2090CartBody(
                              rows: _ItemList(
                                key: _itemListKey,
                                cart: cart,
                                externalSearchQuery: widget.externalSearchQuery,
                                viewAsChecked:
                                    cart.isViewAs ? _viewAsChecked : null,
                                onViewAsToggle: cart.isViewAs
                                    ? _toggleViewAsChecked
                                    : null,
                                lineAvailability: _lineAvailability,
                              ),
                              rails: rails,
                              bill: bill,
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
              child: _C2090CartBody(
                rows: _ItemList(
                  key: _itemListKey,
                  cart: cart,
                  externalSearchQuery: widget.externalSearchQuery,
                  viewAsChecked: cart.isViewAs ? _viewAsChecked : null,
                  onViewAsToggle: cart.isViewAs ? _toggleViewAsChecked : null,
                  lineAvailability: _lineAvailability,
                ),
                rails: rails,
                bill: bill,
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

/// CMD #2090 — HOW THE PAGE STAYS STILL WITHOUT HIDING THE BASKET.
///
/// CMD #2087 kept the rails still by locking the cart lines into a
/// fixed-height inner scroller. It worked, and it cost the thing the screen is
/// for: a basket of nine lines showed four, behind a second scrollbar, and the
/// rest were simply not on the page. The list is FULL HEIGHT again and there
/// is exactly ONE scroll on this screen.
///
/// The stillness now comes from the scroll OFFSET rather than from a box.
/// When a rail's ADD appends a row, the content above the rails grows by that
/// row's height; the page is moved by exactly the same amount, so the rails
/// and the bill stay under the same pixel. Removing a row reverses it.
///
/// It is done in [ScrollPhysics.adjustPositionForNewDimensions], which Flutter
/// calls DURING the layout that changed the height — so the correction lands
/// in the same frame as the growth and there is no frame in which anything
/// moved. A post-frame jumpTo would have shown one.
class C2090ScrollComp {
  const C2090ScrollComp._();

  /// Sub-pixel dimension noise (an image settling, a font landing) is not a
  /// row and is not compensated.
  static const double minDelta = 1;

  /// How far the page must move so everything below the cart lines stays put.
  ///
  /// CMD #2099 — the delta is the height of the content ABOVE the rails, not
  /// the scrollable's maxScrollExtent. #2090 read the max extent, which moves
  /// for three reasons that are NOT a cart row: a bill row appearing under
  /// the rails, a banner appearing above the scroll (the viewport shrinks),
  /// and a rail payload arriving a frame later. Each of those made the page
  /// jump by its own height — the ~35px a bill row is — which is exactly what
  /// a wishlist ADD does that a "You may also like" ADD did not: it lands a
  /// row AND a new bill line in two separate layouts. Measuring the block
  /// above the rails compensates the growth that actually pushed them down,
  /// and nothing else.
  ///
  /// Pure on purpose: the rule is asserted without mounting a screen that
  /// needs five inherited states and a live Supabase client.
  static double shift({
    required double? oldAbove,
    required double? newAbove,
    required bool isScrolling,
    required double velocity,
  }) {
    // A finger or a fling owns the page while it is moving; correcting under
    // it would fight the gesture.
    if (isScrolling || velocity != 0) return 0;
    // Nothing has been measured yet (first layout): there is no previous
    // height to compare against, so there is nothing to correct.
    if (oldAbove == null || newAbove == null) return 0;
    final d = newAbove - oldAbove;
    if (d.abs() < minDelta) return 0;
    return d;
  }

  /// The offset to settle on, clamped to what the scrollable can actually do.
  static double settle({
    required double pixels,
    required double shift,
    required double minExtent,
    required double maxExtent,
  }) =>
      (pixels + shift).clamp(minExtent, maxExtent);
}

/// CMD #2099 — the one number the compensation is computed from: the laid-out
/// height of everything ABOVE the rails (the cart rows block).
///
/// [above] is written by [_C2090AboveProbe] during layout, before the viewport
/// reports its content dimensions; [settled] is what the physics has already
/// corrected for. The pair is deliberately mutable and deliberately tiny — it
/// is read once per layout and never rebuilt.
class C2090Anchor {
  /// The height the probe measured in the layout that is running now.
  double? above;

  /// Growth measured above the rails that the page has not yet been moved by.
  /// It is spent by the physics during the SAME layout, or discarded at the
  /// end of the frame — a correction that could not be spent then can never be
  /// spent later, because by the next frame the page has already been seen.
  double pending = 0;
}

/// Records the laid-out height of the block above the rails into a
/// [C2090Anchor]. It draws nothing and changes no layout of its own.
class _C2090AboveProbe extends SingleChildRenderObjectWidget {
  final C2090Anchor anchor;
  const _C2090AboveProbe({required this.anchor, required Widget super.child});

  @override
  _RenderC2090AboveProbe createRenderObject(BuildContext context) =>
      _RenderC2090AboveProbe(anchor);

  @override
  void updateRenderObject(
      BuildContext context, _RenderC2090AboveProbe renderObject) {
    renderObject.anchor = anchor;
  }
}

class _RenderC2090AboveProbe extends RenderProxyBox {
  _RenderC2090AboveProbe(this.anchor);
  C2090Anchor anchor;

  @override
  void performLayout() {
    super.performLayout();
    final previous = anchor.above;
    anchor.above = size.height;
    if (previous == null) return;
    final d = C2090ScrollComp.shift(
      oldAbove: previous,
      newAbove: size.height,
      isScrolling: false,
      velocity: 0,
    );
    if (d == 0) return;
    anchor.pending += d;
    // The viewport reports its content dimensions immediately after this
    // layout, which is the one moment the correction can land. Whatever is
    // still unspent when the frame ends is dropped rather than carried into
    // an unrelated layout — that carry is how a stale delta becomes a jump.
    SchedulerBinding.instance.addPostFrameCallback((_) => anchor.pending = 0);
  }
}

/// The page scroll of the cart, with [C2090ScrollComp] applied.
class C2090StillPhysics extends ScrollPhysics {
  /// CMD #2099 — the measured height of the block above the rails. Null in the
  /// pure tests and in any caller that has no probe: the physics then behaves
  /// exactly like its parent, never guessing a correction.
  final C2090Anchor? anchor;

  const C2090StillPhysics({super.parent, this.anchor});

  @override
  C2090StillPhysics applyTo(ScrollPhysics? ancestor) =>
      C2090StillPhysics(parent: buildParent(ancestor), anchor: anchor);

  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    final base = super.adjustPositionForNewDimensions(
      oldPosition: oldPosition,
      newPosition: newPosition,
      isScrolling: isScrolling,
      velocity: velocity,
    );
    final a = anchor;
    if (a == null) return base;
    // A finger or a fling owns the page while it is moving; correcting under
    // it would fight the gesture, so the delta is left to expire.
    if (isScrolling || velocity != 0) return base;
    final d = a.pending;
    a.pending = 0;
    if (d == 0) return base;
    RenderLog.write('c2099_still_shift',
        'above=${a.above?.toStringAsFixed(0)};d=${d.toStringAsFixed(0)}');
    return C2090ScrollComp.settle(
      pixels: base,
      shift: d,
      minExtent: newPosition.minScrollExtent,
      maxExtent: newPosition.maxScrollExtent,
    );
  }
}

/// CMD #2090 — the cart page below the banners, in ONE scroll:
/// ROWS (all of them, full height) → WISHLIST rail → YOU MAY ALSO LIKE rail →
/// BILL details.
///
/// CMD #2099 — the children are laid out EVERY frame (a Column in one scroll
/// view, not a lazy list), so the probe that measures the block above the
/// rails is never stale: a lazily-dropped rows sliver was a layout the
/// compensation could not see.
class _C2090CartBody extends StatefulWidget {
  final Widget rows;
  final List<Widget> rails;
  final Widget? bill;

  const _C2090CartBody({
    required this.rows,
    required this.rails,
    this.bill,
  });

  @override
  State<_C2090CartBody> createState() => _C2090CartBodyState();
}

class _C2090CartBodyState extends State<_C2090CartBody> {
  /// One anchor per mounted cart page, so the height measured by the probe and
  /// the height the physics corrects against cannot drift apart.
  final C2090Anchor _anchor = C2090Anchor();

  @override
  Widget build(BuildContext context) {
    RenderLog.write(
      'c2090_cart_layout',
      'rows=full;rails=${widget.rails.length}'
      ';order=rows_rails_bill;bill=${widget.bill != null ? 1 : 0}'
      ';scroll=page_only;comp=above_probe',
    );
    return SingleChildScrollView(
      physics: C2090StillPhysics(
          parent: platformScrollPhysics(), anchor: _anchor),
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Everything the rails sit under. Its height IS the compensation.
          _C2090AboveProbe(anchor: _anchor, child: widget.rows),
          ...widget.rails,
          if (widget.bill != null) widget.bill!,
        ],
      ),
    );
  }
}

class _ItemList extends StatefulWidget {
  final CartModel cart;
  final String? externalSearchQuery;
  // CHANGE #324: ViewAs checkbox state — null means not ViewAs (show X button).
  final Set<String>? viewAsChecked;
  final void Function(String productId)? onViewAsToggle;

  /// CHANGE #553 — product_id → the backend's verdict for that cart line,
  /// from cart_availability(). Empty until the first fetch answers.
  final Map<String, Availability> lineAvailability;

  // CMD #2087 — this list holds the cart LINES and nothing else. The bill and
  // the rails used to be trailing rows of it; they are the page's own blocks
  // now, so nothing below the lines moves when a line is added or removed.
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

  final GlobalKey _firstUnavailableKey = GlobalKey();

  @override
  void dispose() {
    super.dispose();
  }

  /// Scrolls to the first unavailable line. Which line that is comes from the
  /// payload's own flag — this never re-derives availability.
  ///
  /// CMD #2090 — one step: the list is a full-height column inside the page
  /// scroll, so the flagged row is already built and ensureVisible on the page
  /// scrollable is all it takes.
  Future<void> scrollToFirstUnavailable() async {
    final lines = _filteredLines;
    final idx = lines.indexWhere((l) => l.unavailable);
    if (idx < 0) return;

    // CMD #2090 — there is no inner scroller to aim at any more, and no lazy
    // build to work around: every row of the list is built, so the flagged
    // row's element always exists and the page scroll can land on it directly.
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
      // CMD #2090 — a block of the page, not a second scroller.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
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

    // CMD #791 — "Frequently bought together" for the whole basket, from
    // cart_render().companions. `has` is the BACKEND's verdict, so an empty
    // cart and a basket with no co-purchase evidence both draw nothing rather
    // than an invented suggestion. Hidden while a search filter is active,
    // because the list is then answering a different question.
    final companions = widget.cart.companions;
    final companionItems = ((companions['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => PdCompanion.fromMap(e.cast<String, dynamic>()))
        .toList(growable: false);
    final showCompanions =
        !searchActive && companions['has'] == true && companionItems.isNotEmpty;

    int afterCount = 0;
    if (hasRemoved) {
      afterCount += 1;
      if (_showRemoved) afterCount += removed.length;
    }
    if (showCompanions) afterCount += 1;

    // CHANGE #639 — index of the first line the BACKEND flagged, so the
    // scroll-to target can be tagged as it is built.
    final firstUnavailable = filtered.indexWhere((l) => l.unavailable);

    // CMD #2013 — the render-log proof for the compact list. A screenshot
    // shows one cart; this says how many rows the list actually painted, how
    // many carried a backend row payload at all, how many printed a price and
    // how many of those printed a struck MRP + discount percent. Every number
    // is read off the payload — the screen counts what it was handed.
    RenderLog.write(
        'c2013_cart_rows',
        'rows=${filtered.length}'
        ';payload=${filtered.where((l) => l.row.isNotEmpty).length}'
        ';price=${filtered.where((l) => l.rowMap('price')['has'] == true).length}'
        ';strike=${filtered.where((l) => l.rowMap('price')['has_strike'] == true).length}'
        ';discount=${filtered.where((l) => l.rowMap('price')['has_discount'] == true).length}');

    // CMD #2120 — the proof for the four-line phone row. A screenshot shows
    // one cart; this says how many rows carried each of the four lines the
    // shape is made of, read straight off the payload.
    RenderLog.write(
        'c2120_cart_row4',
        'rows=${filtered.length}'
        ';composition=${filtered.where((l) => l.rows('composition').isNotEmpty).length}'
        ';badge=${filtered.where((l) => l.rowMap('sale_badge')['has'] == true).length}'
        ';chip=${filtered.where((l) => l.rowMap('qty_chip')['has'] == true).length}'
        ';stepper=0');

    // CMD #2090 — ALL the rows, at full height, inside the page scroll. This
    // was a ListView.builder in a fixed-height slot, which is what hid items
    // behind a second scrollbar; the row count a basket has is small enough
    // that building it as a column costs nothing and hides nothing.
    final int total = filtered.length + afterCount;
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: List<Widget>.generate(total, (i) {
        if (i < filtered.length) {
          final line = filtered[i];
          // CMD #2013 — no card, no border, no shadow: a hairline between
          // rows and nothing else. The last row carries none, so the list
          // ends on whitespace rather than a rule.
          return RepaintBoundary(
            key: ValueKey(line.product.id),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _CartItemCard(
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
                if (i < filtered.length - 1)
                  Divider(height: Ds.space.hairline, color: Ds.c.divider),
              ],
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
          extra -= _showRemoved ? removed.length : 0;
        }

        if (showCompanions) {
          if (extra == 0) {
            return Padding(
              padding: EdgeInsets.only(top: Ds.space.x24, bottom: Ds.space.x8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (companions['title'] ?? '').toString(),
                    style: Ds.t.subtitle,
                  ),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    (companions['note'] ?? '').toString(),
                    style: Ds.t.caption,
                  ),
                  SizedBox(height: Ds.space.x12),
                  CompanionRail(items: companionItems),
                ],
              ),
            );
          }
          extra -= 1;
        }

        return const SizedBox.shrink();
        }),
      ),
    );
  }
}

// ─── Cart item card — CMD #1912 ───────────────────────────────────────────────
//
// ONE COMPACT ROW PER ITEM, AND THE QUANTITY LEADS IT.
//
// The card used to be ~200px tall and said the same sentence on every line:
// a 150px stepper sat over "MRP ₹944.80 · trade rate on confirmation", the
// footer repeated it, and five items could not share a phone screen. The row
// is now ~90px — image, name, pack, quantity, remove — and everything else
// (company, the MRP line, the pack detail) is one tap away, expanded in place.
//
// Nothing on this row is worded here. `cart_render().items[].row` carries the
// name, the pack caption, "4 Strip", the Rx chip, the price line and the
// detail rows already formatted; this widget only lays them out.
/// CMD #2013 — ONE compact row per item. No card, no border, no shadow, no
/// expand: a square thumbnail, the name and pack under it, and on the right a
/// solid quantity pill with the money directly beneath it.
///
/// Everything printed here is `items[].row`, assembled by cart_row_block():
/// the struck MRP, the price, the discount percent and the Rx badge are all
/// backend strings. This screen decides nothing about money — it does not
/// multiply a quantity, does not derive a percent and does not choose when a
/// ceiling is struck. `price.has_strike` is the backend's answer to "are there
/// two numbers here?", and a locked ("PTR") value simply arrives as one line.
class _CartItemCard extends StatelessWidget {
  final CartLine line;
  final CartModel cart;
  // CHANGE #324: ViewAs checkbox — null = normal mode (show the ✕).
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

  /// CMD #2120 — PHONE AND DESKTOP ARE TWO SHAPES NOW.
  ///
  /// 99% of mediBO is a phone, and on a phone the cart row is the Bulk Upload
  /// row: photo, name, composition, one sale-price badge, one tappable
  /// quantity chip. The desktop cart — a 960px two-column page with room for a
  /// stepper and a struck MRP beside it — is untouched, so the breakpoint is
  /// the same 600px the rest of this screen already splits on.
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.sizeOf(context).width < _kC2120PhoneMax) {
      return _buildPhone(context);
    }
    return _buildWide(context);
  }

  Widget _buildWide(BuildContext context) {
    final p = line.product;
    // CHANGE #553 — the line's availability is whatever cart_availability()
    // said about this product_id. Nothing here re-derives it.
    final av = availability;
    final rx = line.rowMap('rx_chip');
    final price = line.rowMap('price');
    final stepper = line.rowMap('stepper');

    // The name and the pack caption are the payload's, with the product record
    // standing in only while the first cart_render() is in flight.
    final name = line.rows('name').isNotEmpty ? line.rows('name') : p.name;
    // CMD #2025 — the pack caption is the SAME sf_pack_badge() string the
    // storefront card and the product page print, carried on the line by
    // cart_state(). It used to fall back to the cart's own unit word, which is
    // how a row that is "Strip of 10 tablets" everywhere else read "1 Strip".
    final pack = line.rows('pack_label');

    // CMD #2025 — the row's own tap target. `open.has` is the BACKEND's answer
    // to "does this line have a product page?"; the screen only navigates.
    final open = line.rowMap('open');
    final canOpen = open['has'] == true;
    void openProduct() {
      if (!canOpen) return;
      RenderLog.write(kC2025RowOpen, open['product_id']?.toString() ?? p.id);
      // A PUSH, so the cart stays mounted underneath: Android back and the
      // page's own arrow both pop straight back to it, at the same scroll
      // offset, with no re-read.
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProductDetailScreen(
              productId: open['product_id']?.toString() ?? p.id),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Left: the square tile, with the Rx badge on its corner ───────
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: canOpen ? openProduct : null,
            child: C2013Thumb(product: p, rx: rx),
          ),
          SizedBox(width: Ds.space.x12),
          // ── Middle: name, then pack ─────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // CMD #2025 — name AND pack are one tap target, which keeps it
                // over 44 px tall on a phone without padding the compact row
                // out of its rhythm.
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: canOpen ? openProduct : null,
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.body.copyWith(
                              color: Ds.c.text, fontWeight: FontWeight.w700),
                        ),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          pack.isNotEmpty ? pack : p.packSize,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.caption,
                        ),
                      ],
                    ),
                  ),
                ),
                // CHANGE #553 — the backend's verdict for this line, in the
                // backend's own label and colours, shown only when it says the
                // line cannot be ordered. It is the one thing that may still
                // add a line to a row, because it blocks the order.
                if (av != null && !av.canAdd) ...[
                  SizedBox(height: Ds.space.x4),
                  _C1912Chip(
                    label: av.note ?? av.ctaLabel,
                    tone: {'bg': av.bg, 'fg': av.fg},
                  ),
                ],
                if (line.addedByAdmin) ...[
                  SizedBox(height: Ds.space.x4),
                  _C1912Chip(
                    label: c('cart.badge_added_by_admin'),
                    tone: const {'bg': '#D1FAE5', 'fg': '#065F46'},
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          // ── Right: the pill, the money under it, and the ✕ ──────────────
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              // CHANGE #324: ViewAs → checkbox; normal → the stepper.
              if (viewAsChecked != null)
                SizedBox(
                  width: Ds.touch.minTarget,
                  height: Ds.touch.minTarget,
                  child: Checkbox(
                    value: viewAsChecked,
                    onChanged: (_) => onViewAsToggle?.call(),
                    activeColor: Ds.c.brand,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                // CHANGE #615 — the stepper shows cart.quantityOf(), the
                // user's own unsent tap when there is one and the server's
                // number otherwise, so a tap lands in this frame.
                // CHANGE #639 — qty_locked comes from cart_render(); the
                // stepper is dead and tinted danger on the strength of the
                // backend's flag, never on a local stock check.
                // CMD #2039 — `qty_text` is the SERVER's number, and between
                // the tap and the 46 ms reply it is one tap stale. Handing it
                // to the stepper while the user has an unsent tap outstanding
                // is what froze the digit: the control re-rendered with the
                // OLD string every frame until the round trip returned. With a
                // local tap outstanding the stepper prints that tap — the
                // customer's own input echoed back, not a backend string
                // reworded here.
                _CartStepper(
                  product: p,
                  quantity: cart.quantityOf(p.id),
                  cart: cart,
                  locked: line.qtyLocked,
                  // CMD #2087 — the stepper is told WHOSE number it is holding.
                  // While this is true the digit on screen is the customer's
                  // own tap; the moment it goes false the server has answered,
                  // and that answer is applied without a second roll.
                  localIntent: cart.hasLocalIntent(p.id),
                  qtyText: cart.hasLocalIntent(p.id)
                      ? ''
                      : (stepper['qty_text'] ?? '').toString(),
                ),
              SizedBox(height: Ds.space.x8),
              C2013RowPrice(price: price),
            ],
          ),
          // CHANGE #639 — a line cart_render() flagged gets the prominent
          // remove control: same RPC, more emphasis, because this is the one
          // action that clears the block.
          _C1912Remove(onTap: () => cart.remove(p), danger: line.unavailable),
        ],
      ),
      // CMD #2025 — a save that did not land is THIS row's problem. It gets
      // the full row width (a phone has no room for it beside the pill), the
      // sentence and the retry word are the backend's, and the rest of the
      // cart stays usable: nothing blocks the screen.
      if (cart.hasRowError(p.id)) ...[
        SizedBox(height: Ds.space.x4),
        C2025RowRetry(
          message: cart.rowErrorMessage(p.id),
          label: cart.rowRetryLabel(p.id),
          onRetry: () => cart.retryRow(p.id),
        ),
      ],
        ],
      ),
    );
  }

  /// CMD #2120 — THE PHONE ROW: the photo, then four lines, and nothing else.
  ///
  /// This is the shape Bulk Upload settled on (#2115 / CHANGE #1454, #2119)
  /// for the same product on the same 360px screen, and the cart was the last
  /// storefront surface still drawing its own. Every line is `items[].row`,
  /// assembled by cart_row_block():
  ///
  ///   1  `name`             — one line, ellipsis.
  ///   2  `composition`      — MEDICINE.salt_composition VERBATIM. Absent is
  ///                           absent: `has_composition:false` draws nothing.
  ///   3  `sale_badge`       — _pricing_block()'s card_price in its own two
  ///                           colours: the formatted amount when the viewer
  ///                           is entitled to it, the locked word ("PTR") when
  ///                           not. No MRP, no strike, no percent — this
  ///                           screen cannot leak a trade price because it
  ///                           never holds one.
  ///   4  `qty_chip.label`   — "5 strip", bulk_qty_line()'s template with the
  ///                           catalogue's own pack word.
  ///
  /// The − 1 + stepper is gone. The chip is the control now, and it opens the
  /// ONE quantity popup — literally the same widget Bulk Upload opens,
  /// centred on this line's quantity and capped by bulk.qty_picker_max.
  Widget _buildPhone(BuildContext context) {
    final p = line.product;
    final av = availability;
    final rx = line.rowMap('rx_chip');
    final badge = line.rowMap('sale_badge');
    final chip = line.rowMap('qty_chip');

    final name = line.rows('name').isNotEmpty ? line.rows('name') : p.name;
    final composition = line.rows('composition');

    final open = line.rowMap('open');
    final canOpen = open['has'] == true;
    void openProduct() {
      if (!canOpen) return;
      RenderLog.write(kC2025RowOpen, open['product_id']?.toString() ?? p.id);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ProductDetailScreen(
              productId: open['product_id']?.toString() ?? p.id),
        ),
      );
    }

    // Three text lines and one control line, so the chip keeps a full 44px
    // touch height without the first three growing to match it. The tile is
    // exactly as tall as the four of them together.
    final double textH = _kC2120LineH * 3 + Ds.touch.minTarget;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: canOpen ? openProduct : null,
                child: C2013Thumb(product: p, rx: rx, side: textH),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _C2120Line(
                      height: _kC2120LineH,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: canOpen ? openProduct : null,
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Ds.t.body.copyWith(
                              color: Ds.c.text, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                    _C2120Line(
                      height: _kC2120LineH,
                      child: composition.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              composition,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Ds.t.caption,
                            ),
                    ),
                    _C2120Line(
                      height: _kC2120LineH,
                      child: C2120SaleBadge(badge: badge),
                    ),
                    _C2120Line(
                      height: Ds.touch.minTarget,
                      child: C2120QtyChip(
                        chip: chip,
                        locked: line.qtyLocked,
                        onPicked: (qty) => cart.setQuantity(p, qty),
                      ),
                    ),
                  ],
                ),
              ),
              // CHANGE #324: ViewAs → checkbox; normal → the ✕. Both sit where
              // the ✕ has always sat, so nothing moves between the modes.
              if (viewAsChecked != null)
                SizedBox(
                  width: Ds.touch.minTarget,
                  height: Ds.touch.minTarget,
                  child: Checkbox(
                    value: viewAsChecked,
                    onChanged: (_) => onViewAsToggle?.call(),
                    activeColor: Ds.c.brand,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                )
              else
                _C1912Remove(
                    onTap: () => cart.remove(p), danger: line.unavailable),
            ],
          ),
          // CHANGE #553 / #639 — the backend's verdict for this line, in the
          // backend's own label and colours. It is the one thing still allowed
          // to add a line to a row, because it blocks the order.
          if (av != null && !av.canAdd) ...[
            SizedBox(height: Ds.space.x4),
            _C1912Chip(
              label: av.note ?? av.ctaLabel,
              tone: {'bg': av.bg, 'fg': av.fg},
            ),
          ],
          if (line.addedByAdmin) ...[
            SizedBox(height: Ds.space.x4),
            _C1912Chip(
              label: c('cart.badge_added_by_admin'),
              tone: const {'bg': '#D1FAE5', 'fg': '#065F46'},
            ),
          ],
          // CMD #2025 — a save that did not land is THIS row's problem.
          if (cart.hasRowError(p.id)) ...[
            SizedBox(height: Ds.space.x4),
            C2025RowRetry(
              message: cart.rowErrorMessage(p.id),
              label: cart.rowRetryLabel(p.id),
              onRetry: () => cart.retryRow(p.id),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── CMD #2120 — the phone cart row's three pieces ───────────────────────────

/// The phone breakpoint this screen already splits on. Below it the cart row
/// is the Bulk Upload shape; at or above it the desktop row is untouched.
const double _kC2120PhoneMax = 600;

/// One text line of the four-line block. A fixed slot rather than an intrinsic
/// height, so a line the payload left empty still holds its place and the
/// photo beside it ends on the same baseline as line 4.
double get _kC2120LineH => Ds.space.x24;

class _C2120Line extends StatelessWidget {
  final double height;
  final Widget child;
  const _C2120Line({required this.height, required this.child});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: height,
        width: double.infinity,
        child: Align(alignment: Alignment.centerLeft, child: child),
      );
}

/// CMD #2120 — line 3: ONE filled badge, the sale price and nothing else.
///
/// `sale_badge` is cart_row_block()'s copy of _pricing_block()'s `card_price`:
/// the label, the value and the two colours. `value` is already the right
/// answer for THIS viewer — the formatted amount for an approved buyer, the
/// locked word for everyone else — so nothing here asks which it is holding
/// and no PTR number can reach a viewer the backend withheld it from.
///
/// FittedBox rather than an ellipsis (CMD #2119's lesson on the same badge):
/// on a very narrow phone the whole badge scales down together, so the label
/// is never the part that gets cut.
class C2120SaleBadge extends StatelessWidget {
  final Map<String, dynamic> badge;
  const C2120SaleBadge({super.key, required this.badge});

  @override
  Widget build(BuildContext context) {
    if (badge['has'] != true) return const SizedBox.shrink();
    final value = (badge['value'] ?? '').toString();
    if (value.isEmpty) return const SizedBox.shrink();
    final label = (badge['label'] ?? '').toString();
    final ink = _C1912Chip._colour(badge['fg'], Ds.c.surface);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.hairline),
        decoration: BoxDecoration(
          color: _C1912Chip._colour(badge['bg'], Ds.c.brand),
          borderRadius: BorderRadius.circular(Ds.r.chip),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (label.isNotEmpty) ...[
            Text(label,
                maxLines: 1,
                softWrap: false,
                style: Ds.t.caption.copyWith(color: ink)),
            SizedBox(width: Ds.space.x4),
          ],
          Text(value,
              maxLines: 1,
              softWrap: false,
              style: Ds.t.caption
                  .copyWith(color: ink, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}

/// CMD #2120 — line 4: the quantity, as a control rather than a caption.
///
/// The − 1 + stepper is gone. This is an outlined chip with a chevron, so it
/// reads as something to tap, and tapping it opens `showQtyPickerChoice` — the
/// SAME popup Bulk Upload opens, from the same file, centred on this line's
/// quantity and capped by `bulk.qty_picker_max`.
///
/// The word on it is never composed here: `qty_chip.label` is
/// bulk_qty_line()'s template ("5 strip"). Between the pick and the server's
/// reply the chip prints the label the PICKER handed back — still the
/// backend's sentence, just one round trip early — and drops it the moment the
/// payload's own label changes.
///
/// `locked` is cart_render()'s `qty_locked`, carried through: the chip is dead
/// and tinted danger on the strength of that flag, never on a local check.
/// CMD #2120 — the chip's ONE decision, pure so it can be held down.
///
/// After a pick the chip prints the label the PICKER handed back (still a
/// backend string), and it keeps printing it until the payload's own label
/// changes — which is the server answering, whatever it answered. It is never
/// a Dart-composed sentence and it never outlives the round trip.
String? c2120PendingAfterPayload(
    {required String? pending,
    required String oldLabel,
    required String newLabel}) =>
    oldLabel == newLabel ? pending : null;

String c2120ChipText({required String? pending, required String payload}) =>
    (pending != null && pending.isNotEmpty) ? pending : payload;

class C2120QtyChip extends StatefulWidget {
  final Map<String, dynamic> chip;
  final bool locked;
  final ValueChanged<int> onPicked;
  const C2120QtyChip({
    super.key,
    required this.chip,
    required this.onPicked,
    this.locked = false,
  });

  @override
  State<C2120QtyChip> createState() => _C2120QtyChipState();
}

class _C2120QtyChipState extends State<C2120QtyChip> {
  String? _pending;

  @override
  void didUpdateWidget(C2120QtyChip old) {
    super.didUpdateWidget(old);
    // The server answered — whatever it says wins, even if it clamped the pick.
    _pending = c2120PendingAfterPayload(
        pending: _pending,
        oldLabel: _label(old.chip),
        newLabel: _label(widget.chip));
  }

  static String _label(Map<String, dynamic> m) => (m['label'] ?? '').toString();

  Future<void> _open() async {
    final picked = await showQtyPickerChoice(
      context,
      packType: (widget.chip['pack_type'] ?? '').toString(),
      current: (widget.chip['qty'] as num?)?.toInt() ?? 0,
    );
    if (picked == null || !mounted) return;
    setState(() => _pending = picked.label);
    widget.onPicked(picked.value);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chip['has'] != true) return const SizedBox.shrink();
    final text = c2120ChipText(pending: _pending, payload: _label(widget.chip));
    if (text.isEmpty) return const SizedBox.shrink();
    final tint = widget.locked ? Ds.c.danger : Ds.c.brand;
    return Semantics(
      identifier: 'cart_qty_chip',
      button: true,
      label: (widget.chip['hint'] ?? '').toString(),
      child: InkWell(
        onTap: widget.locked ? null : _open,
        borderRadius: BorderRadius.circular(Ds.r.chip),
        child: Container(
          height: Ds.touch.minTarget,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: tint),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.body
                      .copyWith(color: tint, fontWeight: FontWeight.w600)),
            ),
            SizedBox(width: Ds.space.x4),
            Icon(Icons.keyboard_arrow_down, size: Ds.space.x16, color: tint),
          ]),
        ),
      ),
    );
  }
}

/// CMD #2025 — the one thing a failed save is allowed to do: say so on its own
/// row, and offer to send it again.
///
/// Both strings are the payload's — `message` is the backend's refusal (or its
/// stored "Not saved" note when the network never reached it) and `label` is
/// the backend's word for the control. Nothing here is worded, and nothing
/// here blocks: the rest of the cart keeps working while this row is red.
const String kC2025RowOpen = 'c2025_cart_row_open';
const String kC2025RowRetry = 'c2025_cart_row_retry';

class C2025RowRetry extends StatelessWidget {
  final String message;
  final String label;
  final VoidCallback onRetry;

  const C2025RowRetry({
    super.key,
    required this.message,
    required this.label,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write(kC2025RowRetry, message);
    return Row(
      children: [
        Flexible(
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Ds.t.caption.copyWith(color: Ds.c.danger),
          ),
        ),
        if (label.isNotEmpty) ...[
          SizedBox(width: Ds.space.x8),
          SizedBox(
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                foregroundColor: Ds.c.brand,
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                tapTargetSize: MaterialTapTargetSize.padded,
              ),
              child: Text(label,
                  style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ],
    );
  }
}

/// CMD #2013 — the square product tile, with the Rx badge sitting on its
/// top-right corner. `rx.has` is the per-line flag cart_render() sends; the
/// badge's two colours are the payload's own.
class C2013Thumb extends StatelessWidget {
  final Product product;
  final Map<String, dynamic> rx;

  /// CMD #2120 — the phone row sizes the tile to its own text block, so the
  /// photo and the four lines beside it end on the same baseline. Left null
  /// the tile keeps the size every other cart surface draws it at.
  final double? side;
  const C2013Thumb(
      {super.key, required this.product, this.rx = const {}, this.side});

  @override
  Widget build(BuildContext context) {
    final size = side ?? (Ds.space.x48 + Ds.space.x24);
    final tile = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.button),
        border: Border.all(color: Ds.c.divider),
      ),
      child: _ProductImage(product: product, size: size - Ds.space.x12),
    );
    final label = (rx['label'] ?? '').toString();
    if (rx['has'] != true || label.isEmpty) return tile;

    final tone = (rx['tone'] as Map?)?.cast<String, dynamic>();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        tile,
        Positioned(
          top: -Ds.space.x4,
          right: -Ds.space.x4,
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x4 + Ds.space.hairline,
                vertical: Ds.space.hairline),
            decoration: BoxDecoration(
              color: _C1912Chip._colour(tone?['bg'], Ds.c.info),
              borderRadius: BorderRadius.circular(Ds.r.chip),
            ),
            child: Text(
              label,
              style: Ds.t.caption.copyWith(
                color: _C1912Chip._colour(tone?['fg'], Ds.c.surface),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// CMD #2013 — the money, right-aligned under the quantity pill.
///
/// Two lines when there is a discount to show — the struck MRP above, the
/// price with its percent beside it below — and ONE plain line when there is
/// not. Which of those it is comes from `price.has_strike` and
/// `price.has_discount`: this widget never compares two numbers, and the
/// percent it prints is the backend's sentence, not a division done here.
class C2013RowPrice extends StatelessWidget {
  final Map<String, dynamic> price;
  const C2013RowPrice({super.key, required this.price});

  @override
  Widget build(BuildContext context) {
    final value = (price['value'] ?? '').toString();
    if (price['has'] != true || value.isEmpty) return const SizedBox.shrink();
    final mrp = (price['mrp_display'] ?? '').toString();
    final strike = price['has_strike'] == true && mrp.isNotEmpty;
    final discount = (price['discount_label'] ?? '').toString();
    final hasDiscount = price['has_discount'] == true && discount.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (strike)
          Text(
            mrp,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Ds.t.caption
                .copyWith(decoration: TextDecoration.lineThrough),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (hasDiscount) ...[
              Text(
                discount,
                maxLines: 1,
                style: Ds.t.caption.copyWith(
                  color: _C1912Chip._colour(price['discount_fg'], Ds.c.brand),
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(width: Ds.space.x4),
            ],
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.body
                  .copyWith(color: Ds.c.text, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ],
    );
  }
}

/// CMD #1912 — one badge shape for the whole cart row.
///
/// The label and both colours are the payload's; `tone` absent means the
/// neutral info tint, never a colour this widget picked for a meaning it
/// guessed at.
class _C1912Chip extends StatelessWidget {
  final String label;
  final Map<String, dynamic>? tone;
  const _C1912Chip({required this.label, this.tone});

  /// cart_render() sends tones as '#RRGGBB'; cart_availability() has always
  /// sent them as packed ints. Both are the backend's colour — read either
  /// rather than making one of the two callers convert on the way in.
  static Color _colour(Object? raw, Color fallback) {
    if (raw is int) return Color(raw);
    if (raw is num) return Color(raw.toInt());
    return Ds.hex(raw, fallback);
  }

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final t = tone ?? const {};
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4 / 2),
      decoration: BoxDecoration(
        color: _colour(t['bg'], Ds.c.infoSoft),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(color: _colour(t['fg'], Ds.c.info)),
      ),
    );
  }
}

/// CMD #1912 — the ✕ at the far right of a cart row. A 24px mark inside a
/// full-size tap target, so a compact row never costs the customer accuracy.
class _C1912Remove extends StatelessWidget {
  final VoidCallback onTap;
  final bool danger;
  const _C1912Remove({required this.onTap, this.danger = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: Ds.touch.minTarget * 0.8,
      height: Ds.touch.minTarget,
      child: GestureDetector(
        key: danger ? const ValueKey('c639_remove_unavailable') : null,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Center(
          child: Icon(
            Icons.close,
            size: Ds.space.x16,
            color: danger ? Ds.c.danger : Ds.c.textSecondary,
          ),
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

// ─── Cart quantity stepper — CMD #1912 ───────────────────────────────────────
//
// Compact: 132×44 instead of 150×56, so it fits a 90px row next to the name,
// the pack and the ✕. The quantity is still the largest thing on the row —
// it is the only bold number a collapsed row carries.
//
// The word beside the number ("Strip") is `row.qty_label`, formatted by
// cart_row_block(). It used to be _CartStepper._unit(): nine `contains()`
// tests over the pack string, in Dart, deciding a display word. The only
// motion left is the roll when that label changes.
class _CartStepper extends StatefulWidget {
  final Product product;
  final int quantity;
  final CartModel cart;

  /// CHANGE #639 — `qty_locked` from cart_render(). When true both tap zones
  /// are dead and the control is tinted danger. This is the backend's answer,
  /// carried through; the stepper never decides it.
  final bool locked;

  /// The NUMBER, from `items[].row.stepper.qty_text`.
  final String qtyText;

  /// CMD #2087 — true while the digit shown is the customer's own unsent tap
  /// (CartModel.hasLocalIntent). It is the only way this control can tell a
  /// tap apart from the server's reply to that tap.
  final bool localIntent;

  const _CartStepper({
    required this.product,
    required this.quantity,
    required this.cart,
    this.locked = false,
    this.qtyText = '',
    this.localIntent = false,
  });

  @override
  State<_CartStepper> createState() => _CartStepperState();
}

class _CartStepperState extends State<_CartStepper> {
  bool _increasing = true;

  /// CMD #2087 — THE FLICKER.
  ///
  /// One tap produced two animations. The first was right: the local echo
  /// rolls the digit the instant the finger lifts. The second was the server
  /// answering about a second later — cart_update_item() returns, the local
  /// echo is dropped and `qty_text` (the SAME number, as the backend words it)
  /// takes its place. The AnimatedSwitcher saw a new child and rolled the digit
  /// again, so the stepper twitched a second after the customer had moved on.
  ///
  /// The server's value is applied SILENTLY: same place, no roll. Only a change
  /// the customer just made animates.
  bool _silent = false;

  @override
  void didUpdateWidget(_CartStepper old) {
    super.didUpdateWidget(old);
    // The reply to a tap: the echo was on, now it is off. Whatever the server
    // said — the number it acknowledged, or one it clamped — lands without a
    // second animation.
    _silent = c2087StepperSilent(
      wasLocal: old.localIntent,
      isLocal: widget.localIntent,
      oldQty: old.quantity,
      newQty: widget.quantity,
      oldText: old.qtyText,
      newText: widget.qtyText,
    );
    if (widget.quantity != old.quantity) {
      _increasing = widget.quantity > old.quantity;
    }
  }

  @override
  Widget build(BuildContext context) {
    final qty = widget.quantity;
    final increasing = _increasing;
    final locked = widget.locked;
    final zone = Ds.touch.minTarget;
    // CMD #2013 — ONE solid filled pill: brand green, white minus, white
    // number, white plus. The cart list carries no other filled surface, so
    // the pill and Place order are the only two solid greens on the screen.
    final fill = locked ? Ds.c.danger : Ds.c.brand;
    final ink = Ds.c.surface;

    return SizedBox(
      width: zone * 2 + Ds.space.x24,
      height: zone,
      child: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(Ds.r.chip),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: zone,
                    child: Center(
                      child: Icon(Icons.remove, size: Ds.space.x16, color: ink),
                    ),
                  ),
                  // Centre: the quantity, rolling.
                  Expanded(
                    child: Center(
                      child: ClipRect(
                        child: AnimatedSwitcher(
                          duration: _silent
                              ? Duration.zero
                              : Duration(milliseconds: Ds.motion.standardMs),
                          transitionBuilder: (child, anim) {
                            final isNew =
                                (child.key as ValueKey<String>).value ==
                                    '$qty|${widget.qtyText}';
                            final begin = isNew
                                ? (increasing
                                    ? const Offset(0, -1)
                                    : const Offset(0, 1))
                                : (increasing
                                    ? const Offset(0, 1)
                                    : const Offset(0, -1));
                            return SlideTransition(
                              position:
                                  Tween<Offset>(begin: begin, end: Offset.zero)
                                      .animate(anim),
                              child: child,
                            );
                          },
                          child: Text(
                            widget.qtyText.isNotEmpty
                                ? widget.qtyText
                                : '$qty',
                            key: ValueKey<String>('$qty|${widget.qtyText}'),
                            maxLines: 1,
                            overflow: TextOverflow.clip,
                            softWrap: false,
                            style: Ds.t.bodyStrong
                                .copyWith(color: ink, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: zone,
                    child: Center(
                      child: Icon(Icons.add, size: Ds.space.x16, color: ink),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Invisible tap zones — both dead while the backend says locked.
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: zone,
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
                const Expanded(child: SizedBox()),
                SizedBox(
                  width: zone,
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

/// CMD #2087 — cart_place_gate(), as a value.
///
/// The screen must not read `state` to decide anything: `action` IS the
/// instruction, and every word and route in the other fields is printed or
/// opened verbatim. Keeping that as a parsed object rather than map lookups
/// scattered through an async method is what makes it testable without a
/// browser — and an action this build has never heard of is [isUnknown], which
/// does nothing at all rather than guessing (the same forward-compat rule the
/// home feed follows for an unknown layout).
class C2087PlaceGate {
  final String state;
  final String action;
  final String route;
  final String anchor;
  final String popupTitle;
  final String popupBody;
  final String popupDismiss;

  const C2087PlaceGate({
    required this.state,
    required this.action,
    required this.route,
    required this.anchor,
    required this.popupTitle,
    required this.popupBody,
    required this.popupDismiss,
  });

  static const C2087PlaceGate unreachable = C2087PlaceGate(
      state: '', action: '', route: '', anchor: '',
      popupTitle: '', popupBody: '', popupDismiss: '');

  factory C2087PlaceGate.from(Map<String, dynamic> m) {
    final popup =
        (m['popup'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    return C2087PlaceGate(
      state: (m['state'] ?? '').toString(),
      action: (m['action'] ?? '').toString(),
      route: (m['route'] ?? '').toString(),
      anchor: (m['anchor'] ?? '').toString(),
      popupTitle: (popup['title'] ?? '').toString(),
      popupBody: (popup['body'] ?? '').toString(),
      popupDismiss: (popup['dismiss'] ?? '').toString(),
    );
  }

  bool get placesOrder => action == 'order';
  bool get showsPopup => action == 'popup';
  /// A route with nothing to open is not a route.
  bool get opensRoute => action == 'route' && route.isNotEmpty;
  bool get isUnknown => !placesOrder && !showsPopup && action != 'route';

  /// What the render log records, so a live run says which of the five answers
  /// the tap actually got.
  String get logLine => '$state/$action';
}

/// CMD #2087 — should the quantity roll, or just change?
///
/// A tap rolls the digit. The server's reply to that tap — the same number, as
/// the backend words it, about a second later — does not: it is applied in
/// place. That one rule is the whole flicker fix, and it is here rather than
/// inside the stepper's State so it can be tested without a frame.
bool c2087StepperSilent({
  required bool wasLocal,
  required bool isLocal,
  required int oldQty,
  required int newQty,
  required String oldText,
  required String newText,
}) {
  // The echo was on and is now off: the server has answered.
  if (wasLocal && !isLocal) return true;
  // The same number, re-worded.
  if (oldQty == newQty && oldText != newText) return true;
  return false;
}

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
                // CMD #2013 — EXACTLY ONE summary row above the button:
                // "Total items N" on the left, "Advance to pay ₹x" on the
                // right, both from `summary.bottom`. The tax breakup, the
                // sale/PTR line, the MRP total, Delivery FREE and the
                // rate-confirmed note all stacked here and answered questions
                // the customer was not asking at the moment of committing.
                // In View As the one row is cart_selected_total()'s own line
                // and amount for the ticked lines — still one row, still the
                // backend's two strings.
                if (selectedTotal == null)
                  C2013SummaryRow(render: cart.render)
                else
                  C572TotalsBlock(
                    render: cart.render,
                    selectedTotal: selectedTotal,
                    selectedLine: selectedSubtotalLine,
                  ),
                if (selectedTotal == null)
                  C572CartNotice(render: cart.render, onAction: onNoticeAction),
                // CMD #2090 — the ONE gap between the Advance line and Place
                // order, on the design scale rather than as a literal 12.
                SizedBox(height: Ds.space.x12),
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
                            // CMD #2087 — the one handle on this screen a
                            // browser journey can hold: the tap that asks
                            // cart_place_gate() what this basket becomes.
                            child: Semantics(
                              button: true,
                              identifier: 'cart_place_order',
                              child: GestureDetector(
                                onTap: onPlaceOrder,
                                child: Container(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 15),
                                decoration: BoxDecoration(
                                  color: blocked ? Ds.c.textSecondary : Ds.c.brand,
                                  borderRadius:
                                      BorderRadius.circular(Ds.r.button),
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
          // CMD #2013 — the sidebar is the phone bar: ONE summary row, one
          // notice, one button. The phone layout is where this screen is
          // designed, and the wide one must not say more than it does.
          if (selectedTotal == null)
            C2013SummaryRow(render: cart.render)
          else
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
                      color: blocked ? Ds.c.textSecondary : Ds.c.brand,
                      borderRadius: BorderRadius.circular(Ds.r.button),
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

  /// CMD #1848 — present ONLY on a test-session order (`test_badge` /
  /// `test_note` from place_order_v2). Empty on a real order, so the ordinary
  /// dialog is byte-identical to before.
  final String testBadge;
  final String testNote;

  const _OrderPlacedDialog({
    required this.orderNumber,
    required this.amount,
    required this.onDone,
    this.testBadge = '',
    this.testNote = '',
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
              if (testBadge.isNotEmpty) ...[
                Container(
                  key: const ValueKey('placed_test_badge'),
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration: BoxDecoration(
                    color: Ds.c.dangerSoft,
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(testBadge,
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.danger, fontWeight: FontWeight.w700)),
                ),
                SizedBox(height: Ds.space.x12),
              ],
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
              if (testNote.isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(
                  testNote,
                  textAlign: TextAlign.center,
                  style: Ds.t.caption.copyWith(color: Ds.c.danger),
                ),
              ],
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
  /// CMD #1912 — animate the amount when it can change under the customer's
  /// own tap (the cart's own totals). Every other caller prints it still.
  final bool animate;
  const _C461TotalRow(
      {required this.label,
      required this.amount,
      this.strong = false,
      this.animate = false});

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
          // CMD #1912 — the total re-counts when the stepper moves. It is the
          // only motion on this screen besides the rolling quantity, and it is
          // the same roll: a changed string slides the old one out.
          if (animate)
            ClipRect(
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: Ds.motion.standardMs),
                transitionBuilder: (child, anim) => SlideTransition(
                  position: Tween<Offset>(
                          begin: const Offset(0, 0.6), end: Offset.zero)
                      .animate(anim),
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Text(amount,
                    key: ValueKey<String>(amount),
                    style: strong ? Ds.t.subtitle : Ds.t.body,
                    textAlign: TextAlign.right),
              ),
            )
          else
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
    // CMD #1912 — the line only earns its place next to an amount. The BACKEND
    // answers that (`show_line`): on a basket with nothing payable yet the
    // rows below already say the item count, and the line said it again.
    // ABSENCE IS NOT A NO: a payload that never heard of `show_line` (an older
    // cached cart_render, a caller that builds the block itself) keeps the
    // #572 behaviour and prints the line. Only an explicit false suppresses it.
    final showLine = selectedTotal != null || s['show_line'] != false;
    final rows = selectedTotal != null
        ? const <Map<String, dynamic>>[]
        : ((s['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList(growable: false);
    final deliveryNote =
        selectedTotal != null ? '' : (s['delivery_note'] ?? '').toString();
    // CMD #1912 — "Rate confirmed after supplier quote." Once, here, above the
    // total — instead of once per row plus once in the footer.
    final rateNote =
        selectedTotal != null ? '' : (s['rate_note'] ?? '').toString();

    if ((!showLine || line.isEmpty) &&
        amount.isEmpty &&
        rows.isEmpty &&
        rateNote.isEmpty) {
      return const SizedBox.shrink();
    }

    // ONE divider: it sits above the strong row when the payload sent one,
    // and closes the ladder when it did not.
    final strongAt = rows.indexWhere((r) => r['strong'] == true);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showLine && (line.isNotEmpty || amount.isNotEmpty))
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
        for (var i = 0; i < rows.length; i++) ...[
          if (i == strongAt)
            Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
              child: Divider(height: Ds.space.hairline, color: Ds.c.divider),
            ),
          _C461TotalRow(
            label: (rows[i]['label'] ?? '').toString(),
            amount: (rows[i]['amount'] ?? '').toString(),
            strong: rows[i]['strong'] == true,
            animate: true,
          ),
        ],
        if (strongAt < 0 && rows.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Divider(height: Ds.space.hairline, color: Ds.c.divider),
          ),
        if (rateNote.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x4),
            child: Text(rateNote, style: Ds.t.caption),
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
    final chip = (n['chip'] as Map?)?.cast<String, dynamic>() ?? const {};

    if (n['has'] != true) {
      // CMD #1815 — a licence that is not on file WARNS. It is a small chip
      // with a View action and nothing else: no full-width card, no countdown,
      // and no sentence about ordering stopping, because ordering does not
      // stop. Approval decided that, by hand, before the account existed.
      final chipRow =
          chip['has'] == true ? C1815KycChip(chip: chip, onAction: onAction) : null;
      if (chipRow == null && note.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (chipRow != null) chipRow,
            if (chipRow != null && note.isNotEmpty)
              SizedBox(height: Ds.space.x8),
            if (note.isNotEmpty) Text(note, style: Ds.t.caption),
          ],
        ),
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


/// CMD #1815 — the smallest thing that can say "we still need a document".
///
/// Every word, colour and destination is `cart_render().render.notice.chip`,
/// which is `kyc_chip_block()`'s answer: the label, the three tone colours and
/// the action's own label and route descriptor. Nothing here knows what KYC
/// is, which state the account is in, or where Licence & documents lives — a
/// chip with no action draws no button, and a chip the backend did not send
/// draws nothing at all.
class C1815KycChip extends StatelessWidget {
  final Map<String, dynamic> chip;
  final void Function(Map<String, dynamic> action)? onAction;

  const C1815KycChip({super.key, required this.chip, this.onAction});

  @override
  Widget build(BuildContext context) {
    if (chip['has'] != true) return const SizedBox.shrink();
    final label = (chip['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final tone = (chip['tone'] as Map?)?.cast<String, dynamic>() ?? const {};
    final action = (chip['action'] as Map?)?.cast<String, dynamic>() ?? const {};
    final actionLabel =
        action['has'] == true ? (action['label'] ?? '').toString() : '';
    final fg = Ds.hex(tone['fg'], Ds.c.warning);
    RenderLog.write('c1815_kyc_chip', (chip['state'] ?? '').toString());

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: Ds.hex(tone['bg'], Ds.c.warningSoft),
            borderRadius: BorderRadius.circular(Ds.r.chip),
            border: Border.all(color: Ds.hex(tone['border'], Ds.c.divider)),
          ),
          child: Text(label, style: Ds.t.caption.copyWith(color: fg)),
        ),
        if (actionLabel.isNotEmpty && onAction != null) ...[
          SizedBox(width: Ds.space.x4),
          // 44x44 of tappable area around a deliberately small label.
          SizedBox(
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: () => onAction!(action),
              style: TextButton.styleFrom(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                foregroundColor: Ds.c.brand,
              ),
              child: Text(actionLabel, style: Ds.t.caption),
            ),
          ),
        ],
      ],
    );
  }
}

/// CMD #2039 — the cart while it is still being READ.
///
/// The summary row ("Total items / Advance to pay") arrives in the SAME
/// payload as the items, so the screen must already have a place for it when
/// that payload lands. This holds the shape — the row across the bottom of the
/// header block, then a few item rows — so the values drop straight in instead
/// of the whole page appearing at once after the round trip. It draws no words
/// at all: a skeleton that guessed at labels would be the app writing copy.
class C2039CartSkeleton extends StatelessWidget {
  const C2039CartSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2039_cart_skeleton', '1');
    return Shimmer(
      child: ListView(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x12, Ds.space.x12, Ds.space.x12, Ds.space.x24),
        children: [
          // The summary row's own shape: a label+value pair on each side.
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                flex: 3,
                child: SkeletonBox(height: Ds.space.x16, radius: Ds.r.chip),
              ),
              SizedBox(width: Ds.space.x24),
              Flexible(
                flex: 4,
                child: SkeletonBox(height: Ds.space.x16, radius: Ds.r.chip),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x24),
          for (var i = 0; i < 4; i++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(
                    width: Ds.space.x48,
                    height: Ds.space.x48,
                    radius: Ds.r.card),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(height: Ds.space.x12, radius: Ds.r.chip),
                      SizedBox(height: Ds.space.x8),
                      FractionallySizedBox(
                        widthFactor: 0.55,
                        alignment: Alignment.centerLeft,
                        child: SkeletonBox(
                            height: Ds.space.x12, radius: Ds.r.chip),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                SkeletonBox(
                    width: Ds.touch.minTarget * 2 + Ds.space.x24,
                    height: Ds.touch.minTarget,
                    radius: Ds.r.chip),
              ],
            ),
            SizedBox(height: Ds.space.x24),
          ],
        ],
      ),
    );
  }
}

/// CMD #2013 — the ONE summary row above Place order.
///
/// Left: "Total items" and the count. Right: "Advance to pay" and the amount.
/// The four lines that used to stack here — Sale price (PTR), MRP total,
/// Delivery FREE and "Rate confirmed after supplier quote." — said four things
/// about a basket whose one live question is what has to be paid now.
///
/// Both halves are `render.summary.bottom`, which resolves the advance from
/// the ladder (`advance_pct_for`) server-side. This widget counts nothing and
/// multiplies nothing; `has_advance` is the backend's answer to "is there an
/// advance?", so an amount it did not send is never invented.
class C2013SummaryRow extends StatelessWidget {
  final Map<String, dynamic> render;
  const C2013SummaryRow({super.key, required this.render});

  @override
  Widget build(BuildContext context) {
    final s = (render['summary'] as Map?)?.cast<String, dynamic>() ?? const {};
    final b = (s['bottom'] as Map?)?.cast<String, dynamic>() ?? const {};
    if (b['has'] != true) return const SizedBox.shrink();
    final itemsLabel = (b['items_label'] ?? '').toString();
    final itemsValue = (b['items_value'] ?? '').toString();
    final advanceLabel = (b['advance_label'] ?? '').toString();
    final advance = (b['advance_display'] ?? '').toString();
    final hasAdvance = b['has_advance'] == true && advance.isNotEmpty;
    if (itemsLabel.isEmpty && !hasAdvance) return const SizedBox.shrink();

    RenderLog.write('c2013_cart_summary',
        'items=$itemsValue;advance=${hasAdvance ? advance : ''}');

    // CMD #2090 — NO bottom padding here. This row's own 12px stacked on the
    // 12px the checkout bar puts above Place order, and the empty space the
    // KYC chip used to occupy sat between them: 24px of nothing under the
    // Advance line. The single gap above the button is the whole spacing now.
    return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        // spaceBetween, not a Spacer: a Spacer is a flex child and takes its
        // share of the free width in the same pass as the two halves, so the
        // labels lost the space it took. mainAxisAlignment spends the free
        // width AFTER the halves are sized, which keeps "Advance to pay" on
        // the right edge without ever taking a pixel the labels need.
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Both halves are Flexible and neither is a Spacer: a Spacer here
          // claimed the free width first and then squeezed "Advance to pay"
          // into an ellipsis at 360px while 65px sat unused beside it. The
          // amounts never shrink — only the two labels do, and the left one
          // goes first because it is the shorter sentence.
          Flexible(
            flex: 3,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    itemsLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.bodySecondary,
                  ),
                ),
                SizedBox(width: Ds.space.x4),
                Text(itemsValue, style: Ds.t.bodyStrong),
              ],
            ),
          ),
          if (hasAdvance) ...[
            SizedBox(width: Ds.space.x12),
            Flexible(
              flex: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Flexible(
                    child: Text(
                      advanceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: Ds.t.bodySecondary,
                    ),
                  ),
                  SizedBox(width: Ds.space.x4),
                  Text(advance,
                      style: Ds.t.bodyStrong.copyWith(color: Ds.c.brand)),
                ],
              ),
            ),
          ],
        ],
    );
  }
}
