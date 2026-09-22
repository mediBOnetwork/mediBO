import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/live_feed.dart';
import 'package:pharma_b2b/services/ui_copy.dart';

import '../../services/order_alert_service.dart';
import 'package:pharma_b2b/design_tokens.dart';

import 'admin_alert_card.dart';
import 'alert_audio.dart';
import 'order_alert_popup.dart';

// ── Overlay widget ────────────────────────────────────────────────────────────

class AdminAlertOverlay extends StatefulWidget {
  final Widget child;
  final VoidCallback? onOrderTap;

  /// CHANGE #537 — the order's OWN id, handed to the host so it can ask the
  /// backend which pipeline stage that order is actually at
  /// (fulfill_order_stage) and open Fulfill on that tab, instead of dropping
  /// the admin on a list to go and find it. Preferred over [onOrderTap] when
  /// both are supplied and the alert carries an id.
  final ValueChanged<String>? onOrderStageTap;

  /// CMD #2154 — View on a sign-up alert opens the backend's `view.route`,
  /// with `view.params.id` as the subject (the shell's own route door).
  final void Function(String route, String? seed)? onViewRoute;

  const AdminAlertOverlay({
    super.key,
    required this.child,
    this.onOrderTap,
    this.onOrderStageTap,
    this.onViewRoute,
  });

  @override
  State<AdminAlertOverlay> createState() => _AdminAlertOverlayState();
}

