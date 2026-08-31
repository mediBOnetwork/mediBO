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
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import 'settlement_screen.dart';

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
  Map<String, dynamic>? _fence;
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

  /// CHANGE #321 — the reply is SHOWN, always. Every one of these RPCs now
  /// answers with a `message` (and a `tone`) whether it worked or not, so a
  /// refusal reaches the admin as words instead of a button that looks inert.
  /// The words and the tone are the backend's; only the colour is a token.
  void _toast(Map<String, dynamic> r) {
    if (!mounted) return;
    final msg = (r['message'] ?? '').toString();
    if (msg.isEmpty) return;
    final tone = (r['tone'] ?? '').toString();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: tone == 'danger'
          ? Ds.c.danger
          : tone == 'success'
              ? Ds.c.success
              : null,
    ));
  }

  /// The RPC never answered at all (offline, 500, dropped socket). The words
  /// still come from the backend — `failed_message` rides the console payload.
  void _toastFailure() {
    _toast(<String, dynamic>{
      'tone': 'danger',
      'message': (_payload?['failed_message'] ?? '').toString(),
    });
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
    } catch (_) {
      _toastFailure();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _addUser() async {
    if (_busy) return;
    setState(() => _busy = true);
    var added = false;
    try {
      final r = await _rpc('admin_partner_user_add', {
        'p_partner_id': widget.partnerId,
        'p_identity': _identity.text,
        'p_name': _name.text,
      });
      added = r['ok'] == true;
      _toast(r);
    } catch (_) {
      _toastFailure();
    }
    if (!mounted) return;
    // A rejected number stays in the field — the admin fixes it and taps again
    // instead of retyping it from memory.
    if (added) {
      _identity.clear();
      _name.clear();
    }
    setState(() => _busy = false);
    await _load();
  }

  /// CHANGE #352 — the live fence check. It reproduces each of the eight
  /// approved critical findings AS the partner and reports what the backend
  /// did; every write it makes is rolled back inside the RPC.
  Future<void> _verifyFence() async {
    setState(() => _busy = true);
    Map<String, dynamic>? r;
    try {
      r = await _rpc('partner_fence_verify', const {});
    } catch (_) {
      r = null;
    }
    if (!mounted) return;
    setState(() {
      _fence = r;
      _busy = false;
    });
  }

  Future<void> _removeUser(int id) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await _rpc('admin_partner_user_remove', {'p_id': id}));
    } catch (_) {
      _toastFailure();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((p['partner_name'] ?? '').toString()),
        actions: [
          // CHANGE #323 — the settlement lane for this partner. The word is
          // ui_copy's, not a Dart literal; the screen behind it refuses a
          // non-admin itself.
          IconButton(
            key: const ValueKey('partner_settlement_entry'),
            tooltip: c('settlement.entry'),
            icon: const Icon(Icons.handshake_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettlementScreen()),
            ),
          ),
        ],
      ),
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
              fenceResult: _fence,
              onVerifyFence: _verifyFence,
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
    this.fenceResult,
    this.onVerifyFence,
  });

  final Map<String, dynamic> payload;
  final TextEditingController identity;
  final TextEditingController name;
  final bool busy;
  final VoidCallback onAdd;
  final void Function(int id) onRemove;
  final void Function(String featureKey, String access) onAccess;

  /// The payload of the last `partner_fence_verify()` run, or null when the
  /// check has not been run in this session. Never computed here.
  final Map<String, dynamic>? fenceResult;
  final VoidCallback? onVerifyFence;

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final users = (payload['users'] as List?) ?? const [];
    final features = (payload['features'] as List?) ?? const [];
    final audit = (payload['audit'] as List?) ?? const [];
    final fence = (payload['fence'] as Map?) == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(payload['fence'] as Map);
    // Written BEFORE the refusal branch on purpose: the render-log has to prove
    // the screen painted even when the backend said no, otherwise a headless
    // non-super session can never verify the route exists at all.
    try {
      RenderLog.write('c307_partner_console',
          'ok=${payload['ok'] == true},users=${users.length},features=${features.length}');
      // CHANGE #352 — the fence card is its own render key, so "the backend
      // fenced it" and "a super-admin can see that it did" are separate proofs.
      RenderLog.write('c352_partner_fence',
          'card=${fence.isNotEmpty},rows=${(fence['rows'] as List?)?.length ?? 0},'
          'status=${(fence['status_label'] ?? '').toString()}');
    } catch (_) {}
    if (payload['ok'] != true) {
      // CHANGE #321: the refusal prints the backend's SENTENCE when it sent
      // one; the machine slug is only the last resort.
      final msg = (payload['message'] ?? '').toString();
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(
          msg.isNotEmpty ? msg : (payload['error'] ?? '').toString(),
          style: Ds.t.body,
        ),
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
        if (fence.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _FenceCard(
            fence: fence,
            result: fenceResult,
            busy: busy,
            onVerify: onVerifyFence,
          ),
        ],
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

/// CHANGE #352 — the Partner fence card. Every string, every number and every
/// tone arrives in `fence`; this widget picks a colour for a tone name and
/// nothing else.
class _FenceCard extends StatelessWidget {
  const _FenceCard({
    required this.fence,
    required this.busy,
    this.result,
    this.onVerify,
  });

  final Map<String, dynamic> fence;
  final Map<String, dynamic>? result;
  final bool busy;
  final VoidCallback? onVerify;

  static Color toneColor(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'danger' => Ds.c.danger,
        'warning' => Ds.c.warning,
        'info' => Ds.c.info,
        _ => Ds.c.textSecondary,
      };

  static Color toneSoft(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'danger' => Ds.c.dangerSoft,
        'warning' => Ds.c.warningSoft,
        'info' => Ds.c.infoSoft,
        _ => Ds.c.bg,
      };

  @override
  Widget build(BuildContext context) {
    final rows = (fence['rows'] as List?) ?? const [];
    final r = result;
    final checks = (r?['rows'] as List?) ?? const [];
    return _Card(
      title: (fence['title'] ?? '').toString(),
      subtitle: (fence['subtitle'] ?? '').toString(),
      children: [
        _TonePill(
          label: (fence['status_label'] ?? '').toString(),
          tone: (fence['status_tone'] ?? '').toString(),
        ),
        SizedBox(height: Ds.space.x16),
        for (final row in rows) _FenceRow(row: Map<String, dynamic>.from(row as Map)),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            key: const ValueKey('partner_fence_verify'),
            onPressed: busy ? null : onVerify,
            child: Text((fence['verify_label'] ?? '').toString()),
          ),
        ),
        if (r == null) ...[
          SizedBox(height: Ds.space.x12),
          Text((fence['never_run'] ?? '').toString(), style: Ds.t.caption),
        ] else ...[
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              Expanded(
                child: Text((r['title'] ?? '').toString(), style: Ds.t.body),
              ),
              _TonePill(
                label: (r['summary'] ?? '').toString(),
                tone: (r['tone'] ?? '').toString(),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          for (final c in checks) _FenceRow(row: Map<String, dynamic>.from(c as Map)),
        ],
      ],
    );
  }
}

class _FenceRow extends StatelessWidget {
  const _FenceRow({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final tone = (row['tone'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text((row['label'] ?? '').toString(), style: Ds.t.caption),
          ),
          SizedBox(width: Ds.space.x12),
          Text(
            (row['value'] ?? '').toString(),
            textAlign: TextAlign.right,
            style: Ds.t.body.copyWith(color: _FenceCard.toneColor(tone)),
          ),
        ],
      ),
    );
  }
}

class _TonePill extends StatelessWidget {
  const _TonePill({required this.label, required this.tone});
  final String label, tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _FenceCard.toneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label,
          style: Ds.t.caption.copyWith(color: _FenceCard.toneColor(tone))),
    );
  }
}
