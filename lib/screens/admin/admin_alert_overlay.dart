import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../services/live_feed.dart';
import 'package:pharma_b2b/services/date_labels.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../../design_tokens.dart';
import '../../services/order_alert_service.dart';
import 'alert_audio.dart';
import 'order_alert_sheet.dart';

// ── Column skip / label helpers (matches admin_customer_screen) ──────────────

const _kSkip = {'id', 'user_id', '_alertType'};

String _fmtLabel(String col) {
  // The display label for a known column is backend copy, keyed by the column
  // name. An unknown column has no backend label, so it keeps the derived
  // title-cased form rather than rendering blank.
  final label = c('admin_alert.field_$col');
  if (label.isNotEmpty) return label;
  return col.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

String _fmtVal(String col, dynamic v) {
  if (v == null) return '—';
  if (v is bool) return v ? c('admin_alert.value_yes') : c('admin_alert.value_no');
  final s = v.toString().trim();
  if (s.isEmpty || s == 'null') return '—';
  // CHANGE #548: the dd/MM/yyyy  HH:mm builder is DELETED. ist_fmt('dmy_hm2')
  // owns this layout; until the label lands we render the em dash placeholder
  // rather than a client-formatted stand-in.
  if (col.endsWith('_at') && s.length >= 10) {
    return DateLabels.instance.label(s, DateStyle.dmyHm2) ?? '—';
  }
  return s;
}


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

  const AdminAlertOverlay({
    super.key,
    required this.child,
    this.onOrderTap,
    this.onOrderStageTap,
  });

  @override
  State<AdminAlertOverlay> createState() => _AdminAlertOverlayState();
}

