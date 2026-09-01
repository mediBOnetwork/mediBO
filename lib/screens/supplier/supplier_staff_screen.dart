// CHANGE #402 — the supplier's own staff screen.
//
// A supplier had exactly one login. This screen hands out more of them, each
// clamped to an access preset the BACKEND defines: the dropdown is
// `role_options` from `supplier_staff_list()`, so a level this build has never
// heard of still renders, and a level the backend withdrew disappears without
// a deploy.
//
// The screen computes nothing. Every label, every role name, every audit line
// and every toast is a string in the payload — which is also why the whole
// screen is already in Hindi the moment the supplier switches language.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/supplier_account_state.dart';
import '../../utils/render_log.dart';

/// The pure view: hand it a payload, it draws it. No Supabase, no timers.
class SupplierStaffView extends StatelessWidget {
  final Map<String, dynamic> payload;
  final void Function(Map<String, dynamic> row) onRemove;
  final void Function(Map<String, dynamic> row, String roleKey) onRoleChanged;
  final VoidCallback onAdd;
  final TextEditingController identityCtrl;
  final TextEditingController nameCtrl;
  final String addRoleKey;
  final ValueChanged<String> onAddRoleChanged;
  final bool busy;

  const SupplierStaffView({
    super.key,
    required this.payload,
    required this.onRemove,
    required this.onRoleChanged,
    required this.onAdd,
    required this.identityCtrl,
    required this.nameCtrl,
    required this.addRoleKey,
    required this.onAddRoleChanged,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    if (payload['ok'] == false) {
      return _Refusal(message: supplierStr(payload, 'message'));
    }
    final rows = supplierRows(payload['rows']);
    final options = supplierRows(payload['role_options']);
    final canManage = payload['can_manage'] == true;
    RenderLog.write('c402_staff_rows', rows.length);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(supplierStr(payload, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(supplierStr(payload, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        if (canManage) ...[
          _AddCard(
            payload: payload,
            options: options,
            identityCtrl: identityCtrl,
            nameCtrl: nameCtrl,
            roleKey: addRoleKey,
            onRoleChanged: onAddRoleChanged,
            onAdd: onAdd,
            busy: busy,
          ),
          SizedBox(height: Ds.space.x24),
        ],
        if (rows.isEmpty)
          _Empty(text: supplierStr(payload, 'empty'))
        else
          for (final row in rows) ...[
            _StaffRow(
              row: row,
              options: options,
              roleLabel: supplierStr(payload, 'role_label'),
              removeLabel: supplierStr(payload, 'remove_label'),
              ownerLabel: supplierStr(payload, 'owner_label'),
              onRemove: () => onRemove(row),
              onRoleChanged: (k) => onRoleChanged(row, k),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        SizedBox(height: Ds.space.x24),
        _AuditBlock(payload: payload),
      ],
    );
  }
}

class _AddCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  final List<Map<String, dynamic>> options;
  final TextEditingController identityCtrl;
  final TextEditingController nameCtrl;
  final String roleKey;
  final ValueChanged<String> onRoleChanged;
  final VoidCallback onAdd;
  final bool busy;

  const _AddCard({
    required this.payload,
    required this.options,
    required this.identityCtrl,
    required this.nameCtrl,
    required this.roleKey,
    required this.onRoleChanged,
    required this.onAdd,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(supplierStr(payload, 'add_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          _Field(controller: identityCtrl, hint: supplierStr(payload, 'add_hint')),
          SizedBox(height: Ds.space.x12),
          _Field(controller: nameCtrl, hint: supplierStr(payload, 'name_hint')),
          SizedBox(height: Ds.space.x12),
          _RolePicker(
            options: options,
            value: roleKey,
            label: supplierStr(payload, 'role_label'),
            onChanged: onRoleChanged,
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
              child: Text(supplierStr(payload, 'save_label')),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> options;
  final String roleLabel;
  final String removeLabel;
  final String ownerLabel;
  final VoidCallback onRemove;
  final ValueChanged<String> onRoleChanged;

  const _StaffRow({
    required this.row,
    required this.options,
    required this.roleLabel,
    required this.removeLabel,
    required this.ownerLabel,
    required this.onRemove,
    required this.onRoleChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isOwner = row['is_owner'] == true;
    final canEditRole = row['can_edit_role'] == true;
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
                    Text(supplierStr(row, 'name'), style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(supplierStr(row, 'identity'), style: Ds.t.caption),
                  ],
                ),
              ),
              if (isOwner) _Pill(text: ownerLabel, tone: 'info'),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          if (canEditRole)
            _RolePicker(
              options: options,
              value: supplierStr(row, 'role_key'),
              label: roleLabel,
              onChanged: onRoleChanged,
            )
          else
            Text(supplierStr(row, 'role_label'), style: Ds.t.bodySecondary),
          if (supplierStr(row, 'added_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(supplierStr(row, 'added_label'), style: Ds.t.caption),
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

/// The dropdown IS `role_options`. A feature the backend did not send is not
/// an option here, which is the whole point: Dart never invents an access
/// level and never offers one the account cannot actually grant.
class _RolePicker extends StatelessWidget {
  final List<Map<String, dynamic>> options;
  final String value;
  final String label;
  final ValueChanged<String> onChanged;

  const _RolePicker({
    required this.options,
    required this.value,
    required this.label,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final keys = options.map((o) => supplierStr(o, 'role_key')).toList();
    final selected = keys.contains(value) ? value : (keys.isEmpty ? null : keys.first);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Ds.c.bg,
        contentPadding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        border: OutlineInputBorder(
          borderRadius: Ds.r.rButton,
          borderSide: BorderSide(color: Ds.c.divider),
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          value: selected,
          items: [
            for (final o in options)
              DropdownMenuItem<String>(
                value: supplierStr(o, 'role_key'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(supplierStr(o, 'label'), style: Ds.t.body),
                  ],
                ),
              ),
          ],
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}

class _AuditBlock extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _AuditBlock({required this.payload});

  @override
  Widget build(BuildContext context) {
    final audit = supplierRows(payload['audit']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(supplierStr(payload, 'audit_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (audit.isEmpty)
          Text(supplierStr(payload, 'audit_empty'), style: Ds.t.caption)
        else
          for (final a in audit)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(supplierStr(a, 'what'), style: Ds.t.body),
                  SizedBox(height: Ds.space.x4),
                  Text('${supplierStr(a, 'who')} · ${supplierStr(a, 'when')}',
                      style: Ds.t.caption),
                ],
              ),
            ),
      ],
    );
  }
}

// ── small shared pieces ─────────────────────────────────────────────────────

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
          color: supplierToneSoft(tone),
          borderRadius: Ds.r.rChip,
        ),
        child: Text(text,
            style: Ds.t.caption.copyWith(color: supplierTone(tone))),
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

class SupplierStaffScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final SupplierRpc? rpc;
  const SupplierStaffScreen({super.key, this.rpc});

  @override
  State<SupplierStaffScreen> createState() => _SupplierStaffScreenState();
}

class _SupplierStaffScreenState extends State<SupplierStaffScreen> {
  Map<String, dynamic>? _payload;
  final _identity = TextEditingController();
  final _name = TextEditingController();
  String _addRole = '';
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : SupplierApi.call(fn, p);

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
    final p = await _call('supplier_staff_list', const {});
    if (!mounted) return;
    final opts = supplierRows(p['role_options']);
    setState(() {
      _payload = p;
      if (_addRole.isEmpty && opts.isNotEmpty) {
        _addRole = supplierStr(opts.first, 'role_key');
      }
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = supplierStr(r, 'message');
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: supplierTone(r['tone']),
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
        title: Text(p == null ? '' : supplierStr(p, 'title')),
        backgroundColor: Ds.c.surface,
      ),
      body: p == null
          ? const Center(child: CircularProgressIndicator())
          : SupplierStaffView(
              payload: p,
              busy: _busy,
              identityCtrl: _identity,
              nameCtrl: _name,
              addRoleKey: _addRole,
              onAddRoleChanged: (k) => setState(() => _addRole = k),
              onAdd: () {
                final id = _identity.text;
                final nm = _name.text;
                _identity.clear();
                _name.clear();
                _run(_call('supplier_staff_add', {
                  'p_identity': id,
                  'p_name': nm,
                  'p_role_key': _addRole,
                }));
              },
              onRoleChanged: (row, roleKey) => _run(_call(
                  'supplier_staff_set_role',
                  {'p_id': row['id'], 'p_role_key': roleKey})),
              onRemove: (row) => _run(
                  _call('supplier_staff_remove', {'p_id': row['id']})),
            ),
    );
  }
}
