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
import '../partner/partner_documents_screen.dart';
import 'partner_audit_log_screen.dart';
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

  /// CMD #466 row 154 — suspend / resume. The reason is typed by the admin;
  /// every other word on the sheet, and the refusal when the reason is blank,
  /// is the backend's.
  Future<void> _lifecycle(bool suspend, String reason) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await (suspend
          ? _rpc('partner_suspend',
              {'p_partner_id': widget.partnerId, 'p_reason': reason})
          : _rpc('partner_resume', {'p_partner_id': widget.partnerId})));
    } catch (_) {
      _toastFailure();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  /// CMD #466 row 153 — set one licence's expiry. The date comes from the
  /// picker; the kind and the label came from the payload.
  Future<void> _setLicence(String kind, DateTime? date) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      _toast(await _rpc('partner_licence_set', {
        'p_partner_id': widget.partnerId,
        'p_kind': kind,
        'p_expiry': date?.toIso8601String().split('T').first,
      }));
    } catch (_) {
      _toastFailure();
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Future<void> _askSuspendReason(Map<String, dynamic> life) async {
    final ctrl = TextEditingController();
    final go = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
            Ds.space.x16 + MediaQuery.of(ctx).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((life['suspend_label'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: ctrl,
              autofocus: true,
              decoration: InputDecoration(
                  hintText: (life['reason_hint'] ?? '').toString()),
            ),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text((life['suspend_label'] ?? '').toString()),
              ),
            ),
          ],
        ),
      ),
    );
    if (go == true) await _lifecycle(true, ctrl.text);
    ctrl.dispose();
  }

  Future<void> _pickLicenceDate(Map<String, dynamic> row) async {
    final iso = (row['expiry_iso'] ?? '').toString();
    final initial = DateTime.tryParse(iso) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2040),
    );
    if (picked == null) return;
    await _setLicence((row['kind'] ?? '').toString(), picked);
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

  // CMD #467 row 155 — the full, filterable trail. Pushed with the same rpc
  // seam the console itself uses, so a test drives both with one fake.
  void _openAuditLog() {
    final id = (_payload?['partner_id'] as num?)?.toInt() ?? widget.partnerId;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PartnerAuditLogScreen(partnerId: id, rpc: widget.rpc),
    ));
  }

  /// CHANGE #692 — the partner's agreement and KYC documents, on the same
  /// screen the PARTNER sees. `partner_documents_screen()` answers an admin
  /// with can_review:true on each row, so verifying happens there rather than
  /// in a second console-only editor that could drift from it.
  void _openDocuments() {
    final id = (_payload?['partner_id'] as num?)?.toInt() ?? widget.partnerId;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            backgroundColor: Ds.c.bg,
            appBar: AppBar(
              title: Text(
                  ((_payload?['documents_open'] as Map?)?['label'] ?? '')
                      .toString()),
            ),
            body: PartnerDocumentsScreen(partnerId: id),
          ),
        ))
        .then((_) => _load());
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
              onSuspend: _askSuspendReason,
              onResume: () => _lifecycle(false, ''),
              onLicence: _pickLicenceDate,
              onOpenAudit: _openAuditLog,
              onOpenDocuments: _openDocuments,
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
    this.onSuspend,
    this.onResume,
    this.onLicence,
    this.onOpenAudit,
    this.onOpenDocuments,
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

  /// CMD #466 rows 153 + 154. Null in a read-only render (and on any build
  /// whose payload carried no such block) -> the cards simply do not appear.
  final void Function(Map<String, dynamic> lifecycle)? onSuspend;
  final VoidCallback? onResume;
  final void Function(Map<String, dynamic> licenceRow)? onLicence;

  /// CMD #467 row 155. Null in a read-only render -> the button is inert but
  /// still drawn, because whether it EXISTS is the payload's decision.
  final VoidCallback? onOpenAudit;

  /// CHANGE #692. Same rule: the card appears because the payload carried a
  /// `documents` block, not because this build knows the feature exists.
  final VoidCallback? onOpenDocuments;

  /// The label, or '' when this build's payload carried no `documents_open`.
  String get documentsOpenLabel {
    final d = payload['documents_open'];
    if (d is! Map) return '';
    return (d['label'] ?? '').toString();
  }

  /// The label, or '' when this build's payload carried no `audit_open` block.
  String get auditOpenLabel {
    final d = payload['audit_open'];
    if (d is! Map) return '';
    return (d['label'] ?? '').toString();
  }

  String _s(String k) => (payload[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final users = (payload['users'] as List?) ?? const [];
    final features = (payload['features'] as List?) ?? const [];
    final audit = (payload['audit'] as List?) ?? const [];
    final fence = (payload['fence'] as Map?) == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(payload['fence'] as Map);
    final lifecycle = (payload['lifecycle'] as Map?) == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(payload['lifecycle'] as Map);
    final licences = (payload['licences'] as Map?) == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(payload['licences'] as Map);
    final documents = (payload['documents'] as Map?) == null
        ? const <String, dynamic>{}
        : Map<String, dynamic>.from(payload['documents'] as Map);
    // Written BEFORE the refusal branch on purpose: the render-log has to prove
    // the screen painted even when the backend said no, otherwise a headless
    // non-super session can never verify the route exists at all.
    try {
      RenderLog.write('c307_partner_console',
          'ok=${payload['ok'] == true},users=${users.length},features=${features.length}');
      // CHANGE #352 — the fence card is its own render key, so "the backend
      // fenced it" and "a super-admin can see that it did" are separate proofs.
      // CMD #466 — the two new cards prove themselves separately, so
      // "the backend sent it" and "the console drew it" stay distinct.
      RenderLog.write('c466_partner_lifecycle',
          'card=${lifecycle['ok'] == true},status=${(lifecycle['status'] ?? '').toString()},'
          'blocks=${(lifecycle['blocks'] as List?)?.length ?? 0}');
      RenderLog.write('c466_partner_licences',
          'card=${licences['ok'] == true},rows=${(licences['rows'] as List?)?.length ?? 0},'
          'alert=${(licences['alert_tone'] ?? '').toString()}');
      // CHANGE #692 — the documents card proves itself separately, so
      // "the backend sent the block" and "the console drew it" stay distinct.
      RenderLog.write('c692_partner_documents',
          'card=${documents['ok'] == true},'
          'ready=${((documents['golive'] as Map?)?['ready'] ?? '').toString()},'
          'agreement=${((documents['agreement'] as Map?)?['status'] ?? '').toString()},'
          'kyc=${(((documents['kyc'] as Map?)?['rows']) as List?)?.length ?? 0}');
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
        if (lifecycle['ok'] == true) ...[
          SizedBox(height: Ds.space.x24),
          _LifecycleCard(
            life: lifecycle,
            busy: busy,
            onSuspend: onSuspend,
            onResume: onResume,
          ),
        ],
        if (licences['ok'] == true) ...[
          SizedBox(height: Ds.space.x24),
          _LicenceCard(
            card: licences,
            busy: busy,
            onLicence: onLicence,
          ),
        ],
        // CHANGE #692 — the agreement + KYC block. It appears because the
        // payload carried it; the chips and the blocking sentence are the
        // backend's own, and tapping opens the same screen the partner uses.
        if (documents['ok'] == true) ...[
          SizedBox(height: Ds.space.x24),
          _DocumentsCard(
            docs: documents,
            openLabel: documentsOpenLabel,
            busy: busy,
            onOpen: onOpenDocuments,
          ),
        ],
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
            // CMD #467 row 155 — the door to the filterable, paged log. It is
            // a descriptor, not a flag: a payload with no label draws nothing.
            if (auditOpenLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: OutlinedButton(
                  onPressed: onOpenAudit,
                  child: Text(auditOpenLabel),
                ),
              ),
            ],
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
          // CMD #467 row 155 — the sentence arrives composed. This used to be
          // `action · feature_key` joined here, which printed raw slugs
          // ("open_denied · partner.settlement") at a mediBO admin. The tone is
          // a 4 px accent, not the text colour: nine action types painted as
          // nine coloured sentences is a rainbow, and the one that matters
          // (a refusal) stops standing out.
          Container(
            width: Ds.space.x4,
            height: Ds.space.x16,
            margin: EdgeInsets.only(right: Ds.space.x8, top: Ds.space.x4),
            decoration: BoxDecoration(
              color: PartnerAuditTone.fg((row['tone'] ?? 'neutral').toString()),
              borderRadius: Ds.r.rChip,
            ),
          ),
          Expanded(
            child: Text(
              (row['line'] ?? row['action'] ?? '').toString(),
              style: Ds.t.body,
            ),
          ),
          SizedBox(width: Ds.space.x8),
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

/// CMD #466 row 154 — a partner's status, and the two consequences the gap
/// register said were undefined: what happens to work already in hand, and what
/// happens to the open settlement balance. Every heading, sentence, count and
/// rupee below is printed from `partner_lifecycle_card()`; nothing on this
/// widget decides what suspension means.
class _LifecycleCard extends StatelessWidget {
  const _LifecycleCard({
    required this.life,
    required this.busy,
    this.onSuspend,
    this.onResume,
  });

  final Map<String, dynamic> life;
  final bool busy;
  final void Function(Map<String, dynamic> lifecycle)? onSuspend;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final suspended = life['is_suspended'] == true;
    final canAct = life['can_act'] == true;
    final since = (life['suspended_since'] ?? '').toString();
    final reason = (life['suspend_reason'] ?? '').toString();
    final blocks = (life['blocks'] as List?) ?? const [];

    return _Card(
      title: (life['heading'] ?? '').toString(),
      subtitle: '',
      children: [
        Row(
          children: [
            _TonePill(
              label: (life['status_label'] ?? '').toString(),
              tone: (life['status_tone'] ?? '').toString(),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(
              child: Text((life['partner_name'] ?? '').toString(),
                  style: Ds.t.body, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        if (since.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(since, style: Ds.t.caption),
        ],
        if (suspended && reason.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(reason, style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        for (final b in blocks) ...[
          _LifecycleBlock(block: Map<String, dynamic>.from(b as Map)),
          SizedBox(height: Ds.space.x12),
        ],
        if (canAct) ...[
          SizedBox(height: Ds.space.x4),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: suspended
                ? OutlinedButton(
                    key: const ValueKey('partner_resume'),
                    onPressed: busy ? null : onResume,
                    child: Text((life['resume_label'] ?? '').toString()),
                  )
                : OutlinedButton(
                    key: const ValueKey('partner_suspend'),
                    onPressed:
                        busy || onSuspend == null ? null : () => onSuspend!(life),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Ds.c.danger,
                        side: BorderSide(color: Ds.c.danger)),
                    child: Text((life['suspend_label'] ?? '').toString()),
                  ),
          ),
        ],
      ],
    );
  }
}

class _LifecycleBlock extends StatelessWidget {
  const _LifecycleBlock({required this.block});
  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final amount = (block['amount'] ?? '').toString();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: _FenceCard.toneSoft((block['tone'] ?? '').toString()),
        borderRadius: Ds.r.rChip,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text((block['heading'] ?? '').toString(),
                    style: Ds.t.bodySecondary),
              ),
              if (amount.isNotEmpty) Text(amount, style: Ds.t.subtitle),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text((block['text'] ?? '').toString(), style: Ds.t.caption),
        ],
      ),
    );
  }
}

/// CMD #466 row 153 — the licences and when they run out. The row's words and
/// its tone are `partner_licence_card()`'s; the only thing this widget knows is
/// that tapping a row asks for a date.
class _LicenceCard extends StatelessWidget {
  const _LicenceCard({
    required this.card,
    required this.busy,
    this.onLicence,
  });

  final Map<String, dynamic> card;
  final bool busy;
  final void Function(Map<String, dynamic> licenceRow)? onLicence;

  @override
  Widget build(BuildContext context) {
    final rows = (card['rows'] as List?) ?? const [];
    final canEdit = card['can_edit'] == true && onLicence != null;

    return _Card(
      title: (card['heading'] ?? '').toString(),
      subtitle: (card['sub'] ?? '').toString(),
      children: [
        _TonePill(
          label: (card['alert_label'] ?? '').toString(),
          tone: (card['alert_tone'] ?? '').toString(),
        ),
        SizedBox(height: Ds.space.x16),
        for (final r in rows.cast<Map>().map(Map<String, dynamic>.from))
          _LicenceRow(
            row: r,
            setLabel: (card['set_label'] ?? '').toString(),
            busy: busy,
            onTap: canEdit ? () => onLicence!(r) : null,
          ),
      ],
    );
  }
}

class _LicenceRow extends StatelessWidget {
  const _LicenceRow({
    required this.row,
    required this.setLabel,
    required this.busy,
    this.onTap,
  });

  final Map<String, dynamic> row;
  final String setLabel;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((row['label'] ?? '').toString(), style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text((row['number'] ?? '').toString(), style: Ds.t.caption),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _TonePill(
                label: (row['expiry_label'] ?? '').toString(),
                tone: (row['tone'] ?? '').toString(),
              ),
              if (onTap != null) ...[
                SizedBox(height: Ds.space.x4),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: busy ? null : onTap,
                    child: Text(setLabel),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// CHANGE #692 — the partner's agreement and KYC documents, as a status card on
/// the console. Every word here is `partner_documents_screen()`'s: the go-live
/// sentence, the agreement chip, the document progress line and the button
/// label. The card knows only that tapping it opens the full screen.
class _DocumentsCard extends StatelessWidget {
  const _DocumentsCard({
    required this.docs,
    required this.openLabel,
    required this.busy,
    this.onOpen,
  });

  final Map<String, dynamic> docs;
  final String openLabel;
  final bool busy;
  final VoidCallback? onOpen;

  static Map<String, dynamic> _block(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

  @override
  Widget build(BuildContext context) {
    final golive = _block(docs['golive']);
    final agreement = _block(docs['agreement']);
    final kyc = _block(docs['kyc']);
    final blockers = (golive['blockers'] as List?) ?? const [];

    return _Card(
      title: (docs['title'] ?? '').toString(),
      subtitle: (kyc['sub'] ?? '').toString(),
      children: [
        _TonePill(
          label: (golive['status_label'] ?? '').toString(),
          tone: (golive['status_tone'] ?? '').toString(),
        ),
        for (final b in blockers.cast<Map>().map(Map<String, dynamic>.from)) ...[
          SizedBox(height: Ds.space.x8),
          Text((b['text'] ?? '').toString(), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x16),
        Row(
          children: [
            Expanded(
              child: Text((agreement['heading'] ?? '').toString(),
                  style: Ds.t.body),
            ),
            SizedBox(width: Ds.space.x12),
            _TonePill(
              label: (agreement['status_label'] ?? '').toString(),
              tone: (agreement['status_tone'] ?? '').toString(),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x12),
        Row(
          children: [
            Expanded(
              child: Text((kyc['progress_label'] ?? '').toString(),
                  style: Ds.t.body),
            ),
            SizedBox(width: Ds.space.x12),
            _TonePill(
              label: (kyc['summary_label'] ?? '').toString(),
              tone: (kyc['summary_tone'] ?? '').toString(),
            ),
          ],
        ),
        if (openLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              key: const ValueKey('partner_documents_open'),
              onPressed: busy ? null : onOpen,
              child: Text(openLabel),
            ),
          ),
        ],
      ],
    );
  }
}
