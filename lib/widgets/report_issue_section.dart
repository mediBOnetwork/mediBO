import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../fulfill/fulfill_lookups.dart';
import '../utils/render_log.dart';

/// '#RRGGBB' / '#AARRGGBB' -> Color. Fallback is a COLOUR only — never copy.
Color _hexColor(String? hex, Color fallback) {
  if (hex == null || hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

const _kGreen  = Color(0xFF1B7A43);
const _kText   = Color(0xFF111827);
const _kSub    = Color(0xFF6B7280);
const _kBorder = Color(0xFFE5E7EB);
const _kAmber  = Color(0xFFB45309);
const _kAmberBg = Color(0xFFFFFBEB);
const _kAmberBorder = Color(0xFFFCD34D);

/// Unified 5-option issue-flagging section embedded in item popups.
/// Replaces the old ad-hoc "Few item wrong / Wrong item / Not coming" buttons.
class ReportIssueSection extends StatefulWidget {
  final String orderItemId;
  // C365: PRODUCT scope — the dispute popup is aggregated (one row per product). These drive
  // the NEW fw_set_product_issue RPC which distributes the disputed qty across ALL the
  // supplier+product order-lines and caps at the TOTAL gap. orderedQty/receivedQty/refQty below
  // are now the PRODUCT aggregate totals (not one line), so the stepper cap = the total gap.
  final String supplierName;
  final int productId;
  final int orderedQty;
  final int receivedQty;
  // C360: stage REFERENCE qty for gating + qty math (short/excess boundary, stepper
  // caps). SHOP = ordered; WAREHOUSE = expected (forwarded shop_qty), matching the
  // backend's dispute reference. Defaults to orderedQty when unset. `orderedQty`
  // stays display-only ("Ordered: N"). Without this, an over-forward warehouse line
  // (expected < received <= ordered) could not pick 'excess' -> confirm deadlock.
  final int? refQty;
  final bool isLocked;
  final String? existingIssue;
  final int? existingIssueQty;
  final String? existingWrongName;
  final String? existingProofUrl;
  final VoidCallback onSaved;
  // C354: tab label ('shop'|'warehouse') for render-log gate proof; cosmetic only.
  final String? tab;
  // C359: "Report missing / Short" moved INTO this popup as a dispute type. Since
  // this widget has no supplier/product context, the parent wires the existing
  // report-missing flow here. Called with the received qty to flag short, or null
  // to clear/undo the short. Absent (null) => the short option is not offered.
  final Future<void> Function(int? receivedQty)? onReportMissing;
  // C359: line is already marked short (report_missing) — pre-select 'short'.
  final bool isShort;

  const ReportIssueSection({
    super.key,
    this.tab,
    required this.orderItemId,
    required this.supplierName,
    required this.productId,
    required this.orderedQty,
    required this.receivedQty,
    this.refQty,
    required this.isLocked,
    this.existingIssue,
    this.existingIssueQty,
    this.existingWrongName,
    this.existingProofUrl,
    required this.onSaved,
    this.onReportMissing,
    this.isShort = false,
  });

  @override
  State<ReportIssueSection> createState() => _ReportIssueSectionState();
}

class _ReportIssueSectionState extends State<ReportIssueSection> {
  bool _expanded = false;
  String? _selected;
  int _qty = 1;
  final _nameCtrl = TextEditingController();
  String? _proofUrl;
  bool _uploading = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // C531: option table + error copy are backend-owned (fw_issue_options /
    // fw_error_messages). Nothing renders until they land.
    FulfillLookups.instance.addListener(_onLookups);
    FulfillLookups.instance.ensureLoaded();
    final ei = _cleanIssue(widget.existingIssue);
    if (ei != null) {
      _selected = ei;
      _qty = widget.existingIssueQty ?? 1;
      if (widget.existingWrongName != null && widget.existingWrongName!.isNotEmpty) {
        _nameCtrl.text = widget.existingWrongName!;
      }
      _proofUrl = widget.existingProofUrl;
      _expanded = true;
    }
  }

  void _onLookups() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(ReportIssueSection old) {
    super.didUpdateWidget(old);
    // C353/C531: item values may refresh in place while the sheet stays open —
    // drop a selection the backend's option table no longer offers.
    if (_selected != null &&
        FulfillLookups.instance.ready &&
        FulfillLookups.instance.issueOption(_selected) == null) {
      _selected = null;
    }
  }

  @override
  void dispose() {
    FulfillLookups.instance.removeListener(_onLookups);
    _nameCtrl.dispose();
    super.dispose();
  }

  String? _cleanIssue(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    return raw;
  }

  // C360: stage reference for gating + qty math (falls back to ordered when unset).
  int get _ref => widget.refQty ?? widget.orderedQty;

  int get _maxQty {
    final uncounted = _ref - widget.receivedQty;
    return uncounted > 0 ? uncounted : (_ref > 0 ? _ref : 1);
  }

  bool get _saveEnabled {
    if (_selected == null || _saving) return false;
    // C531: WHICH inputs a kind requires is backend-owned (fw_issue_options
    // needs_qty / needs_name). Only the pure keystroke checks live here.
    final lk = FulfillLookups.instance;
    if (lk.needsQty(_selected) && _qty < 1) return false;
    if (lk.needsName(_selected) && _nameCtrl.text.trim().isEmpty) return false;
    return true;
  }

  /// Backend-owned error copy. Never falls back to a client string — an empty
  /// result means the lookup cache has not landed and we stay silent.
  void _showErr(String? code) {
    final text = FulfillLookups.instance.message(code);
    if (!mounted || text == null || text.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: const Color(0xFFDC2626)));
  }

  Future<String?> _pickAndUpload() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    } catch (_) {
      return null;
    }
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) return null;
    final ext = file.name.split('.').last.toLowerCase();
    final mime = ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg';
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = 'issue/${widget.orderItemId}_$ts.$ext';
    try {
      await Supabase.instance.client.storage
          .from('dispute-proofs')
          .uploadBinary(path, bytes, fileOptions: FileOptions(upsert: true, contentType: mime));
      return Supabase.instance.client.storage.from('dispute-proofs').getPublicUrl(path);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clear() async {
    if (_saving) return;
    setState(() => _saving = true);
    // C364: a NEW short (count_issue='short') clears via fw_set_line_issue('clear') below.
    // Only a LEGACY report-missing short (isShort flag, no count_issue) undoes via the parent.
    if (widget.isShort && _cleanIssue(widget.existingIssue) == null &&
        widget.onReportMissing != null) {
      try {
        await widget.onReportMissing!(null); // null = clear/undo the short
        if (!mounted) return;
        RenderLog.write('c359_flag_marked', 'issue=short_cleared');
        widget.onSaved();
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        RenderLog.write('c531_issue_err', 'where=clear_missing');
        _showErr(null); // backend 'default' message
      }
      return;
    }
    try {
      // C365: PRODUCT-level clear un-flags ALL the product's order-lines at once.
      final res = await Supabase.instance.client.rpc('fw_set_product_issue', params: {
        'p_supplier': widget.supplierName,
        'p_product_id': widget.productId,
        'p_issue': 'clear',
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _saving = false);
        _showErr(err);
        return;
      }
      RenderLog.write('c351_flag_cleared', 'ok=1');
      RenderLog.write('c365_prod_issue', 'product=${widget.productId},disputed=0,gap=0');
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      RenderLog.write('c531_issue_err', 'where=clear');
      _showErr(null);
    }
  }

  Future<void> _save() async {
    if (!_saveEnabled) return;
    setState(() => _saving = true);
    final issue = _selected!;
    final qty = _qty;
    final name = _nameCtrl.text.trim();
    final proofUrl = _proofUrl;
    // C364: 'short' now flows through fw_set_line_issue with the entered disputed qty
    // (stored in issue_qty), exactly like the other qty kinds — no separate report-missing call.
    try {
      if (widget.isLocked) {
        final kind = issue == 'wrong' ? 'wrong_item' : issue;
        final res = await Supabase.instance.client.rpc('fw_raise_typed_dispute', params: {
          'p_order_item_id': widget.orderItemId,
          'p_kind': kind,
          if (qty > 0 && issue != 'wrong' && issue != 'not_coming') 'p_qty': qty,
          if (name.isNotEmpty) 'p_wrong_name': name,
          if (proofUrl != null) 'p_proof_url': proofUrl,
        }) as Map;
        if (!mounted) return;
        final err = res['error']?.toString();
        if (err != null) {
          setState(() => _saving = false);
          _showErr(err); // C531: backend fw_error_messages copy, not 'Error: <code>'
          return;
        }
        RenderLog.write('c351_typed', 'kind=$kind');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dispute raised')));
        widget.onSaved();
        return;
      }

      // C365: PRODUCT-level flag — fw_set_product_issue distributes the disputed qty across ALL
      // the supplier+product order-lines and caps at the TOTAL gap. Send p_qty for every kind
      // except not_coming (incl 'wrong', whose _qty is preset to the full ordered_total).
      final params = <String, dynamic>{
        'p_supplier': widget.supplierName,
        'p_product_id': widget.productId,
        'p_issue': issue,
      };
      if (issue != 'not_coming' && qty > 0) {
        params['p_qty'] = qty;
      }
      if (name.isNotEmpty && (issue == 'wrong' || issue == 'few_wrong')) {
        params['p_wrong_name'] = name;
      }
      if (proofUrl != null) params['p_proof_url'] = proofUrl;

      final res = await Supabase.instance.client.rpc('fw_set_product_issue', params: params) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        // C365: on qty_required{max}, snap the stepper to the backend's max so the retry is valid.
        if (err.startsWith('qty_required')) {
          final max = (res['max'] as num?)?.toInt();
          if (max != null && max > 0) _qty = max;
        }
        setState(() => _saving = false);
        _showErr(err);
        return;
      }
      final disputed = (res['disputed'] as num?)?.toInt() ?? qty;
      final gap = (res['gap'] as num?)?.toInt() ?? 0;
      RenderLog.write('c351_flag_saved', 'issue=$issue,qty=$qty');
      RenderLog.write('c359_flag_marked', 'issue=$issue'); // C359: flagged, not yet disputed
      RenderLog.write('c364_qty_submit', 'tab=${widget.tab ?? "?"},qty=$qty'); // C364: disputed qty saved
      RenderLog.write('c365_prod_issue', 'product=${widget.productId},disputed=$disputed,gap=$gap');
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      RenderLog.write('c531_issue_err', 'where=save');
      _showErr(null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      RenderLog.write('c351_ready', 'ui=v2');
      // C531: nothing here has a client-side copy fallback — while the backend
      // option table / error map is still in flight we render a spinner only.
      if (!FulfillLookups.instance.ready) {
        RenderLog.write('c531_issue_wait', 'ready=0');
        return const SizedBox(
          height: 44,
          child: Center(
            child: SizedBox(width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _kAmber)),
          ),
        );
      }
      if (!_expanded) {
        final ei = _cleanIssue(widget.existingIssue);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (ei != null) ...[
            _buildExistingChip(ei),
            const SizedBox(height: 6),
          ],
          _buildEntryButton(isEdit: ei != null),
        ]);
      }
      return _buildExpandedSection();
    });
  }

  Widget _buildExistingChip(String issue) {
    return Row(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _kAmberBorder),
        ),
        // C531: label verbatim from fw_issue_options; falls back to the raw
        // backend key (never to a client-authored English string).
        child: Text('Issue: ${FulfillLookups.instance.issueLabel(issue) ?? issue}',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kAmber)),
      ),
      const SizedBox(width: 8),
      TextButton(
        onPressed: _saving ? null : _clear,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFDC2626),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: _saving
            ? const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Clear', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  Widget _buildEntryButton({required bool isEdit}) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton.icon(
        onPressed: () => setState(() => _expanded = true),
        icon: const Icon(Icons.flag_outlined, size: 16),
        label: Text(
            isEdit ? 'Change issue' : 'Report issue',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          foregroundColor: _kAmber,
          side: const BorderSide(color: _kAmberBorder),
          backgroundColor: _kAmberBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildExpandedSection() {
    return Builder(builder: (_) {
      // C531: the option table (keys, labels, help, colours AND their order) is
      // fw_issue_options() verbatim. No client list, no client gating.
      final opts = FulfillLookups.instance.issueOptions;
      RenderLog.write('c351_section', 'n=${opts.length}');
      RenderLog.write('c363_opts5', 'n=${opts.length}');
      RenderLog.write('c531_issue_opts', 'n=${opts.length}');
      final hasExisting = _cleanIssue(widget.existingIssue) != null;
      const title = 'Report issue';
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _kAmberBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kAmberBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Header
          Row(children: [
            const Icon(Icons.flag_outlined, size: 14, color: _kAmber),
            const SizedBox(width: 6),
            Text(title,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kAmber)),
            const Spacer(),
            if (hasExisting)
              TextButton(
                onPressed: _saving ? null : _clear,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFDC2626),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('Clear issue',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            GestureDetector(
              onTap: () => setState(() => _expanded = false),
              child: const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.close, size: 18, color: _kSub),
              ),
            ),
          ]),
          const SizedBox(height: 10),

          // C531: backend order, backend labels/help/colours.
          for (final opt in opts) _buildOption(opt),

          // Conditional inputs + save
          if (_selected != null) ...[
            const SizedBox(height: 12),
            _buildInputs(),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                onPressed: _saveEnabled ? _save : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _kGreen,
                  disabledBackgroundColor: _kGreen.withValues(alpha: 0.4),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: _saving
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text('Save — ${FulfillLookups.instance.issueLabel(_selected) ?? _selected!}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                            color: Colors.white)),
              ),
            ),
          ],
        ]),
      );
    });
  }

  // C531: one row per fw_issue_options() entry. label/help/colors are printed
  // verbatim; the only client decision left is the selected/unselected glyph.
  Widget _buildOption(Map<String, dynamic> opt) {
    final value = opt['key']?.toString() ?? '';
    final label = opt['label']?.toString() ?? '';
    final hint  = opt['help']?.toString() ?? '';
    final colors = opt['colors'];
    final optBg = _hexColor(
        colors is Map ? colors['bg']?.toString() : null, const Color(0xFFFEF3C7));
    final optFg = _hexColor(colors is Map ? colors['fg']?.toString() : null, _kAmber);
    final isSelected = _selected == value;
    return GestureDetector(
      onTap: () => setState(() {
        if (_selected == value) return;
        _selected = value;
        // C364/C365: pre-fill the "Disputed units" stepper. GAP (aggregate ref − received) for
        // short/few_wrong/damaged; over-count (received − ref) for excess; FULL ordered_total for
        // 'wrong' (whole product). A save without stepping matches the product balance point.
        _qty = value == 'excess'
            ? (widget.receivedQty - _ref).clamp(1, 9999)
            : value == 'wrong'
                ? (_ref > 0 ? _ref : 1)
                : (_ref - widget.receivedQty).clamp(1, _ref > 0 ? _ref : 1);
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? optBg : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? optFg : _kBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
              size: 16, color: isSelected ? optFg : _kSub),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: isSelected ? optFg : _kText)),
              Text(hint, style: const TextStyle(fontSize: 11, color: _kSub)),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _buildInputs() {
    final issue = _selected!;
    // C531: WHICH inputs this kind needs is fw_issue_options()'s needs_qty /
    // needs_name / needs_proof — no client per-kind table.
    final lk = FulfillLookups.instance;
    final needsQty   = lk.needsQty(issue);
    final needsName  = lk.needsName(issue);
    final needsProof = lk.needsProof(issue);
    // C365: cap = the aggregate gap (short/few_wrong/damaged); excess uncapped; wrong = full ordered.
    final max = issue == 'excess' ? 9999 : issue == 'wrong' ? (_ref > 0 ? _ref : 1) : _maxQty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
      if (needsQty) ...[
        Builder(builder: (_) {
          RenderLog.write('c364_qty_field', 'tab=${widget.tab ?? "?"},default=$_qty');
          RenderLog.write('c364_qty_shown', 'where=popup,qty=$_qty');
          // C365: qty field renders for this type; stepper max = the total gap.
          RenderLog.write('c365_qty_alltypes', 'type=$issue');
          RenderLog.write('c365_qty_max', 'tab=${widget.tab ?? "?"},max=$max');
          return Text(
            issue == 'excess'
                ? 'Disputed units — how many?'
                : 'Disputed units — how many?  (max $max)',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
          );
        }),
        const SizedBox(height: 6),
        Row(children: [
          _RisStepper(
            value: _qty,
            min: 1,
            max: max,
            onChanged: (v) => setState(() => _qty = v),
          ),
          const SizedBox(width: 8),
          Text('units', style: const TextStyle(fontSize: 12, color: _kSub)),
        ]),
        const SizedBox(height: 10),
      ],
      if (needsName) ...[
        const Text(
          'What item did they send? *',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _nameCtrl,
          decoration: InputDecoration(
            hintText: 'e.g. Paracetamol 500mg instead',
            hintStyle: const TextStyle(fontSize: 13, color: _kSub),
            filled: true, fillColor: Colors.white, isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kBorder)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: _kGreen, width: 1.5)),
          ),
          style: const TextStyle(fontSize: 13),
          textCapitalization: TextCapitalization.sentences,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 10),
      ],
      // C531: the photo affordance is offered when the backend says the kind
      // takes proof (needs_proof); otherwise the option's own help text stands
      // in — printed verbatim, never a client-authored sentence.
      if (needsProof) ...[
        const Text('Photo proof (optional)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
        const SizedBox(height: 6),
        _buildPhotoRow(),
      ] else ...[
        Text(lk.issueOption(issue)?['help']?.toString() ?? '',
            style: const TextStyle(fontSize: 12, color: _kSub)),
        const SizedBox(height: 6),
      ],
    ]);
  }

  Widget _buildPhotoRow() {
    if (_proofUrl != null) {
      return Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(_proofUrl!, width: 48, height: 48, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) =>
                  const Icon(Icons.broken_image_outlined, size: 32, color: _kSub)),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: () => setState(() => _proofUrl = null),
          icon: const Icon(Icons.close, size: 14),
          label: const Text('Remove', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
              foregroundColor: const Color(0xFFDC2626),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4)),
        ),
      ]);
    }
    return SizedBox(
      height: 40,
      child: OutlinedButton.icon(
        onPressed: _uploading
            ? null
            : () async {
                setState(() => _uploading = true);
                final url = await _pickAndUpload();
                if (mounted) setState(() { _proofUrl = url; _uploading = false; });
              },
        icon: _uploading
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.camera_alt_outlined, size: 16),
        label: const Text('Attach photo', style: TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          foregroundColor: _kSub,
          side: const BorderSide(color: _kBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

}

class _RisStepper extends StatelessWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  const _RisStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _RisStepBtn(
        icon: Icons.remove,
        enabled: value > min,
        onTap: () => onChanged(value - 1),
      ),
      Container(
        width: 40,
        height: 36,
        alignment: Alignment.center,
        child: Text('$value',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
      ),
      _RisStepBtn(
        icon: Icons.add,
        enabled: value < max,
        onTap: () => onChanged(value + 1),
      ),
    ]);
  }
}

class _RisStepBtn extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _RisStepBtn({required this.icon, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        width: 32, height: 36,
        decoration: BoxDecoration(
          color: enabled ? const Color(0xFFF5F6F8) : const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _kBorder),
        ),
        child: Icon(icon, size: 16, color: enabled ? _kText : _kSub),
      ),
    );
  }
}