class _AdminAlertOverlayState extends State<AdminAlertOverlay>
    with TickerProviderStateMixin {
  final List<Map<String, dynamic>> _queue = [];
  bool _muted = false;

  // CMD #1989 — the popup. It is a bottom sheet now, and WHETHER it opens is
  // order_alert_strip().sheet_autoshow: #1988's "one interrupt per order" rule
  // is still the backend's to enforce, not a flag invented here. This set is
  // only a memory of what has already been shown, so a poll does not reopen a
  // sheet the admin just swiped away.
  final Set<String> _sheetShownFor = {};
  bool _sheetOpen = false;
  AnimationController? _sheetCtrl;
  bool _detailsOpen = false;
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
        switch (kind) {
          case 'new_registration':
            _enqueue(rec, id);
            break;
          case 'new_supplier':
            _enqueueSupplier(rec, id);
            break;
          case 'new_order':
            _enqueueOrder(rec, id);
            break;
          default:
            // mr_registration / company_registration / dp_registration —
            // the backend's own alert type, printed as it arrived.
            _enqueueGeneric(rec, id, kind);
        }
      }
    } catch (_) {
      // A failed poll shows nothing new; the next tick asks again.
    } finally {
      _alertInFlight = false;
    }
  }

  Future<void> _maybeFetchAndEnqueue(String id) async {
    if (_seenIds.contains(id)) return;
    try {
      final res = await Supabase.instance.client.rpc('admin_customer_alert_row', params: {'p_id': id});
      // #589 — `found` is explicit; an empty row object is not "no customer".
      final m = (res is List ? res.first : res) as Map;
      if (m['found'] == true) {
        _enqueue(Map<String, dynamic>.from(m['row'] as Map), id);
      }
    } catch (_) {}
  }

  void _enqueue(Map<String, dynamic> rec, String id) {
    if (id.isNotEmpty && _seenIds.contains(id)) return;
    if (id.isNotEmpty) _seenIds.add(id);
    final tagged = {...rec, '_alertType': 'registration'};
    if (mounted) {
      setState(() {
        _queue.add(tagged);
        _detailsOpen = false;
      });
      if (_queue.length == 1) _onFirstAlert();
    }
  }

  void _enqueueSupplier(Map<String, dynamic> rec, String id) {
    if (id.isNotEmpty && _seenIds.contains(id)) return;
    if (id.isNotEmpty) _seenIds.add(id);
    final tagged = {...rec, '_alertType': 'supplier_registration'};
    if (mounted) {
      setState(() { _queue.add(tagged); _detailsOpen = false; });
      if (_queue.length == 1) _onFirstAlert();
    }
  }

  void _enqueueGeneric(Map<String, dynamic> rec, String id, String alertType) {
    if (id.isNotEmpty && _seenIds.contains(id)) return;
    if (id.isNotEmpty) _seenIds.add(id);
    final tagged = {...rec, '_alertType': alertType};
    if (mounted) {
      setState(() { _queue.add(tagged); _detailsOpen = false; });
      if (_queue.length == 1) _onFirstAlert();
    }
  }

  // CMD #1988 — THE ORDER POPUP IS GONE.
  //
  // Om got a lock-screen alert AND a centre dialog for the same order, and the
  // dialog would not go silent. Two interrupts for one event is one too many,
  // so the full-screen alert is now the only interrupt and the app shows a
  // slim tappable strip instead. Nothing about that strip is decided here:
  // order_alert_strip() sends both sentences, the tone, the action word and
  // whether the sound rings at all.
  //
  // Accept and Reject are not on this surface either. They live on the order
  // screen, next to the items and the amount — a decision is never taken from
  // a notification or from a banner that only knows a total.
  void _enqueueOrder(Map<String, dynamic> rec, String id) {
    if (id.isNotEmpty && _orderSeenIds.contains(id)) return;
    if (id.isNotEmpty) _orderSeenIds.add(id);
    // The realtime insert is only a nudge to re-read; the strip is the answer.
    OrderAlertService.instance.refreshStrip();
  }

  /// The strip was tapped: the order is being opened, so the ring stops on
  /// EVERY device (the backend stamps the row), then the host opens it.
  Future<void> _openOrder(String orderId) async {
    if (orderId.isEmpty) return;
    orderAudioStop();
    await OrderAlertService.instance.seen(orderId, source: 'strip');
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
  void _syncStripAudio() {
    if (OrderAlertService.instance.stripRing) {
      orderAudioStart();
    } else {
      orderAudioStop();
    }
  }

  /// CMD #1989 — open the popup when the BACKEND says to.
  ///
  /// `sheet_autoshow` is the whole decision: it is false the moment somebody
  /// has opened the order anywhere, and false for an alert that is no longer
  /// ringing, so the sheet can never become the second interrupt #1988 removed.
  /// Once shown for an order it is not shown again — the strip stays behind it
  /// as the quiet reminder.
  void _maybeShowSheet() {
    final strip = OrderAlertService.instance.strip;
    if (strip == null || strip['sheet_autoshow'] != true) return;
    final orderId = (strip['sheet_order_id'] as String?) ?? '';
    if (orderId.isEmpty || _sheetOpen || _sheetShownFor.contains(orderId)) return;
    _sheetShownFor.add(orderId);
    // Out of the build phase: this is reached from an AnimatedBuilder.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openSheet(orderId));
  }

  Future<void> _openSheet(String orderId) async {
    if (!mounted || _sheetOpen) return;
    final payload = await OrderAlertService.instance.sheet(orderId);
    if (!mounted || payload == null || payload['show'] != true) return;
    _sheetOpen = true;
    _sheetCtrl?.dispose();
    final ctrl = orderAlertSheetController(this);
    _sheetCtrl = ctrl;
    try {
      await showOrderAlertSheet(
        context,
        sheet: payload,
        controller: ctrl,
        onOpen: () {
          Navigator.of(context).pop();
          _openOrder(orderId);
        },
      );
    } finally {
      _sheetOpen = false;
      ctrl.dispose();
      if (identical(_sheetCtrl, ctrl)) _sheetCtrl = null;
    }
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
      _detailsOpen = false;
      _busy = false;
    });
    if (_queue.isNotEmpty) {
      audioStart();
      _slideCtrl.forward(from: 0);
    }
  }

  String _tableForCurrentAlert() {
    if (_queue.isEmpty) return 'pharmacy_profiles';
    final type = _queue.first['_alertType'] as String? ?? 'registration';
    return type == 'supplier_registration' ? 'supplier_profiles' : 'pharmacy_profiles';
  }

  Future<void> _approve() async {
    if (_queue.isEmpty || _busy) return;
    setState(() => _busy = true);
    final rec   = _queue.first;
    final id    = rec['id'] as String? ?? '';
    final table = _tableForCurrentAlert();
    try {
      // CHANGE #603 — this write hid behind a VARIABLE table name, so it
      // survived the whole write sweep. It stamped approved_at from the DEVICE
      // clock, wrote approved_by as the literal string 'admin' rather than a
      // person, and had no admin check beyond RLS — on the approval flag that
      // my_session().can_place_order reads.
      await Supabase.instance.client.rpc(
        table == 'supplier_profiles' ? 'admin_supplier_action' : 'admin_customer_action',
        params: {
          table == 'supplier_profiles' ? 'p_supplier_id' : 'p_customer_id': id,
          'p_action': 'approve',
        },
      );
      // Fire-and-forget notification (existing logic)
      // CHANGE #508 D: this path handles BOTH customer (pharmacy_profiles) and
      // supplier (supplier_profiles) approvals via _tableForCurrentAlert() —
      // pass ptype so the backend gate checks the right audience's toggle
      // (customer_approved vs supplier_approved), not always 'customer'.
      Supabase.instance.client.functions.invoke('notify-registration', body: {
        'action': 'approve',
        'ptype': table == 'supplier_profiles' ? 'supplier' : 'customer',
        'pharmacyName': rec['pharmacy_name'],
        'email': rec['email'],
        'whatsappNo': rec['whatsapp_no'],
      }).then((_) {}).catchError((_) {});
    } catch (e) {
      if (mounted) {
        showToast(context, cf('admin_alert.toast_approve_failed', {'error': '$e'}), isError: true);
      }
    }
    _advance();
  }

  Future<void> _reject() async {
    if (_queue.isEmpty || _busy) return;
    setState(() => _busy = true);
    final rec   = _queue.first;
    final id    = rec['id'] as String? ?? '';
    final table = _tableForCurrentAlert();
    try {
      await Supabase.instance.client.rpc(
        table == 'supplier_profiles' ? 'admin_supplier_action' : 'admin_customer_action',
        params: {
          table == 'supplier_profiles' ? 'p_supplier_id' : 'p_customer_id': id,
          'p_action': 'reject',
        },
      );
      Supabase.instance.client.functions.invoke('notify-registration', body: {
        'action': 'reject',
        'ptype': table == 'supplier_profiles' ? 'supplier' : 'customer',
        'pharmacyName': rec['pharmacy_name'],
        'email': rec['email'],
        'whatsappNo': rec['whatsapp_no'],
      }).then((_) {}).catchError((_) {});
    } catch (e) {
      if (mounted) {
        showToast(context, cf('admin_alert.toast_reject_failed', {'error': '$e'}), isError: true);
      }
    }
    _advance();
  }

  void _dismiss() => _advance();

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
    _sheetCtrl?.dispose();
    _sheetCtrl = null;
    _flashCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      // CMD #1988 — the strip sits ABOVE the shell, never over it: it pushes
      // nothing off screen, steals no tap, and is the only in-app trace of an
      // unactioned order.
      Column(children: [
        AnimatedBuilder(
          animation: OrderAlertService.instance,
          builder: (context, _) {
            _syncStripAudio();
            _maybeShowSheet();
            final strip = OrderAlertService.instance.strip;
            if (strip == null || strip['show'] != true) {
              return const SizedBox.shrink();
            }
            return OrderAlertStrip(
              strip: strip,
              onOpen: () => _openOrder((strip['order_id'] as String?) ?? ''),
            );
          },
        ),
        Expanded(child: widget.child),
      ]),
      if (_queue.isNotEmpty) _buildOverlay(_queue.first),
    ]);
  }

  Widget _buildOverlay(Map<String, dynamic> rec) {
    return Positioned.fill(
      child: SlideTransition(
        position: _slideAnim,
        child: Material(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _buildCard(rec),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(Map<String, dynamic> rec) {
    final type = rec['_alertType'] as String? ?? 'registration';
    if (type == 'supplier_registration') return _buildSupplierRegCard(rec);
    if (type == 'mr_registration') return _buildSimpleRegCard(rec, title: c('admin_alert.banner_new_mr'), color: const Color(0xFF7C3AED), nameKey: 'full_name', subtitleKey: 'company_represented');
    if (type == 'company_registration') return _buildSimpleRegCard(rec, title: c('admin_alert.banner_new_company'), color: const Color(0xFF0369A1), nameKey: 'company_name', subtitleKey: 'contact_person');
    if (type == 'dp_registration') return _buildSimpleRegCard(rec, title: c('admin_alert.banner_new_delivery_partner'), color: const Color(0xFFB45309), nameKey: 'full_name', subtitleKey: 'vehicle_type');
    return _buildRegistrationCard(rec);
  }

  Widget _buildRegistrationCard(Map<String, dynamic> rec) {
    final pharmacyName = rec['pharmacy_name'] as String? ?? '';
    final ownerName    = rec['customer_name'] as String? ?? rec['owner_name'] as String? ?? '';
    final phone        = rec['whatsapp_no']   as String? ?? rec['phone'] as String? ?? '';
    final storeType    = rec['store_type']    as String? ?? '';
    final city         = rec['city']          as String? ?? '';
    final state        = rec['state']         as String? ?? '';

    final queueLen = _queue.length;
    final location = [city, state].where((s) => s.isNotEmpty).join(', ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(
          color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // ── Flashing banner ──────────────────────────────────────────────
        FadeTransition(
          opacity: _flashAnim,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF1B7A43),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16), topRight: Radius.circular(16)),
            ),
            child: Row(children: [
              const Icon(Icons.person_add_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  queueLen > 1
                      ? cf('admin_alert.banner_new_registration_queued',
                          {'count': '$queueLen'})
                      : c('admin_alert.banner_new_registration'),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800,
                      color: Colors.white, letterSpacing: 0.5),
                ),
              ),
              // Mute toggle
              InkWell(
                onTap: _toggleMute,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    _muted ? Icons.volume_off : Icons.volume_up,
                    color: Colors.white.withValues(alpha: _muted ? 0.5 : 1.0),
                    size: 18,
                  ),
                ),
              ),
            ]),
          ),
        ),

        // ── Key fields ───────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (pharmacyName.isNotEmpty)
              Text(pharmacyName,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800,
                      color: Color(0xFF111827))),
            if (ownerName.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(ownerName,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              if (phone.isNotEmpty)     _chip(Icons.phone_outlined,         phone),
              if (storeType.isNotEmpty) _chip(Icons.storefront_outlined,    storeType),
              if (location.isNotEmpty)  _chip(Icons.location_on_outlined,   location),
            ]),
          ]),
        ),

        // ── Details expander ─────────────────────────────────────────────
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _detailsOpen = !_detailsOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              Text(c('admin_alert.view_full_details'),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF1B7A43),
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _detailsOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more,
                    size: 16, color: Color(0xFF1B7A43)),
              ),
            ]),
          ),
        ),
        if (_detailsOpen) _buildDetails(rec),

        const Divider(height: 1, color: Color(0xFFE5E7EB)),

        // ── Action buttons ───────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: _busy
              ? const Center(child: SizedBox(width: 24, height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2,
                      color: Color(0xFF1B5E20))))
              : Row(children: [
                  // Dismiss (only if multiple queued)
                  if (queueLen > 1) ...[
                    OutlinedButton(
                      onPressed: _dismiss,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF6B7280),
                        side: const BorderSide(color: Color(0xFFD1D5DB)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                      ),
                      child: Text(c('admin_alert.btn_skip'),
                          style: const TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _reject,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDC2626),
                        side: const BorderSide(color: Color(0xFFDC2626)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(c('admin_alert.btn_reject'),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _approve,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF16A34A),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: Text(c('admin_alert.btn_approve'),
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ]),
        ),
      ]),
    );
  }

  Widget _buildSupplierRegCard(Map<String, dynamic> rec) {
    final supplierName = rec['supplier_name'] as String? ?? '';
    final contactName  = rec['contact_name']  as String? ?? '';
    final phone        = rec['whatsapp_no']   as String? ?? rec['phone'] as String? ?? '';
    final city         = rec['city']          as String? ?? '';
    final state        = rec['state']         as String? ?? '';
    final queueLen     = _queue.length;
    final location     = [city, state].where((s) => s.isNotEmpty).join(', ');

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: _flashAnim,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFF0284C7),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16)),
            ),
            child: Row(children: [
              const Icon(Icons.add_business_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(
                queueLen > 1
                    ? cf('admin_alert.banner_new_supplier_queued',
                        {'count': '$queueLen'})
                    : c('admin_alert.banner_new_supplier'),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5),
              )),
              InkWell(
                onTap: _toggleMute,
                borderRadius: BorderRadius.circular(20),
                child: Padding(padding: const EdgeInsets.all(4),
                  child: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                      color: Colors.white.withValues(alpha: _muted ? 0.5 : 1.0), size: 18)),
              ),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (supplierName.isNotEmpty)
              Text(supplierName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
            if (contactName.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(contactName, style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              if (phone.isNotEmpty)    _chip(Icons.phone_outlined,       phone),
              if (location.isNotEmpty) _chip(Icons.location_on_outlined, location),
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _detailsOpen = !_detailsOpen),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              Text(c('admin_alert.view_full_details'), style: const TextStyle(fontSize: 12, color: Color(0xFF0284C7), fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _detailsOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more, size: 16, color: Color(0xFF0284C7)),
              ),
            ]),
          ),
        ),
        if (_detailsOpen) _buildDetails(rec),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: _busy
              ? const Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B5E20))))
              : Row(children: [
                  if (queueLen > 1) ...[
                    OutlinedButton(
                      onPressed: _dismiss,
                      style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF6B7280), side: const BorderSide(color: Color(0xFFD1D5DB)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                      child: Text(c('admin_alert.btn_skip'),
                          style: const TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFDC2626), side: const BorderSide(color: Color(0xFFDC2626)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: Text(c('admin_alert.btn_reject'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: FilledButton(
                    onPressed: _approve,
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0284C7), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: Text(c('admin_alert.btn_approve'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                ]),
        ),
      ]),
    );
  }

  Widget _buildDetails(Map<String, dynamic> rec) {
    final entries = rec.entries.where((e) => !_kSkip.contains(e.key)).toList();
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      color: const Color(0xFFF9FAFB),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
        child: LayoutBuilder(builder: (ctx, constraints) {
          final cols = constraints.maxWidth > 400 ? 2 : 1;
          final itemW = (constraints.maxWidth - (cols - 1) * 16.0) / cols;
          return Wrap(spacing: 16, runSpacing: 10,
            children: entries.map((e) => SizedBox(
              width: itemW,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(_fmtLabel(e.key),
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                        color: Color(0xFF9CA3AF), letterSpacing: 0.4)),
                const SizedBox(height: 2),
                Text(_fmtVal(e.key, e.value),
                    style: TextStyle(
                      fontSize: 12,
                      color: _fmtVal(e.key, e.value) == '—'
                          ? const Color(0xFFD1D5DB)
                          : const Color(0xFF374151),
                    )),
              ]),
            )).toList(),
          );
        }),
      ),
    );
  }

  Widget _buildSimpleRegCard(Map<String, dynamic> rec, {
    required String title,
    required Color color,
    required String nameKey,
    required String subtitleKey,
  }) {
    final name     = rec[nameKey]     as String? ?? '';
    final subtitle = rec[subtitleKey] as String? ?? '';
    final phone    = rec['phone']     as String? ?? '';
    final city     = rec['city']      as String? ?? '';
    final state    = rec['state']     as String? ?? '';
    final location = [city, state].where((s) => s.isNotEmpty).join(', ');
    final queueLen = _queue.length;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      decoration: BoxDecoration(
        color: Colors.white, borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: _flashAnim,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), topRight: Radius.circular(16))),
            child: Row(children: [
              const Icon(Icons.person_add_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(
                queueLen > 1
                    ? cf('admin_alert.banner_queued',
                        {'title': title, 'count': '$queueLen'})
                    : title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.5),
              )),
              InkWell(onTap: _toggleMute, borderRadius: BorderRadius.circular(20), child: Padding(padding: const EdgeInsets.all(4),
                child: Icon(_muted ? Icons.volume_off : Icons.volume_up, color: Colors.white.withValues(alpha: _muted ? 0.5 : 1.0), size: 18))),
            ]),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (name.isNotEmpty) Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
            if (subtitle.isNotEmpty) ...[const SizedBox(height: 3), Text(subtitle, style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)))],
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              if (phone.isNotEmpty)    _chip(Icons.phone_outlined,       phone),
              if (location.isNotEmpty) _chip(Icons.location_on_outlined, location),
            ]),
          ]),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _detailsOpen = !_detailsOpen),
          child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              Text(c('admin_alert.view_full_details'), style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              AnimatedRotation(turns: _detailsOpen ? 0.5 : 0.0, duration: const Duration(milliseconds: 180),
                child: Icon(Icons.expand_more, size: 16, color: color)),
            ])),
        ),
        if (_detailsOpen) _buildDetails(rec),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(children: [
            if (queueLen > 1) ...[
              OutlinedButton(onPressed: _dismiss,
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF6B7280), side: const BorderSide(color: Color(0xFFD1D5DB)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                child: Text(c('admin_alert.btn_skip'),
                    style: const TextStyle(fontSize: 12))),
              const SizedBox(width: 8),
            ],
            Expanded(child: OutlinedButton(onPressed: _dismiss,
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF6B7280), side: const BorderSide(color: Color(0xFFD1D5DB)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
              child: Text(c('admin_alert.btn_dismiss'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))),
          ]),
        ),
      ]),
    );
  }

  static Widget _chip(IconData icon, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 13, color: const Color(0xFF6B7280)),
      const SizedBox(width: 4),
      Text(label, style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
    ],
  );
}

