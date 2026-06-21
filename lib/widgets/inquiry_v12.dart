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

/// Design v12 shared inquiry item list used across all three inquiry surfaces.
///
/// Default view: nested Company → Category grouping.
/// Toggle allows switching to flat Category grouping.
///
/// onBulkCompanyCategory: called for per-category "Don't stock all" and popup
///   "Mark all" — returns marked count on success, null on error.
/// surface: 'admin' | 'link' | 'supplier' — for render-log instrumentation.
class InquiryAnswerList extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, String> answerOverrides;
  final void Function(int inquiryId, String answer) onAnswer;
  final void Function(List<int> ids, String answer)? onBulk;
  final Future<int?> Function(String company, String category)? onBulkCompanyCategory;
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
  String _groupBy = 'company'; // default: nested Company → Category
  final Set<String> _bulkGroups = {}; // for flat category toggle
  final Set<String> _bulkingCatKeys = {}; // "$company|$category" in-flight
  final Map<int, LayerLink> _dontStockLinks = {};
  OverlayEntry? _popupEntry;
  Timer? _popupTimer;

  // Global counters for render-log (persist across rebuild)
  static int _popupShownCount = 0;
  static int _bulkCalledCount = 0;

  @override
  void dispose() {
    _closePopup();
    super.dispose();
  }

  LayerLink _getDontStockLink(int id) =>
      _dontStockLinks.putIfAbsent(id, LayerLink.new);

  // ── Grouping helpers ───────────────────────────────────────────────────────

  String _flatGroupKey(Map<String, dynamic> item) {
    final tc = (item['therapeutic_class'] as String? ?? '').trim();
    return tc.isEmpty ? 'Uncategorised' : tc.toUpperCase();
  }

  Map<String, List<Map<String, dynamic>>> _flatGrouped() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in widget.items) {
      (map[_flatGroupKey(item)] ??= []).add(item);
    }
    return map;
  }

  // Returns: company → (category → items), all sorted A→Z, items by product_name
  Map<String, Map<String, List<Map<String, dynamic>>>> _nestedGrouped() {
    final raw = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final item in widget.items) {
      final comp = (item['company'] as String? ?? '').trim();
      final compKey = comp.isEmpty ? 'Other' : comp;
      final cat = (item['therapeutic_class'] as String? ?? '').trim();
      final catKey = cat.isEmpty ? 'Uncategorised' : cat.toUpperCase();
      ((raw[compKey] ??= {})[catKey] ??= []).add(item);
    }
    final sortedCompanies = raw.keys.toList()..sort();
    final result = <String, Map<String, List<Map<String, dynamic>>>>{};
    for (final comp in sortedCompanies) {
      final cats = raw[comp]!;
      final sortedCats = cats.keys.toList()..sort();
      final sortedCatMap = <String, List<Map<String, dynamic>>>{};
      for (final cat in sortedCats) {
        final catItems = cats[cat]!
          ..sort((a, b) {
            final na = (a['product_name'] as String? ?? '');
            final nb = (b['product_name'] as String? ?? '');
            return na.compareTo(nb);
          });
        sortedCatMap[cat] = catItems;
      }
      result[comp] = sortedCatMap;
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

  // ── Popup management ───────────────────────────────────────────────────────

  void _closePopup() {
    _popupTimer?.cancel();
    _popupTimer = null;
    _popupEntry?.remove();
    _popupEntry = null;
  }

  void _handleDontStockTap(int id, Map<String, dynamic> item) {
    // C1(a): answer the item immediately
    widget.onAnswer(id, "We don't stock this product");

    // C1(b): show tiny popup above the chip
    final company = (item['company'] as String? ?? '').trim();
    final category = (item['therapeutic_class'] as String? ?? '').trim();

    _closePopup();
    _popupShownCount++;
    RenderLog.write('inq_dontstock_popup_shown', _popupShownCount);

    final link = _getDontStockLink(id);
    final overlay = Overlay.of(context, rootOverlay: true);
    _popupEntry = OverlayEntry(
      builder: (_) => _DontStockPopup(
        link: link,
        company: company,
        category: category,
        hasBulk: widget.onBulkCompanyCategory != null,
        onMarkAll: () => _doBulkCompanyCategory(company, category),
        onDismiss: _closePopup,
      ),
    );
    overlay.insert(_popupEntry!);
    _popupTimer = Timer(const Duration(seconds: 6), _closePopup);
  }

  Future<void> _doBulkCompanyCategory(String company, String category) async {
    _closePopup();
    if (widget.onBulkCompanyCategory == null) return;

    final catKey = '$company|$category';
    if (mounted) setState(() => _bulkingCatKeys.add(catKey));

    try {
      final marked = await widget.onBulkCompanyCategory!(company, category);
      _bulkCalledCount++;
      RenderLog.write('inq_bulk_dontstock_called', _bulkCalledCount);
      if (marked != null) {
        RenderLog.write('inq_bulk_last_marked', marked);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Marked $marked ${category.isNotEmpty ? category : "item"}${marked == 1 ? "" : "s"} as don\'t stock'),
            backgroundColor: const Color(0xFF1B7A43),
            duration: const Duration(seconds: 3),
          ));
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not mark items — please try again'),
            backgroundColor: Color(0xFFDC2626),
            duration: Duration(seconds: 3),
          ));
        }
      }
    } catch (e) {
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

  // Flat category "Don't stock all" handler (toggle)
  void _handleFlatBulkTap(
      String groupKey, List<Map<String, dynamic>> groupItems) {
    final ids = groupItems
        .where((i) => !_isLocked(i) && !_noSupplier(i))
        .map((i) => (i['inquiry_id'] as num).toInt())
        .toList();
    if (ids.isEmpty) return;

    final wasBulked = _bulkGroups.contains(groupKey);
    setState(() {
      if (wasBulked) {
        _bulkGroups.remove(groupKey);
      } else {
        _bulkGroups.add(groupKey);
      }
    });

    final answer = wasBulked ? '' : "We don't stock this product";
    if (widget.onBulk != null) {
      widget.onBulk!(ids, answer);
    } else if (!wasBulked) {
      for (final id in ids) {
        widget.onAnswer(id, answer);
      }
    }
    RenderLog.write('inquiry_v12_bulk_dontstock',
        '${wasBulked ? 'clear' : 'set'}:${ids.length}:$groupKey');
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    RenderLog.write('inq_group_mode', 'company_category');
    RenderLog.write('inquiry_v12_widget', _groupBy);

    // Surface-specific render-log
    final surf = widget.surface;
    if (surf == 'admin') RenderLog.write('inq_surface_admin_grouped', 1);
    if (surf == 'link') RenderLog.write('inq_surface_link_grouped', 1);
    if (surf == 'supplier') RenderLog.write('inq_surface_supplier_grouped', 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _kWideBreakpoint;

        if (_groupBy == 'company') {
          return _buildNestedCompanyView(isWide);
        } else {
          return _buildFlatCategoryView(isWide);
        }
      },
    );
  }

  // ── Nested Company → Category view ────────────────────────────────────────

  Widget _buildNestedCompanyView(bool isWide) {
    final nested = _nestedGrouped();
    final totalPending = widget.items
        .where((i) => !_isLocked(i) && !_noSupplier(i))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.readOnly) ...[
          _buildGroupToggle(totalPending),
          const SizedBox(height: 14),
        ],
        ...nested.entries.expand((compEntry) {
          final company = compEntry.key;
          final byCategory = compEntry.value;
          final allCompanyItems =
              byCategory.values.expand((x) => x).toList();
          final pendingCount = allCompanyItems
              .where((i) => !_isLocked(i) && !_noSupplier(i))
              .length;
          return [
            _buildCompanyHeader(company, allCompanyItems.length, pendingCount),
            const SizedBox(height: 6),
            ...byCategory.entries.expand((catEntry) {
              final category = catEntry.key;
              final catItems = catEntry.value;
              final catAnswerable = catItems
                  .where((i) => !_isLocked(i) && !_noSupplier(i))
                  .length;
              return [
                Padding(
                  padding: const EdgeInsets.only(left: 16),
                  child: _buildCategorySubHeader(
                      company, category, catItems.length, catAnswerable),
                ),
                const SizedBox(height: 6),
                ...catItems.map((item) => _buildItemCard(item, isWide)),
                const SizedBox(height: 8),
              ];
            }),
            const SizedBox(height: 10),
          ];
        }),
      ],
    );
  }

  Widget _buildCompanyHeader(String company, int total, int pending) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBBF7D0)),
      ),
      child: Row(children: [
        const Icon(Icons.store_outlined, size: 14, color: Color(0xFF0F6E56)),
        const SizedBox(width: 7),
        Expanded(
          child: RichText(
            text: TextSpan(children: [
              TextSpan(
                text: company,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF065F46)),
              ),
              TextSpan(
                text: '  ·  $total item${total == 1 ? '' : 's'}',
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFF0F6E56)),
              ),
              if (pending > 0)
                TextSpan(
                  text: '  ($pending pending)',
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280)),
                ),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _buildCategorySubHeader(
      String company, String category, int total, int answerable) {
    final catKey = '$company|$category';
    final inFlight = _bulkingCatKeys.contains(catKey);

    return Row(children: [
      const Icon(Icons.category_outlined, size: 12, color: Color(0xFF9CA3AF)),
      const SizedBox(width: 5),
      Expanded(
        child: RichText(
          text: TextSpan(children: [
            TextSpan(
              text: category,
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF374151)),
            ),
            TextSpan(
              text: ' · $total item${total == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 11, color: Color(0xFF6B7280)),
            ),
          ]),
        ),
      ),
      if (answerable > 0 && !widget.readOnly) ...[
        const SizedBox(width: 6),
        GestureDetector(
          onTap: inFlight
              ? null
              : () => _categoryDontStockAll(company, category, []),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: const Color(0xFFF1EFE8),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFD1D5DB)),
            ),
            child: inFlight
                ? const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.5, color: Color(0xFF444441)))
                : const Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.do_not_disturb_on_outlined,
                        size: 11, color: Color(0xFF6B7280)),
                    SizedBox(width: 3),
                    Text("Don't stock all",
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF6B7280))),
                  ]),
          ),
        ),
      ],
    ]);
  }

  Future<void> _categoryDontStockAll(
      String company, String category, List<Map<String, dynamic>> items) async {
    if (widget.onBulkCompanyCategory != null) {
      await _doBulkCompanyCategory(company, category);
    } else {
      // Fallback: mark items one by one
      final ids = widget.items
          .where((i) {
            final comp = (i['company'] as String? ?? '').trim();
            final compKey = comp.isEmpty ? 'Other' : comp;
            final cat = (i['therapeutic_class'] as String? ?? '').trim();
            final catKey = cat.isEmpty ? 'Uncategorised' : cat.toUpperCase();
            return compKey == company &&
                catKey == category &&
                !_isLocked(i) &&
                !_noSupplier(i);
          })
          .map((i) => (i['inquiry_id'] as num).toInt())
          .toList();
      if (widget.onBulk != null && ids.isNotEmpty) {
        widget.onBulk!(ids, "We don't stock this product");
      } else {
        for (final id in ids) {
          widget.onAnswer(id, "We don't stock this product");
        }
      }
    }
  }

  // ── Flat category view ─────────────────────────────────────────────────────

  Widget _buildFlatCategoryView(bool isWide) {
    final grouped = _flatGrouped();
    final totalPending = widget.items
        .where((i) => !_isLocked(i) && !_noSupplier(i))
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.readOnly) ...[
          _buildGroupToggle(totalPending),
          const SizedBox(height: 14),
        ],
        ...grouped.entries.expand((entry) {
          final groupKey = entry.key;
          final groupItems = entry.value;
          return [
            _buildFlatGroupHeader(groupKey, groupItems),
            const SizedBox(height: 8),
            ...groupItems.map((item) => _buildItemCard(item, isWide)),
            const SizedBox(height: 14),
          ];
        }),
      ],
    );
  }

  Widget _buildGroupToggle(int totalPending) {
    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _segment('company', 'Company'),
            const SizedBox(width: 2),
            _segment('category', 'Category'),
          ]),
        ),
        const Spacer(),
        if (totalPending > 0)
          Text(
            '$totalPending item${totalPending == 1 ? '' : 's'} pending',
            style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          ),
      ],
    );
  }

  Widget _segment(String value, String label) {
    final active = _groupBy == value;
    return GestureDetector(
      onTap: () {
        if (_groupBy == value) return;
        setState(() {
          _groupBy = value;
          _bulkGroups.clear();
        });
        RenderLog.write('inquiry_v12_group_toggle', value);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF0F6E56) : Colors.transparent,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  Widget _buildFlatGroupHeader(
      String groupKey, List<Map<String, dynamic>> items) {
    final isBulked = _bulkGroups.contains(groupKey);
    final answerableCount =
        items.where((i) => !_isLocked(i) && !_noSupplier(i)).length;

    return Row(children: [
      const Icon(Icons.category_outlined,
          size: 14, color: Color(0xFF6B7280)),
      const SizedBox(width: 6),
      Expanded(
        child: RichText(
          text: TextSpan(children: [
            TextSpan(
              text: groupKey,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827)),
            ),
            TextSpan(
              text: ' · ${items.length} item${items.length == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ]),
        ),
      ),
      if (answerableCount > 0 && !widget.readOnly) ...[
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _handleFlatBulkTap(groupKey, items),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isBulked ? const Color(0xFFF1EFE8) : Colors.white,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isBulked
                    ? const Color(0xFFB4B2A9)
                    : const Color(0xFFD1D5DB),
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                Icons.do_not_disturb_on_outlined,
                size: 12,
                color: isBulked
                    ? const Color(0xFF444441)
                    : const Color(0xFF6B7280),
              ),
              const SizedBox(width: 4),
              Text(
                "Don't stock all",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isBulked
                      ? const Color(0xFF444441)
                      : const Color(0xFF6B7280),
                ),
              ),
            ]),
          ),
        ),
      ],
    ]);
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

  // ── Wide layout: single horizontal row ────────────────────────────────────

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
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
                if (locked && currentAnswer != null && currentAnswer.isNotEmpty)
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
        final isDontStock =
            chip.answer == "We don't stock this product";

        Widget chipWidget = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 90,
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            color: selected ? chip.selBg : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? chip.selBorder : const Color(0xFFE5E7EB),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(chip.icon, size: 14,
                  color: selected ? chip.selText : const Color(0xFF6B7280)),
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
        );

        final gesture = GestureDetector(
          onTap: isDontStock
              ? () => _handleDontStockTap(id, item)
              : () => widget.onAnswer(id, chip.answer),
          child: chipWidget,
        );

        Widget child = isDontStock
            ? CompositedTransformTarget(
                link: _getDontStockLink(id),
                child: gesture,
              )
            : gesture;

        return Padding(
          padding: EdgeInsets.only(left: i > 0 ? 8 : 0),
          child: child,
        );
      }),
    );
  }

  // ── Narrow layout: stacked ─────────────────────────────────────────────────

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
            offset: const Offset(0, 2),
          ),
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
        final isDontStock =
            chip.answer == "We don't stock this product";

        Widget chipWidget = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? chip.selBg : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected ? chip.selBorder : const Color(0xFFE5E7EB),
              width: 0.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(chip.icon, size: 18,
                  color: selected ? chip.selText : const Color(0xFF6B7280)),
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
        );

        final gesture = GestureDetector(
          onTap: isDontStock
              ? () => _handleDontStockTap(id, item)
              : () => widget.onAnswer(id, chip.answer),
          child: chipWidget,
        );

        Widget child = isDontStock
            ? CompositedTransformTarget(
                link: _getDontStockLink(id),
                child: gesture,
              )
            : gesture;

        return Expanded(
          child: Padding(
            padding:
                EdgeInsets.only(right: i < _kChips.length - 1 ? 8 : 0),
            child: child,
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
          ? Image.network(
              imageUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _placeholder(),
            )
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
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        cls,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w500, color: fg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildReadOnlyPill(String answer) {
    Color bg;
    Color fg;
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
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        answer,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: fg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
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
      child: const Text(
        'No supplier available',
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            color: Color(0xFF6B7280)),
      ),
    );
  }
}

