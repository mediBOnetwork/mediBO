// CMD #2014 — Cart bill & rail.
//
// The admin surface behind the customer cart's bill summary card and its
// suggested rail. Everything this screen edits is a backend row, and the cart
// reads those rows on its next load: a label, a fee amount, a popup body, a
// row's position or its visibility all change what customers see WITHOUT a
// rebuild.
//
// Every word on screen — the title, the field labels, the option names, the
// zone line — comes from admin_cart_bill_list(). This file writes none of them.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

class AdminCartBillScreen extends StatefulWidget {
  /// Injected so a test can drive the screen without Supabase; production
  /// leaves them null and the screen calls the RPCs directly.
  final Future<Map<String, dynamic>> Function()? listRpc;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> row)? saveRowRpc;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> cfg)? saveRailRpc;

  const AdminCartBillScreen({
    super.key,
    this.listRpc,
    this.saveRowRpc,
    this.saveRailRpc,
  });

  @override
  State<AdminCartBillScreen> createState() => _AdminCartBillScreenState();
}

class _AdminCartBillScreenState extends State<AdminCartBillScreen> {
  Map<String, dynamic> _payload = const <String, dynamic>{};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    RenderLog.write('c2014_admin_bill_opened', 1);
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic>? params) async {
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final m = widget.listRpc != null
          ? await widget.listRpc!()
          : await _call('admin_cart_bill_list', null);
      if (!mounted) return;
      setState(() {
        _payload = m;
        _loading = false;
        _error = m['ok'] == true ? '' : (m['message'] ?? '').toString();
      });
      final rows = (m['rows'] as List?) ?? const [];
      RenderLog.write('c2014_admin_bill_rows', rows.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveRow(Map<String, dynamic> patch) async {
    final m = widget.saveRowRpc != null
        ? await widget.saveRowRpc!(patch)
        : await _call('admin_cart_bill_save', {'p_row': patch});
    if (!mounted) return;
    setState(() {
      _payload = m;
      _error = m['ok'] == true ? '' : (m['message'] ?? '').toString();
    });
  }

  Future<void> _saveRail(Map<String, dynamic> cfg) async {
    final m = widget.saveRailRpc != null
        ? await widget.saveRailRpc!(cfg)
        : await _call('admin_cart_rail_save', {'p_cfg': cfg});
    if (!mounted) return;
    setState(() {
      _payload = m;
      _error = m['ok'] == true ? '' : (m['message'] ?? '').toString();
    });
  }

  List<Map<String, dynamic>> get _rows => ((_payload['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Map<String, dynamic> get _rail => _payload['rail'] is Map
      ? Map<String, dynamic>.from(_payload['rail'] as Map)
      : const <String, dynamic>{};

  List<String> _opts(String key) => ((_payload[key] as List?) ?? const [])
      .map((e) => e.toString())
      .toList();

  /// Every caption on this screen is a key of the payload's `labels` object.
  /// An unknown key renders nothing rather than an invented English word.
  Map<String, String> get _labels {
    final raw = _payload['labels'];
    if (raw is! Map) return const <String, String>{};
    return raw.map((k, v) => MapEntry(k.toString(), (v ?? '').toString()));
  }

  @override
  Widget build(BuildContext context) {
    final title = (_payload['title'] ?? '').toString();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        elevation: Ds.space(0) * 0,
        title: Text(title, style: Ds.t.subtitle),
      ),
      body: _loading
          ? const _BillSkeleton()
          : RefreshIndicator(
              onRefresh: _load,
              color: Ds.c.brand,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x12, Ds.space.x12, Ds.space.x12, Ds.space.x32),
                children: [
                  if (_error.isNotEmpty)
                    _ErrorCard(
                        message: _error,
                        retryLabel: _labels['retry'] ?? '',
                        onRetry: _load),
                  _ZoneLine(line: (_payload['zone_line'] ?? '').toString()),
                  SizedBox(height: Ds.space.x12),
                  _Heading(text: _labels['rail_heading'] ?? ''),
                  _RailCard(
                    cfg: _rail,
                    sources: _opts('rail_sources'),
                    labels: _labels,
                    onSave: _saveRail,
                  ),
                  SizedBox(height: Ds.space.x24),
                  _Heading(text: _labels['rows_heading'] ?? ''),
                  for (final r in _rows) ...[
                    _RowCard(
                      row: r,
                      sources: _opts('sources'),
                      tones: _opts('tones'),
                      labels: _labels,
                      onSave: _saveRow,
                    ),
                    SizedBox(height: Ds.space.x12),
                  ],
                ],
              ),
            ),
    );
  }
}

class _ZoneLine extends StatelessWidget {
  final String line;
  const _ZoneLine({required this.line});

  @override
  Widget build(BuildContext context) {
    if (line.isEmpty) return SizedBox(height: Ds.space(0) * 0);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
      child: Text(line, style: Ds.t.caption),
    );
  }
}

