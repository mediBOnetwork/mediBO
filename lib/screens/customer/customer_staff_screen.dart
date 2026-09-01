// CHANGE #408 — the pharmacy owner's staff screen.
//
// A pharmacy had exactly one login, so an owner who wanted a counter person to
// place orders handed over their own. This screen hands out more of them, each
// clamped to an access level the BACKEND defines: the dropdown is
// `access_options` from `customer_staff_list()`, so a level this build has
// never heard of still renders, and a level the caller is not allowed to grant
// is not disabled here — it is never sent, so it cannot be picked at all.
//
// The screen computes nothing. Every label, every access name, every activity
// line and every toast is a string in the payload.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// The one seam. Null in production -> the real RPCs.
typedef CustomerRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

Future<Map<String, dynamic>> customerCall(
    String fn, Map<String, dynamic> params) async {
  final raw = await Supabase.instance.client.rpc(fn, params: params);
  return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
}

List<Map<String, dynamic>> custRows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

String custStr(Map<String, dynamic> m, String key) => (m[key] ?? '').toString();

Color custTone(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

Color custToneSoft(Object? tone) => switch ((tone ?? '').toString()) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

/// The pure view: hand it a payload, it draws it. No Supabase, no timers.
class CustomerStaffView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row) onRemove;
  final void Function(Map<String, dynamic> row, String accessKey) onAccessChanged;
  final VoidCallback onAdd;
  final TextEditingController identityCtrl;
  final TextEditingController nameCtrl;
  final String addAccessKey;
  final ValueChanged<String> onAddAccessChanged;
  final bool busy;

  const CustomerStaffView({
    super.key,
    required this.payload,
    required this.onRemove,
    required this.onAccessChanged,
    required this.onAdd,
    required this.identityCtrl,
    required this.nameCtrl,
    required this.addAccessKey,
    required this.onAddAccessChanged,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Refusal(message: custStr(payload, 'message'));
    }
    final rows = custRows(payload['rows']);
    final options = custRows(payload['access_options']);
    final canManage = payload['can_manage'] == true;
    RenderLog.write('c408_staff_rows', rows.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(custStr(payload, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(custStr(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (canManage) ...[
          _AddCard(
            payload: payload,
            options: options,
            identityCtrl: identityCtrl,
            nameCtrl: nameCtrl,
            accessKey: addAccessKey,
            onAccessChanged: onAddAccessChanged,
            onAdd: onAdd,
            busy: busy,
          ),
          SizedBox(height: Ds.space.x24),
        ],
        if (rows.isEmpty)
          _Empty(text: custStr(payload, 'empty'))
        else
          for (final row in rows) ...[
            _StaffRow(
              row: row,
              options: options,
              accessLabel: custStr(payload, 'access_label'),
              removeLabel: custStr(payload, 'remove_label'),
              onRemove: () => onRemove(row),
              onAccessChanged: (k) => onAccessChanged(row, k),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        SizedBox(height: Ds.space.x32),
        _ActivityBlock(payload: payload),
      ],
    );
  }
}

class _AddCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> options;
  final TextEditingController identityCtrl;
  final TextEditingController nameCtrl;
  final String accessKey;
  final ValueChanged<String> onAccessChanged;
  final VoidCallback onAdd;
  final bool busy;

  const _AddCard({
    required this.payload,
    required this.options,
    required this.identityCtrl,
    required this.nameCtrl,
    required this.accessKey,
    required this.onAccessChanged,
    required this.onAdd,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) => _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(custStr(payload, 'add_label'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            _Field(controller: identityCtrl, hint: custStr(payload, 'add_hint')),
            SizedBox(height: Ds.space.x12),
            _Field(controller: nameCtrl, hint: custStr(payload, 'name_hint')),
            SizedBox(height: Ds.space.x12),
            _AccessPicker(
              options: options,
              value: accessKey,
              label: custStr(payload, 'access_label'),
              onChanged: onAccessChanged,
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: busy ? null : onAdd,
                child: Text(custStr(payload, 'save_label')),
              ),
            ),
          ],
        ),
      );
}

class _StaffRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> options;
  final String accessLabel;
  final String removeLabel;
  final VoidCallback onRemove;
  final ValueChanged<String> onAccessChanged;

  const _StaffRow({
    required this.row,
    required this.options,
    required this.accessLabel,
    required this.removeLabel,
    required this.onRemove,
    required this.onAccessChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isOwner = row['is_owner'] == true;
    final canEditAccess = row['can_edit_access'] == true;
    final canRemove = row['can_remove'] == true;

    return _Card(
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
                    Text(custStr(row, 'name'), style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(custStr(row, 'identity'), style: Ds.t.caption),
                  ],
                ),
              ),
              if (isOwner) _Pill(text: custStr(row, 'access_label'), tone: 'info'),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          if (canEditAccess)
            _AccessPicker(
              options: options,
              value: custStr(row, 'access_key'),
              label: accessLabel,
              onChanged: onAccessChanged,
            )
          else if (!isOwner)
            Text(custStr(row, 'access_label'), style: Ds.t.bodySecondary),
          if (custStr(row, 'added_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(custStr(row, 'added_label'), style: Ds.t.caption),
          ],
          if (canRemove) ...[
            SizedBox(height: Ds.space.x8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onRemove,
                child: Text(removeLabel, style: TextStyle(color: Ds.c.danger)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The dropdown IS `access_options`. A level the backend did not send is not an
/// option here, which is the whole point: Dart never invents an access level
/// and never offers one the caller is not allowed to grant.
class _AccessPicker extends StatelessWidget {
  final List<Map<String, dynamic>> options;
  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  const _AccessPicker({
    required this.options,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) return const SizedBox.shrink();
    final keys = options.map((o) => custStr(o, 'access_key')).toList();
    final selected = keys.contains(value) ? value : keys.first;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Container(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.bg,
            borderRadius: Ds.r.rButton,
            border: Border.all(color: Ds.c.divider),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: selected,
              isExpanded: true,
              style: Ds.t.body,
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
              items: [
                for (final o in options)
                  DropdownMenuItem(
                    value: custStr(o, 'access_key'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(custStr(o, 'label'), style: Ds.t.body),
                        if (custStr(o, 'description').isNotEmpty)
                          Text(custStr(o, 'description'), style: Ds.t.caption),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Who did what. The owner reads it here; an admin reads the same rows through
/// `customer_activity(customer_id)`.
class _ActivityBlock extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _ActivityBlock({required this.payload});

  @override
  Widget build(BuildContext context) {
    final rows = custRows(payload['activity']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(custStr(payload, 'activity_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (rows.isEmpty)
          Text(custStr(payload, 'activity_empty'), style: Ds.t.caption)
        else
          _Card(
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) Divider(color: Ds.c.divider, height: Ds.space.x24),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${custStr(rows[i], 'who')} · ${custStr(rows[i], 'what')}',
                              style: Ds.t.body,
                            ),
                            if (custStr(rows[i], 'order_code').isNotEmpty) ...[
                              SizedBox(height: Ds.space.x4),
                              Text(custStr(rows[i], 'order_code'),
                                  style: Ds.t.caption),
                            ],
                          ],
                        ),
                      ),
                      Text(custStr(rows[i], 'when'), style: Ds.t.caption),
                    ],
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  const _Field({required this.controller, required this.hint});

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        style: Ds.t.body,
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: Ds.t.caption,
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
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final String tone;
  const _Pill({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: custToneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(text, style: Ds.t.caption.copyWith(color: custTone(tone))),
      );
}

class _Empty extends StatelessWidget {
  final String text;
  const _Empty({required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
        child: Center(child: Text(text, style: Ds.t.caption)),
      );
}

class _Refusal extends StatelessWidget {
  final String message;
  const _Refusal({required this.message});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Center(child: Text(message, style: Ds.t.bodySecondary)),
      );
}

// ── the live screen ─────────────────────────────────────────────────────────

class CustomerStaffScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final CustomerRpc? rpc;
  const CustomerStaffScreen({super.key, this.rpc});

  @override
  State<CustomerStaffScreen> createState() => _CustomerStaffScreenState();
}

class _CustomerStaffScreenState extends State<CustomerStaffScreen> {
  Map<String, dynamic>? _payload;
  final _identity = TextEditingController();
  final _name = TextEditingController();
  String _addAccess = '';
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : customerCall(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _identity.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await _call('customer_staff_list', const {});
    if (!mounted) return;
    final opts = custRows(p['access_options']);
    setState(() {
      _payload = p;
      if (_addAccess.isEmpty && opts.isNotEmpty) {
        _addAccess = custStr(opts.first, 'access_key');
      }
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = custStr(r, 'message');
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: custTone(r['tone']),
    ));
  }

  Future<void> _run(Future<Map<String, dynamic>> future) async {
    setState(() => _busy = true);
    final r = await future;
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(r);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p == null ? '' : custStr(p, 'title')),
        backgroundColor: Ds.c.surface,
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : CustomerStaffView(
              payload: p,
              busy: _busy,
              identityCtrl: _identity,
              nameCtrl: _name,
              addAccessKey: _addAccess,
              onAddAccessChanged: (k) => setState(() => _addAccess = k),
              onAdd: () {
                final id = _identity.text;
                final nm = _name.text;
                _identity.clear();
                _name.clear();
                _run(_call('customer_staff_add', {
                  'p_identity': id,
                  'p_name': nm,
                  'p_access_key': _addAccess,
                }));
              },
              onAccessChanged: (row, accessKey) => _run(_call(
                  'customer_staff_set_access',
                  {'p_id': row['id'], 'p_access_key': accessKey})),
              onRemove: (row) =>
                  _run(_call('customer_staff_remove', {'p_id': row['id']})),
            ),
    );
  }
}
