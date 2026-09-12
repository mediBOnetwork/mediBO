import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../widgets/ds_tone.dart';

/// CMD #1886 — the registration funnel, as three tabs on the Customers screen.
///
/// 22 auth logins and 13 profiles: a person who signs in and does not finish
/// the form appeared on no screen anybody opened. These three tabs are where
/// they live now — Signed up, My follow-ups, Needs attention.
///
/// NOTHING here is decided in Dart. The tab labels and counts, the stage word
/// and its tone, "5 fields missing: Drug licence, GSTIN", the WhatsApp button's
/// caption and its refusal, the overdue colouring and the approve gate's reason
/// are all strings the backend sent. This file lays them out and sends taps
/// back. A row with a key this build has never heard of simply draws nothing
/// rather than throwing.
class CustomerPipelineTab extends StatefulWidget {
  const CustomerPipelineTab({
    super.key,
    required this.tabKey,
    this.assignees = const [],
    this.payload,
    this.onCountChanged,
  });

  /// 'signed_up' | 'followups' | 'needs' — the backend's own tab keys.
  final String tabKey;

  /// customer_pipeline_home().assignees — {value, label} pairs, backend order.
  final List<Map<String, dynamic>> assignees;

  /// Injected payload (tests). When null the tab fetches its own.
  final Map<String, dynamic>? payload;

  final void Function(int count)? onCountChanged;

  /// The RPC each tab key reads. One lookup, never a branch on content.
  static const Map<String, String> rpcForTab = {
    'signed_up': 'customers_signed_up',
    'followups': 'customer_followups_mine',
    'needs': 'customers_needs_attention',
  };

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<CustomerPipelineTab> createState() => _CustomerPipelineTabState();
}

class _CustomerPipelineTabState extends State<CustomerPipelineTab> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.payload != null) {
      _payload = widget.payload!;
      _loading = false;
      _report();
    } else {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant CustomerPipelineTab old) {
    super.didUpdateWidget(old);
    if (old.tabKey != widget.tabKey && widget.payload == null) _load();
  }

  static Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  Future<void> _load() async {
    final fn = CustomerPipelineTab.rpcForTab[widget.tabKey];
    if (fn == null) {
      setState(() {
        _payload = const {};
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final res = _asMap(await CustomerPipelineTab.rpc(fn));
      if (!mounted) return;
      setState(() {
        _payload = res ?? const {};
        _loading = false;
      });
      _report();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _report() {
    RenderLog.write('c1886_pipeline_${widget.tabKey}', _rows.length);
    widget.onCountChanged?.call(_rows.length);
  }

  String _s(String k) => (_payload[k] ?? '').toString();

  /// Every caption on a row's controls arrives in the payload; this file owns
  /// no word of its own.
  Map<String, dynamic> get _actions => (_payload['actions'] is Map)
      ? Map<String, dynamic>.from(_payload['actions'] as Map)
      : const {};

  List<Map<String, dynamic>> get _rows => ((_payload['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Future<void> _toast(String msg) async {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _nudge(Map<String, dynamic> row) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await CustomerPipelineTab.rpc(
          'customer_signup_nudge', {'p_user_id': row['user_id']}));
      await _toast((res?['message'] ?? '').toString());
    } catch (_) {
      // the backend owns every sentence; a transport failure says nothing here
    }
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await CustomerPipelineTab.rpc('admin_customer_action',
          {'p_customer_id': row['customer_id'], 'p_action': 'approve'});
    } on PostgrestException catch (e) {
      await _toast(e.message);
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _assign(Map<String, dynamic> row, String kind, dynamic id) async {
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _AssignSheet(
        actions: _actions,
        assignees: widget.assignees,
        currentOwner: row['assigned_to'],
        currentDate: row['next_action_at'],
        note: (row['note'] ?? '').toString(),
      ),
    );
    if (res == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final out = _asMap(await CustomerPipelineTab.rpc('customer_followup_set', {
        'p_kind': kind,
        'p_subject_id': id,
        'p_assigned_to': res['assigned_to'],
        'p_next_action_at': res['next_action_at'],
        'p_note': res['note'],
      }));
      await _toast((out?['message'] ?? '').toString());
    } catch (_) {}
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List.generate(
              3,
              (_) => Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x12),
                    child: Container(
                      height: 72,
                      decoration: BoxDecoration(
                          color: Ds.c.divider, borderRadius: Ds.r.rCard),
                    ),
                  )),
        ),
      );
    }

    if (_payload['allowed'] == false) {
      return _Empty(text: _s('message'));
    }
    if (_rows.isEmpty) return _Empty(text: _s('empty_label'));

    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in _rows) ...[
            _PipelineCard(
              row: r,
              tabKey: widget.tabKey,
              actions: _actions,
              busy: _busy,
              onNudge: () => _nudge(r),
              onApprove: () => _approve(r),
              onAssign: () => _assign(
                  r,
                  _kindOf(r),
                  r['customer_id'] ?? r['user_id'] ?? r['subject_id']),
            ),
            SizedBox(height: Ds.space.x12),
          ],
          SizedBox(height: Ds.space.x24),
        ],
      ),
    );
  }

  /// The backend names the kind on a follow-up row; the two single-kind tabs
  /// are what they are.
  String _kindOf(Map<String, dynamic> r) {
    final k = (r['kind'] ?? '').toString();
    if (k.isNotEmpty) return k;
    return widget.tabKey == 'signed_up' ? 'signup' : 'customer';
  }
}

