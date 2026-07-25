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

Color get _kGreen  => FulfillLookups.instance.color('c_ff1b7a43');
Color get _kText   => FulfillLookups.instance.color('c_ff111827');
Color get _kSub    => FulfillLookups.instance.color('c_ff6b7280');
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb');
Color get _kAmber  => FulfillLookups.instance.color('c_ffb45309');
Color get _kAmberBg => FulfillLookups.instance.color('c_fffffbeb');
Color get _kAmberBorder => FulfillLookups.instance.color('c_fffcd34d');

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
  // C532: null until the backend hands us a per-kind default (fw_issue_qty_rules).
  // There is deliberately no client seed value — the stepper renders its loading
  // state instead of guessing a number.
  int? _qty;
  final _nameCtrl = TextEditingController();
  String? _proofUrl;
  bool _uploading = false;
  bool _saving = false;

  // C532: fw_issue_qty_rules(p_order_item_id) payload — the ONLY source of the
  // qty reference, per-kind min/max and per-kind default. Fetched ONCE per
  // order_item_id when the section first expands; never per render/keystroke.
  Map<String, dynamic>? _qtyRules;
  String? _rulesFor; // order_item_id the payload/in-flight fetch belongs to

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
      // Saved qty is a backend value; absent means "let the rules default fill it".
      _qty = widget.existingIssueQty;
      if (widget.existingWrongName != null && widget.existingWrongName!.isNotEmpty) {
        _nameCtrl.text = widget.existingWrongName!;
      }
      _proofUrl = widget.existingProofUrl;
      _expanded = true;
      _loadQtyRules();
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
    // C532: the sheet can be re-pointed at another line in place — the cached
    // qty rules belong to the OLD order_item_id, so drop them and refetch once.
    if (old.orderItemId != widget.orderItemId) {
      _qtyRules = null;
      _rulesFor = null;
      _qty = null;
      if (_expanded) _loadQtyRules();
    }
  }

  // ── C532: backend qty rules ────────────────────────────────────────────────

  /// Fetched ONCE per order_item_id (on first expand). Idempotent.
  Future<void> _loadQtyRules() async {
    final id = widget.orderItemId;
    if (_rulesFor == id) return; // loaded or already in flight for this line
    _rulesFor = id;
    try {
      final res = await Supabase.instance.client
          .rpc('fw_issue_qty_rules', params: {'p_order_item_id': id});
      if (!mounted || widget.orderItemId != id) return;
      final map = res is Map ? Map<String, dynamic>.from(res) : null;
      final err = map?['error']?.toString();
      if (map == null || err != null) {
        _rulesFor = null; // allow a retry on the next expand
        setState(() {});
        RenderLog.write('c532_qty_rules_err', 'code=${err ?? "shape"}');
        _showErr(err); // C531: backend fw_error_messages copy only
        return;
      }
      setState(() {
        _qtyRules = map;
        // Fill the stepper only if nothing (saved qty) is already in it.
        if (_selected != null && _qty == null) _qty = _ruleInt(_selected, 'default');
      });
      RenderLog.write('c532_qty_rules',
          'ref=${map['ref_qty']},label=${map['ref_label']}');
    } catch (_) {
      if (!mounted) return;
      _rulesFor = null;
      setState(() {});
      RenderLog.write('c532_qty_rules_err', 'code=exception');
      _showErr(null); // backend 'default' message
    }
  }

  /// rules[kind] as returned: {min,max,default}. Null while unloaded/unknown.
  Map<String, dynamic>? _ruleFor(String? kind) {
    if (kind == null) return null;
    final r = _qtyRules?['rules'];
    if (r is! Map) return null;
    final k = r[kind];
    return k is Map ? Map<String, dynamic>.from(k) : null;
  }

  int? _ruleInt(String? kind, String field) {
    final v = _ruleFor(kind)?[field];
    return v is num ? v.toInt() : null;
  }

  /// Backend `ref_label` (`counted/ref_qty`), ready to render. Empty while unloaded.
  String get _refLabel => _qtyRules?['ref_label']?.toString() ?? '';

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

  // C532: _ref / _maxQty deleted — the reference qty and every per-kind bound
  // now come from fw_issue_qty_rules (ref_qty / rules[kind].min|max|default).

  bool get _saveEnabled {
    if (_selected == null || _saving) return false;
    // C531: WHICH inputs a kind requires is backend-owned (fw_issue_options
    // needs_qty / needs_name). Only the pure keystroke checks live here.
    final lk = FulfillLookups.instance;
    if (lk.needsQty(_selected)) {
      // C532: bounds are the backend's; unloaded rules => not saveable yet.
      final q = _qty;
      final lo = _ruleInt(_selected, 'min');
      final hi = _ruleInt(_selected, 'max');
      if (q == null || lo == null || hi == null) return false;
      if (q < lo || q > hi) return false;
    }
    if (lk.needsName(_selected) && _nameCtrl.text.trim().isEmpty) return false;
    return true;
  }

  /// Backend-owned error copy. Never falls back to a client string — an empty
  /// result means the lookup cache has not landed and we stay silent.
  void _showErr(String? code) {
    final text = FulfillLookups.instance.message(code);
    if (!mounted || text == null || text.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), backgroundColor: FulfillLookups.instance.color('c_ffdc2626')));
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
    // C532: 0 when the kind takes no qty (backend rules[kind].default == 0) —
    // the p_qty payload conditions below are unchanged.
    final qty = _qty ?? 0;
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
          SnackBar(content: Text(FulfillLookups.instance.ui('dispute_raised'))));
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
        return SizedBox(
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
          color: FulfillLookups.instance.color('c_fffef3c7'),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _kAmberBorder),
        ),
        // C531: label verbatim from fw_issue_options; falls back to the raw
        // backend key (never to a client-authored English string).
        child: Text(FulfillLookups.instance.uiFill('issue_line', {'label': FulfillLookups.instance.issueLabel(issue) ?? issue}),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kAmber)),
      ),
      const SizedBox(width: 8),
      TextButton(
        onPressed: _saving ? null : _clear,
        style: TextButton.styleFrom(
          foregroundColor: FulfillLookups.instance.color('c_ffdc2626'),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: _saving
            ? const SizedBox(width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(FulfillLookups.instance.ui('clear'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  Widget _buildEntryButton({required bool isEdit}) {
    return SizedBox(
      width: double.infinity,
      height: 44,
      child: OutlinedButton.icon(
        // C532: the qty rules are fetched ONCE here — when the section first
        // expands for this order_item_id — not per render and not per keystroke.
        onPressed: () {
          setState(() => _expanded = true);
          _loadQtyRules();
        },
        icon: const Icon(Icons.flag_outlined, size: 16),
        label: Text(
            isEdit ? 'Change issue' : 'Report issue',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          foregroundColor: _kAmber,
          side: BorderSide(color: _kAmberBorder),
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
            Icon(Icons.flag_outlined, size: 14, color: _kAmber),
            const SizedBox(width: 6),
            Text(title,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kAmber)),
            const Spacer(),
            if (hasExisting)
              TextButton(
                onPressed: _saving ? null : _clear,
                style: TextButton.styleFrom(
                  foregroundColor: FulfillLookups.instance.color('c_ffdc2626'),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: Text(FulfillLookups.instance.ui('clear_issue'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            GestureDetector(
              onTap: () => setState(() => _expanded = false),
              child: Padding(
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
                    : Text(FulfillLookups.instance.uiFill('save_issue', {'label': FulfillLookups.instance.issueLabel(_selected) ?? _selected!}),
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
        colors is Map ? colors['bg']?.toString() : null, FulfillLookups.instance.color('c_fffef3c7'));
    final optFg = _hexColor(colors is Map ? colors['fg']?.toString() : null, _kAmber);
    final isSelected = _selected == value;
    return GestureDetector(
      onTap: () => setState(() {
        if (_selected == value) return;
        _selected = value;
        // C532: the "Disputed units" pre-fill is fw_issue_qty_rules'
        // rules[kind].default, verbatim. No client per-kind arithmetic. Null
        // while the payload is still in flight -> the stepper shows loading.
        _qty = _ruleInt(value, 'default');
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
              Text(hint, style: TextStyle(fontSize: 11, color: _kSub)),
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
    // C532: every bound is fw_issue_qty_rules' rules[<kind>] — no client caps,
    // no per-kind branching. Null => payload still in flight.
    final min = _ruleInt(issue, 'min');
    final max = _ruleInt(issue, 'max');
    final qty = _qty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
      if (needsQty) ...[
        if (min == null || max == null || qty == null)
          // C532: rules not landed — loading state only, never a guessed number.
          Builder(builder: (_) {
            RenderLog.write('c532_qty_wait', 'type=$issue');
            return SizedBox(
              height: 36,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _kAmber)),
              ),
            );
          })
        else ...[
          Builder(builder: (_) {
            RenderLog.write('c364_qty_field', 'tab=${widget.tab ?? "?"},default=$qty');
            RenderLog.write('c364_qty_shown', 'where=popup,qty=$qty');
            // C365: qty field renders for this type; C532: bounds are backend-owned.
            RenderLog.write('c365_qty_alltypes', 'type=$issue');
            RenderLog.write('c365_qty_max', 'tab=${widget.tab ?? "?"},max=$max');
            return Text(
              FulfillLookups.instance.uiFill('disputed_units_prompt', {'max': max}),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
            );
          }),
          const SizedBox(height: 6),
          Row(children: [
            _RisStepper(
              value: qty,
              min: min,
              max: max,
              onChanged: (v) => setState(() => _qty = v),
            ),
            const SizedBox(width: 8),
            Text(FulfillLookups.instance.ui('units'), style: TextStyle(fontSize: 12, color: _kSub)),
            if (_refLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              // C532: ref_label ('<counted>/<ref_qty>') printed verbatim.
              Text(_refLabel, style: TextStyle(fontSize: 12, color: _kSub)),
            ],
          ]),
        ],
        const SizedBox(height: 10),
      ],
      if (needsName) ...[
        Text(
          FulfillLookups.instance.ui('what_item_sent'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _nameCtrl,
          decoration: InputDecoration(
            hintText: FulfillLookups.instance.ui('wrong_item_hint'),
            hintStyle: TextStyle(fontSize: 13, color: _kSub),
            filled: true, fillColor: Colors.white, isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: _kBorder)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: _kBorder)),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: _kGreen, width: 1.5)),
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
        Text(FulfillLookups.instance.ui('photo_proof_optional'),
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
        const SizedBox(height: 6),
        _buildPhotoRow(),
      ] else ...[
        Text(lk.issueOption(issue)?['help']?.toString() ?? '',
            style: TextStyle(fontSize: 12, color: _kSub)),
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
                  Icon(Icons.broken_image_outlined, size: 32, color: _kSub)),
        ),
        const SizedBox(width: 8),
        TextButton.icon(
          onPressed: () => setState(() => _proofUrl = null),
          icon: const Icon(Icons.close, size: 14),
          label: Text(FulfillLookups.instance.ui('remove'), style: const TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(
              foregroundColor: FulfillLookups.instance.color('c_ffdc2626'),
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
        label: Text(FulfillLookups.instance.ui('attach_photo'), style: const TextStyle(fontSize: 12)),
        style: OutlinedButton.styleFrom(
          foregroundColor: _kSub,
          side: BorderSide(color: _kBorder),
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
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
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
          color: enabled ? FulfillLookups.instance.color('c_fff5f6f8') : FulfillLookups.instance.color('c_fff9fafb'),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _kBorder),
        ),
        child: Icon(icon, size: 16, color: enabled ? _kText : _kSub),
      ),
    );
  }
}
