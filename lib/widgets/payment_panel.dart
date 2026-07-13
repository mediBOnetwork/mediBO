// lib/widgets/payment_panel.dart — CHANGE #462
// ONE payment panel, used by BOTH admin ("View Payment") and customer
// ("Payment" tab). Everything on screen — labels, which buttons show, the
// above/below layout — comes straight from order_payment_panel(); nothing is
// formatted, computed, pluralised, or role-gated here. The server tells us
// can_respond / can_add_cash / can_pay; we never derive those from a role.
// ignore_for_file: use_build_context_synchronously
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';
import '../utils/safe_parse.dart';
import '../utils/toast.dart';
import 'cash_payment_sheet.dart';
import 'fullscreen_image.dart';
import 'sup_pay_panel.dart' show C330CopyRow;

class PaymentPanel extends StatefulWidget {
  final String orderId;
  final VoidCallback? onChanged;
  const PaymentPanel({super.key, required this.orderId, this.onChanged});

  @override
  State<PaymentPanel> createState() => _PaymentPanelState();
}

class _PaymentPanelState extends State<PaymentPanel> with WidgetsBindingObserver {
  Map<String, dynamic>? _panel;
  bool _loading = true;
  String? _error;
  int _chip = 0;
  RealtimeChannel? _rt;
  RealtimeChannel? _rtAdmin;
  Timer? _debounce;
  int _events = 0;
  int _reloads = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    if (_rt != null) {
      try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
    }
    if (_rtAdmin != null) {
      try { Supabase.instance.client.removeChannel(_rtAdmin!); } catch (_) {}
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A backgrounded socket dies silently — re-subscribe on resume.
    if (state == AppLifecycleState.resumed) {
      _load(silent: true);
      _subscribeRealtime();
    }
  }

  // ── CHANGE #462: broadcast-only realtime (same pattern as #458) — no ────────
  // table replication, no polling. The topic comes from the backend; the
  // broadcast payload is data-free, so every event just re-fetches the panel,
  // coalesced with a 250ms debounce.
  Future<void> _subscribeRealtime() async {
    try {
      final t = await Supabase.instance.client
          .rpc('payment_realtime_topic', params: {'p_order_id': widget.orderId}) as Map;
      if (!mounted) return;
      final topic = t['topic'] as String?;
      final event = t['event'] as String? ?? 'payment_changed';
      final adminTopic = t['admin_topic'] as String?;
      if (topic == null) {
        try { RenderLog.write('c462_topic', 'error'); } catch (_) {}
        return;
      }
      try { RenderLog.write('c462_topic', topic); } catch (_) {}
      if (_rt != null) {
        try { Supabase.instance.client.removeChannel(_rt!); } catch (_) {}
        _rt = null;
      }
      _rt = Supabase.instance.client
          .channel(topic)
          .onBroadcast(event: event, callback: (_) => _onRealtimeEvent())
          .subscribe((status, error) {
            if (status == RealtimeSubscribeStatus.subscribed) {
              try { RenderLog.write('c462_subscribed', 1); } catch (_) {}
            }
          });
      if (adminTopic != null) {
        if (_rtAdmin != null) {
          try { Supabase.instance.client.removeChannel(_rtAdmin!); } catch (_) {}
          _rtAdmin = null;
        }
        _rtAdmin = Supabase.instance.client
            .channel(adminTopic)
            .onBroadcast(event: event, callback: (_) => _onRealtimeEvent())
            .subscribe();
      }
    } catch (e) {
      try { RenderLog.write('c462_topic', 'exception'); } catch (_) {}
    }
  }

