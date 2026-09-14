// CMD #1930 — THE PARSER RULE EDITOR (super admin).
//
// A new payment app must never need a new build. This screen is the whole of
// that promise: the rule list, the form's own fields, the test box and every
// verdict arrive from payment_alert_rules_screen() / payment_alert_rule_test(),
// and saving is one RPC.
//
// THE FORM IS THE BACKEND'S. `fields[]` names each input, its label, its hint,
// whether it is required and how many lines it gets — so a seventh regex is an
// UPDATE to that array, not a deploy of this file.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/payment_alerts_service.dart';
import '../../utils/render_log.dart';
import 'payment_alerts_screen.dart' show payAlertTone, payAlertToneSoft;

String _s(Object? v) => v == null ? '' : v.toString().trim();

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PaymentAlertRulesScreen extends StatefulWidget {
  const PaymentAlertRulesScreen({super.key, this.rpc});

  final PayAlertRpc? rpc;

  @override
  State<PaymentAlertRulesScreen> createState() => _PaymentAlertRulesScreenState();
}

class _PaymentAlertRulesScreenState extends State<PaymentAlertRulesScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String _error = '';
  String _busy = '';

  PayAlertRpc get _call => widget.rpc ?? payAlertLiveRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_rules_screen', const {});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['ok'] == true) {
        _payload = res;
        _error = '';
      } else {
        _error = _s(res['message']).isNotEmpty ? _s(res['message']) : _s(res['error']);
      }
    });
    RenderLog.write('c1930_rule_rows', _rows(_payload['rows']).length);
  }

  Future<void> _save(Map<String, dynamic> patch) async {
    setState(() => _busy = _s(patch['id']));
    Map<String, dynamic> res;
    try {
      res = await _call('payment_alert_rule_save', {'p_patch': patch});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = '');
    final msg = _s(res['toast']).isNotEmpty ? _s(res['toast']) : _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    if (res['ok'] == true) {
      setState(() => _payload = res);
    }
  }

  Future<void> _openForm(Map<String, dynamic>? rule) async {
    final patch = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _RuleForm(
          screen: _payload,
          rule: rule,
          test: (p, title, text) => _call('payment_alert_rule_test', {
            'p_patch': p,
            'p_title': title,
            'p_text': text,
          }),
        ),
      ),
    );
    if (patch != null) await _save(patch);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(_payload['rows']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_payload['title']))),
      floatingActionButton: _error.isNotEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openForm(null),
              icon: const Icon(Icons.add),
              label: Text(_s(_payload['add_label'])),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48 + Ds.space.x24),
          children: [
            if (_s(_payload['subtitle']).isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x16),
                child: Text(_s(_payload['subtitle']), style: Ds.t.caption),
              ),
            if (_loading)
              const _RuleSkeleton()
            else if (_error.isNotEmpty)
              Container(
                padding: EdgeInsets.all(Ds.space.x24),
                decoration: BoxDecoration(
                  color: Ds.c.dangerSoft,
                  borderRadius: Ds.r.rCard,
                ),
                child: Text(_error, style: Ds.t.body, textAlign: TextAlign.center),
              )
            else if (rows.isEmpty)
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(Ds.space.x24),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: Column(
                  children: [
                    Text(_s(_payload['empty_label']),
                        style: Ds.t.body, textAlign: TextAlign.center),
                    SizedBox(height: Ds.space.x8),
                    Text(_s(_payload['empty_hint']),
                        style: Ds.t.caption, textAlign: TextAlign.center),
                  ],
                ),
              )
            else
              for (final r in rows)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: _RuleCard(
                    row: r,
                    busy: _busy == _s(r['id']),
                    onEdit: () => _openForm(r),
                    onToggle: () => _save(<String, dynamic>{
                      'id': r['id'],
                      'enabled': !(r['enabled'] == true),
                    }),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.row,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
  });

  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tone = _s(row['status_tone']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(_s(row['label']), style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x8),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: payAlertToneSoft(tone),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(_s(row['status_label']),
                    style: Ds.t.caption.copyWith(color: payAlertTone(tone))),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(row['package_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(row['order_label']), style: Ds.t.caption),
          if (_s(row['note']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(row['note']), style: Ds.t.caption),
          ],
          if (busy) ...[
            SizedBox(height: Ds.space.x12),
            const LinearProgressIndicator(minHeight: 2),
          ] else ...[
            SizedBox(height: Ds.space.x16),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: onEdit,
                    child: Text(_s(row['edit_label'])),
                  ),
                ),
                SizedBox(
                  height: 44,
                  child: OutlinedButton(
                    onPressed: onToggle,
                    child: Text(_s(row['toggle_label'])),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ── The form + the test box ──────────────────────────────────────────────────
class _RuleForm extends StatefulWidget {
  const _RuleForm({required this.screen, required this.rule, required this.test});

  /// The rules screen payload: the field list and every label live in it.
  final Map<String, dynamic> screen;
  final Map<String, dynamic>? rule;
  final Future<Map<String, dynamic>> Function(
      Map<String, dynamic> patch, String title, String text) test;

  @override
  State<_RuleForm> createState() => _RuleFormState();
}

class _RuleFormState extends State<_RuleForm> {
  final Map<String, TextEditingController> _ctl = {};
  final TextEditingController _sampleTitle = TextEditingController();
  final TextEditingController _sampleText = TextEditingController();
  Map<String, dynamic> _result = const {};
  bool _testing = false;

  List<Map<String, dynamic>> get _fields => _rows(widget.screen['fields']);

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      final k = _s(f['key']);
      _ctl[k] = TextEditingController(text: _s(widget.rule?[k]));
    }
    RenderLog.write('c1930_rule_form', _fields.length);
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    _sampleTitle.dispose();
    _sampleText.dispose();
    super.dispose();
  }

  Map<String, dynamic> _patch() => <String, dynamic>{
        if (widget.rule?['id'] != null) 'id': widget.rule!['id'],
        for (final e in _ctl.entries) e.key: e.value.text.trim(),
        'enabled': widget.rule == null ? true : widget.rule!['enabled'] == true,
      };

  Future<void> _runTest() async {
    setState(() => _testing = true);
    Map<String, dynamic> res;
    try {
      res = await widget.test(_patch(), _sampleTitle.text, _sampleText.text);
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = res;
    });
    RenderLog.write('c1930_rule_test', 1);
  }

  @override
  Widget build(BuildContext context) {
    final resultRows = _rows(_result['rows']);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(widget.screen['add_label']), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x16),
              for (final f in _fields) ...[
                _Field(
                  controller: _ctl[_s(f['key'])]!,
                  label: _s(f['label']),
                  hint: _s(f['hint']),
                  lines: (f['lines'] as num?)?.toInt() ?? 1,
                ),
                SizedBox(height: Ds.space.x12),
              ],
              SizedBox(height: Ds.space.x12),
              Text(_s(widget.screen['test_title']), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(_s(widget.screen['test_hint']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x12),
              _Field(controller: _sampleTitle, label: '', hint: '', lines: 1),
              SizedBox(height: Ds.space.x8),
              _Field(controller: _sampleText, label: '', hint: '', lines: 3),
              SizedBox(height: Ds.space.x12),
              SizedBox(
                width: double.infinity,
                height: 44,
                child: OutlinedButton(
                  onPressed: _testing ? null : _runTest,
                  child: Text(_s(widget.screen['test_run_label'])),
                ),
              ),
              if (_s(_result['verdict_label']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(Ds.space.x12),
                  decoration: BoxDecoration(
                    color: payAlertToneSoft(_s(_result['verdict_tone'])),
                    borderRadius: Ds.r.rCard,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _s(_result['verdict_label']),
                        style: Ds.t.body.copyWith(
                          color: payAlertTone(_s(_result['verdict_tone'])),
                        ),
                      ),
                      for (final r in resultRows) ...[
                        SizedBox(height: Ds.space.x8),
                        Row(
                          children: [
                            Expanded(child: Text(_s(r['label']), style: Ds.t.caption)),
                            SizedBox(width: Ds.space.x8),
                            Flexible(
                              child: Text(
                                _s(r['value']),
                                textAlign: TextAlign.right,
                                style: Ds.t.body.copyWith(
                                  color: payAlertTone(_s(r['tone'])),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (_s(_result['message']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Text(_s(_result['message']), style: Ds.t.caption),
              ],
              SizedBox(height: Ds.space.x24),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(_s(widget.screen['cancel_label'])),
                      ),
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: SizedBox(
                      height: 44,
                      child: FilledButton(
                        onPressed: () => Navigator.pop(context, _patch()),
                        child: Text(_s(widget.screen['save_label'])),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    required this.lines,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int lines;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: lines,
      maxLines: lines,
      style: Ds.t.body,
      decoration: InputDecoration(
        labelText: label.isEmpty ? null : label,
        hintText: hint.isEmpty ? null : hint,
      ),
    );
  }
}

class _RuleSkeleton extends StatelessWidget {
  const _RuleSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < 3; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: 112,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
      ],
    );
  }
}
