// CMD #451 — register row 128: "No system-generated GST tax invoice — the bill
// is a manually uploaded file".
//
// This card renders. It does not decide. Every string it prints arrives from
// `customer_invoice(p_order_id)` already worded and already cased:
//
//   * `title`     — "TAX INVOICE" once the order is dispatched and the number
//                   is drawn from the statutory per-financial-year series,
//                   "PROFORMA INVOICE" before that, "Invoice not ready" when
//                   there is no rate yet. Dart never picks between them.
//   * `invoice_no`— "MB/2026-27/0001", assigned ONCE by the backend and never
//                   recomputed here. Empty means unnumbered, which is a real
//                   state (a proforma), not a missing value.
//   * `not_ready_message` / `unrated_lines` — the backend naming exactly which
//                   lines are still waiting for a rate. The old Bill tab could
//                   only say "processing" because customer_bill_file() knew
//                   nothing except whether a human had uploaded a file.
//
// Absence is explicit throughout: `ready`, `proforma` and `file.has` are
// backend flags, never inferred from an empty string.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import 'delivery_proof_card.dart';
import 'bill_actions_row.dart';

class CustomerInvoiceCard extends StatefulWidget {
  final String orderId;

  /// Renders the payload directly instead of fetching it. The widget test
  /// drives this; the app leaves it null and the card self-fetches.
  final Map<String, dynamic>? payload;

  const CustomerInvoiceCard({super.key, required this.orderId, this.payload});

  @override
  State<CustomerInvoiceCard> createState() => _CustomerInvoiceCardState();
}

class _CustomerInvoiceCardState extends State<CustomerInvoiceCard> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    if (widget.payload != null) {
      _data = widget.payload;
      _loading = false;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final raw = await Supabase.instance.client
          .rpc('customer_invoice', params: {'p_order_id': widget.orderId});
      final data = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (mounted) setState(() { _data = data; _loading = false; });
    } catch (e) {
      // The backend owns the copy for every state it knows about; a transport
      // failure is the one thing it cannot word, so it is shown as itself.
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _InvoiceSkeleton();
    if (_error.isNotEmpty) {
      return _Shell(children: [
        Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        SizedBox(height: Ds.space.x12),
        OutlinedButton(
          onPressed: () { setState(() { _loading = true; _error = ''; }); _load(); },
          child: const Text('Retry'),
        ),
      ]);
    }

    final d = _data ?? const <String, dynamic>{};
    final title = (d['title'] ?? '').toString();
    final invoiceNo = (d['invoice_no'] ?? '').toString();
    final issued = (d['issued_label'] ?? '').toString();
    final ready = d['ready'] == true;
    final proforma = d['proforma'] == true;
    final message = (d['not_ready_message'] ?? '').toString();
    final file = d['file'] is Map
        ? (d['file'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final lines = d['unrated_lines'] is List
        ? (d['unrated_lines'] as List)
        : const <dynamic>[];

    return _Shell(children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(title, style: Ds.t.bodyStrong),
        ),
        // The chip appears only for a document the backend has titled a
        // proforma. Nothing here derives that from a missing number.
        if (proforma)
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration:
                BoxDecoration(color: Ds.c.warningSoft, borderRadius: Ds.r.rChip),
            child: Text('Proforma',
                style: Ds.t.caption.copyWith(color: Ds.c.warning)),
          ),
      ]),

      // An unnumbered document is a real state, so the row is omitted rather
      // than printed with a dash.
      if (invoiceNo.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(invoiceNo, style: Ds.t.subtitle),
      ],
      if (issued.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(issued, style: Ds.t.caption),
      ],

      if (!ready && message.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Text(message, style: Ds.t.caption),
      ],

      // The backend names each line that is still waiting for a rate, so the
      // customer sees WHICH item is holding the invoice rather than a blanket
      // "processing".
      if (lines.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        for (final raw in lines)
          if (raw is Map)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: EdgeInsets.only(top: Ds.space.x4),
                  child: Icon(Icons.circle,
                      size: Ds.space.x4, color: Ds.c.textSecondary),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(
                      '${(raw['product'] ?? '').toString()} — ${(raw['reason'] ?? '').toString()}',
                      style: Ds.t.caption),
                ),
              ]),
            ),
      ],

      // CHANGE #691 (register row 126) — proof of delivery on the document the
      // buyer files. `has:false` until the stop is closed, so nothing is drawn
      // on an invoice for an order still on the road.
      DeliveryProofCard(
          proof: (d['delivery_proof'] as Map?)?.cast<String, dynamic>() ??
              const {}),

      // The rendered PDF, when one exists. Download / WhatsApp / Share are the
      // same implementation the admin card uses.
      if (file['has'] == true) ...[
        SizedBox(height: Ds.space.x16),
        UploadedBillActionsRow(
          orderId: widget.orderId,
          bucket: (file['bucket'] ?? 'customer-bills').toString(),
          path: (file['path'] ?? '').toString(),
          fileName: (file['name'] ?? 'Invoice').toString(),
        ),
      ],
    ]);
  }
}

class _Shell extends StatelessWidget {
  final List<Widget> children;
  const _Shell({required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }
}

/// A skeleton, not a bare spinner — the card's shape is known before its words
/// are.
class _InvoiceSkeleton extends StatelessWidget {
  const _InvoiceSkeleton();

  @override
  Widget build(BuildContext context) {
    return _Shell(children: [
      Container(height: Ds.space.x12, width: Ds.space.x48 * 3, color: Ds.c.bg),
      SizedBox(height: Ds.space.x12),
      Container(height: Ds.space.x16, width: Ds.space.x48 * 4, color: Ds.c.bg),
      SizedBox(height: Ds.space.x12),
      Container(height: Ds.space.x12, width: Ds.space.x48 * 5, color: Ds.c.bg),
    ]);
  }
}
