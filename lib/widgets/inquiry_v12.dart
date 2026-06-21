import 'dart:async';
import 'package:flutter/material.dart';
import '../utils/render_log.dart';

// ── Category → color map ──────────────────────────────────────────────────────

const Map<String, List<Color>> _kClassColors = {
  'CARDIAC':            [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'NEURO CNS':          [Color(0xFFEEEDFE), Color(0xFF534AB7)],
  'GASTRO INTESTINAL':  [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
  'ANTI INFECTIVES':    [Color(0xFFE6F1FB), Color(0xFF0C447C)],
  'PAIN ANALGESICS':    [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'DERMA':              [Color(0xFFFBEAF0), Color(0xFF993556)],
  'GYNAECOLOGICAL':     [Color(0xFFFBEAF0), Color(0xFF993556)],
  'RESPIRATORY':        [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
};
const _kDefaultClassBg = Color(0xFFF1EFE8);
const _kDefaultClassFg = Color(0xFF2C2C2A);

// ── Chip specs (fixed order: Don't stock / Out of stock / Available) ──────────

class _ChipSpec {
  final String label;
  final String answer;
  final IconData icon;
  final Color selBg;
  final Color selBorder;
  final Color selText;
  const _ChipSpec({
    required this.label,
    required this.answer,
    required this.icon,
    required this.selBg,
    required this.selBorder,
    required this.selText,
  });
}

const _kChips = [
  _ChipSpec(
    label: "Don't stock",
    answer: "We don't stock this product",
    icon: Icons.do_not_disturb_on_outlined,
    selBg: Color(0xFFF1EFE8),
    selBorder: Color(0xFFB4B2A9),
    selText: Color(0xFF444441),
  ),
  _ChipSpec(
    label: 'Out of stock',
    answer: 'Out of Stock',
    icon: Icons.close,
    selBg: Color(0xFFFAECE7),
    selBorder: Color(0xFFF0997B),
    selText: Color(0xFF993C1D),
  ),
  _ChipSpec(
    label: 'Available',
    answer: 'Available',
    icon: Icons.check,
    selBg: Color(0xFFE1F5EE),
    selBorder: Color(0xFF5DCAA5),
    selText: Color(0xFF0F6E56),
  ),
];

const _kWideBreakpoint = 500.0;

// ── Public widget ─────────────────────────────────────────────────────────────

/// Shared inquiry item list for all three surfaces (admin, token link, supplier).
///
/// Items are sorted company→category→product_name A→Z and rendered as a clean
/// flat list — no toggle, no company/category group headers. The per-card
/// category chip and company name make headers redundant.
///
/// onBulkCompanyCategory: bulk RPC for (company, category) — returns marked
///   count on success, null on error.
/// surface: 'admin' | 'link' | 'supplier' — for render-log.
class InquiryAnswerList extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, String> answerOverrides;
  final void Function(int inquiryId, String answer) onAnswer;
  final void Function(List<int> ids, String answer)? onBulk;
  final Future<int?> Function(String company, String category)?
      onBulkCompanyCategory;
  final Set<int> answeringIds;
  final bool readOnly;
  final Widget Function(Map<String, dynamic> item)? itemTrailingWidget;
  final String? surface;

  const InquiryAnswerList({
    super.key,
    required this.items,
    this.answerOverrides = const {},
    required this.onAnswer,
    this.onBulk,
    this.onBulkCompanyCategory,
    this.answeringIds = const {},
    this.readOnly = false,
    this.itemTrailingWidget,
    this.surface,
  });

  @override
  State<InquiryAnswerList> createState() => _InquiryAnswerListState();
}

class _InquiryAnswerListState extends State<InquiryAnswerList> {
  final Set<String> _bulkingCatKeys = {}; // "$company|$category" in-flight
  OverlayEntry? _popupEntry;
  Timer? _popupTimer;

  static int _popupShownCount = 0;
  static int _bulkCalledCount = 0;

  final Map<int, GlobalKey> _dontStockKeys = {};
  GlobalKey _dontStockKey(int id) =>
      _dontStockKeys.putIfAbsent(id, () => GlobalKey());

  @override
  void dispose() {
    _closePopup();
    super.dispose();
  }

  // ── Grouping: company → category → items, all A→Z ─────────────────────────

  Map<String, Map<String, List<Map<String, dynamic>>>> _nestedGrouped() {
    final raw = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final item in widget.items) {
      final comp = (item['company'] as String? ?? '').trim();
      final compKey = comp.isEmpty ? 'Other' : comp;
      final cat = (item['therapeutic_class'] as String? ?? '').trim();
      final catKey = cat.isEmpty ? 'Uncategorised' : cat.toUpperCase();
      ((raw[compKey] ??= {})[catKey] ??= []).add(item);
    }
    final sortedComp = raw.keys.toList()..sort();
    final result = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final comp in sortedComp) {
      final cats = raw[comp]!;
      final sortedCats = cats.keys.toList()..sort();
      final out = <String, List<Map<String, dynamic>>>{};
      for (final cat in sortedCats) {
        out[cat] = cats[cat]!
          ..sort((a, b) =>
              (a['product_name'] as String? ?? '')
                  .compareTo(b['product_name'] as String? ?? ''));
      }
      result[comp] = out;
    }
    return result;
  }

  bool _isLocked(Map<String, dynamic> item) {
    if (widget.readOnly) return true;
    if (item['locked'] == true) return true;
    if (item['answered'] == true) return true;
    return false;
  }

  bool _noSupplier(Map<String, dynamic> item) {
    final slot = (item['slot_index'] as num?)?.toInt() ?? -1;
    final role = item['role'] as String? ?? '';
    return slot == 0 || role == 'none' || role == 'no_supplier';
  }

  String? _currentAnswer(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    return widget.answerOverrides[id] ?? item['answer'] as String?;
  }

  // ── Popup (bottom-center toast) ────────────────────────────────────────────

  void _closePopup() {
    _popupTimer?.cancel();
    _popupTimer = null;
    _popupEntry?.remove();
    _popupEntry = null;
  }

  void _handleDontStockTap(int id, Map<String, dynamic> item,
      {GlobalKey? buttonKey}) {
    widget.onAnswer(id, "We don't stock this product");

    final company = (item['company'] as String? ?? '').trim();
    final category = (item['therapeutic_class'] as String? ?? '').trim();

    RenderLog.write('dontstock.tap', '$id:$category|$company');

    if (company.isEmpty && category.isEmpty) return;
    if (widget.onBulkCompanyCategory == null) return;

    _closePopup();
    _popupShownCount++;
    RenderLog.write('inq_dontstock_popup_shown', _popupShownCount);
    RenderLog.write('inq_dontstock_popup_compact', 1);

    // Responsive: anchored above button on desktop (>600px), bottom-center on mobile.
    final isWide = MediaQuery.of(context).size.width > 600;
    if (isWide && buttonKey != null) {
      _showAnchoredPopup(buttonKey, id, company, category);
    } else {
      RenderLog.write('inq_popup_anchor', 'bottom_center');
      final overlay = Overlay.of(context, rootOverlay: true);
      _popupEntry = OverlayEntry(
        builder: (_) => _InqDontStockToast(
          company: company,
          category: category,
          hasBulk: true,
          onMarkAll: () => _doBulkCompanyCategory(company, category),
          onDismiss: _closePopup,
        ),
      );
      overlay.insert(_popupEntry!);
      _popupTimer = Timer(const Duration(seconds: 5), _closePopup);
    }
  }

  void _showAnchoredPopup(
      GlobalKey buttonKey, int id, String company, String category) {
    final ctx = buttonKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final buttonTopLeft = box.localToGlobal(Offset.zero);
    final buttonSize = box.size;
    final screenSize = MediaQuery.of(context).size;
    final safeTop = MediaQuery.of(context).padding.top;

    const estimatedPopupHeight = 120.0;
    const popupGap = 8.0;
    const screenPad = 8.0;
    const popupMaxW = 320.0;

    final popupW =
        popupMaxW < screenSize.width - screenPad * 2
            ? popupMaxW
            : screenSize.width - screenPad * 2;

    var popupX =
        buttonTopLeft.dx + (buttonSize.width - popupW) / 2;
    if (popupX < screenPad) popupX = screenPad;
    if (popupX + popupW > screenSize.width - screenPad) {
      popupX = screenSize.width - popupW - screenPad;
    }

    final fitsAbove =
        (buttonTopLeft.dy - estimatedPopupHeight - popupGap) >
            (safeTop + screenPad);
    final popupTop = fitsAbove
        ? buttonTopLeft.dy - estimatedPopupHeight - popupGap
        : buttonTopLeft.dy + buttonSize.height + popupGap;
    final anchorSide = fitsAbove ? 'above' : 'below';

    RenderLog.write('popup.anchor', '$anchorSide:$id');
    RenderLog.write('inq_popup_anchor', '$anchorSide:$id');

    final overlay = Overlay.of(context, rootOverlay: true);
    _popupEntry = OverlayEntry(
      builder: (_) => _InqDontStockAnchoredPopup(
        popupLeft: popupX,
        popupTop: popupTop,
        popupWidth: popupW,
        company: company,
        category: category,
        onMarkAll: () => _doBulkCompanyCategory(company, category),
        onDismiss: _closePopup,
      ),
    );
    overlay.insert(_popupEntry!);
  }

  Future<void> _doBulkCompanyCategory(
      String company, String category) async {
    _closePopup();
    if (widget.onBulkCompanyCategory == null) return;

    final catKey = '$company|$category';
    if (mounted) setState(() => _bulkingCatKeys.add(catKey));

    try {
      final marked =
          await widget.onBulkCompanyCategory!(company, category);
      _bulkCalledCount++;
      RenderLog.write('inq_bulk_dontstock_called', _bulkCalledCount);
      if (marked != null) {
        RenderLog.write('inq_bulk_last_marked', marked);
        RenderLog.write('bulk.yesall', '$company|$category:$marked');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Marked $marked item${marked == 1 ? '' : 's'} as don\'t stock'),
            backgroundColor: const Color(0xFF1B7A43),
            duration: const Duration(seconds: 3),
          ));
        }
      } else {
        RenderLog.write('bulk.error', 'rpc_returned_null:$company|$category');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not mark — please try again'),
            backgroundColor: Color(0xFFDC2626),
            duration: Duration(seconds: 3),
          ));
        }
      }
    } catch (e) {
      RenderLog.write('bulk.error', e.toString().length > 80
          ? e.toString().substring(0, 80)
          : e.toString());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: $e'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 3),
        ));
      }
    } finally {
      if (mounted) setState(() => _bulkingCatKeys.remove(catKey));
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    RenderLog.write('inq_flat_list', 1);
    RenderLog.write('inq_toggle_removed', 1);
    RenderLog.write('inq_company_header_removed', 1);
    RenderLog.write('inq_category_header_removed', 1);
    RenderLog.write('headerlinks.count', 0);

    final surf = widget.surface;
    if (surf == 'admin') RenderLog.write('inq_surface_admin_grouped', 1);
    if (surf == 'link') RenderLog.write('inq_surface_link_grouped', 1);
    if (surf == 'supplier') RenderLog.write('inq_surface_supplier_grouped', 1);

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= _kWideBreakpoint;
      final nested = _nestedGrouped();

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final compEntry in nested.entries)
            for (final catEntry in compEntry.value.entries) ...[
              ...catEntry.value
                  .map((item) => _buildItemCard(item, isWide)),
              const SizedBox(height: 4),
            ],
        ],
      );
    });
  }

  // ── Item card dispatcher ───────────────────────────────────────────────────

  Widget _buildItemCard(Map<String, dynamic> item, bool isWide) {
    if (isWide) {
      RenderLog.write('inquiry_v12_web_row', 'true');
      return _buildWideCard(item);
    } else {
      RenderLog.write('inquiry_v12_mobile_stack', 'true');
      return _buildNarrowCard(item);
    }
  }

  // ── Wide card ─────────────────────────────────────────────────────────────

  Widget _buildWideCard(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    final productName = (item['product_name'] as String? ?? '').trim();
    final tc = (item['therapeutic_class'] as String? ?? '').trim();
    final company = (item['company'] as String? ?? '').trim();
    final imageUrl = item['image_url'] as String?;
    final locked = _isLocked(item);
    final noSup = !locked && _noSupplier(item);
    final isAnswering = widget.answeringIds.contains(id);
    final currentAnswer = _currentAnswer(item);
    final trailing = !locked ? widget.itemTrailingWidget?.call(item) : null;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _buildImageTile(imageUrl, 72, locked: locked),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        productName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: locked
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF111827),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (tc.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        _buildClassPill(tc),
                      ],
                      if (company.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          company,
                          style: TextStyle(
                            fontSize: 13,
                            color: locked
                                ? const Color(0xFFD1D5DB)
                                : const Color(0xFF6B7280),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                if (locked &&
                    currentAnswer != null &&
                    currentAnswer.isNotEmpty)
                  Row(children: [
                    _buildReadOnlyPill(currentAnswer),
                    const SizedBox(width: 6),
                    const Icon(Icons.lock_outline,
                        size: 14, color: Color(0xFFD1D5DB)),
                  ])
                else if (locked)
                  const SizedBox.shrink()
                else if (noSup)
                  _buildNoSupplierLabel()
                else if (isAnswering)
                  const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Color(0xFF1B7A43)),
                  )
                else
                  _buildWideChips(id, currentAnswer, item),
              ],
            ),
          ),
          if (trailing != null) ...[
            const Divider(height: 1, color: Color(0xFFF3F4F6)),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: trailing,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildWideChips(
      int id, String? currentAnswer, Map<String, dynamic> item) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_kChips.length, (i) {
        final chip = _kChips[i];
        final selected = currentAnswer == chip.answer;
        final isDontStock = chip.answer == "We don't stock this product";
        final dsKey = isDontStock ? _dontStockKey(id) : null;
        return Padding(
          padding: EdgeInsets.only(left: i > 0 ? 8 : 0),
          child: GestureDetector(
            key: dsKey,
            onTap: isDontStock
                ? () => _handleDontStockTap(id, item, buttonKey: dsKey)
                : () => widget.onAnswer(id, chip.answer),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: 90,
              padding: const EdgeInsets.symmetric(vertical: 9),
              decoration: BoxDecoration(
                color: selected ? chip.selBg : Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected
                      ? chip.selBorder
                      : const Color(0xFFE5E7EB),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(chip.icon,
                      size: 14,
                      color: selected
                          ? chip.selText
                          : const Color(0xFF6B7280)),
                  const SizedBox(width: 5),
                  Text(chip.label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: selected
                              ? chip.selText
                              : const Color(0xFF6B7280))),
                ],
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Narrow card ───────────────────────────────────────────────────────────

  Widget _buildNarrowCard(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    final productName = (item['product_name'] as String? ?? '').trim();
    final tc = (item['therapeutic_class'] as String? ?? '').trim();
    final company = (item['company'] as String? ?? '').trim();
    final imageUrl = item['image_url'] as String?;
    final locked = _isLocked(item);
    final noSup = !locked && _noSupplier(item);
    final isAnswering = widget.answeringIds.contains(id);
    final currentAnswer = _currentAnswer(item);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImageTile(imageUrl, 88, locked: locked),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        productName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: locked
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF111827),
                          height: 1.3,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (tc.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildClassPill(tc),
                      ],
                      if (company.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          company,
                          style: TextStyle(
                            fontSize: 13,
                            color: locked
                                ? const Color(0xFFD1D5DB)
                                : const Color(0xFF6B7280),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      if (locked) ...[
                        const SizedBox(height: 6),
                        Row(children: [
                          const Icon(Icons.lock_outline,
                              size: 13, color: Color(0xFFD1D5DB)),
                          if (currentAnswer != null &&
                              currentAnswer.isNotEmpty) ...[
                            const SizedBox(width: 5),
                            _buildReadOnlyPill(currentAnswer),
                          ],
                        ]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (!locked) ...[
              const SizedBox(height: 12),
              if (noSup)
                _buildNoSupplierLabel()
              else if (isAnswering)
                const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Color(0xFF1B7A43)),
                )
              else
                _buildNarrowChips(id, currentAnswer, item),
              if (widget.itemTrailingWidget != null) ...[
                const SizedBox(height: 10),
                widget.itemTrailingWidget!.call(item),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNarrowChips(
      int id, String? currentAnswer, Map<String, dynamic> item) {
    return Row(
      children: List.generate(_kChips.length, (i) {
        final chip = _kChips[i];
        final selected = currentAnswer == chip.answer;
        final isDontStock = chip.answer == "We don't stock this product";
        final dsKey = isDontStock ? _dontStockKey(id) : null;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
                right: i < _kChips.length - 1 ? 8 : 0),
            child: GestureDetector(
              key: dsKey,
              onTap: isDontStock
                  ? () => _handleDontStockTap(id, item, buttonKey: dsKey)
                  : () => widget.onAnswer(id, chip.answer),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? chip.selBg : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? chip.selBorder
                        : const Color(0xFFE5E7EB),
                    width: 0.5,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(chip.icon,
                        size: 18,
                        color: selected
                            ? chip.selText
                            : const Color(0xFF6B7280)),
                    const SizedBox(height: 4),
                    Text(
                      chip.label,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: selected
                              ? chip.selText
                              : const Color(0xFF6B7280)),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  // ── Shared helpers ─────────────────────────────────────────────────────────

  Widget _buildImageTile(String? imageUrl, double size,
      {required bool locked}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: imageUrl != null && imageUrl.isNotEmpty
          ? Image.network(imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder())
          : _placeholder(),
    );
  }

  Widget _placeholder() => const Center(
        child: Icon(Icons.medication_outlined,
            size: 32, color: Color(0xFFD1D5DB)),
      );

  Widget _buildClassPill(String cls) {
    final upper = cls.toUpperCase();
    Color? bg;
    Color? fg;
    for (final entry in _kClassColors.entries) {
      if (upper.contains(entry.key) || entry.key.contains(upper)) {
        bg = entry.value[0];
        fg = entry.value[1];
        break;
      }
    }
    bg ??= _kDefaultClassBg;
    fg ??= _kDefaultClassFg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(cls,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w500, color: fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
    );
  }

  Widget _buildReadOnlyPill(String answer) {
    final Color bg;
    final Color fg;
    if (answer == 'Available') {
      bg = const Color(0xFFE1F5EE);
      fg = const Color(0xFF0F6E56);
    } else if (answer == 'Out of Stock') {
      bg = const Color(0xFFFAECE7);
      fg = const Color(0xFF993C1D);
    } else {
      bg = const Color(0xFFF1EFE8);
      fg = const Color(0xFF444441);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(answer,
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: fg),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
    );
  }

  Widget _buildNoSupplierLabel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFD1D5DB)),
      ),
      child: const Text('No supplier available',
          style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Color(0xFF6B7280))),
    );
  }
}

// ── Shared popup text helper ──────────────────────────────────────────────────

String _dontStockPopupText(String category, String company) {
  final cat = category;
  final raw = company;
  final comp = raw.length > 18 ? '${raw.substring(0, 18)}…' : raw;
  if (cat.isNotEmpty && comp.isNotEmpty) {
    return 'Also mark all $cat from $comp as "Don\'t stock"?';
  }
  if (cat.isNotEmpty) return 'Also mark all $cat as "Don\'t stock"?';
  if (comp.isNotEmpty) return 'Also mark all from $comp as "Don\'t stock"?';
  return 'Also mark all as "Don\'t stock"?';
}

// ── Anchored "Don't stock all" popup (desktop) ────────────────────────────────

class _InqDontStockAnchoredPopup extends StatelessWidget {
  final double popupLeft;
  final double popupTop;
  final double popupWidth;
  final String company;
  final String category;
  final VoidCallback onMarkAll;
  final VoidCallback onDismiss;

  const _InqDontStockAnchoredPopup({
    required this.popupLeft,
    required this.popupTop,
    required this.popupWidth,
    required this.company,
    required this.category,
    required this.onMarkAll,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final text = _dontStockPopupText(category, company);
    return Stack(
      children: [
        // Transparent barrier — tap outside dismisses
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
          ),
        ),
        // Anchored popup box
        Positioned(
          left: popupLeft,
          top: popupTop,
          width: popupWidth,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: const Color(0xFFE5E7EB), width: 1),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    text,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF111827),
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      GestureDetector(
                        onTap: onDismiss,
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(Icons.close,
                              size: 16, color: Color(0xFF9CA3AF)),
                        ),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: onMarkAll,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B7A43),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text(
                            'Mark all',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Bottom-center "Don't stock all" toast ─────────────────────────────────────

class _InqDontStockToast extends StatefulWidget {
  final String company;
  final String category;
  final bool hasBulk;
  final VoidCallback onMarkAll;
  final VoidCallback onDismiss;

  const _InqDontStockToast({
    required this.company,
    required this.category,
    required this.hasBulk,
    required this.onMarkAll,
    required this.onDismiss,
  });

  @override
  State<_InqDontStockToast> createState() => _InqDontStockToastState();
}

class _InqDontStockToastState extends State<_InqDontStockToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 200));
    _fade =
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
            begin: const Offset(0, 0.4), end: Offset.zero)
        .animate(
            CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _dontStockPopupText(widget.category, widget.company);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: FadeTransition(
                opacity: _fade,
                child: SlideTransition(
                  position: _slide,
                  child: Material(
                    color: Colors.transparent,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1F2937),
                          borderRadius: BorderRadius.circular(10),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.22),
                              blurRadius: 14,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                text,
                                style: const TextStyle(
                                    fontSize: 13,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                    height: 1.35),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.hasBulk) ...[
                              const SizedBox(width: 10),
                              GestureDetector(
                                onTap: widget.onMarkAll,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 7),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1B7A43),
                                    borderRadius:
                                        BorderRadius.circular(7),
                                  ),
                                  child: const Text('Mark all',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.white,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: widget.onDismiss,
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(Icons.close,
                                    size: 16,
                                    color: Color(0xFFD1D5DB)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
