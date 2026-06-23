import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

const _kGreen      = Color(0xFF1B7A43);
const _kText       = Color(0xFF111827);
const _kSub        = Color(0xFF6B7280);
const _kBg         = Color(0xFFF5F6F8);
const _kCard       = Color(0xFFFFFFFF);
const _kBorder     = Color(0xFFE5E7EB);
// Dispute palette — purple/blue/orange distinct from C/CR/P green/red/yellow
const _kReminderBg = Color(0xFFEDE9FE);
const _kReminderFg = Color(0xFF7C3AED);
const _kDeniedBg   = Color(0xFFFFEDD5);
const _kDeniedFg   = Color(0xFFC2410C);

class DisputeFormScreen extends StatefulWidget {
  final String token;
  const DisputeFormScreen({super.key, required this.token});

  @override
  State<DisputeFormScreen> createState() => _DisputeFormScreenState();
}

class _DisputeFormScreenState extends State<DisputeFormScreen> {
  bool _loading  = true;
  String? _error;
  String? _supplierName;
  String? _status; // reminder_sent | accepted_missing | denied | resolved | shop_logged | cancelled
  Map<String, dynamic>? _main; // {dispute_id, product_name, image_url, ordered, received, short}
  List<Map<String, dynamic>> _others = [];
  bool _submitting = false;
  String? _submitted; // 'missing' | 'denied' — post-submit state
  bool _othersExpanded = false;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c132a_dispute_route', 'true');
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Supabase.instance.client
          .rpc('get_dispute_form', params: {'p_token': widget.token});
      if (!mounted) return;
      final data = Map<String, dynamic>.from(result as Map);
      if (data['error'] != null) {
        setState(() { _error = data['error'] as String; _loading = false; });
        return;
      }
      final mainRaw = data['main'];
      final othersRaw = (data['others'] as List? ?? []);
      setState(() {
        _supplierName = data['supplier_name']?.toString();
        _status       = data['status']?.toString();
        _main         = mainRaw != null ? Map<String, dynamic>.from(mainRaw as Map) : null;
        _others       = othersRaw.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        _loading      = false;
      });
      RenderLog.write('c132a_dispute_form_loaded', 'true');
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'load_failed'; _loading = false; });
    }
  }

  Future<void> _submit(String response) async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final result = await Supabase.instance.client.rpc(
        'submit_dispute_response',
        params: {'p_token': widget.token, 'p_response': response},
      );
      if (!mounted) return;
      final data = Map<String, dynamic>.from(result as Map);
      if (data['error'] != null) {
        final err = data['error'] as String;
        if (err == 'already_responded') {
          // reload to show current status
          setState(() => _submitting = false);
          await _load();
          return;
        }
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)),
        );
        return;
      }
      setState(() { _submitted = response; _submitting = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Submission failed. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _kGreen, strokeWidth: 2.5))
                : _error != null
                    ? _buildError()
                    : _buildPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    final isInvalid = _error == 'invalid' || _error == 'load_failed';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(20)),
            child: Icon(Icons.link_off_outlined, size: 36, color: const Color(0xFF9CA3AF)),
          ),
          const SizedBox(height: 20),
          Text(
            isInvalid ? 'This link is invalid or expired.' : 'Unable to load. Please try again.',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF374151)),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const Text('Please contact mediBO for assistance.',
              style: TextStyle(fontSize: 14, color: _kSub), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          Image.network('https://medibo.in/icons/Icon-192.png', width: 48, height: 48,
              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    // Already answered (status != reminder_sent and no in-session submit)
    if (_submitted == null && _status != 'reminder_sent') {
      return _buildAlreadyAnswered();
    }
    // In-session submit confirmation
    if (_submitted != null) {
      return _buildConfirmation();
    }
    return _buildForm();
  }

  Widget _buildAlreadyAnswered() {
    final label = _status == 'accepted_missing' ? 'Accepted (missing stock)'
        : _status == 'denied' ? 'Denied'
        : _status == 'resolved' ? 'Resolved'
        : _status?.replaceAll('_', ' ') ?? 'Answered';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(20)),
            child: const Icon(Icons.check_circle_outline, size: 36, color: _kGreen),
          ),
          const SizedBox(height: 20),
          const Text('This request has already been answered.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: _kText),
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('Status: $label',
              style: const TextStyle(fontSize: 14, color: _kSub), textAlign: TextAlign.center),
          const SizedBox(height: 32),
          _mediboFooter(),
        ]),
      ),
    );
  }

  Widget _buildConfirmation() {
    final short = _main != null ? (_main!['short'] as num?)?.toInt() ?? 0 : 0;
    final unit  = _main?['unit']?.toString() ?? '';
    final isMissing = _submitted == 'missing';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: isMissing ? const Color(0xFFECFDF5) : const Color(0xFFFFF7ED),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(isMissing ? Icons.check_circle_outline : Icons.info_outline,
                size: 36, color: isMissing ? _kGreen : const Color(0xFFD97706)),
          ),
          const SizedBox(height: 20),
          Text(
            isMissing
                ? "Thanks — we'll send the missing $short${unit.isNotEmpty ? ' $unit' : ''} shortly."
                : 'Recorded. Our team will review with proof.',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: _kText),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          _mediboFooter(),
        ]),
      ),
    );
  }

  Widget _buildForm() {
    final m = _main;
    if (m == null) return _buildError();
    final productName = m['product_name']?.toString() ?? '—';
    final ordered     = (m['ordered'] as num?)?.toInt() ?? 0;
    final received    = (m['received'] as num?)?.toInt() ?? 0;
    final short       = (m['short'] as num?)?.toInt() ?? 0;
    final imageUrl    = m['image_url']?.toString();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Brand header ──────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(color: _kGreen, borderRadius: BorderRadius.circular(12)),
          child: Row(children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.local_shipping_outlined, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('mediBO · Delivery Dispute',
                    style: TextStyle(color: Colors.white, fontSize: 11,
                        fontWeight: FontWeight.w500, letterSpacing: 0.5)),
                const SizedBox(height: 3),
                Text(_supplierName ?? '',
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800),
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: 20),

        // ── Main disputed item card ───────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _kBorder),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Product image
              if (imageUrl != null && imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(imageUrl, width: 64, height: 64, fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _placeholderImage()),
                )
              else
                _placeholderImage(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(productName,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
                  const SizedBox(height: 10),
                  _labelRow('Ordered',  '$ordered'),
                  const SizedBox(height: 4),
                  _labelRow('Received', '$received'),
                  const SizedBox(height: 4),
                  _labelRow('Missing',  '$short',
                      valueStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kDeniedFg)),
                ]),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 20),

        // ── Question ─────────────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF7ED),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFFCD34D)),
          ),
          child: const Row(children: [
            Icon(Icons.help_outline_rounded, size: 18, color: Color(0xFFD97706)),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Did the missing quantity actually go undelivered?',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF92400E)),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 16),

        // ── Response buttons ──────────────────────────────────────────────────
        SizedBox(
          width: double.infinity, height: 50,
          child: FilledButton.icon(
            onPressed: _submitting ? null : () => _submit('missing'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD97706),
              disabledBackgroundColor: const Color(0xFFFDE68A),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: _submitting
                ? const SizedBox(width: 16, height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Icon(Icons.check_rounded, size: 18, color: Colors.white),
            label: const Text('Yes — the quantity is missing (our mistake)',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity, height: 50,
          child: OutlinedButton.icon(
            onPressed: _submitting ? null : () => _submit('denied'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
              side: const BorderSide(color: _kBorder, width: 1.5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('No — we delivered the correct quantity',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: const Text(
            'Your response is recorded and shared with mediBO.',
            style: TextStyle(fontSize: 12, color: _kSub),
          ),
        ),
        const SizedBox(height: 20),

        // ── Others dropdown ───────────────────────────────────────────────────
        if (_others.isNotEmpty) ...[
          GestureDetector(
            onTap: () => setState(() => _othersExpanded = !_othersExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kBorder),
              ),
              child: Row(children: [
                const Icon(Icons.inventory_2_outlined, size: 16, color: _kSub),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Other pending items (${_others.length})',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kSub)),
                ),
                Icon(_othersExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    size: 20, color: _kSub),
              ]),
            ),
          ),
          if (_othersExpanded) ...[
            const SizedBox(height: 8),
            for (final o in _others) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: _kCard,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: _kBorder),
                ),
                child: Row(children: [
                  Expanded(
                    child: Text(o['product_name']?.toString() ?? '—',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  Text(
                    'Ord ${(o['ordered'] as num?)?.toInt() ?? 0} · '
                    'Rec ${(o['received'] as num?)?.toInt() ?? 0} · '
                    'Miss ${(o['short'] as num?)?.toInt() ?? 0}',
                    style: const TextStyle(fontSize: 12, color: _kSub),
                  ),
                ]),
              ),
            ],
          ],
          const SizedBox(height: 20),
        ],

        _mediboFooter(),
      ]),
    );
  }

  Widget _placeholderImage() => Container(
    width: 64, height: 64,
    decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(8)),
    child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFF9CA3AF)),
  );

  Widget _labelRow(String label, String value, {TextStyle? valueStyle}) {
    return Row(children: [
      SizedBox(
        width: 72,
        child: Text(label, style: const TextStyle(fontSize: 13, color: _kSub)),
      ),
      Text(value,
          style: valueStyle ?? const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
    ]);
  }

  Widget _mediboFooter() => Center(
    child: Text('mediBO · Powered by mediBO B2B Pharmacy',
        style: const TextStyle(fontSize: 11, color: _kSub)),
  );
}
