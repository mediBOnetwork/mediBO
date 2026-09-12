import 'package:flutter/material.dart';
import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../widgets/fulfill_item_sheet.dart' show ProofThumbnail;
import '../admin/dispute/dispute_models.dart';

// CHANGE #671 gap 51: the eleven-colour private palette and the private hex
// parser are both gone. Every colour is a `Ds` token, so ui_design_set()
// recolours this public link with no deploy, and the backend's own
// active_colors / kind_colors / return-note hexes are read by Ds.hex.

String _packQty(num n, String? packType) {
  if (packType == null || packType.trim().isEmpty) return '$n';
  final unit = n == 1 ? packType.trim() : '${packType.trim()}s';
  return '$n $unit';
}

class DisputeFormScreen extends StatefulWidget {
  final String token;
  const DisputeFormScreen({super.key, required this.token});

  @override
  State<DisputeFormScreen> createState() => _DisputeFormScreenState();
}

class _DisputeFormScreenState extends State<DisputeFormScreen> {
  bool _loading = true;
  String? _error;
  String _supplierName = '';
  List<DisputeItem> _items = [];
  final Map<String, bool> _submitting = {};

  @override
  void initState() {
    super.initState();
    RenderLog.write('c348_token_ready', 'token_page=v2');
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() { _loading = true; _error = null; });
    try {
      final result = await fetchDisputeForm(widget.token);
      if (!mounted) return;
      RenderLog.write('c190_link_loaded',
          'supplier=${result.supplierName};count=${result.items.length}');
      setState(() {
        _supplierName = result.supplierName;
        _items = result.items;
        _loading = false;
      });
    } on DisputeException catch (e) {
      if (!mounted) return;
      if (e.message == 'invalid') {
        RenderLog.write('c190_link_invalid_shown', 'token_invalid');
      }
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'load_failed'; _loading = false; });
    }
  }

  Future<void> _submitAction(DisputeItem item, DisputeAction action,
      {List<String> alsoIds = const []}) async {
    if (_submitting[item.disputeId] == true) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(action.label),
        content: Text(
          cf('dispute_form_screen.confirm_body',
              {'a': item.productName, 'b': action.label}),
          style: Ds.t.body,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(c('dispute_form_screen.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c('dispute_form_screen.confirm')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _submitting[item.disputeId] = true);
    RenderLog.write('c190_link_submit_called',
        'dispute=${item.disputeId};response=${action.code}');

    try {
      await submitDisputeResponse(
        token: widget.token,
        disputeId: item.disputeId,
        response: action.code,
      );
      // C362 point-8: fan the SAME response to the OTHER lines of this aggregated product.
      for (final id in alsoIds.where((x) => x != item.disputeId)) {
        try {
          await submitDisputeResponse(
              token: widget.token, disputeId: id, response: action.code);
        } catch (_) {}
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(c('dispute_form_screen.response_recorded'))));
      await _load();
    } on DisputeException catch (e) {
      if (!mounted) return;
      if (e.message == 'already_responded') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(c('dispute_form_screen.already_answered'))));
        await _load();
      } else if (e.message == 'invalid') {
        setState(() { _error = 'invalid'; _loading = false; });
        RenderLog.write('c190_link_invalid_shown', 'token_invalid_on_submit');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(cf('dispute_form_screen.error', {'a': e.message})),
              backgroundColor: Ds.c.danger));
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(c('dispute_form_screen.submission_failed'))));
    } finally {
      if (mounted) setState(() => _submitting.remove(item.disputeId));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: _loading
                ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2.5),
                    SizedBox(height: Ds.space.x12),
                    Text(c('dispute_form_screen.loading'),
                        style: Ds.t.bodySecondary),
                  ]))
                : _error != null ? _buildErrorState() : _buildPage(),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final isInvalid = _error == 'invalid';
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72, height: 72,
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rChip,
            ),
            child: Icon(Icons.link_off_rounded,
                size: 34, color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x24),
          // CHANGE #671: these two sentences were English literals in Dart —
          // the only wording on this page that could not be changed without a
          // deploy. They are ui_copy now, like every other string here.
          Text(
            c(isInvalid
                ? 'dispute_form_screen.invalid_title'
                : 'dispute_form_screen.load_failed_title'),
            style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            c(isInvalid
                ? 'dispute_form_screen.invalid_body'
                : 'dispute_form_screen.load_failed_body'),
            style: Ds.t.bodySecondary,
            textAlign: TextAlign.center,
          ),
          if (!isInvalid) ...[
            SizedBox(height: Ds.space.x24),
            FilledButton.icon(
              onPressed: _load,
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: Text(c('dispute_form_screen.retry')),
            ),
          ],
          SizedBox(height: Ds.space.x32),
          _footer(),
        ]),
      ),
    );
  }

  Widget _buildPage() {
    // C363-F: ITEM-WISE — aggregate by product (summed disputed qty; Active if any).
    // NO Active/Closed sections — one flat list, active rows first; each row's
    // Active(red)/Inactive(green) badge conveys status.
    final aggregated = aggregateDisputesByProduct(_items);
    final rows = [
      ...aggregated.where((a) => a.active),
      ...aggregated.where((a) => !a.active),
    ];
    RenderLog.write('c362_disp_group', 'where=token;items=${aggregated.length}');
    RenderLog.write('c363_disp_group', 'where=supplier;items=${rows.length}');

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x48),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildHeader(),
        SizedBox(height: Ds.space.x16),
        Text(c('dispute_form_screen.confirm_items_below'),
            style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
            child: Text(c('dispute_form_screen.no_disputes'),
                style: Ds.t.caption),
          )
        else
          ...rows.map((item) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: _buildItemCard(item),
          )),
        SizedBox(height: Ds.space.x24),
        _footer(),
      ]),
    );
  }

  Widget _buildItemCard(AggregatedDispute agg) {
    // C362 point-8: item-wise — representative drives labels/actions; qty summed; the row
    // is Active if ANY underlying line is active.
    final item = agg.representative;
    final isActive   = agg.active;
    final isWrong    = item.kind == 'wrong_item';
    final hasFewWrong = item.kind == 'few_wrong';
    final hasImage   = (item.imageUrl ?? '').isNotEmpty;
    final isSubmitting = _submitting[item.disputeId] == true;

    // Backend-owned (get_dispute_form): active_colors, kind_label/kind_colors —
    // verbatim, drive the badge and kind tag below.
    final activeColors = agg.activeColors;
    final activeLabel = activeColors?['label'] ?? (isActive ? 'Active' : 'Inactive');
    final activeBg = Ds.hex(activeColors?['bg'], Ds.c.bg);
    final activeFg = Ds.hex(activeColors?['fg'], Ds.c.textSecondary);
    final kindTagText = item.kindLabel;
    final kindTagBg = Ds.hex(item.kindColors?['bg'], Ds.c.bg);
    final kindTagFg = Ds.hex(item.kindColors?['fg'], Ds.c.textSecondary);

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      padding: EdgeInsets.all(Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [

        // (a) Header row
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ClipRRect(
            borderRadius: Ds.r.rButton,
            child: hasImage
                ? Image.network(item.imageUrl!, width: 60, height: 60, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _imagePlaceholder())
                : _imagePlaceholder(),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(item.productName.isNotEmpty ? item.productName : '—',
                        style: Ds.t.body.copyWith(
                            fontWeight: FontWeight.w700,
                            color: isActive ? Ds.c.text : Ds.c.textSecondary),
                        maxLines: 2, overflow: TextOverflow.ellipsis),
                    // (a) wrong product name
                    if ((isWrong || hasFewWrong) && (item.wrongProductName ?? '').isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(cf('dispute_form_screen.they_say_we_sent', {'a': item.wrongProductName ?? ''}),
                          style: Ds.t.caption.copyWith(color: Ds.c.danger),
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                    ],
                    if (kindTagText.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x4, vertical: Ds.space.x4),
                          decoration: BoxDecoration(
                              color: kindTagBg, borderRadius: Ds.r.rChip),
                          child: Text(kindTagText,
                              style: Ds.t.caption.copyWith(
                                  fontWeight: FontWeight.w700, color: kindTagFg)),
                        ),
                      ),
                    ],
                  ]),
                ),
                SizedBox(width: Ds.space.x4),
                // Backend-owned (get_dispute_form): active_colors, verbatim —
                // replaces the verbose "Awaiting supplier response" item_status_label pill.
                Builder(builder: (_) {
                  RenderLog.write('c363_badge', 'where=supplier,active=$isActive');
                  return Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x8, vertical: Ds.space.x4),
                    decoration: BoxDecoration(
                      color: activeBg,
                      borderRadius: Ds.r.rChip,
                    ),
                    child: Text(activeLabel,
                        style: Ds.t.caption.copyWith(
                            fontWeight: FontWeight.w700, color: activeFg)),
                  );
                }),
              ]),
              // (b) meta
              if ((item.disputeCode ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(
                  item.disputeCode!,
                  style: Ds.t.caption.copyWith(
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
              if ((item.category ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(item.category!,
                    style: Ds.t.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
              if ((item.company ?? '').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(item.company!,
                    style: Ds.t.caption,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ]),
          ),
        ]),

        // (c) Quantities table
        SizedBox(height: Ds.space.x12),
        _buildQtyTable(agg.orderedQty, agg.receivedQty, agg.disputedQty, item.packType),
        if (agg.disputedQty > 0) ...[
          SizedBox(height: Ds.space.x4),
          Text(
              cf('dispute_form_screen.in_dispute_units', {'a': '${agg.disputedQty.toInt()}'})
              + (agg.lines.length > 1 ? cf('dispute_form_screen.orders_suffix', {'a': '${agg.lines.length}'}) : ''),
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w600, color: Ds.c.warning)),
        ],

        // (d) item_status_label — pill already in header; log only
        Builder(builder: (_) {
          final hidden = item.isAwaitingSupplier;
          RenderLog.write('c191_link_awaiting_hidden', '${hidden ? 'true' : 'false'};dispute=${item.disputeId};status=${item.statusCode}');
          return const SizedBox.shrink();
        }),

        // Return-note chip — backend-owned (get_dispute_form's return_note_chip), verbatim.
        if (item.returnNoteChip != null) ...[
          SizedBox(height: Ds.space.x8),
          Builder(builder: (_) {
            final chip = item.returnNoteChip!;
            return Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                  color: Ds.hex(chip.bg, Ds.c.bg),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  chip.labelCard,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w600,
                      color: Ds.hex(chip.fg, Ds.c.textSecondary)),
                ),
              ),
            );
          }),
        ],

        // (e2) Proof photo — c194
        if ((item.proofUrl ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Text(c('dispute_form_screen.proof_photo'),
                style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
            SizedBox(width: Ds.space.x8),
            ProofThumbnail(proofUrl: item.proofUrl!, size: 72),
          ]),
        ],

        // (f) Action buttons — dynamic from item.actions; only shown when array non-empty
        if (item.actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          _buildActionButtons(item, isSubmitting, agg.allActiveDisputeIds),
        ],
      ]),
    );
  }

  Widget _imagePlaceholder() => Container(
    width: 60, height: 60,
    decoration: BoxDecoration(
      color: Ds.c.bg,
      borderRadius: Ds.r.rButton,
    ),
    child: Icon(Icons.medication_outlined, size: 28, color: Ds.c.divider),
  );

  Widget _buildQtyTable(num ordered, num received, num short, String? packType) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rButton,
      ),
      child: Column(children: [
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell(c('dispute_form_screen.qty_ordered'),
                isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell(c('dispute_form_screen.qty_received'),
                isHeader: true, isAmber: false),
            _vertDivider(),
            _qtyCell(c('dispute_form_screen.qty_missing'),
                isHeader: true, isAmber: true),
          ]),
        ),
        Divider(height: 1, color: Ds.c.divider),
        IntrinsicHeight(
          child: Row(children: [
            _qtyCell(_packQty(ordered, packType), isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(received, packType), isHeader: false, isAmber: false),
            _vertDivider(),
            _qtyCell(_packQty(short, packType), isHeader: false, isAmber: true, isBold: true),
          ]),
        ),
      ]),
    );
  }

  Widget _qtyCell(String text, {required bool isHeader, required bool isAmber,
      bool isBold = false}) {
    return Expanded(
      child: Container(
        padding: EdgeInsets.symmetric(
            vertical: Ds.space.x8, horizontal: Ds.space.x4),
        color: isAmber && !isHeader ? Ds.c.warningSoft : null,
        child: Text(text, textAlign: TextAlign.center,
          style: Ds.t.caption.copyWith(
            fontWeight: (isHeader || isBold) ? FontWeight.w700 : FontWeight.w400,
            color: isAmber
                ? Ds.c.warning
                : (isHeader ? Ds.c.textSecondary : Ds.c.text),
          ),
        ),
      ),
    );
  }

  Widget _vertDivider() =>
      VerticalDivider(width: 1, color: Ds.c.divider, thickness: 1);

  // Dynamic buttons from item.actions — no hardcoded codes or labels
  Widget _buildActionButtons(DisputeItem item, bool isSubmitting, List<String> groupIds) {
    RenderLog.write('c190_link_buttons_rendered',
        'dispute=${item.disputeId};count=${item.actions.length}');
    final spinner = SizedBox(width: 14, height: 14,
        child: CircularProgressIndicator(color: Ds.c.surface, strokeWidth: 2));

    if (item.actions.length == 1) {
      final action = item.actions.first;
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.warning,
            disabledBackgroundColor: Ds.c.warningSoft,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
          ),
          child: isSubmitting ? spinner : Text(action.label,
              style: Ds.t.caption.copyWith(
                  fontWeight: FontWeight.w700, color: Ds.c.surface)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: item.actions.asMap().entries.map((e) {
        final idx = e.key;
        final action = e.value;
        final isPrimary = idx == 0;
        if (isPrimary) {
          return Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x4),
            child: FilledButton(
              onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.warning,
                disabledBackgroundColor: Ds.c.warningSoft,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
              ),
              child: isSubmitting ? spinner : Text(action.label,
                  style: Ds.t.caption.copyWith(
                      fontWeight: FontWeight.w700, color: Ds.c.surface)),
            ),
          );
        }
        return OutlinedButton(
          onPressed: isSubmitting ? null : () => _submitAction(item, action, alsoIds: groupIds),
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.text,
            side: BorderSide(color: Ds.c.divider),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
          ),
          child: Text(action.label,
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600)),
        );
      }).toList(),
    );
  }

  Widget _buildHeader() => Container(
    padding: EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(color: Ds.c.brand, borderRadius: Ds.r.rCard),
    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: Ds.c.surface.withValues(alpha: 0.16),
          borderRadius: Ds.r.rButton,
        ),
        child: Icon(Icons.local_shipping_outlined, color: Ds.c.surface, size: 26),
      ),
      SizedBox(width: Ds.space.x12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dispute_form_screen.header_kicker'),
              style: Ds.t.caption.copyWith(
                  color: Ds.c.surface.withValues(alpha: 0.70),
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.5)),
          SizedBox(height: Ds.space.x4),
          Text(cf('dispute_form_screen.hi_supplier', {'a': _supplierName}),
              style: Ds.t.display.copyWith(
                  color: Ds.c.surface, fontWeight: FontWeight.w800),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ]),
      ),
    ]),
  );

  Widget _footer() => Center(
    child: Text(c('dispute_form_screen.footer'), style: Ds.t.caption),
  );
}