  void _onRealtimeEvent() {
    _events++;
    try { RenderLog.write('c462_events', _events); } catch (_) {}
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      _reloads++;
      try { RenderLog.write('c462_reloads', _reloads); } catch (_) {}
      _load(silent: true);
    });
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .rpc('order_payment_panel', params: {'p_order_id': widget.orderId});
      final panel = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      setState(() { _panel = panel; _loading = false; });
      widget.onChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load payment details.';
        if (!silent) _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _panel == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))),
      );
    }
    if (_error != null && _panel == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(_error!, style: const TextStyle(color: Colors.red)),
      );
    }
    final panel = _panel;
    if (panel == null) return const SizedBox.shrink();

    final viewer = panel['viewer']?.toString() ?? '';
    final hasPayments = panel['has_payments'] == true;
    final canRespond = panel['can_respond'] == true;
    final canAddCash = panel['can_add_cash'] == true;
    final canPay = panel['can_pay'] == true;
    final totals = Map<String, dynamic>.from(panel['totals'] as Map? ?? {});
    final info = Map<String, dynamic>.from(panel['info'] as Map? ?? {});
    final advance = Map<String, dynamic>.from(panel['advance'] as Map? ?? {});
    final remaining = Map<String, dynamic>.from(panel['remaining'] as Map? ?? {});
    final upi = Map<String, dynamic>.from(panel['upi'] as Map? ?? {});
    final payments = ((panel['payments'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final paymentsEmptyLabel = panel['payments_empty_label']?.toString() ?? '';
    final unlinked = ((panel['unlinked'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final advPayments = payments.where((p) => p['kind'] == 'advance').toList();
    final balPayments = payments.where((p) => p['kind'] == 'balance').toList();

    final respondBtns = payments
        .where((p) => canRespond && p['awaiting_response'] == true)
        .length;
    final payBtns = canPay ? 2 : 0; // Pay button + Upload button

    RenderLog.write('c462_widgets', 1);
    RenderLog.write('c462_viewer', viewer);
    RenderLog.write('c462_has_payments', hasPayments.toString());
    RenderLog.write('c462_cards', payments.length.toString());
    RenderLog.write('c462_respond_btns', respondBtns.toString());
    RenderLog.write('c462_pay_btns', payBtns.toString());
    RenderLog.write('c462_unlinked', unlinked.length.toString());
    RenderLog.write('c462_isadmin', '0');
    RenderLog.write('c462_timers', '0');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // ── Headline strip ──────────────────────────────────────────────────
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
        child: Row(children: [
          Expanded(child: _statLine('Total', totals['total_label']?.toString() ?? '')),
          Expanded(child: _statLine('Paid', totals['paid_label']?.toString() ?? '')),
          Expanded(child: _statLine('Due', totals['due_label']?.toString() ?? '')),
        ]),
      ),
      const SizedBox(height: 12),
      // ── Chip row ─────────────────────────────────────────────────────────
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _PayPanelChip(label: 'Payment Info', selected: _chip == 0, onTap: () => setState(() => _chip = 0)),
          const SizedBox(width: 6),
          _PayPanelChip(label: 'Advance Payment', selected: _chip == 1, onTap: () => setState(() => _chip = 1)),
          const SizedBox(width: 6),
          _PayPanelChip(label: 'Remaining', selected: _chip == 2, onTap: () => setState(() => _chip = 2)),
        ]),
      ),
      const SizedBox(height: 12),
      if (_chip == 0) _buildInfoTab(info),
      if (_chip == 1)
        _buildKindTab(
          statLabel: advance['basis_label']?.toString() ?? '',
          statHeadline: advance['value']?.toString() ?? '',
          statSub: '',
          statFill: (safeParseInt(advance['pct'])).clamp(0, 100) / 100,
          statBarColor: advance['done'] == true ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
          hasPayments: hasPayments,
          kindPayments: advPayments,
          emptyLabel: advance['empty_label']?.toString() ?? paymentsEmptyLabel,
          canRespond: canRespond,
          canAddCash: canAddCash,
          canPay: canPay,
          payDisabled: advance['done'] == true,
          payLabel: advance['pay_label']?.toString() ?? '',
          upi: upi,
        ),
      if (_chip == 2)
        _buildKindTab(
          statLabel: 'Remaining balance',
          statHeadline: remaining['value']?.toString() ?? '',
          statSub: remaining['sub']?.toString() ?? '',
          statFill: (safeParseInt(remaining['pct'])).clamp(0, 100) / 100,
          statBarColor: const Color(0xFF1B7A43),
          hasPayments: hasPayments,
          kindPayments: balPayments,
          emptyLabel: remaining['empty_label']?.toString() ?? paymentsEmptyLabel,
          canRespond: canRespond,
          canAddCash: canAddCash,
          canPay: canPay,
          payDisabled: remaining['can_pay'] != true,
          payLabel: remaining['pay_label']?.toString() ?? '',
          upi: upi,
        ),
      if (canAddCash) ..._buildUnlinked(unlinked),
    ]);
  }

  Widget _statLine(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF))),
      Text(value,
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
    ]);
  }

  // ── Chip 1: Payment Info — three stat cards, no buttons, unconditional ─────
  Widget _buildInfoTab(Map<String, dynamic> info) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _PayStatCard(
        label: info['ordered_label']?.toString() ?? '',
        headline: info['ordered_value']?.toString() ?? '',
        sub: info['ordered_pct_label']?.toString() ?? '',
        fill: (safeParseInt(info['ordered_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      _PayStatCard(
        label: info['advance_label']?.toString() ?? '',
        headline: info['advance_value']?.toString() ?? '',
        sub: '',
        fill: (safeParseInt(info['advance_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
      _PayStatCard(
        label: info['remaining_label']?.toString() ?? '',
        headline: info['remaining_value']?.toString() ?? '',
        sub: info['remaining_sub']?.toString() ?? '',
        fill: (safeParseInt(info['remaining_pct'])).clamp(0, 100) / 100,
        barColor: const Color(0xFF1B7A43),
      ),
    ]);
  }

  // ── Chips 2/3: Advance / Remaining — ⭐ THE LAYOUT RULE (PART C1) ───────────
  // has_payments true  -> stat card, then payment cards (or per-kind empty
  //                       label) ABOVE, buttons BELOW.
  // has_payments false -> buttons ONLY. No stat card, no empty container.
  Widget _buildKindTab({
    required String statLabel,
    required String statHeadline,
    required String statSub,
    required double statFill,
    required Color statBarColor,
    required bool hasPayments,
    required List<Map<String, dynamic>> kindPayments,
    required String emptyLabel,
    required bool canRespond,
    required bool canAddCash,
    required bool canPay,
    required bool payDisabled,
    required String payLabel,
    required Map<String, dynamic> upi,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (hasPayments) ...[
        _PayStatCard(label: statLabel, headline: statHeadline, sub: statSub, fill: statFill, barColor: statBarColor),
        if (kindPayments.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(emptyLabel, style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
          )
        else
          ...kindPayments.map((p) => _PayCard(
                payment: p, orderId: widget.orderId, canRespond: canRespond, onReload: _load,
              )),
      ],
      if (canAddCash)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => CashPaymentSheet(
                  orderId: widget.orderId,
                  onSuccess: () => _load(),
                ),
              ),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Add Cash Payment', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF1B7A43)),
                foregroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
          ),
        ),
      if (canPay) ...[
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: payDisabled ? null : () => _openPaySheet(upi, payLabel),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(payLabel, style: const TextStyle(color: Colors.white)),
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _openUploadSheet(),
          icon: const Icon(Icons.upload_outlined, size: 16),
          label: const Text('Upload payment screenshot',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFF1B7A43)),
            foregroundColor: const Color(0xFF1B7A43),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            minimumSize: const Size(double.infinity, 40),
          ),
        ),
      ],
    ]);
  }

  // ── C6: unlinked payments — admin only, amber, below everything ───────────
  List<Widget> _buildUnlinked(List<Map<String, dynamic>> unlinked) {
    if (unlinked.isEmpty) return const [];
    return [
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFF59E0B)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Icons.warning_amber_rounded, size: 16, color: Color(0xFF92400E)),
            SizedBox(width: 6),
            Expanded(
              child: Text('Unlinked payments from this customer',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Color(0xFF92400E))),
            ),
          ]),
          const SizedBox(height: 8),
          ...unlinked.map((u) => _UnlinkedRow(payment: u, orderId: widget.orderId, onLinked: _load)),
        ]),
      ),
    ];
  }

  // ── Pay sheet (QR only — no deep link) ──────────────────────────────────
  Future<void> _openPaySheet(Map<String, dynamic> upi, String payLabel) async {
    final qrPayload = upi['qr_payload']?.toString();
    if (qrPayload == null || qrPayload.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PaySheet(
        qrPayload: qrPayload,
        vpa: upi['vpa']?.toString() ?? '',
        payeeName: upi['name']?.toString() ?? '',
        hint: upi['hint']?.toString() ?? '',
        payLabel: payLabel,
      ),
    );
  }

  // ── Upload sheet ─────────────────────────────────────────────────────────
  Future<void> _openUploadSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _PaymentUploadSheet(
        orderId: widget.orderId,
        onSuccess: (message) {
          if (mounted) showToast(context, message);
          _load();
        },
      ),
    );
  }
}

