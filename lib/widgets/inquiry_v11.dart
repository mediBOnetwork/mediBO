import 'package:flutter/material.dart';
import '../utils/render_log.dart';

// ── Category → color map ──────────────────────────────────────────────────────

const Map<String, List<Color>> _kClassColors = {
  'CARDIAC':            [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'NEURO CNS':          [Color(0xFFEEEDFE), Color(0xFF534AB7)],
  'GASTRO INTESTINAL':  [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
  'ANTI INFECTIVES':    [Color(0xFFE6F1FB), Color(0xFF0C447C)],
  'DERMA':              [Color(0xFFFBEAF0), Color(0xFF993556)],
  'GYNAECOLOGICAL':     [Color(0xFFFBEAF0), Color(0xFF993556)],
};
const _kDefaultClassBg = Color(0xFFF1EFE8);
const _kDefaultClassFg = Color(0xFF2C2C2A);

// ── 3-chip spec (order: Don't stock / Out of stock / Available) ───────────────

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

// ── Public widget ─────────────────────────────────────────────────────────────

/// Shared Design-v11 inquiry item list used across all three inquiry surfaces.
///
/// Parameters:
///   items           — raw item maps from the RPC. Must include inquiry_id,
///                     product_name. Optional: therapeutic_class, company,
///                     image_url, answer, locked, answered, role, slot_index.
///   answerOverrides — local answer state (public form before submit).
///                     Overrides item['answer'] when present.
///   onAnswer        — called when user taps a chip.
///   onBulkAnswer    — called when "Don't stock all" is tapped. answer == ''
///                     means undo. Falls back to calling onAnswer per item.
///   answeringIds    — inquiry_ids that are mid-RPC (show spinner).
///   readOnly        — if true, all items are shown read-only regardless of
///                     individual item fields.
class InquiryV11List extends StatefulWidget {
  final List<Map<String, dynamic>> items;
  final Map<int, String> answerOverrides;
  final void Function(int inquiryId, String answer) onAnswer;
  final void Function(List<int> ids, String answer)? onBulkAnswer;
  final Set<int> answeringIds;
  final bool readOnly;

  const InquiryV11List({
    super.key,
    required this.items,
    this.answerOverrides = const {},
    required this.onAnswer,
    this.onBulkAnswer,
    this.answeringIds = const {},
    this.readOnly = false,
  });

  @override
  State<InquiryV11List> createState() => _InquiryV11ListState();
}

class _InquiryV11ListState extends State<InquiryV11List> {
  String _groupBy = 'category'; // 'category' | 'company'
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

  void _handleBulkTap(
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
    if (widget.onBulkAnswer != null) {
      widget.onBulkAnswer!(ids, answer);
    } else if (!wasBulked) {
      // fallback: call onAnswer per item
      for (final id in ids) {
        widget.onAnswer(id, answer);
      }
    }
    RenderLog.write('inquiry_v11_bulk_dontstock',
        '${wasBulked ? 'clear' : 'set'}:${ids.length}:$groupKey');
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    RenderLog.write('inquiry_v11_group_toggle', _groupBy);
    final grouped = _grouped();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.readOnly) ...[
          _buildGroupToggle(),
          const SizedBox(height: 14),
        ],
        ...grouped.entries.expand((entry) {
          final groupKey = entry.key;
          final groupItems = entry.value;
          return [
            _buildGroupHeader(groupKey, groupItems),
            const SizedBox(height: 8),
            ...groupItems.map(_buildItemCard),
            const SizedBox(height: 14),
          ];
        }),
      ],
    );
  }

  Widget _buildGroupToggle() {
    return Container(
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
        RenderLog.write('inquiry_v11_group_toggle', value);
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
              text:
                  ' · ${items.length} item${items.length == 1 ? '' : 's'}',
              style: const TextStyle(
                  fontSize: 12, color: Color(0xFF6B7280)),
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
              color: isBulked
                  ? const Color(0xFFF1EFE8)
                  : Colors.white,
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

  Widget _buildItemCard(Map<String, dynamic> item) {
    final id = (item['inquiry_id'] as num).toInt();
    final productName = (item['product_name'] as String? ?? '').trim();
    final tc =
        (item['therapeutic_class'] as String? ?? '').trim();
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
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
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
            // Top row: 96px image + info stack
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildImage(imageUrl, locked: locked),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name — single line + ellipsis
                      Text(
                        productName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: locked
                              ? const Color(0xFF9CA3AF)
                              : const Color(0xFF111827),
                          height: 1.3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      // Therapeutic class pill
                      if (tc.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _buildClassPill(tc),
                      ],
                      // Company — straight (not italic)
                      if (company.isNotEmpty) ...[
                        const SizedBox(height: 5),
                        Text(
                          company,
                          style: TextStyle(
                            fontSize: 14,
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
                if (locked) ...[
                  const SizedBox(width: 6),
                  const Icon(Icons.lock_outline,
                      size: 14, color: Color(0xFFD1D5DB)),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // Answer area
            if (locked && currentAnswer != null && currentAnswer.isNotEmpty)
              _buildReadOnlyAnswer(currentAnswer)
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
              _buildChips(id, currentAnswer),
          ],
        ),
      ),
    );
  }

  Widget _buildImage(String? imageUrl, {required bool locked}) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB)),
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
            size: 40, color: Color(0xFFD1D5DB)),
      );

  Widget _buildClassPill(String cls) {
    final upper = cls.toUpperCase();
    final colors = _kClassColors[upper];
    final bg = colors?[0] ?? _kDefaultClassBg;
    final fg = colors?[1] ?? _kDefaultClassFg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        cls,
        style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w500, color: fg),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildReadOnlyAnswer(String answer) {
    Color color;
    if (answer == 'Available') {
      color = const Color(0xFF0F6E56);
    } else if (answer == 'Out of Stock') {
      color = const Color(0xFF993C1D);
    } else {
      color = const Color(0xFF444441);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        answer,
        style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w600, color: color),
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

  Widget _buildChips(int id, String? currentAnswer) {
    return Row(
      children: List.generate(_kChips.length, (i) {
        final chip = _kChips[i];
        final selected = currentAnswer == chip.answer;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < _kChips.length - 1 ? 9 : 0),
            child: GestureDetector(
              onTap: () => widget.onAnswer(id, chip.answer),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: selected ? chip.selBg : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? chip.selBorder
                        : const Color(0xFFE5E7EB),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      chip.icon,
                      size: 18,
                      color: selected
                          ? chip.selText
                          : const Color(0xFF6B7280),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      chip.label,
                      style: TextStyle(
                        fontSize: 12,
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
}