// ── Don't stock tiny popup (overlay widget) ───────────────────────────────────

class _DontStockPopup extends StatefulWidget {
  final LayerLink link;
  final String company;
  final String category;
  final bool hasBulk;
  final VoidCallback onMarkAll;
  final VoidCallback onDismiss;

  const _DontStockPopup({
    required this.link,
    required this.company,
    required this.category,
    required this.hasBulk,
    required this.onMarkAll,
    required this.onDismiss,
  });

  @override
  State<_DontStockPopup> createState() => _DontStockPopupState();
}

class _DontStockPopupState extends State<_DontStockPopup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 180));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.88, end: 1.0)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String get _label {
    final c = widget.company;
    final k = widget.category;
    if (c.isNotEmpty && k.isNotEmpty) return "We don't stock $c – $k products";
    if (c.isNotEmpty) return "We don't stock $c products";
    if (k.isNotEmpty) return "We don't stock $k products";
    return "We don't stock these products";
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Dismiss on outside tap
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        CompositedTransformFollower(
          link: widget.link,
          showWhenUnlinked: false,
          targetAnchor: Alignment.topCenter,
          followerAnchor: Alignment.bottomCenter,
          offset: const Offset(0, -8),
          child: FadeTransition(
            opacity: _fade,
            child: ScaleTransition(
              scale: _scale,
              alignment: Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 340),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.do_not_disturb_on_outlined,
                            size: 14, color: Color(0xFF6B7280)),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            _label,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: Color(0xFF111827)),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.hasBulk) ...[
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: widget.onMarkAll,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF1EFE8),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                    color: const Color(0xFFB4B2A9)),
                              ),
                              child: const Text(
                                'Mark all',
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFF444441)),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: widget.onDismiss,
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(Icons.close,
                                size: 14, color: Color(0xFF9CA3AF)),
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
      ],
    );
  }
}
