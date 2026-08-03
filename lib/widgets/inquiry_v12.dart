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

// #112: WIDE only when content area >= 960px.
// At 960px viewport, admin gets 872px and supplier gets 920px — both < 960 → narrow.
// At 1280px, both surfaces get > 1000px → wide.
const _kWideBreakpoint = 960.0;

// ── Public widget ─────────────────────────────────────────────────────────────

/// Shared inquiry item list for all three surfaces (admin, token link, supplier).
///
/// Items are rendered in the exact order they arrive from the backend
/// (inquiry.id DESC — the single source of truth) as a clean flat list — no
/// toggle, no company/category group headers, no client-side re-sort. The
/// per-card category chip and company name make headers redundant.
///
/// onBulkCompanyCategory: bulk RPC for (company, category) — returns marked
///   count on success, null on error.
/// surface: 'admin' | 'link' | 'supplier' — for render-log.
class InquiryAnswerList extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, String> answerOverrides;
  final void Function(int inquiryId, String answer) onAnswer;
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

  @override
  void dispose() {
    super.dispose();
  }

  // ── Company/category keys (for slim-row bulk action grouping only —
  // counts items per company+category without touching render order) ───────

  (String, String) _groupKeyFor(Map<String, dynamic> item) {
    final comp = (item['company'] as String? ?? '').trim();
    final compKey = comp.isEmpty ? 'Other' : comp;
    final cat = (item['therapeutic_class'] as String? ?? '').trim();
    final catKey = cat.isEmpty ? 'Uncategorised' : cat.toUpperCase();
    return (compKey, catKey);
  }

  Map<(String, String), int> _groupCounts() {
    final counts = <(String, String), int>{};
    for (final item in widget.items) {
      final key = _groupKeyFor(item);
      counts[key] = (counts[key] ?? 0) + 1;
    }
    return counts;
  }

  /// CHANGE #574 — `readOnly` is this widget's own display mode, so it stays
  /// here. Whether the ITEM is locked is the backend's answer, read from the
  /// `flags` block every inquiry source now emits.
  bool _isLocked(Map<String, dynamic> item) {
    if (widget.readOnly) return true;
    return _flag(item, 'is_locked');
  }

  /// CHANGE #574 — was: `slot == 0 || role == 'none' || role == 'no_supplier'`,
  /// written identically in three files that had already drifted apart
  /// (`== 0` here, `<= 0` in admin_supplier_screen). One rule now lives in
  /// inquiry_item_flags() in Postgres and every surface reads the same answer.
  bool _noSupplier(Map<String, dynamic> item) => _flag(item, 'no_supplier');

  /// Reads one boolean out of the backend's `flags` block. A missing block
  /// means the row did not come from a converted RPC; false is the safe read
  /// (nothing is hidden or disabled on the strength of an absent answer).
  bool _flag(Map<String, dynamic> item, String key) {
    final f = item['flags'];
    return f is Map && f[key] == true;
  }

  /// CHANGE #639 — three sources, in falling priority, and none of them is a
  /// guess made here:
  ///   1. the user's own tap this session (answerOverrides)
  ///   2. `answer` — what this supplier already submitted
  ///   3. `prestate` — the backend's auto-tick: "your zone state already says
  ///      Available for this item", so the chip arrives SELECTED.
  ///
  /// prestate only pre-selects; it never locks. The item is not `is_locked`,
  /// so its chips stay tappable and the supplier can overrule the tick. A null
  /// prestate means nothing is selected and the supplier answers manually.
  String? _currentAnswer(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    final override = widget.answerOverrides[id];
    if (override != null) return override;
    final answered = item['answer'] as String?;
    if (answered != null && answered.isNotEmpty) return answered;
    final pre = item['prestate'] as String?;
    if (pre != null && pre.isNotEmpty) return pre;
    return null;
  }

  // ── Popup (bottom-center toast) ────────────────────────────────────────────

  // Slim row: call bulk callback, show snackbar result.
  Future<void> _doBulkCompanyCategory(String company, String category) async {
    if (widget.onBulkCompanyCategory == null) return;
    final catKey = '$company|$category';
    if (mounted) setState(() => _bulkingCatKeys.add(catKey));
    try {
      final marked = await widget.onBulkCompanyCategory!(company, category);
      if (marked != null && mounted) {
        RenderLog.write('inq_slim_bulk_marked', '$company|$category:$marked');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text("Marked $marked item${marked == 1 ? '' : 's'} as don't stock"),
          backgroundColor: const Color(0xFF1B7A43),
          duration: const Duration(seconds: 3),
        ));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not mark — please try again'),
          backgroundColor: Color(0xFFDC2626),
          duration: Duration(seconds: 3),
        ));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Error — please try again'),
          backgroundColor: Color(0xFFDC2626),
          duration: Duration(seconds: 3),
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
    // #599 — no branch on the surface word; log it as data.
    RenderLog.write('inq_surface_grouped', surf);


    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= _kWideBreakpoint;
      final counts = _groupCounts();

      final showSlim = !widget.readOnly && widget.onBulkCompanyCategory != null;
      final seenGroupKeys = <(String, String)>{};
      int slimRowCount = 0;
      final children = <Widget>[];
      // Render items in exactly the order received from the backend
      // (inquiry.id DESC) — no sort, no grouping-induced reordering.
      for (final item in widget.items) {
        final key = _groupKeyFor(item);
        if (showSlim && (counts[key] ?? 0) > 3 && seenGroupKeys.add(key)) {
          children.add(_buildSlimRow(key.$1, key.$2));
          slimRowCount++;
        }
        children.add(_buildItemCard(item, isWide));
      }
      if (children.isNotEmpty) children.add(const SizedBox(height: 4));
      RenderLog.write('inq_slim_rows', slimRowCount);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: children,
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
    final inquiryCode = (item['inquiry_code'] as String? ?? '').trim();
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
                      if (inquiryCode.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Builder(builder: (_) {
                          RenderLog.write('c317_inquiry_id_shown', inquiryCode);
                          return Text(
                            inquiryCode,
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF9CA3AF),
                              letterSpacing: 0.3,
                            ),
                          );
                        }),
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
        return Padding(
          padding: EdgeInsets.only(left: i > 0 ? 8 : 0),
          child: GestureDetector(
            onTap: () => widget.onAnswer(id, chip.answer),
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
    final inquiryCode = (item['inquiry_code'] as String? ?? '').trim();
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
                      if (inquiryCode.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          inquiryCode,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            color: Color(0xFF9CA3AF),
                            letterSpacing: 0.3,
                          ),
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
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
                right: i < _kChips.length - 1 ? 8 : 0),
            child: GestureDetector(
              onTap: () => widget.onAnswer(id, chip.answer),
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

  Widget _buildSlimRow(String company, String category) {
    final compDisplay = company.length > 22 ? '${company.substring(0, 22)}…' : company;
    final catDisplay = category.length > 16 ? '${category.substring(0, 16)}…' : category;
    final catKey = '$company|$category';
    final isBulking = _bulkingCatKeys.contains(catKey);
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFD1FAE5)),
      ),
      child: Row(children: [
        Expanded(
          child: Text(
            "I don't stock $catDisplay from $compDisplay",
            style: const TextStyle(fontSize: 12, color: Color(0xFF065F46), fontWeight: FontWeight.w500),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: isBulking ? null : () => _doBulkCompanyCategory(company, category),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: isBulking ? const Color(0xFF6B7280) : const Color(0xFF1B7A43),
              borderRadius: BorderRadius.circular(6),
            ),
            child: isBulking
                ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                : Text("Don't stock $catDisplay",
                    style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ),
      ]),
    );
  }
}
