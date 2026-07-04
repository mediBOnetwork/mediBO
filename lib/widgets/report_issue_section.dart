import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

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
  final int orderedQty;
  final int receivedQty;
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
    required this.orderedQty,
    required this.receivedQty,
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
    final ei = _cleanIssue(widget.existingIssue);
    if (ei != null) {
      _selected = ei;
      _qty = widget.existingIssueQty ?? 1;
      if (widget.existingWrongName != null && widget.existingWrongName!.isNotEmpty) {
        _nameCtrl.text = widget.existingWrongName!;
      }
      _proofUrl = widget.existingProofUrl;
      _expanded = true;
    } else if (widget.isShort && widget.onReportMissing != null) {
      // C359: line already marked short — pre-select the short option (qty = received).
      _selected = 'short';
      _qty = widget.receivedQty;
      _expanded = true;
    }
  }

  @override
  void didUpdateWidget(ReportIssueSection old) {
    super.didUpdateWidget(old);
    // C353: item values may refresh in place while the sheet stays open —
    // drop a selection that is no longer offered by the gated option list.
    if (_selected != null && !_gatedOptions.any((o) => o.$1 == _selected)) {
      _selected = null;
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  String? _cleanIssue(String? raw) {
    if (raw == null || raw.isEmpty || raw == 'null') return null;
    return raw;
  }

  int get _maxQty {
    final uncounted = widget.orderedQty - widget.receivedQty;
    return uncounted > 0 ? uncounted : (widget.orderedQty > 0 ? widget.orderedQty : 1);
  }

  bool get _saveEnabled {
    if (_selected == null || _saving) return false;
    if (_selected == 'few_wrong') {
      return _qty >= 1 && _nameCtrl.text.trim().isNotEmpty;
    }
    // C359: short — received qty may be 0..ordered (0 = fully missing); always valid.
    if (_selected == 'short') return true;
    return true;
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
    // C359: clearing a short un-does the report-missing (fw_product_undo) via the parent.
    if ((_selected == 'short' || (widget.isShort && _cleanIssue(widget.existingIssue) == null)) &&
        widget.onReportMissing != null) {
      try {
        await widget.onReportMissing!(null); // null = clear/undo the short
        if (!mounted) return;
        RenderLog.write('c359_flag_marked', 'issue=short_cleared');
        widget.onSaved();
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
      return;
    }
    try {
      final res = await Supabase.instance.client.rpc('fw_set_line_issue', params: {
        'p_order_item_id': widget.orderItemId,
        'p_issue': 'clear',
      }) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      RenderLog.write('c351_flag_cleared', 'ok=1');
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _save() async {
    if (!_saveEnabled) return;
    setState(() => _saving = true);
    final issue = _selected!;
    final qty = _qty;
    final name = _nameCtrl.text.trim();
    final proofUrl = _proofUrl;
    // C359: "Report missing / Short" — reuse the parent's existing report-missing
    // flow (fw_product_action). Flag only; the confirm RPC raises the dispute later.
    if (issue == 'short') {
      try {
        await widget.onReportMissing!(qty); // qty = units received
        if (!mounted) return;
        RenderLog.write('c359_flag_marked', 'issue=short');
        widget.onSaved();
      } catch (e) {
        if (!mounted) return;
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
      return;
    }
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
          return;
        }
        RenderLog.write('c351_typed', 'kind=$kind');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Dispute raised')));
        widget.onSaved();
        return;
      }

      final params = <String, dynamic>{
        'p_order_item_id': widget.orderItemId,
        'p_issue': issue,
      };
      if ((issue == 'few_wrong' || issue == 'damaged' || issue == 'excess') && qty > 0) {
        params['p_qty'] = qty;
      }
      if (name.isNotEmpty && (issue == 'wrong' || issue == 'few_wrong')) {
        params['p_wrong_name'] = name;
      }
      if (proofUrl != null) params['p_proof_url'] = proofUrl;

      final res = await Supabase.instance.client.rpc('fw_set_line_issue', params: params) as Map;
      if (!mounted) return;
      final err = res['error']?.toString();
      if (err != null) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $err'), backgroundColor: const Color(0xFFDC2626)));
        return;
      }
      RenderLog.write('c351_flag_saved', 'issue=$issue,qty=$qty');
      RenderLog.write('c359_flag_marked', 'issue=$issue'); // C359: flagged, not yet disputed
      widget.onSaved();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Builder(builder: (ctx) {
      RenderLog.write('c351_ready', 'ui=v2');
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
        child: Text('Issue: ${_issueLabel(issue)}',
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
            isEdit ? 'Change issue' : (_gateMode == 'excess' ? 'Report excess' : 'Report issue'),
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

  static const _options = [
    // C359: "Report missing / Short" — moved in from the old standalone button.
    ('short',      Icons.content_cut_rounded,        'Report missing / Short', 'Fewer units arrived than ordered'),
    ('wrong',      Icons.swap_horiz_rounded,         'Wrong item',        'Whole line is wrong'),
    ('few_wrong',  Icons.remove_circle_outline,      'Few units wrong',   'Some units are wrong'),
    ('damaged',    Icons.broken_image_outlined,      'Damaged / expired', 'Units are damaged or expired'),
    ('excess',     Icons.add_circle_outline_rounded, 'Excess received',   'More units than ordered'),
    ('not_coming', Icons.block_outlined,             'Not coming',        'Item will leave the counting list'),
  ];

  // C359: the short option is only offered when the parent wired the report-missing
  // callback AND the line can actually be short (received < ordered).
  bool get _shortOffered =>
      widget.onReportMissing != null && widget.receivedQty < widget.orderedQty;

  // C353 B2: probable-dispute gating — only offer issues that are actually
  // possible for the line's current ordered/received state. An existing flag
  // keeps the full list so it can be changed or cleared.
  String get _gateMode {
    if (_cleanIssue(widget.existingIssue) != null) return 'flagged';
    if (widget.isShort && widget.onReportMissing != null) return 'flagged';
    if (widget.receivedQty >= widget.orderedQty && widget.orderedQty > 0) return 'excess';
    if (widget.receivedQty > 0) return 'partial';
    return 'full';
  }

  List<(String, IconData, String, String)> get _gatedOptions {
    Iterable<(String, IconData, String, String)> opts;
    switch (_gateMode) {
      case 'excess':
        opts = _options.where((o) => o.$1 == 'excess');
        break;
      case 'partial':
        opts = _options.where((o) =>
            o.$1 == 'short' || o.$1 == 'wrong' || o.$1 == 'few_wrong' || o.$1 == 'damaged');
        break;
      case 'full':
        opts = _options.where((o) => o.$1 != 'excess');
        break;
      default: // flagged
        opts = _options;
    }
    // C359: only offer the short option when the parent wired the report-missing flow.
    if (!_shortOffered) opts = opts.where((o) => o.$1 != 'short');
    return opts.toList();
  }

  Widget _buildExpandedSection() {
    return Builder(builder: (_) {
      final opts = _gatedOptions;
      RenderLog.write('c351_section', 'n=${opts.length}');
      RenderLog.write('c353_gate', 'mode=$_gateMode');
      RenderLog.write('c354_gate', 'tab=${widget.tab ?? "?"},mode=$_gateMode');
      final hasExisting = _cleanIssue(widget.existingIssue) != null ||
          (widget.isShort && widget.onReportMissing != null);
      final title = _gateMode == 'excess' ? 'Report excess' : 'Report issue';
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

          // C353 B2: gated options — only probable-dispute issues for this line
          for (final opt in opts)
            _buildOption(opt.$1, opt.$2, opt.$3, opt.$4),

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
                    : Text('Save — ${_issueLabel(_selected!)}',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700,
                            color: Colors.white)),
              ),
            ),
          ],
        ]),
      );
    });
  }

  Widget _buildOption(String value, IconData icon, String label, String hint) {
    final isSelected = _selected == value;
    return GestureDetector(
      onTap: () => setState(() {
        if (_selected == value) return;
        _selected = value;
        // C359: short defaults its qty to the units already counted as received.
        _qty = value == 'short' ? widget.receivedQty.clamp(0, widget.orderedQty) : 1;
      }),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFEF3C7) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? _kAmberBorder : _kBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(icon, size: 16, color: isSelected ? _kAmber : _kSub),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600,
                      color: isSelected ? _kAmber : _kText)),
              Text(hint, style: const TextStyle(fontSize: 11, color: _kSub)),
            ]),
          ),
          if (isSelected)
            const Icon(Icons.check_circle_rounded, size: 16, color: _kAmber),
        ]),
      ),
    );
  }

  Widget _buildInputs() {
    final issue = _selected!;
    // C359: short — enter how many actually arrived; the rest is the missing gap
    // that the confirm RPC raises as a short dispute. No name / no photo needed.
    if (issue == 'short') {
      final missing = (widget.orderedQty - _qty).clamp(0, widget.orderedQty);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
          children: [
        Text('Units received (of ${widget.orderedQty})',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
        const SizedBox(height: 6),
        Row(children: [
          _RisStepper(
            value: _qty,
            min: 0,
            max: widget.orderedQty,
            onChanged: (v) => setState(() => _qty = v),
          ),
          const SizedBox(width: 10),
          Text('$missing missing',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kAmber)),
        ]),
        const SizedBox(height: 6),
        const Text('The missing units are raised as a short dispute when you confirm.',
            style: TextStyle(fontSize: 11, color: _kSub)),
      ]);
    }
    final needsQty = issue == 'few_wrong' || issue == 'damaged' || issue == 'excess';
    final needsName = issue == 'few_wrong' || issue == 'wrong';
    final nameRequired = issue == 'few_wrong';
    final max = issue == 'excess' ? 9999 : _maxQty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
        children: [
      if (needsQty) ...[
        Text(
          issue == 'few_wrong' ? 'Wrong units (max $max)' :
          issue == 'damaged'   ? 'Damaged units (max $max)' : 'Excess units',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
        ),
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
        Text(
          nameRequired ? 'What item did they send? *' : 'What item (optional)',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText),
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
      if (issue == 'not_coming') ...[
        const Text('Item will leave the counting list.',
            style: TextStyle(fontSize: 12, color: _kSub)),
        const SizedBox(height: 6),
      ] else ...[
        const Text('Photo proof (optional)',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: _kText)),
        const SizedBox(height: 6),
        _buildPhotoRow(),
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

  String _issueLabel(String issue) => switch (issue) {
    'short'      => 'Report missing',
    'wrong'      => 'Wrong item',
    'few_wrong'  => 'Few wrong',
    'damaged'    => 'Damaged',
    'excess'     => 'Excess',
    'not_coming' => 'Not coming',
    _            => issue,
  };
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