class _Heading extends StatelessWidget {
  final String text;
  const _Heading({required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return SizedBox(height: Ds.space(0) * 0);
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x4, Ds.space.x8, Ds.space.x4, Ds.space.x8),
      child: Text(text, style: Ds.t.subtitle),
    );
  }
}

/// One editable bill row. Saved on demand, never on every keystroke: the
/// backend answers a save with the WHOLE list, so the card always redraws from
/// the server's version rather than from what was typed.
class _RowCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final List<String> sources;
  final List<String> tones;
  final Map<String, String> labels;
  final Future<void> Function(Map<String, dynamic> patch) onSave;

  const _RowCard({
    required this.row,
    required this.sources,
    required this.tones,
    required this.labels,
    required this.onSave,
  });

  @override
  State<_RowCard> createState() => _RowCardState();
}

class _RowCardState extends State<_RowCard> {
  late final TextEditingController _label;
  late final TextEditingController _icon;
  late final TextEditingController _order;
  late final TextEditingController _amount;
  late final TextEditingController _formula;
  late final TextEditingController _popupTitle;
  late final TextEditingController _popupBody;
  late final TextEditingController _popupDismiss;
  late TextEditingController _fallback;
  late String _source;
  late String _tone;
  late bool _visible;
  late bool _waived;
  late bool _bold;
  late bool _divider;
  bool _busy = false;
  bool _open = false;

  String _s(String k) => (widget.row[k] ?? '').toString();
  String t(String k) => widget.labels[k] ?? '';

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: _s('label'));
    _icon = TextEditingController(text: _s('icon'));
    _order = TextEditingController(text: _s('sort_order'));
    _amount = TextEditingController(text: _s('fixed_amount'));
    _formula = TextEditingController(text: _s('formula'));
    _popupTitle = TextEditingController(text: _s('popup_title'));
    _popupBody = TextEditingController(text: _s('popup_body'));
    _popupDismiss = TextEditingController(text: _s('popup_dismiss'));
    // CMD #2079 — the sentence a row prints instead of a price while the
    // basket is not fully priced yet. Stored copy, edited here, never in Dart.
    _fallback = TextEditingController(text: _s('fallback_text'));
    _source = _s('value_source');
    _tone = _s('tone');
    _visible = widget.row['visible'] == true;
    _waived = widget.row['waived'] == true;
    _bold = widget.row['bold'] == true;
    _divider = widget.row['divider_before'] == true;
  }

  @override
  void dispose() {
    for (final c in [
      _label,
      _icon,
      _order,
      _amount,
      _formula,
      _popupTitle,
      _popupBody,
      _popupDismiss,
      _fallback,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.onSave(<String, dynamic>{
        'id': widget.row['id'],
        'label': _label.text,
        'icon': _icon.text,
        'sort_order': _order.text,
        'visible': _visible,
        'value_source': _source,
        'fixed_amount': _amount.text,
        'formula': _formula.text,
        'waived': _waived,
        'tone': _tone,
        'bold': _bold,
        'divider_before': _divider,
        'popup_title': _popupTitle.text,
        'popup_body': _popupBody.text,
        'popup_dismiss': _popupDismiss.text,
        'fallback_text': _fallback.text,
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // CMD #2079 — a stable handle for this row, so the feature journey
          // can open exactly the fee it is about instead of the first card on
          // the screen. The key is the backend's, never invented here.
          Semantics(
            button: true,
            identifier: 'cart_bill_row_${_s('key')}',
            child: InkWell(
            onTap: () => setState(() => _open = !_open),
            borderRadius: Ds.r.rButton,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_label.text, style: Ds.t.body),
                        Text(_s('key'), style: Ds.t.caption),
                      ],
                    ),
                  ),
                  Switch(
                    value: _visible,
                    activeThumbColor: Ds.c.brand,
                    onChanged: (v) => setState(() => _visible = v),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: Ds.c.textSecondary),
                ],
              ),
            ),
          ),
          ),
          if (_open) ...[
            SizedBox(height: Ds.space.x12),
            _Field(label: t('label'), ctrl: _label),
            _Field(label: t('icon'), ctrl: _icon),
            _Field(label: t('sort_order'), ctrl: _order, numeric: true),
            _Choice(
              label: t('value_source'),
              value: _source,
              options: widget.sources,
              onChanged: (v) => setState(() => _source = v),
            ),
            _Field(label: t('fixed_amount'), ctrl: _amount, numeric: true),
            _Field(label: t('formula'), ctrl: _formula),
            _Choice(
              label: t('tone'),
              value: _tone,
              options: widget.tones,
              onChanged: (v) => setState(() => _tone = v),
            ),
            _Toggle(
                label: t('waived'),
                value: _waived,
                onChanged: (v) => setState(() => _waived = v)),
            _Toggle(
                label: t('bold'),
                value: _bold,
                onChanged: (v) => setState(() => _bold = v)),
            _Toggle(
                label: t('divider_before'),
                value: _divider,
                onChanged: (v) => setState(() => _divider = v)),
            _Field(label: t('fallback_text'), ctrl: _fallback),
            _Field(label: t('popup_title'), ctrl: _popupTitle),
            _Field(label: t('popup_body'), ctrl: _popupBody, lines: 3),
            _Field(label: t('popup_dismiss'), ctrl: _popupDismiss),
            SizedBox(height: Ds.space.x12),
            _SaveButton(busy: _busy, label: t('save'), onPressed: _save),
          ],
        ],
      ),
    );
  }
}

