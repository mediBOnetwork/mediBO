// CHANGE #611 — seller-of-record disclosure.
//
// mediBO is the platform; the medicines are sold and invoiced by the licensed
// partner for the zone. Those lines are composed by the backend
// (partner_seller_block / order_seller_block) and rendered verbatim here.
// This file writes no user-facing copy of its own.
//
//   found == false        → nothing renders
//   a requested line null → that line is skipped
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../utils/render_log.dart';

/// Canonical key names in the seller payloads.
class SellerLine {
  static const soldBy = 'sold_by_line';
  static const address = 'address_line';
  static const dl = 'dl_line';
  static const gstin = 'gstin_line';
  static const footerNote = 'footer_note';

  /// The four identity lines shown on an order.
  static const orderLines = [soldBy, address, dl, gstin];

  /// The three lines shown before placing an order.
  static const checkoutLines = [soldBy, dl, gstin];
}

/// Renders the requested [lines] from an already-fetched seller payload.
class SellerLinesText extends StatelessWidget {
  final Map<String, dynamic>? data;
  final List<String> lines;
  final TextAlign align;
  final EdgeInsets padding;
  final double fontSize;
  final Color color;

  const SellerLinesText({
    super.key,
    required this.data,
    required this.lines,
    this.align = TextAlign.left,
    this.padding = EdgeInsets.zero,
    this.fontSize = 11.5,
    this.color = const Color(0xFF6B7280),
  });

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null || d['found'] != true) return const SizedBox.shrink();

    final visible = <String>[];
    for (final key in lines) {
      final v = d[key];
      if (v is String && v.trim().isNotEmpty) visible.add(v);
    }
    if (visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: align == TextAlign.center
            ? CrossAxisAlignment.center
            : CrossAxisAlignment.start,
        children: visible
            .map((t) => Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    t,
                    textAlign: align,
                    style: TextStyle(fontSize: fontSize, height: 1.45, color: color),
                  ),
                ))
            .toList(),
      ),
    );
  }
}

/// Fetches `partner_seller_block()` — the partner serving the viewer's zone.
/// Used on Home (footer note) and at checkout.
class PartnerSellerBlock extends StatefulWidget {
  final List<String> lines;
  final TextAlign align;
  final EdgeInsets padding;
  final double fontSize;
  final Color color;
  final String logTag;

  const PartnerSellerBlock({
    super.key,
    required this.lines,
    this.align = TextAlign.left,
    this.padding = EdgeInsets.zero,
    this.fontSize = 11.5,
    this.color = const Color(0xFF6B7280),
    this.logTag = 'c611_seller_block',
  });

  @override
  State<PartnerSellerBlock> createState() => _PartnerSellerBlockState();
}

class _PartnerSellerBlockState extends State<PartnerSellerBlock> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client.rpc('partner_seller_block');
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(raw as Map));
      RenderLog.write(widget.logTag, _data?['found'] == true ? 1 : 0);
    } catch (e) {
      // No payload, no disclosure — the block simply does not render.
      if (!mounted) return;
      RenderLog.write('${widget.logTag}_error', 1);
    }
  }

  @override
  Widget build(BuildContext context) => SellerLinesText(
        data: _data,
        lines: widget.lines,
        align: widget.align,
        padding: widget.padding,
        fontSize: widget.fontSize,
        color: widget.color,
      );
}

/// Fetches `order_seller_block(p_order_id)` — the partner stamped on the order,
/// which is the one that actually sold it, not today's active partner.
class OrderSellerBlock extends StatefulWidget {
  final String orderId;
  final List<String> lines;
  final EdgeInsets padding;
  final double fontSize;
  final Color color;

  const OrderSellerBlock({
    super.key,
    required this.orderId,
    this.lines = SellerLine.orderLines,
    this.padding = EdgeInsets.zero,
    this.fontSize = 11.5,
    this.color = const Color(0xFF6B7280),
  });

  @override
  State<OrderSellerBlock> createState() => _OrderSellerBlockState();
}

class _OrderSellerBlockState extends State<OrderSellerBlock> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant OrderSellerBlock old) {
    super.didUpdateWidget(old);
    if (old.orderId != widget.orderId) _load();
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('order_seller_block', params: {'p_order_id': widget.orderId});
      if (!mounted) return;
      setState(() => _data = Map<String, dynamic>.from(raw as Map));
      RenderLog.write('c611_order_seller_block', _data?['found'] == true ? 1 : 0);
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c611_order_seller_block_error', 1);
    }
  }

  @override
  Widget build(BuildContext context) => SellerLinesText(
        data: _data,
        lines: widget.lines,
        padding: widget.padding,
        fontSize: widget.fontSize,
        color: widget.color,
      );
}