// ── Chip ───────────────────────────────────────────────────────────────────

class _PayPanelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _PayPanelChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF1B7A43) : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(20),
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

// ── Stat card ────────────────────────────────────────────────────────────────

class _PayStatCard extends StatelessWidget {
  final String label;
  final String headline;
  final String sub;
  final double fill;
  final Color barColor;
  const _PayStatCard({
    required this.label,
    required this.headline,
    required this.sub,
    required this.fill,
    required this.barColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
        const SizedBox(height: 4),
        Text(headline, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        if (sub.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
        ],
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: fill,
            minHeight: 10,
            backgroundColor: const Color(0xFFF3F4F6),
            color: barColor,
          ),
        ),
      ]),
    );
  }
}

// ── Pay sheet — QR + copy only, no deep link ──────────────────────────────

class _PaySheet extends StatelessWidget {
  final String qrPayload;
  final String vpa;
  final String payeeName;
  final String hint;
  final String payLabel;
  const _PaySheet({
    required this.qrPayload,
    required this.vpa,
    required this.payeeName,
    required this.hint,
    required this.payLabel,
  });

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.92),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: const Color(0xFFD1D5DB), borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(children: [
            Expanded(
              child: Text(payLabel,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
              visualDensity: VisualDensity.compact,
            ),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 32 + bottom),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: QrImageView(
                    data: qrPayload,
                    version: QrVersions.auto,
                    size: 220,
                    errorCorrectionLevel: QrErrorCorrectLevel.M,
                    backgroundColor: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              C330CopyRow(label: 'UPI ID', value: vpa),
              if (payeeName.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(payeeName, style: const TextStyle(fontSize: 12.5, color: Color(0xFF6B7280))),
                const SizedBox(height: 10),
              ],
              if (hint.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFF5F6F8), borderRadius: BorderRadius.circular(10)),
                  child: Text(hint, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ── Upload sheet — gallery first ──────────────────────────────────────────

class _PaymentUploadSheet extends StatefulWidget {
  final String orderId;
  final void Function(String message) onSuccess;
  const _PaymentUploadSheet({required this.orderId, required this.onSuccess});

  @override
  State<_PaymentUploadSheet> createState() => _PaymentUploadSheetState();
}

class _PaymentUploadSheetState extends State<_PaymentUploadSheet> {
  final TextEditingController _amountCtrl = TextEditingController();
  final TextEditingController _utrCtrl = TextEditingController();
  XFile? _picked;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _utrCtrl.dispose();
    super.dispose();
  }

  // C5 — gallery is the default, one-tap action: a payment screenshot is
  // always already in the gallery (just captured in PhonePe/GPay).
  Future<void> _pickFromGallery() async {
    RenderLog.write('c462_gallery', 1);
    try {
      final img = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 90);
      if (img == null) return;
      setState(() { _picked = img; _error = null; });
    } catch (_) {}
  }

  Future<void> _submit() async {
    final amount = num.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter the amount you paid.');
      return;
    }
    final picked = _picked;
    if (picked == null) {
      setState(() => _error = 'Upload the payment screenshot so we can verify it.');
      return;
    }
    setState(() { _submitting = true; _error = null; });

    final ext = (picked.name.split('.').isNotEmpty ? picked.name.split('.').last : 'jpg').toLowerCase();
    final safeExt = ['jpg', 'jpeg', 'png', 'webp'].contains(ext) ? ext : 'jpg';
    final token = '${DateTime.now().microsecondsSinceEpoch}';
    final path = '${widget.orderId}/$token.$safeExt';
    final contentType = safeExt == 'png' ? 'image/png' : safeExt == 'webp' ? 'image/webp' : 'image/jpeg';

    try {
      final bytes = await picked.readAsBytes();
      await Supabase.instance.client.storage.from('payment-proofs').uploadBinary(
            path, bytes,
            fileOptions: FileOptions(contentType: contentType),
          );
    } catch (_) {
      if (mounted) setState(() { _submitting = false; _error = 'Screenshot upload failed. Try again.'; });
      return;
    }

    try {
      final res = await Supabase.instance.client.rpc('cust_submit_payment', params: {
        'p_order_id': widget.orderId,
        'p_amount': amount,
        'p_screenshot_path': path,
        'p_utr': _utrCtrl.text.trim().isEmpty ? null : _utrCtrl.text.trim(),
        'p_app': null,
        'p_ocr': null,
      });
      final result = Map<String, dynamic>.from(res as Map);
      final message = result['message']?.toString() ?? '';
      if (result['ok'] == true) {
        if (mounted) Navigator.of(context).pop();
        widget.onSuccess(message);
      } else {
        if (mounted) setState(() { _submitting = false; _error = message; });
      }
    } catch (e) {
      if (mounted) setState(() { _submitting = false; _error = 'Could not submit payment.'; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Upload payment proof', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        const SizedBox(height: 14),
        TextField(
          controller: _amountCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount paid', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _utrCtrl,
          decoration: const InputDecoration(labelText: 'UTR / reference (optional)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _pickFromGallery,
          icon: const Icon(Icons.photo_library_outlined, size: 16),
          label: Text(_picked == null ? 'Choose screenshot from gallery' : 'Selected: ${_picked!.name}'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 40)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 12.5)),
        ],
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _submitting ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1B7A43),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: _submitting
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Submit'),
          ),
        ),
      ]),
    );
  }
}

