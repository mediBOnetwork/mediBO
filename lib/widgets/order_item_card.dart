import 'package:flutter/material.dart';

import '../utils/pack_label.dart';
import '../utils/render_log.dart';

// Shared order-item card used by supplier portal, admin supplier-orders, and public order page.

const double kOrderItemWideBreakpoint = 900.0;

const Map<String, List<Color>> kOrderItemClassColors = {
  'CARDIAC':            [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'NEURO CNS':          [Color(0xFFEEEDFE), Color(0xFF534AB7)],
  'GASTRO INTESTINAL':  [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
  'ANTI INFECTIVES':    [Color(0xFFE6F1FB), Color(0xFF0C447C)],
  'PAIN ANALGESICS':    [Color(0xFFFAECE7), Color(0xFF993C1D)],
  'DERMA':              [Color(0xFFFBEAF0), Color(0xFF993556)],
  'GYNAECOLOGICAL':     [Color(0xFFFBEAF0), Color(0xFF993556)],
  'RESPIRATORY':        [Color(0xFFE1F5EE), Color(0xFF0F6E56)],
  'HORMONES':           [Color(0xFFFBEAF0), Color(0xFF993556)],
};
const _kDefaultClassBg = Color(0xFFF1EFE8);
const _kDefaultClassFg = Color(0xFF2C2C2A);

class OrderItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  const OrderItemCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c108_orderitemcard_shared_used', 'true');
    final productName = (item['product_name'] as String? ?? '').trim();
    final tc          = (item['therapeutic_class'] as String? ?? '').trim().toUpperCase();
    final company     = (item['company'] as String? ?? '').trim();
    final imageUrl    = item['image_url'] as String?;
    final qty         = (item['quantity'] as num?)?.toInt() ?? 0;
    final packType    = item['pack_type'] as String?;
    final pillText    = qtyPillLabel(qty, packType);
    RenderLog.write('c189_merged_pill', 'true');

    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth >= kOrderItemWideBreakpoint;
      return isWide
          ? _buildWide(productName, tc, company, imageUrl, pillText)
          : _buildNarrow(productName, tc, company, imageUrl, pillText);
    });
  }

  Widget _buildWide(String name, String tc, String company, String? imageUrl, String pillText) {
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
            _buildImageTile(imageUrl, 72),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF111827),
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
                      style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 18),
            _buildQtyPill(pillText),
          ],
        ),
      ),
    );
  }

  Widget _buildNarrow(String name, String tc, String company, String? imageUrl, String pillText) {
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
                _buildImageTile(imageUrl, 88),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF111827),
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
                          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _buildQtyPill(pillText),
          ],
        ),
      ),
    );
  }

  Widget _buildQtyPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFBFDBFE)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Color(0xFF1E40AF),
        ),
      ),
    );
  }

  Widget _buildImageTile(String? imageUrl, double size) {
    if (imageUrl != null && imageUrl.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.network(
          imageUrl,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _pillIconBox(size),
        ),
      );
    }
    return _pillIconBox(size);
  }

  Widget _pillIconBox(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.medication_outlined, size: 28, color: Color(0xFFD1D5DB)),
    );
  }

  Widget _buildClassPill(String tc) {
    final colors = kOrderItemClassColors[tc];
    final bg = colors != null ? colors[0] : _kDefaultClassBg;
    final fg = colors != null ? colors[1] : _kDefaultClassFg;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(
        tc,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}
