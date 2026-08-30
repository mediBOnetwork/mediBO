// CHANGE #307 — Payment and Partner -> one partner's logins and access.
//
// Three sections, all rendered verbatim from `admin_partner_console()`:
//   • Logins — the staff numbers/emails attached to this region_partners row.
//     Adding one writes a login_identities binding; they then sign in with the
//     ordinary WhatsApp OTP / Google login. No new auth system exists.
//   • Access — the per-feature matrix. The three choices, their words and which
//     one is selected all come from the payload's `options[]`; this file never
//     writes "No access" or decides what a feature is called.
//   • Activity — the partner's audit trail. Read-only here, and not editable by
//     the partner at all.
//
// The zone is NOT on this screen as a control. It belongs to the partner
// record; the backend clamps it into every RPC the partner can reach.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/partner_state.dart';
import '../../utils/render_log.dart';

class AdminPartnerConsoleScreen extends StatefulWidget {
  const AdminPartnerConsoleScreen({
    super.key,
    required this.partnerId,
    this.rpc,
  });

  final int partnerId;

  /// Test seam. Null in production -> the real RPCs.
  final PartnerRpc? rpc;

  @override
  State<AdminPartnerConsoleScreen> createState() =>
      _AdminPartnerConsoleScreenState();
}

class _AdminPartnerConsoleScreenState extends State<AdminPartnerConsoleScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  bool _busy = false;

  final _identity = TextEditingController();
  final _name = TextEditingController();

  PartnerRpc get _rpc => widget.rpc ?? PartnerApi.call;

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
    setState(() => _loading = true);
    Map<String, dynamic> p;
    try {
      p = await _rpc('admin_partner_console', {'p_partner_id': widget.partnerId});
    } catch (_) {
      p = <String, dynamic>{};
    }
    if (!mounted) return;
    setState(() {
      _payload = p;
      _loading = false;
    });
  }

  void _toast(Map<String, dynamic> r) {
    final msg = (r['message'] ?? '').toString();
    if (msg.isNotEmpty && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _setAccess(String featureKey, String access) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await _rpc('admin_partner_access_set', {
        'p_partner_id': widget.partnerId,
        'p_feature_key': featureKey,
        'p_access': access,
      }));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _addUser() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await _rpc('admin_partner_user_add', {
        'p_partner_id': widget.partnerId,
        'p_identity': _identity.text,
        'p_name': _name.text,
      }));
    } catch (_) {}
    if (!mounted) return;
    _identity.clear();
    _name.clear();
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _removeUser(int id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await _rpc('admin_partner_user_remove', {'p_id': id}));
    } catch (_) {}
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text((p['partner_name'] ?? '').toString())),
      body: _loading
          ? const _ConsoleSkeleton()
          : PartnerConsoleView(
              payload: p,
              identity: _identity,
              name: _name,
              busy: _busy,
              onAdd: _addUser,
              onRemove: _removeUser,
              onAccess: _setAccess,
            ),
    );
  }
}

class _ConsoleSkeleton extends StatelessWidget {
  const _ConsoleSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 4,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (_, __) => Container(
        height: Ds.touch.listRowMinHeight,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
      ),
    );
  }
}

/// The pure render half — testable with an inline payload, no network.
class PartnerConsoleView extends StatelessWidget {
  const PartnerConsoleView({
    super.key,
    required this.payload,
    required this.identity,
    required this.name,
    required this.onAdd,
    required this.onRemove,
    required this.onAccess,
    this.busy = false,
  });