// ── Payment card — identical for admin and customer. Received/Reject only ──
// appear when the server says can_respond AND that specific payment is
// awaiting_response — never derived from a role or from a status string.

class _PayCard extends StatefulWidget {
  final Map<String, dynamic> payment;
  final String orderId;
  final bool canRespond;
  final VoidCallback onReload;
  const _PayCard({
    required this.payment,
    required this.orderId,
    required this.canRespond,
    required this.onReload,
  });

  @override
  State<_PayCard> createState() => _PayCardState();
}

class _PayCardState extends State<_PayCard> {
  String? _url;
  bool _loadingUrl = false;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _loadUrl();
  }

  Future<void> _loadUrl() async {
    final path = widget.payment['screenshot'] as String?;
    final bucket = widget.payment['bucket'] as String? ?? 'payment-proofs';
    if (path == null || path.isEmpty) return;
    setState(() => _loadingUrl = true);
    try {
      final url = await Supabase.instance.client.storage.from(bucket).createSignedUrl(path, 3600);
      if (mounted) setState(() { _url = url; _loadingUrl = false; });
    } catch (_) {
      if (mounted) setState(() => _loadingUrl = false);
    }
  }

  Color _toneColor(String tone) => switch (tone) {
        'ok' => const Color(0xFF16A34A),
        'bad' => const Color(0xFFDC2626),
        _ => const Color(0xFFD97706),
      };

  Color _toneBg(String tone) => switch (tone) {
        'ok' => const Color(0xFFD1FAE5),
        'bad' => const Color(0xFFFEE2E2),
        _ => const Color(0xFFFEF3C7),
      };

  // C3 — admin: Received ✓ on a claimed payment.
  Future<void> _markReceived() async {
    setState(() => _acting = true);
    try {
      await Supabase.instance.client.rpc('mark_payment_received', params: {
        'p_claim_id': widget.payment['id'],
        'p_order_id': widget.orderId,
      });
      widget.onReload();
    } catch (_) {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _reject() async {
    final ctrl = TextEditingController(text: 'Not received');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Payment', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Reason'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (reason == null || reason.isEmpty || !mounted) return;
    setState(() => _acting = true);
    try {
      await Supabase.instance.client.rpc('reject_payment_claim', params: {
        'p_claim_id': widget.payment['id'],
        'p_order_id': widget.orderId,
        'p_reason': reason,
      });
      widget.onReload();
    } catch (_) {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payment;
    final statusLabel = p['status_label']?.toString() ?? '';
    final statusTone = p['status_tone']?.toString() ?? 'pending';
    final methodLabel = p['method_label']?.toString() ?? '';
    final reason = p['reason']?.toString();
    final hasSnap = (p['screenshot'] as String? ?? '').isNotEmpty;
    final showActions = widget.canRespond && p['awaiting_response'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(color: _toneBg(statusTone), borderRadius: BorderRadius.circular(12)),
            child: Text(statusLabel,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _toneColor(statusTone))),
          ),
          const Spacer(),
          if (methodLabel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
              child: Text(methodLabel,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF374151))),
            ),
        ]),
        const SizedBox(height: 10),
        C330CopyRow(label: 'Amount', value: p['amount_label']?.toString()),
        C330CopyRow(label: 'Payee', value: p['payee_name']?.toString()),
        C330CopyRow(label: 'App', value: p['app']?.toString()),
        C330CopyRow(label: 'UTR', value: p['utr']?.toString()),
        C330CopyRow(label: 'Txn', value: p['txn_id']?.toString()),
        C330CopyRow(label: 'Paid', value: p['paid_label']?.toString()),
        C330CopyRow(label: 'Collected by', value: p['collected_by']?.toString()),
        C330CopyRow(label: 'Location', value: p['location']?.toString()),
        if (reason != null && reason.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(reason, style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626))),
        ],
        if (hasSnap) ...[
          const SizedBox(height: 8),
          if (_loadingUrl)
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
          else if (_url != null)
            GestureDetector(
              onTap: () => openFullscreenImage(context, _url!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  _url!,
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: 160,
                  errorBuilder: (_, e, st) => const Text('Screenshot unavailable',
                      style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                ),
              ),
            ),
        ],
        if (showActions) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _acting ? null : _reject,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFFDC2626)),
                  foregroundColor: const Color(0xFFDC2626),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 40),
                ),
                child: const Text('Reject'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _acting ? null : _markReceived,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  minimumSize: const Size(0, 40),
                ),
                child: _acting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Received ✓'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }
}

