// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── External JS function declarations (web only) ─────────────────────────────

@JS('adminAlertStart')
external void _jsStart();

@JS('adminAlertStop')
external void _jsStop();

@JS('adminAlertMute')
external void _jsMute(bool muted);

@JS('adminAlertRegisterMessageHandler')
external void _jsRegisterHandler(JSFunction callback);

@JS('adminOrderAlertStart')
external void _jsOrderStart();

@JS('adminOrderAlertStop')
external void _jsOrderStop();

@JS('adminOrderAlertMute')
external void _jsOrderMuteJs(bool muted);

void _jsAudioStart() {
  if (!kIsWeb) return;
  try { _jsStart(); } catch (_) {}
}

void _jsAudioStop() {
  if (!kIsWeb) return;
  try { _jsStop(); } catch (_) {}
}

void _jsAudioMute(bool muted) {
  if (!kIsWeb) return;
  try { _jsMute(muted); } catch (_) {}
}

void _jsOrderAudioStart() {
  if (!kIsWeb) return;
  try { _jsOrderStart(); } catch (_) {}
}

void _jsOrderAudioStop() {
  if (!kIsWeb) return;
  try { _jsOrderStop(); } catch (_) {}
}

void _jsOrderAudioMute(bool muted) {
  if (!kIsWeb) return;
  try { _jsOrderMuteJs(muted); } catch (_) {}
}

// ── Column skip / label helpers (matches admin_customer_screen) ──────────────

const _kSkip = {'id', 'user_id', '_alertType'};

String _fmtLabel(String col) {
  const ov = {
    'whatsapp_no': 'WhatsApp No.',        'other_contact_no': 'Other Contact',
    'dl_20b': 'Drug Licence 20B',         'dl_21b': 'Drug Licence 21B',
    'gst_no': 'GST No.',                  'gstin': 'GSTIN',
    'store_location_link': 'Store Location','range_zone': 'Range / Zone',
    'address_local': 'Local Address',     'customer_code': 'Customer Code',
    'payment_term': 'Payment Term',       'store_type': 'Store Type',
    'pharmacy_name': 'Pharmacy Name',     'customer_name': 'Customer Name',
    'owner_name': 'Owner Name',           'created_at': 'Registered',
    'approved_at': 'Approved At',         'approved_by': 'Approved By',
    'payment_id': 'Order No.',            'total_amount': 'Total Amount',
  };
  if (ov.containsKey(col)) return ov[col]!;
  return col.split('_').map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}').join(' ');
}

String _fmtVal(String col, dynamic v) {
  if (v == null) return '—';
  if (v is bool) return v ? 'Yes' : 'No';
  final s = v.toString().trim();
  if (s.isEmpty || s == 'null') return '—';
  if (col.endsWith('_at') && s.length >= 10) {
    try {
      final dt = DateTime.parse(s).toLocal();
      return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}  '
             '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) {}
  }
  return s;
}

// Rounds to nearest rupee with Indian-style thousands separators.
String _fmtRupee(dynamic v) {
  if (v == null) return '₹0';
  double amount;
  try {
    amount = (v is num) ? v.toDouble() : double.parse(v.toString().trim());
  } catch (_) { return '₹0'; }
  final rounded = amount.round();
  if (rounded == 0) return '₹0';
  final abs = rounded.abs().toString();
  final buf = StringBuffer();
  for (int i = 0; i < abs.length; i++) {
    if (i > 0 && (abs.length - i) % 3 == 0) buf.write(',');
    buf.write(abs[i]);
  }
  return rounded < 0 ? '₹-$buf' : '₹$buf';
}

// ── Overlay widget ────────────────────────────────────────────────────────────

class AdminAlertOverlay extends StatefulWidget {
  final Widget child;
  final VoidCallback? onOrderTap;
  const AdminAlertOverlay({super.key, required this.child, this.onOrderTap});

  @override
  State<AdminAlertOverlay> createState() => _AdminAlertOverlayState();
}