// ── one row ─────────────────────────────────────────────────────────────────

class _PipelineCard extends StatelessWidget {
  const _PipelineCard({
    required this.row,
    required this.tabKey,
    required this.actions,
    required this.busy,
    required this.onNudge,
    required this.onApprove,
    required this.onAssign,
  });

  final Map<String, dynamic> row;
  final String tabKey;
  final Map<String, dynamic> actions;
  final bool busy;
  final VoidCallback onNudge;
  final VoidCallback onApprove;
  final VoidCallback onAssign;

  String _t(String k) => (row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final wa = (row['wa'] is Map)
        ? Map<String, dynamic>.from(row['wa'] as Map)
        : const <String, dynamic>{};
    final approve = (row['approve'] is Map)
        ? Map<String, dynamic>.from(row['approve'] as Map)
        : const <String, dynamic>{};

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
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_t('name'), style: Ds.t.subtitle),
                    if (_contact.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_contact, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              CustomerStageChip(chip: row['stage_chip']),
            ],
          ),
          if (_t('missing_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_t('missing_label'), style: Ds.t.body),
          ],
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x12,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (_t('joined_label').isNotEmpty)
                Text(_t('joined_label'), style: Ds.t.caption),
              if (_t('last_login_label').isNotEmpty)
                Text(_t('last_login_label'), style: Ds.t.caption),
              if (_t('assigned_label').isNotEmpty)
                Text(_t('assigned_label'), style: Ds.t.caption),
              if (_t('next_action_label').isNotEmpty)
                Text(
                  _t('next_action_label'),
                  style: Ds.t.caption
                      .copyWith(color: dsToneFg(_t('next_action_tone'))),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              if (wa.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(right: Ds.space.x12),
                  child: _Action(
                    label: (wa['label'] ?? '').toString(),
                    reason: (wa['reason'] ?? '').toString(),
                    enabled: wa['can'] == true && !busy,
                    primary: true,
                    onTap: onNudge,
                  ),
                ),
              if (approve.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(right: Ds.space.x12),
                  child: _Action(
                    label: (approve['label'] ?? '').toString(),
                    reason: (approve['reason'] ?? '').toString(),
                    enabled: approve['can'] == true && !busy,
                    primary: true,
                    onTap: onApprove,
                  ),
                ),
              _Action(
                label: _assignLabel,
                reason: '',
                enabled: !busy,
                primary: false,
                onTap: onAssign,
              ),
            ],
          ),
          if (_t('note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_t('note'), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }

  String get _contact {
    final c = _t('contact');
    if (c.isNotEmpty) return c;
    final parts = [_t('email'), _t('phone')].where((e) => e.isNotEmpty);
    return parts.join(' · ');
  }

  /// The payload's caption, and nothing else: an absent one draws no button
  /// rather than a word this build invented.
  String get _assignLabel => (actions['assign_label'] ?? '').toString();
}

class _Action extends StatelessWidget {
  const _Action({
    required this.label,
    required this.reason,
    required this.enabled,
    required this.primary,
    required this.onTap,
  });

  final String label;
  final String reason;
  final bool enabled;
  final bool primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final button = SizedBox(
      height: 44,
      child: primary
          ? ElevatedButton(onPressed: enabled ? onTap : null, child: Text(label))
          : OutlinedButton(onPressed: enabled ? onTap : null, child: Text(label)),
    );
    if (enabled || reason.isEmpty) return button;
    // Never hidden: disabled, carrying the backend's own reason beside it.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        button,
        SizedBox(height: Ds.space.x4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(reason,
              style: Ds.t.caption.copyWith(color: dsToneFg('danger'))),
        ),
      ],
    );
  }
}