// ── C6: one unlinked-payment row — admin only ──────────────────────────────

class _UnlinkedRow extends StatefulWidget {
  final Map<String, dynamic> payment;
  final String orderId;
  final VoidCallback onLinked;
  const _UnlinkedRow({required this.payment, required this.orderId, required this.onLinked});

  @override
  State<_UnlinkedRow> createState() => _UnlinkedRowState();
}

class _UnlinkedRowState extends State<_UnlinkedRow> {
  bool _linking = false;

  Future<void> _link() async {
    setState(() => _linking = true);
    try {
      final res = await Supabase.instance.client.rpc('payment_claim_link', params: {
        'p_claim_id': widget.payment['id'],
        'p_order_id': widget.orderId,
      });
      final result = Map<String, dynamic>.from(res as Map);
      final message = result['message']?.toString();
      if (mounted && message != null) showToast(context, message, isError: result['ok'] != true);
      widget.onLinked();
    } catch (e) {
      if (mounted) showToast(context, 'Could not link payment: $e', isError: true);
    } finally {
      if (mounted) setState(() => _linking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.payment['label']?.toString() ?? '';
    final actionLabel = widget.payment['action_label']?.toString() ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Expanded(
          child: Text(label, style: const TextStyle(fontSize: 12.5, color: Color(0xFF92400E))),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: _linking ? null : _link,
          style: OutlinedButton.styleFrom(
            side: const BorderSide(color: Color(0xFFF59E0B)),
            foregroundColor: const Color(0xFF92400E),
            visualDensity: VisualDensity.compact,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: _linking
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF92400E)))
              : Text(actionLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}