/// CMD #1988 — the ONE in-app surface an unactioned order gets.
///
/// A slim strip, not a dialog: it interrupts nothing, it can be ignored, and
/// the lock-screen alert stays the only thing that takes over the phone. It
/// computes nothing — the title, the subtitle, the badge, the action word and
/// the tone all arrive from order_alert_strip(). Tapping it opens the order,
/// which is where Accept and Reject live.
class OrderAlertStrip extends StatelessWidget {
  final Map<String, dynamic> strip;
  final VoidCallback onOpen;

  const OrderAlertStrip({super.key, required this.strip, required this.onOpen});

  Color _tone(String tone) {
    switch (tone) {
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.warningSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tone = (strip['tone'] as String?) ?? 'warning';
    final title = (strip['title'] as String?) ?? '';
    final subtitle = (strip['subtitle'] as String?) ?? '';
    final action = (strip['action_label'] as String?) ?? '';
    final risk = (strip['risk_label'] as String?) ?? '';
    final more = (strip['more_label'] as String?) ?? '';
    final accent = _tone(tone);

    return Material(
      color: _toneSoft(tone),
      child: SafeArea(
        bottom: false,
        child: InkWell(
          onTap: onOpen,
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.space.x48),
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x8),
            decoration: BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: accent, width: Ds.space.x4 / 2)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: Ds.space.x8,
                  height: Ds.space.x8,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(children: [
                        Flexible(
                          child: Text(title,
                              style: Ds.t.bodyStrong,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (risk.isNotEmpty) ...[
                          SizedBox(width: Ds.space.x8),
                          Flexible(
                              child: Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: Ds.space.x8,
                                vertical: Ds.space.x4 / 2),
                            decoration: BoxDecoration(
                                color: Ds.c.surface,
                                borderRadius: Ds.r.rChip),
                            child: Text(risk,
                                style: Ds.t.caption,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          )),
                        ],
                      ]),
                      SizedBox(height: Ds.space.x4),
                      Text(subtitle,
                          style: Ds.t.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      if (more.isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(more, style: Ds.t.caption, maxLines: 1),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                // The action word is the backend's and can be any length, so
                // it shrinks rather than pushing the strip off a 320px phone.
                Flexible(
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: Ds.space.x48 - Ds.space.x4),
                    child: TextButton(
                      onPressed: onOpen,
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        padding:
                            EdgeInsets.symmetric(horizontal: Ds.space.x8),
                        shape:
                            RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      ),
                      child: Text(action,
                          style: Ds.t.bodyStrong.copyWith(color: accent),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
