import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

const _kGreen = Color(0xFF1B7A43);
const _kAnswers = [
  'Available',
  'Out of Stock',
  "We don't stock this product",
];

class InquiryFormScreen extends StatefulWidget {
  final String token;
  const InquiryFormScreen({super.key, required this.token});

  @override
  State<InquiryFormScreen> createState() => _InquiryFormScreenState();
}

class _InquiryFormScreenState extends State<InquiryFormScreen> {
  bool _loading = true;
  String? _error;
  String? _supplierName;
  List<Map<String, dynamic>> _items = [];
  final Map<int, String> _selections = {};
  bool _submitting = false;
  bool _newItemsAdded = false;
  Set<int> _prevUnlockedIds = {};
  bool _respondedExpanded = false;

  @override
  void initState() {
    super.initState();
    RenderLog.write('inquiry_form_init', widget.token.substring(0, 8));
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await Supabase.instance.client
          .rpc('get_inquiry_form', params: {'p_token': widget.token});

      if (!mounted) return;
      final data = Map<String, dynamic>.from(result as Map);

      if (data['error'] != null) {
        setState(() {
          _error = data['error'] as String;
          _loading = false;
        });
        RenderLog.write('inquiry_form_error', data['error']);
        return;
      }

      final items = (data['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      final unlockedIds = items
          .where((i) => i['locked'] == false)
          .map((i) => (i['inquiry_id'] as num).toInt())
          .toSet();

      final hadItems = _items.isNotEmpty;
      final newlyAppeared = hadItems &&
          unlockedIds.any((id) => !_prevUnlockedIds.contains(id));

      setState(() {
        _supplierName = data['supplier_name'] as String?;
        _items = items;
        _newItemsAdded = newlyAppeared;
        final nowLocked = items
            .where((i) => i['locked'] == true)
            .map((i) => (i['inquiry_id'] as num).toInt())
            .toSet();
        for (final id in nowLocked) {
          _selections.remove(id);
        }
        _prevUnlockedIds = unlockedIds;
        _loading = false;
      });

      RenderLog.write('inquiry_form_loaded', '${items.length}_items_${widget.token.substring(0, 8)}');
      RenderLog.write('inquiry_form_qty_hidden', 'true');
      RenderLog.write('inquiry_form_pending_first', 'true');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'load_failed';
        _loading = false;
      });
      RenderLog.write('inquiry_form_load_error', e.toString().substring(0, 40));
    }
  }

  Future<void> _submit() async {
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final toSubmit = unanswered
        .map((i) {
          final id = (i['inquiry_id'] as num).toInt();
          return {'inquiry_id': id, 'answer': _selections[id] ?? ''};
        })
        .where((a) => (a['answer'] as String).isNotEmpty)
        .toList();

    if (toSubmit.isEmpty) return;

    setState(() => _submitting = true);
    try {
      await Supabase.instance.client.rpc('submit_inquiry_form', params: {
        'p_token': widget.token,
        'p_answers': toSubmit,
      });
      RenderLog.write('inquiry_form_submitted', '${toSubmit.length}_answers');
      await _load();
    } catch (e) {
      RenderLog.write('inquiry_form_submit_error', e.toString().substring(0, 40));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Submission failed. Please try again.'),
            backgroundColor: Color(0xFFDC2626),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  bool get _canSubmit {
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    if (unanswered.isEmpty) return false;
    return unanswered.every(
        (i) => _selections.containsKey((i['inquiry_id'] as num).toInt()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                        color: _kGreen, strokeWidth: 2.5))
                : _error != null
                    ? _buildError()
                    : _buildForm(),
          ),
        ),
      ),
    );
  }

  Widget _buildError() {
    final isExpired = _error == 'expired';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                isExpired
                    ? Icons.timer_off_outlined
                    : Icons.link_off_outlined,
                size: 36,
                color: const Color(0xFF9CA3AF),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isExpired
                  ? 'This inquiry link has expired'
                  : 'This link is no longer valid',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              isExpired
                  ? 'Please contact mediBO for a new link.'
                  : 'Please contact mediBO for assistance.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            Image.network(
              'https://medibo.in/icons/Icon-192.png',
              width: 48,
              height: 48,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    final locked = _items.where((i) => i['locked'] == true).toList();
    final unanswered = _items.where((i) => i['locked'] == false).toList();
    final allDone = unanswered.isEmpty && _items.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 48),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ───────────────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kGreen,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.medication_outlined,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'mediBO · Stock Check',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _supplierName ?? '',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          // ── New items banner ─────────────────────────────────────────────
          if (_newItemsAdded) ...[
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFFBEB),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFCD34D)),
              ),
              child: const Row(children: [
                Icon(Icons.info_outline,
                    size: 16, color: Color(0xFFD97706)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'New items added — please respond below',
                    style:
                        TextStyle(fontSize: 13, color: Color(0xFF92400E)),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],

          // ── All done banner ──────────────────────────────────────────────
          if (allDone) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: const Color(0xFFECFDF5),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF6EE7B7)),
              ),
              child: const Row(children: [
                Icon(Icons.check_circle_outline,
                    color: _kGreen, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'All responses submitted. Thank you!',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _kGreen),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
          ],

          // ── Already Responded — collapsed dropdown (shown before pending) ─
          if (locked.isNotEmpty) ...[
            GestureDetector(
              onTap: () => setState(
                  () => _respondedExpanded = !_respondedExpanded),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF9FAFB),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                child: Row(children: [
                  const Icon(Icons.check_circle_outline,
                      size: 16, color: Color(0xFF6B7280)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Already Responded (${locked.length})',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  Builder(builder: (ctx) {
                    RenderLog.write(
                        'inquiry_form_responded_dropdown_collapsed',
                        _respondedExpanded ? 'expanded' : 'collapsed');
                    return Icon(
                      _respondedExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: const Color(0xFF9CA3AF),
                    );
                  }),
                ]),
              ),
            ),
            if (_respondedExpanded) ...[
              const SizedBox(height: 8),
              ...locked.map(_buildLockedItem),
            ],
            const SizedBox(height: 16),
          ],

          // ── Pending items — shown AFTER the collapsed responded section ──
          if (unanswered.isNotEmpty) ...[
            const Text(
              'PENDING RESPONSE — REQUIRED',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: Color(0xFF374151),
                letterSpacing: 1.0,
              ),
            ),
            const SizedBox(height: 8),
            ...unanswered.map(_buildAnswerItem),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: (_canSubmit && !_submitting) ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  disabledBackgroundColor: const Color(0xFFD1FAE5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text(
                        'Submit Responses',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white),
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                'All fields are required before submitting',
                style: TextStyle(
                    fontSize: 12,
                    color: _canSubmit
                        ? const Color(0xFF9CA3AF)
                        : const Color(0xFFDC2626)),
              ),
            ),
          ],

          const SizedBox(height: 32),
          Center(
            child: Text(
              'mediBO · Powered by mediBO B2B Pharmacy',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLockedItem(Map<String, dynamic> item) {
    final answer = item['answer'] as String? ?? '';
    final imageUrl = item['image_url'] as String?;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildProductImage(imageUrl, size: 56, locked: true),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: _buildProductInfo(item, locked: true)),
              const SizedBox(width: 8),
              const Icon(Icons.lock_outline,
                  size: 14, color: Color(0xFFD1D5DB)),
            ]),
            const SizedBox(height: 10),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _answerColor(answer).withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                answer,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: _answerColor(answer),
                ),
              ),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _buildAnswerItem(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    final hasSelection = _selections.containsKey(id);
    final imageUrl = item['image_url'] as String?;
    return Builder(builder: (ctx) {
      RenderLog.write('inquiry_form_item_card_4line', 'true');
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: hasSelection ? _kGreen : const Color(0xFFE5E7EB),
            width: hasSelection ? 1.5 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Cart-style: image left + 4-line info right
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
              _buildProductImage(imageUrl, size: 72, locked: false),
              const SizedBox(width: 12),
              Expanded(
                  child: _buildProductInfo(item, locked: false)),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          // 3 answer buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              children:
                  _kAnswers.map((ans) => _buildAnswerButton(id, ans)).toList(),
            ),
          ),
        ]),
      );
    });
  }

  Widget _buildProductImage(String? imageUrl,
      {required double size, required bool locked}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl != null && imageUrl.isNotEmpty
          ? Image.network(
              imageUrl,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => _placeholderIcon(size),
            )
          : _placeholderIcon(size),
    );
  }

  Widget _placeholderIcon(double containerSize) {
    return Center(
      child: Icon(Icons.medication_outlined,
          size: containerSize * 0.45, color: const Color(0xFFD1D5DB)),
    );
  }

  Widget _buildProductInfo(Map<String, dynamic> item,
      {required bool locked}) {
    final textColor =
        locked ? const Color(0xFF9CA3AF) : const Color(0xFF111827);
    final subColor =
        locked ? const Color(0xFFD1D5DB) : const Color(0xFF6B7280);
    final productName = item['product_name'] as String? ?? '';
    final packSize = item['pack_size'] as String?;
    final therapeuticClass = item['therapeutic_class'] as String?;
    final company = item['company'] as String?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        productName,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: textColor,
          height: 1.3,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      if (packSize != null && packSize.isNotEmpty) ...[
        const SizedBox(height: 3),
        Text(packSize,
            style: TextStyle(fontSize: 12, color: subColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
      if (therapeuticClass != null && therapeuticClass.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(therapeuticClass,
            style: TextStyle(fontSize: 12, color: subColor),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
      if (company != null && company.isNotEmpty) ...[
        const SizedBox(height: 2),
        Text(company,
            style: TextStyle(
                fontSize: 12,
                color: subColor,
                fontStyle: FontStyle.italic),
            maxLines: 1,
            overflow: TextOverflow.ellipsis),
      ],
    ]);
  }

  Widget _buildAnswerButton(int inquiryId, String answer) {
    final selected = _selections[inquiryId] == answer;
    return GestureDetector(
      onTap: () => setState(() => _selections[inquiryId] = answer),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFECFDF5)
              : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _kGreen : const Color(0xFFE5E7EB),
            width: selected ? 1.5 : 1.0,
          ),
        ),
        child: Row(children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? _kGreen : const Color(0xFFD1D5DB),
                width: 2,
              ),
              color: selected ? _kGreen : Colors.white,
            ),
            child: selected
                ? const Center(
                    child: Icon(Icons.check,
                        size: 12, color: Colors.white))
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              answer,
              style: TextStyle(
                fontSize: 14,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400,
                color:
                    selected ? _kGreen : const Color(0xFF374151),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Color _answerColor(String answer) {
    switch (answer) {
      case 'Available':
        return _kGreen;
      case 'Out of Stock':
        return const Color(0xFFDC2626);
      default:
        return const Color(0xFF6B7280);
    }
  }
}