class _AdminAlertOverlayState extends State<AdminAlertOverlay>
    with TickerProviderStateMixin {
  final List<Map<String, dynamic>> _queue = [];
  bool _muted = false;

  // CMD #2016 — the popup, and it is the ONLY in-app surface a new order gets.
  // WHETHER it opens is order_alert_popup().autoshow: #1988's "one interrupt
  // per order" rule is still the backend's to enforce, not a flag invented
  // here, and "Later" is a dismissal the SERVER holds per device — so nothing
  // in this class remembers what has been put aside.
  bool _popupOpen = false;
  String _popupOrderId = '';
  bool _busy = false;

  // CHANGE #643: six unfiltered postgres_changes channels (pharmacy_profiles,
  // supplier_profiles, orders, mr_registrations, company_profiles,
  // delivery_partner_registrations) replaced by ONE backend read. Three of
  // those tables were never in the publication, so three of the six had been
  // delivering nothing since the day they were written; the other three fanned
  // every INSERT on the busiest tables in the product to every admin session.
  LiveFeedHandle? _alertWatch;
  String? _alertCursor;
  bool _alertInFlight = false;
  late final AnimationController _flashCtrl;
  late final Animation<double> _flashAnim;
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;

  final Set<String> _seenIds = {};
  final Set<String> _orderSeenIds = {};

  @override
  void initState() {
    super.initState();
    _flashCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
    _flashAnim = Tween(begin: 0.3, end: 1.0).animate(_flashCtrl);

    _slideCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 320));
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -0.06), end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    _startAlertFeed();

    // Listen for messages from the FCM service worker (dedup: SW posts when
    // app is focused so we don't also get the OS notification)
    registerAlertHandler((dartObj) {
      if (dartObj is Map) {
        final type = dartObj['type']?.toString();
        final id   = dartObj['regId']?.toString();
        if (type == 'new_registration' && id != null) {
          _maybeFetchAndEnqueue(id);
        }
      }
    });
  }

  /// CHANGE #643 — one read: "what has arrived since I last asked?".
  ///
  /// admin_alert_new_since() decides which rows are alert-worthy (a pending
  /// registration, a pending order) and hands them back already typed by
  /// `kind`. This method routes each one to the same enqueue it always used —
  /// nothing about which alerts appear, or in what order, is decided here.
  ///
  /// The cadence is the registry's: LiveFeed watches the tables this feed is
  /// built from, so if any of them is ever put back on a live channel the
  /// overlay picks that up with no code change.
  void _startAlertFeed() {
    _pollAlerts();
    LiveFeed.instance
        .watch(
          channelPrefix: 'admin_alert_overlay',
          tables: const [
            'pharmacy_profiles',
            'supplier_profiles',
            'orders',
            'mr_registrations',
            'company_profiles',
            'delivery_partner_registrations',
          ],
          onChange: (_) => _pollAlerts(),
        )
        .then((h) {
      if (!mounted) {
        h.dispose();
        return;
      }
      _alertWatch?.dispose();
      _alertWatch = h;
    });
  }

  Future<void> _pollAlerts() async {
    if (_alertInFlight || !mounted) return;
    _alertInFlight = true;
    try {
      final raw = await Supabase.instance.client.rpc(
        'admin_alert_new_since',
        params: {'p_since': _alertCursor},
      );
      final m = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (m is! Map || m['ok'] != true || !mounted) return;
      _alertCursor = m['server_time']?.toString() ?? _alertCursor;
      for (final e in (m['rows'] as List? ?? const [])) {
        if (e is! Map) continue;
        final kind = e['kind']?.toString() ?? '';
        final id = e['id']?.toString() ?? '';
        final row = e['row'];
        if (id.isEmpty || row is! Map) continue;
        final rec = Map<String, dynamic>.from(row);
        if (kind == 'new_order') {
          _enqueueOrder(rec, id);
          continue;
        }
        // Every sign-up kind — pharmacy, supplier, MR, company, delivery
        // partner — is ONE card now (CMD #2154), drawn from the row's own
        // `card` and `view`.
        _enqueueAlert(kind, id, e['card'], e['view']);
      }
    } catch (_) {
      // A failed poll shows nothing new; the next tick asks again.
    } finally {
      _alertInFlight = false;
    }
  }

  // The service worker's "new registration" nudge: the backend read is the
  // answer, so it simply asks again (the row arrives with its card and view).
  void _maybeFetchAndEnqueue(String id) {
    if (_seenIds.contains(id)) return;
    _pollAlerts();
  }

  void _enqueueAlert(String kind, String id, dynamic card, dynamic view) {
    if (id.isEmpty || _seenIds.contains(id)) return;
    _seenIds.add(id);
    final tagged = <String, dynamic>{
      '_kind': kind,
      '_id': id,
      '_card': card is Map ? Map<String, dynamic>.from(card) : const {},
      '_view': view is Map ? Map<String, dynamic>.from(view) : const {},
    };
    if (!mounted) return;
    setState(() => _queue.add(tagged));
    if (_queue.length == 1) _onFirstAlert();
  }

  // CMD #2016 — A NEW ORDER NEVER ENTERS THIS QUEUE.
  //
  // The registration queue below is the flashing centre card for a new SIGN-UP.
  // An order takes a different road: the app in the background gets a system
  // notification, and the app in the foreground gets the centre popup that
  // _syncPopup() opens. Nothing about that popup is decided here —
  // order_alert_popup() sends every sentence, the pill's tone, both button
  // words and whether the sound rings at all.
  //
  // Accept and Reject are not on this surface either. They live on the order
  // screen, next to the items and the amount — a decision is never taken from
  // a notification or from a popup that only knows a total.
  void _enqueueOrder(Map<String, dynamic> rec, String id) {
    if (id.isNotEmpty && _orderSeenIds.contains(id)) return;
    if (id.isNotEmpty) _orderSeenIds.add(id);
    // The realtime insert is only a nudge to re-read; the popup is the answer.
    OrderAlertService.instance.refreshPopup();
  }

  /// The popup's Open button was tapped: the order is being opened, so the
  /// ring stops on EVERY device (the backend stamps the row), then the host
  /// opens it.
  Future<void> _openOrder(String orderId) async {
    if (orderId.isEmpty) return;
    orderAudioStop();
    await OrderAlertService.instance.seen(orderId, source: 'popup');
    if (!mounted) return;
    if (widget.onOrderStageTap != null) {
      widget.onOrderStageTap!(orderId);
    } else {
      widget.onOrderTap?.call();
    }
  }

  /// The web sound follows the backend's `ring` flag and nothing else — which
  /// is how quiet hours, a snoozed device and "somebody already opened it"
  /// all reach the speaker without a single client-side rule.
  void _syncPopupAudio() {
    if (OrderAlertService.instance.popupRing) {
      orderAudioStart();
    } else {
      orderAudioStop();
    }
  }

  /// CMD #2016 — open the centre popup when the BACKEND says to, and close it
  /// when the backend stops saying so.
  ///
  /// `autoshow` is the whole decision: it is false the moment somebody has
  /// opened the order anywhere, false for an alert that is no longer ringing,
  /// and the payload itself is absent (show:false) for an alert THIS device has
  /// put aside with Later. So spec item 4 needs no client rule — a popup on
  /// screen with no live alert behind it closes itself on the next read.
  void _syncPopup() {
    final svc = OrderAlertService.instance;
    final live = svc.popupShow && svc.popup?['autoshow'] == true;
    final orderId = svc.popupOrderId;

    if (_popupOpen && (!live || orderId != _popupOrderId)) {
      // The server alert this popup was drawn for is gone (opened elsewhere,
      // actioned, expired) — take the popup off the screen.
      _popupOpen = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop(OrderAlertPopupResult.gone);
        }
      });
      return;
    }
    if (!live || _popupOpen) return;
    _popupOpen = true;
    _popupOrderId = orderId;
    // Out of the build phase: this is reached from an AnimatedBuilder.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openPopup());
  }

  Future<void> _openPopup() async {
    final svc = OrderAlertService.instance;
    final payload = svc.popup;
    if (!mounted || payload == null || payload['show'] != true) {
      _popupOpen = false;
      return;
    }
    final orderId = (payload['order_id'] as String?) ?? '';
    OrderAlertPopupResult? result;
    try {
      result = await showOrderAlertPopup(context, popup: payload);
    } finally {
      _popupOpen = false;
      _popupOrderId = '';
    }
    if (!mounted) return;
    if (result == OrderAlertPopupResult.open) {
      await _openOrder(orderId);
      return;
    }
    if (result == OrderAlertPopupResult.gone) return;
    // Later — and a tap outside is Later too. The dismissal is the server's to
    // hold, per device: the order stays in Awaiting action and the nav badge
    // still counts it.
    await svc.popupLater(orderId);
  }

  void _onFirstAlert() {
    // Orders never enter this queue any more (CMD #1988) — registrations and
    // supplier registrations share the same alert sound.
    audioStart();
    _slideCtrl.forward(from: 0);
  }

  void _advance() {
    audioStop();
    setState(() {
      _queue.removeAt(0);
      _busy = false;
    });
    if (_queue.isNotEmpty) {
      audioStart();
      _slideCtrl.forward(from: 0);
    }
  }

  /// CMD #2154 — the popup's ONE button.
  ///
  /// The ring stops on the tap itself (before any network), the alert is
  /// stamped seen on the server so it never rings again for that item — on
  /// any admin device, reload included — the popup closes, and the item's own
  /// action screen opens. WHERE is the backend's `view` {route, params}; the
  /// view the RPC hands back wins over the one the row arrived with.
  Future<void> _view() async {
    if (_queue.isEmpty || _busy) return;
    audioStop();
    final rec = _queue.first;
    final kind = rec['_kind'] as String? ?? '';
    final id = rec['_id'] as String? ?? '';
    var view = Map<String, dynamic>.from(rec['_view'] as Map? ?? const {});
    setState(() => _busy = true);
    try {
      final raw = await Supabase.instance.client.rpc(
        'admin_alert_view',
        params: {'p_kind': kind, 'p_id': id},
      );
      final m = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
      if (m is Map && m['ok'] == true && m['view'] is Map) {
        view = Map<String, dynamic>.from(m['view'] as Map);
      }
    } catch (_) {
      // The row's own view still opens the right screen; the next poll will
      // not re-ring it on this device either (_seenIds).
    }
    if (!mounted) return;
    _advance();
    final route = view['route'] as String? ?? '';
    final params = view['params'];
    final seed = params is Map ? params['id']?.toString() : null;
    if (route.isNotEmpty) widget.onViewRoute?.call(route, seed);
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    audioMute(_muted);
    orderAudioMute(_muted);
  }

  @override
  void dispose() {
    _alertWatch?.dispose();
    audioStop();
    orderAudioStop();
    _flashCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // CMD #2016 — there is NO in-app strip any more, on any screen. The shell
      // is the whole tree; a new order reaches an open app as the centre popup
      // this listener opens, and reaches a closed one as a notification.
      widget.child,
      AnimatedBuilder(
        animation: OrderAlertService.instance,
        builder: (context, _) {
          _syncPopupAudio();
          _syncPopup();
          return const SizedBox.shrink();
        },
      ),
      if (_queue.isNotEmpty) _buildOverlay(_queue.first),
    ]);
  }

  Widget _buildOverlay(Map<String, dynamic> rec) {
    return Positioned.fill(
      child: SlideTransition(
        position: _slideAnim,
        child: Material(
          color: Ds.c.text.withValues(alpha: 0.45),
          child: Center(
            child: ConstrainedBox(
              // Fills a phone; stops growing on a desktop (a token multiple).
              constraints: BoxConstraints(maxWidth: Ds.space.x48 * 10),
              child: _buildCard(rec),
            ),
          ),
        ),
      ),
    );
  }


  Widget _buildCard(Map<String, dynamic> rec) {
    final card = Map<String, dynamic>.from(rec['_card'] as Map? ?? const {});
    final title = (card['title'] as String?) ?? '';
    final heading = _queue.length > 1
        ? cf('admin_alert.banner_queued',
            {'title': title, 'count': '${_queue.length}'})
        : title;
    return AdminAlertCard(
      heading: heading,
      card: card,
      view: Map<String, dynamic>.from(rec['_view'] as Map? ?? const {}),
      muted: _muted,
      flash: _flashAnim,
      onView: _view,
      onMute: _toggleMute,
    );
  }
}