/// The stage chip — one word, one tone, both from the payload. Used by the tabs
/// AND by every row the Customers screen already draws.
class CustomerStageChip extends StatelessWidget {
  const CustomerStageChip({super.key, required this.chip});

  final dynamic chip;

  @override
  Widget build(BuildContext context) {
    final m = chip is Map ? Map<String, dynamic>.from(chip as Map) : null;
    final label = (m?['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final tone = (m?['tone'] ?? '').toString();
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration:
          BoxDecoration(color: dsToneBg(tone), borderRadius: Ds.r.rChip),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: dsToneFg(tone))),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.all(Ds.space.x32),
      child: Text(text, style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
    );
  }
}

// ── the assign sheet ────────────────────────────────────────────────────────

class _AssignSheet extends StatefulWidget {
  const _AssignSheet({
    required this.actions,
    required this.assignees,
    this.currentOwner,
    this.currentDate,
    this.note = '',
  });

  final Map<String, dynamic> actions;
  final List<Map<String, dynamic>> assignees;
  final dynamic currentOwner;
  final dynamic currentDate;
  final String note;

  @override
  State<_AssignSheet> createState() => _AssignSheetState();
}

class _AssignSheetState extends State<_AssignSheet> {
  String? _owner;
  DateTime? _when;
  late final TextEditingController _note =
      TextEditingController(text: widget.note);

  @override
  void initState() {
    super.initState();
    _owner = widget.currentOwner?.toString();
    final raw = widget.currentDate?.toString();
    if (raw != null && raw.isNotEmpty) _when = DateTime.tryParse(raw);
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  String _a(String k) => (widget.actions[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final options = widget.assignees
        .map((e) => DropdownMenuItem<String>(
              value: (e['value'] ?? '').toString(),
              child: Text((e['label'] ?? '').toString(), style: Ds.t.body),
            ))
        .toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
          MediaQuery.of(context).viewInsets.bottom + Ds.space.x16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_a('owner_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          DropdownButtonFormField<String>(
            initialValue:
                options.any((o) => o.value == _owner) ? _owner : null,
            items: options,
            onChanged: (v) => setState(() => _owner = v),
          ),
          SizedBox(height: Ds.space.x24),
          Text(_a('date_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            height: 44,
            child: OutlinedButton(
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _when ?? now,
                  firstDate: now.subtract(const Duration(days: 365)),
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _when = picked);
              },
              child: Text(_when == null
                  ? _a('no_date_label')
                  : '${_when!.day}/${_when!.month}/${_when!.year}'),
            ),
          ),
          SizedBox(height: Ds.space.x24),
          Text(_a('note_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          TextField(controller: _note, maxLines: 2),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: 48,
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context, {
                'assigned_to': _owner,
                'next_action_at': _when?.toUtc().toIso8601String(),
                'note': _note.text,
              }),
              child: Text(_a('save_label')),
            ),
          ),
        ],
      ),
    );
  }
}