class _AdminAlertOverlayState extends State<AdminAlertOverlay>
    with TickerProviderStateMixin {
  final List<Map<String, dynamic>> _queue = [];
  bool _muted = false;
  bool _detailsOpen = false;
  bool _busy = false;

  RealtimeChannel? _channel;
  RealtimeChannel? _orderChannel;
  RealtimeChannel? _supplierChannel;
  RealtimeChannel? _mrChannel;
  RealtimeChannel? _companyChannel;
  RealtimeChannel? _dpChannel;
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

    _subscribeRealtime();
    _subscribeOrders();
    _subscribeSuppliers();
    _subscribeMr();
    _subscribeCompanies();
    _subscribeDeliveryPartners();

    // Listen for messages from the FCM service worker (dedup: SW posts when
    // app is focused so we don't also get the OS notification)
    if (kIsWeb) {
      try {
        _jsRegisterHandler(((JSAny? rawMsg) {
          if (rawMsg == null) return;
          try {
            final dartObj = rawMsg.dartify();
            if (dartObj is Map) {
              final type = dartObj['type']?.toString();
              final id   = dartObj['regId']?.toString();
              if (type == 'new_registration' && id != null) {
                _maybeFetchAndEnqueue(id);
              }
            }
          } catch (_) {}
        }).toJS);
      } catch (_) {}
    }
  }

  void _subscribeRealtime() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _channel = Supabase.instance.client
        .channel('admin_new_reg_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'pharmacy_profiles',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            final approved = rec['approved'] as bool? ?? false;
            final status   = rec['status']   as String? ?? '';
            final id       = rec['id']       as String? ?? '';
            if (!approved && (status == 'pending' || status.isEmpty)) {
              _enqueue(rec, id);
            }
          },
        )
        .subscribe();
  }

  void _subscribeSuppliers() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _supplierChannel = Supabase.instance.client
        .channel('admin_new_sup_reg_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'supplier_profiles',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            final approved = rec['approved'] as bool? ?? false;
            final status   = rec['status']   as String? ?? '';
            final id       = rec['id']       as String? ?? '';
            if (!approved && (status == 'pending' || status.isEmpty)) {
              _enqueueSupplier(rec, id);
            }
          },
        )
        .subscribe();
  }

  void _subscribeMr() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _mrChannel = Supabase.instance.client
        .channel('admin_new_mr_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'mr_registrations',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            _enqueueGeneric(rec, rec['id'] as String? ?? '', 'mr_registration');
          },
        )
        .subscribe();
  }

  void _subscribeCompanies() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _companyChannel = Supabase.instance.client
        .channel('admin_new_co_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'company_registrations',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            _enqueueGeneric(rec, rec['id'] as String? ?? '', 'company_registration');
          },
        )
        .subscribe();
  }

  void _subscribeDeliveryPartners() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _dpChannel = Supabase.instance.client
        .channel('admin_new_dp_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'delivery_partner_registrations',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            _enqueueGeneric(rec, rec['id'] as String? ?? '', 'dp_registration');
          },
        )
        .subscribe();
  }

  void _subscribeOrders() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    _orderChannel = Supabase.instance.client
        .channel('admin_new_order_$ts')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (payload) {
            final rec = Map<String, dynamic>.from(payload.newRecord);
            if (rec.isEmpty) return;
            final status = rec['status'] as String? ?? '';
            final id     = rec['id']     as String? ?? '';
            if (status == 'pending' || status.isEmpty) {
              _enqueueOrder(rec, id);
            }
          },
        )
        .subscribe();
  }

  Future<void> _maybeFetchAndEnqueue(String id) async {
    if (_seenIds.contains(id)) return;
    try {
      final res = await Supabase.instance.client
          .from('pharmacy_profiles').select().eq('id', id).maybeSingle();
      if (res != null) {
        final rec = Map<String, dynamic>.from(res as Map);
        _enqueue(rec, id);
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

  void _enqueueOrder(Map<String, dynamic> rec, String id) {
    if (id.isNotEmpty && _orderSeenIds.contains(id)) return;
    if (id.isNotEmpty) _orderSeenIds.add(id);
    final tagged = {...rec, '_alertType': 'order'};
    if (mounted) {
      setState(() {
        _queue.add(tagged);
        _detailsOpen = false;
      });
      if (_queue.length == 1) _onFirstAlert();
    }
  }

  void _onFirstAlert() {
    final type = _queue.first['_alertType'] as String? ?? 'registration';
    if (type == 'order') {
      _jsOrderAudioStart();
    } else {
      _jsAudioStart(); // registration and supplier_registration share the same alert sound
    }
    _slideCtrl.forward(from: 0);
  }

  void _advance() {
    final currentType = _queue.isNotEmpty
        ? (_queue.first['_alertType'] as String? ?? 'registration')
        : 'registration';
    if (currentType == 'order') {
      _jsOrderAudioStop();
    } else {
      _jsAudioStop();
    }
    setState(() {
      _queue.removeAt(0);
      _detailsOpen = false;
      _busy = false;
    });
    if (_queue.isNotEmpty) {
      final nextType = _queue.first['_alertType'] as String? ?? 'registration';
      if (nextType == 'order') {
        _jsOrderAudioStart();
      } else {
        _jsAudioStart();
      }
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
      await Supabase.instance.client.from(table).update({
        'approved': true,
        'status': 'approved',
        'approved_at': DateTime.now().toUtc().toIso8601String(),
        'approved_by': 'admin',
      }).eq('id', id);
      // Fire-and-forget notification (existing logic)
      Supabase.instance.client.functions.invoke('notify-registration', body: {
        'action': 'approve',
        'pharmacyName': rec['pharmacy_name'],
        'email': rec['email'],
        'whatsappNo': rec['whatsapp_no'],
      }).then((_) {}).catchError((_) {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Approve failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
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
      await Supabase.instance.client.from(table)
          .update({'approved': false, 'status': 'rejected'}).eq('id', id);
      Supabase.instance.client.functions.invoke('notify-registration', body: {
        'action': 'reject',
        'pharmacyName': rec['pharmacy_name'],
        'email': rec['email'],
        'whatsappNo': rec['whatsapp_no'],
      }).then((_) {}).catchError((_) {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Reject failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
    _advance();
  }

  void _dismiss() => _advance();

  void _toggleMute() {
    setState(() => _muted = !_muted);
    _jsAudioMute(_muted);
    _jsOrderAudioMute(_muted);
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _orderChannel?.unsubscribe();
    _supplierChannel?.unsubscribe();
    _mrChannel?.unsubscribe();
    _companyChannel?.unsubscribe();
    _dpChannel?.unsubscribe();
    _jsAudioStop();
    _jsOrderAudioStop();
    _flashCtrl.dispose();
    _slideCtrl.dispose();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
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
    if (type == 'order') return _buildOrderCard(rec);
    if (type == 'supplier_registration') return _buildSupplierRegCard(rec);
    if (type == 'mr_registration') return _buildSimpleRegCard(rec, title: 'NEW MR REGISTRATION', color: const Color(0xFF7C3AED), nameKey: 'full_name', subtitleKey: 'company_represented');
    if (type == 'company_registration') return _buildSimpleRegCard(rec, title: 'NEW COMPANY REGISTRATION', color: const Color(0xFF0369A1), nameKey: 'company_name', subtitleKey: 'contact_person');
    if (type == 'dp_registration') return _buildSimpleRegCard(rec, title: 'NEW DELIVERY PARTNER', color: const Color(0xFFB45309), nameKey: 'full_name', subtitleKey: 'vehicle_type');
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
                      ? 'NEW REGISTRATION  ·  $queueLen pending'
                      : 'NEW REGISTRATION',
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
              const Text('View full details',
                  style: TextStyle(fontSize: 12, color: Color(0xFF1B7A43),
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
                      child: const Text('Skip', style: TextStyle(fontSize: 12)),
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
                      child: const Text('Reject',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
                      child: const Text('Approve',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
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
                queueLen > 1 ? 'NEW SUPPLIER  ·  $queueLen pending' : 'NEW SUPPLIER REGISTRATION',
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
              const Text('View full details', style: TextStyle(fontSize: 12, color: Color(0xFF0284C7), fontWeight: FontWeight.w600)),
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
                      child: const Text('Skip', style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: OutlinedButton(
                    onPressed: _reject,
                    style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFDC2626), side: const BorderSide(color: Color(0xFFDC2626)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: const Text('Reject', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                  const SizedBox(width: 10),
                  Expanded(child: FilledButton(
                    onPressed: _approve,
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0284C7), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
                    child: const Text('Approve', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  )),
                ]),
        ),
      ]),
    );
  }

  Widget _buildOrderCard(Map<String, dynamic> rec) {
    // payment_id is the human-readable order number (e.g. PO-260605-0861)
    final orderId      = rec['payment_id']    as String?
                      ?? rec['order_id']      as String?
                      ?? rec['order_number']  as String?
                      ?? '';
    final rawTotal     = rec['total_amount'] ?? rec['grand_total'] ?? rec['total'];
    final customerName = rec['pharmacy_name'] as String?
                      ?? rec['customer_name'] as String?
                      ?? '';
    final createdAt    = rec['created_at']   as String? ?? '';

    final queueLen  = _queue.length;
    // Round to nearest rupee with ₹ symbol
    final totalStr  = rawTotal != null ? _fmtRupee(rawTotal) : '';
    final dateStr   = createdAt.length >= 10
        ? () {
            try {
              final dt = DateTime.parse(createdAt).toLocal();
              return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}';
            } catch (_) { return ''; }
          }()
        : '';

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
              color: Color(0xFF15803D),
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(16), topRight: Radius.circular(16)),
            ),
            child: Row(children: [
              const Icon(Icons.shopping_bag_outlined, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  queueLen > 1
                      ? 'NEW ORDER  ·  $queueLen pending'
                      : 'NEW ORDER',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800,
                      color: Colors.white, letterSpacing: 0.5),
                ),
              ),
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
            if (customerName.isNotEmpty)
              Text(customerName,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w800,
                      color: Color(0xFF111827))),
            if (orderId.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(orderId,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ],
            const SizedBox(height: 12),
            Wrap(spacing: 16, runSpacing: 8, children: [
              if (totalStr.isNotEmpty)  _chip(Icons.currency_rupee,          totalStr),
              if (dateStr.isNotEmpty)   _chip(Icons.calendar_today_outlined, dateStr),
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
              const Text('View full details',
                  style: TextStyle(fontSize: 12, color: Color(0xFF15803D),
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _detailsOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more,
                    size: 16, color: Color(0xFF15803D)),
              ),
            ]),
          ),
        ),
        // Order-specific details: items table + meta fields (not generic _buildDetails)
        if (_detailsOpen) _buildOrderDetails(rec),

        const Divider(height: 1, color: Color(0xFFE5E7EB)),

        // ── Action buttons ───────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Row(children: [
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
                child: const Text('Skip', style: TextStyle(fontSize: 12)),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: OutlinedButton(
                onPressed: _dismiss,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF6B7280),
                  side: const BorderSide(color: Color(0xFFD1D5DB)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Dismiss',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: () {
                  _dismiss();
                  widget.onOrderTap?.call();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF15803D),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('View Orders',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  // ── Order-specific details panel ──────────────────────────────────────────

  Widget _buildOrderDetails(Map<String, dynamic> rec) {
    const skip = {'id', 'user_id', '_alertType', 'items'};

    // Parse items — Supabase returns JSONB as List already; handle string fallback.
    List<Map<String, dynamic>> items = [];
    final rawItems = rec['items'];
    if (rawItems is List) {
      for (final e in rawItems) {
        if (e is Map) items.add(Map<String, dynamic>.from(e));
      }
    } else if (rawItems is String && rawItems.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawItems);
        if (decoded is List) {
          for (final e in decoded) {
            if (e is Map) items.add(Map<String, dynamic>.from(e));
          }
        }
      } catch (_) {}
    }

    final entries = rec.entries.where((e) => !skip.contains(e.key)).toList();

    const labelStyle = TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
        color: Color(0xFF9CA3AF), letterSpacing: 0.4);
    const valueStyle = TextStyle(fontSize: 12, color: Color(0xFF374151));
    const dimStyle   = TextStyle(fontSize: 12, color: Color(0xFFD1D5DB));

    const colHeader = TextStyle(fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.3);
    const cellStyle = TextStyle(fontSize: 11, color: Color(0xFF374151));

    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      color: const Color(0xFFF9FAFB),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // ── Meta fields (payment_id, status, address, phone, total_amount…) ──
          if (entries.isNotEmpty)
            LayoutBuilder(builder: (_, constraints) {
              final cols = constraints.maxWidth > 400 ? 2 : 1;
              final itemW = (constraints.maxWidth - (cols - 1) * 16.0) / cols;
              return Wrap(spacing: 16, runSpacing: 8,
                children: entries.map((e) {
                  final display = e.key == 'total_amount'
                      ? _fmtRupee(e.value)
                      : _fmtVal(e.key, e.value);
                  return SizedBox(
                    width: itemW,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(_fmtLabel(e.key), style: labelStyle),
                      const SizedBox(height: 2),
                      Text(display,
                          style: display == '—' ? dimStyle : valueStyle),
                    ]),
                  );
                }).toList(),
              );
            }),

          // ── Items table ──────────────────────────────────────────────────
          if (items.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 8),
            // Header
            Row(children: const [
              Expanded(flex: 5, child: Text('Product', style: colHeader)),
              SizedBox(width: 30, child: Text('Qty',   style: colHeader, textAlign: TextAlign.center)),
              SizedBox(width: 54, child: Text('MRP',   style: colHeader, textAlign: TextAlign.right)),
              SizedBox(width: 58, child: Text('Total', style: colHeader, textAlign: TextAlign.right)),
            ]),
            const SizedBox(height: 4),
            // Item rows
            ...items.map((item) {
              final name  = item['product_name'] as String? ?? '—';
              final qty   = item['quantity'];
              final mrp   = item['mrp'];
              final rawLt = item['line_total'];
              // Fallback: price × qty if line_total absent/zero and price present
              final lineTotal = (rawLt != null &&
                      (rawLt is num) && rawLt.toDouble() != 0.0)
                  ? rawLt
                  : (item['price'] is num && qty is num
                      ? (item['price'] as num).toDouble() *
                        (qty as num).toDouble()
                      : rawLt);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 2.5),
                child: Row(children: [
                  Expanded(
                    flex: 5,
                    child: Text(name,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: cellStyle),
                  ),
                  SizedBox(
                    width: 30,
                    child: Text('${qty ?? '—'}',
                        textAlign: TextAlign.center, style: cellStyle),
                  ),
                  SizedBox(
                    width: 54,
                    child: Text(_fmtRupee(mrp),
                        textAlign: TextAlign.right, style: cellStyle),
                  ),
                  SizedBox(
                    width: 58,
                    child: Text(_fmtRupee(lineTotal),
                        textAlign: TextAlign.right, style: cellStyle),
                  ),
                ]),
              );
            }),
          ],
        ]),
      ),
    );
  }

  // ── Registration generic details panel ───────────────────────────────────

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
                queueLen > 1 ? '$title  ·  $queueLen pending' : title,
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
              Text('View full details', style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
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
                child: const Text('Skip', style: TextStyle(fontSize: 12))),
              const SizedBox(width: 8),
            ],
            Expanded(child: OutlinedButton(onPressed: _dismiss,
              style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF6B7280), side: const BorderSide(color: Color(0xFFD1D5DB)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)), padding: const EdgeInsets.symmetric(vertical: 12)),
              child: const Text('Dismiss', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)))),
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