  final Map<String, dynamic> payload;
  final TextEditingController identity;
  final TextEditingController name;
  final bool busy;
  final VoidCallback onAdd;
  final void Function(int id) onRemove;
  final void Function(String featureKey, String access) onAccess;

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final users = (payload['users'] as List?) ?? const [];
    final features = (payload['features'] as List?) ?? const [];
    final audit = (payload['audit'] as List?) ?? const [];
    // Written BEFORE the refusal branch on purpose: the render-log has to prove
    // the screen painted even when the backend said no, otherwise a headless
    // non-super session can never verify the route exists at all.
    try {
      RenderLog.write('c307_partner_console',
          'ok=${payload['ok'] == true},users=${users.length},features=${features.length}');
    } catch (_) {}
    if (payload['ok'] != true) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text((payload['error'] ?? '').toString(), style: Ds.t.body),
      );
    }

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        _Measure(children: [
        _Card(
          title: _s('users_title'),
          subtitle: _s('users_subtitle'),
          children: [
            if (users.isEmpty) Text(_s('empty_users'), style: Ds.t.caption),
            for (final u in users)
              _UserRow(
                user: Map<String, dynamic>.from(u as Map),
                removeLabel: _s('remove_label'),
                onRemove: onRemove,
              ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: identity,
              decoration: InputDecoration(hintText: _s('add_hint')),
            ),
            SizedBox(height: Ds.space.x8),
            TextField(
              controller: name,
              decoration: InputDecoration(hintText: _s('name_hint')),
            ),
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: busy ? null : onAdd,
                child: Text(_s('add_label')),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        _Card(
          title: _s('perm_title'),
          subtitle: _s('perm_subtitle'),
          children: [
            Text(_s('zone_locked_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            for (final f in features)
              _FeatureRow(
                feature: Map<String, dynamic>.from(f as Map),
                busy: busy,
                onAccess: onAccess,
              ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        _Card(
          title: _s('audit_title'),
          subtitle: '',
          children: [
            if (audit.isEmpty) Text(_s('empty_audit'), style: Ds.t.caption),
            for (final a in audit)
              _AuditRow(row: Map<String, dynamic>.from(a as Map)),
          ],
        ),
        SizedBox(height: Ds.space.x32),
        ]),
      ],
    );
  }
}

/// A readable measure: full width on a phone, centred and capped on a desktop
/// so a settings form does not stretch to 1200 px of empty row.
class _Measure extends StatelessWidget {
  const _Measure({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: Ds.space.x48 * 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.title, required this.subtitle, required this.children});
  final String title, subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
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
          if (title.isNotEmpty) Text(title, style: Ds.t.subtitle),
          if (subtitle.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(subtitle, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x16),
          ...children,
        ],
      ),
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.removeLabel,
    required this.onRemove,
  });

  final Map<String, dynamic> user;
  final String removeLabel;
  final void Function(int id) onRemove;

  @override
  Widget build(BuildContext context) {
    final id = int.tryParse((user['id'] ?? '').toString()) ?? 0;
    final nm = (user['display_name'] ?? '').toString();
    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((user['identity'] ?? '').toString(), style: Ds.t.bodyStrong),
                Text(
                  nm.isEmpty
                      ? (user['status_label'] ?? '').toString()
                      : '$nm · ${(user['status_label'] ?? '')}',
                  style: Ds.t.caption,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onRemove(id),
            child: Text(removeLabel),
          ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.feature,
    required this.busy,
    required this.onAccess,
  });

  final Map<String, dynamic> feature;
  final bool busy;
  final void Function(String featureKey, String access) onAccess;

  @override
  Widget build(BuildContext context) {
    final key = (feature['feature_key'] ?? '').toString();
    final options = (feature['options'] as List?) ?? const [];
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((feature['group_label'] ?? '').toString().isNotEmpty)
            Text((feature['group_label'] ?? '').toString(), style: Ds.t.caption),
          Text((feature['label'] ?? '').toString(), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final o in options.map((e) =>
                  Map<String, dynamic>.from(e as Map)))
                _AccessChip(
                  option: o,
                  onTap: busy
                      ? null
                      : () => onAccess(key, (o['value'] ?? '').toString()),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AccessChip extends StatelessWidget {
  const _AccessChip({required this.option, required this.onTap});

  final Map<String, dynamic> option;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final selected = option['selected'] == true;
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: onTap,
      // No `alignment:` here — a Container with one set expands to fill the
      // loose constraints a Wrap hands it, which stacked the three choices as
      // three full-width bars instead of a row.
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : Ds.c.bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text((option['label'] ?? '').toString(), style: Ds.t.caption),
      ),
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              '${row['action'] ?? ''} · ${row['feature_key'] ?? ''}',
              style: Ds.t.body,
            ),
          ),
          Text((row['at_label'] ?? '').toString(), style: Ds.t.caption),
        ],
      ),
    );
  }
}
