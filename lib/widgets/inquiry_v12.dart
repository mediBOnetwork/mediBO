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
/// Responsive: wide (≥700px) = single horizontal row per item;
/// narrow (<700px) = stacked image+text then full-width 3-chip grid.
///
/// Parameters:
///   items           — raw item maps. Required: inquiry_id, product_name.
///                     Optional: therapeutic_class, company, image_url,
///                     answer, locked, answered, role, slot_index.
///   answerOverrides — local overrides (public form before submit).
///   onAnswer        — called when a chip is tapped.
///   onBulk          — called for "Don't stock all"; ids = unlocked items in
///                     group; answer == '' means undo/clear.
///   answeringIds    — inquiry_ids with in-flight RPC (show spinner).
///   readOnly        — show all items as locked read-only.
class InquiryAnswerList extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, String> answerOverrides;
  final void Function(int inquiryId, String answer) onAnswer;
  final void Function(List<int> ids, String answer)? onBulk;
  final Set<int> answeringIds;
  final bool readOnly;

  const InquiryAnswerList({
    super.key,
    required this.items,
    this.answerOverrides = const {},
    required this.onAnswer,
    this.onBulk,
    this.answeringIds = const {},
    this.readOnly = false,
  });

  @override
  State<InquiryAnswerList> createState() => _InquiryAnswerListState();
}

class _InquiryAnswerListState extends State<InquiryAnswerList> {
  String _groupBy = 'category';
  final Set<String> _bulkGroups = {};

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _groupKey(Map<String, dynamic> item) {
    if (_groupBy == 'company') {
      final c = (item['company'] as String? ?? '').trim();
      return c.isEmpty ? 'Unknown Company' : c;
    }
    final tc = (item['therapeutic_class'] as String? ?? '').trim();
    return tc.isEmpty ? 'Uncategorized' : tc.toUpperCase();
  }

  Map<String, List<Map<String, dynamic>>> _grouped() {
    final map = <String, List<Map<String, dynamic>>>{};
    for (final item in widget.items) {
      (map[_groupKey(item)] ??= []).add(item);
    }
    return map;
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

  void _handleBulkTap(String groupKey, List<Map<String, dynamic>> groupItems) {
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
    RenderLog.write(
        'inquiry_v12_bulk_dontstock',
        '${wasBulked ? 'clear' : 'set'}:${ids.length}:$groupKey');
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    RenderLog.write('inquiry_v12_widget', _groupBy);
    RenderLog.write('inquiry_v12_group_toggle', _groupBy);
    final grouped = _grouped();

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _kWideBreakpoint;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!widget.readOnly) ...[
              _buildGroupToggle(grouped),
              const SizedBox(height: 14),
            ],
            ...grouped.entries.expand((entry) {
              final groupKey = entry.key;
              final groupItems = entry.value;
              return [
                _buildGroupHeader(groupKey, groupItems),
                const SizedBox(height: 8),
                ...groupItems.map((item) => _buildItemCard(item, isWide)),
                const SizedBox(height: 14),
              ];
            }),
          ],
        );
      },
    );
  }

  Widget _buildGroupToggle(Map<String, List<Map<String, dynamic>>> grouped) {
    final totalPending = widget.items
        .where((i) => !_isLocked(i) && !_noSupplier(i))
        .length;

    return Row(
      children: [
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF3F4F6),
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(3),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _segment('category', 'Category'),
            const SizedBox(width: 2),
            _segment('company', 'Company'),
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

  Widget _buildGroupHeader(
      String groupKey, List<Map<String, dynamic>> items) {
    final icon = _groupBy == 'category'
        ? Icons.category_outlined
        : Icons.store_outlined;
    final isBulked = _bulkGroups.contains(groupKey);
    final answerableCount =
        items.where((i) => !_isLocked(i) && !_noSupplier(i)).length;

    return Row(children: [
      Icon(icon, size: 14, color: const Color(0xFF6B7280)),
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ]),
        ),
      ),
      if (answerableCount > 0 && !widget.readOnly) ...[
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => _handleBulkTap(groupKey, items),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // 72×72 image tile
            _buildImageTile(imageUrl, 72, locked: locked),
            const SizedBox(width: 18),
            // Middle: name + pill + company
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
            // Right: chips or read-only answer
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
              _buildWideChips(id, currentAnswer),
          ],
        ),
      ),
    );
  }

  Widget _buildWideChips(int id, String? currentAnswer) {
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
                  color: selected ? chip.selBorder : const Color(0xFFE5E7EB),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    chip.icon,
                    size: 14,
                    color: selected ? chip.selText : const Color(0xFF6B7280),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    chip.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color:
                          selected ? chip.selText : const Color(0xFF6B7280),
                    ),
                  ),
                ],
              ),
            ),
          ),
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
            // Top row: image + text
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
            // Answer area
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
                _buildNarrowChips(id, currentAnswer),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildNarrowChips(int id, String? currentAnswer) {
    return Row(
      children: List.generate(_kChips.length, (i) {
        final chip = _kChips[i];
        final selected = currentAnswer == chip.answer;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < _kChips.length - 1 ? 8 : 0),
            child: GestureDetector(
              onTap: () => widget.onAnswer(id, chip.answer),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: selected ? chip.selBg : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        selected ? chip.selBorder : const Color(0xFFE5E7EB),
                    width: 0.5,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      chip.icon,
                      size: 18,
                      color:
                          selected ? chip.selText : const Color(0xFF6B7280),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chip.label,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: selected
                            ? chip.selText
                            : const Color(0xFF6B7280),
                      ),
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
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg),
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