class _RailCard extends StatefulWidget {
  final Map<String, dynamic> cfg;
  final List<String> sources;
  final Map<String, String> labels;
  final Future<void> Function(Map<String, dynamic> cfg) onSave;
  const _RailCard(
      {required this.cfg,
      required this.sources,
      required this.labels,
      required this.onSave});

  @override
  State<_RailCard> createState() => _RailCardState();
}

class _RailCardState extends State<_RailCard> {
  late final TextEditingController _title;
  late final TextEditingController _max;
  late String _source;
  late bool _enabled;
  bool _busy = false;

  String t(String k) => widget.labels[k] ?? '';

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: (widget.cfg['title'] ?? '').toString());
    _max = TextEditingController(text: (widget.cfg['max_items'] ?? '').toString());
    _source = (widget.cfg['source'] ?? '').toString();
    _enabled = widget.cfg['enabled'] == true;
  }

  @override
  void dispose() {
    _title.dispose();
    _max.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      await widget.onSave(<String, dynamic>{
        'zone_id': (widget.cfg['zone_id'] ?? '').toString(),
        'enabled': _enabled,
        'title': _title.text,
        'source': _source,
        'max_items': _max.text,
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Toggle(
              label: t('rail_enabled'),
              value: _enabled,
              onChanged: (v) => setState(() => _enabled = v)),
          _Field(label: t('rail_title'), ctrl: _title),
          _Choice(
            label: t('rail_source'),
            value: _source,
            options: widget.sources,
            onChanged: (v) => setState(() => _source = v),
          ),
          _Field(label: t('rail_max'), ctrl: _max, numeric: true),
          SizedBox(height: Ds.space.x12),
          _SaveButton(busy: _busy, label: t('save'), onPressed: _save),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  final bool numeric;
  final int lines;
  const _Field({
    required this.label,
    required this.ctrl,
    this.numeric = false,
    this.lines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: TextField(
        controller: ctrl,
        maxLines: lines,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        style: Ds.t.body,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: Ds.t.caption,
          filled: true,
          fillColor: Ds.c.bg,
          contentPadding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x12),
          border: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Ds.r.rButton,
            borderSide: BorderSide(color: Ds.c.brand),
          ),
        ),
      ),
    );
  }
}

class _Choice extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  const _Choice({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return SizedBox(height: Ds.space(0) * 0);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final o in options)
                ChoiceChip(
                  label: Text(o, style: Ds.t.caption),
                  selected: o == value,
                  selectedColor: Ds.c.brandSoft,
                  backgroundColor: Ds.c.bg,
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
                  onSelected: (_) => onChanged(o),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle(
      {required this.label, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ds.t.body)),
          Switch(
              value: value, activeThumbColor: Ds.c.brand, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SaveButton extends StatelessWidget {
  final bool busy;
  final String label;
  final VoidCallback onPressed;
  const _SaveButton(
      {required this.busy, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: Ds.touch.minTarget,
      child: FilledButton(
        onPressed: busy ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: Ds.c.brand,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
        child: busy
            ? SizedBox(
                width: Ds.space.x16,
                height: Ds.space.x16,
                child: CircularProgressIndicator(
                    strokeWidth: Ds.space.x4 / 2, color: Ds.c.surface),
              )
            : Text(label,
                style: Ds.t.body.copyWith(
                    color: Ds.c.surface, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorCard(
      {required this.message, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.dangerSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Row(
        children: [
          Expanded(
              child: Text(message,
                  style: Ds.t.body.copyWith(color: Ds.c.danger))),
          SizedBox(width: Ds.space.x12),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(foregroundColor: Ds.c.danger),
            child: Text(retryLabel,
                style: Ds.t.body.copyWith(color: Ds.c.danger)),
          ),
        ],
      ),
    );
  }
}

class _BillSkeleton extends StatelessWidget {
  const _BillSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x12),
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            height: Ds.touch.listRowMinHeight + Ds.space.x16,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              border: Border.all(color: Ds.c.divider),
            ),
          ),
      ],
    );
  }
}
