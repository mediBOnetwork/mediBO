// CMD #1985 — Admin › Partner agreement.
//
// The agreement stopped being a block of prose the day the Raipur partner
// changed from Jai Mahakal to UNIVERSAL PHARMA and every signed copy went
// stale. It is a list of CLAUSES now, and a clause carries {{tokens}} rather
// than a name: {{partner}}, {{partner_gstin}}, {{split_pct}}, {{cadence}}.
// agreement_render() fills them in from the partner's own record at the moment
// the document is drawn, so changing the partner changes the agreement.
//
// This screen edits that, and decides nothing itself. Every heading, chip word,
// status tone, validity line, button caption and refusal sentence is a field of
// agreement_admin_versions(); the three writes are agreement_version_save(),
// agreement_clause_save() and agreement_version_publish(), and each one hands
// back the whole state to draw next.
//
// The third block is the one a partner cannot reach: the clause changes THEY
// have asked for. Approving one writes a partner-specific override and voids
// their signature, so the deal a partner signed is never quietly rewritten.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../partner/partner_ui.dart';
import 'agreement_document_screen.dart';

class AgreementVersionsScreen extends StatefulWidget {
  const AgreementVersionsScreen({super.key});

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<AgreementVersionsScreen> createState() => _AgreementVersionsScreenState();
}

class _AgreementVersionsScreenState extends State<AgreementVersionsScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;
  int? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _s(Map<String, dynamic> m, String k) =>
      (m[k] == null) ? '' : m[k].toString();

  List<Map<String, dynamic>> _rows(String k) {
    final raw = _p[k];
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final r = await AgreementVersionsScreen.rpc(
          'agreement_admin_versions', {'p_version_id': _selected});
      if (!mounted) return;
      final m = r is Map ? Map<String, dynamic>.from(r) : const <String, dynamic>{};
      setState(() {
        _p = m;
        _selected = (m['selected_id'] as num?)?.toInt();
        _loading = false;
      });
      RenderLog.write(
          'c1985_agreement_admin',
          'ok=${m['ok'] == true},'
          'versions=${_rows('rows').length},'
          'clauses=${_rows('clauses').length},'
          'proposals=${_rows('proposals').length}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c1985_agreement_admin', 'ok=false,versions=0');
    }
  }

  /// Every write: call, print the backend's own message, take the state it
  /// hands back. The screen never decides what happened.
  Future<bool> _write(String fn, Map<String, dynamic> params) async {
    setState(() => _busy = true);
    try {
      final r = await AgreementVersionsScreen.rpc(fn, params);
      if (!mounted) return false;
      final m = r is Map ? Map<String, dynamic>.from(r) : const <String, dynamic>{};
      final next = m['state'];
      setState(() {
        _busy = false;
        if (next is Map) {
          _p = Map<String, dynamic>.from(next);
          _selected = (_p['selected_id'] as num?)?.toInt();
        }
      });
      final msg = _s(m, 'message');
      if (msg.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      return m['ok'] == true;
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.toString())));
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_p, 'heading'))),
      body: SafeArea(
        child: _loading
            ? const PartnerSkeleton(rows: 5)
            : _p['ok'] != true
                ? PartnerNotice(text: _s(_p, 'message'))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: EdgeInsets.all(Ds.space.x16),
                      children: [
                        Text(_s(_p, 'sub'), style: Ds.t.bodySecondary),
                        SizedBox(height: Ds.space.x16),
                        _newVersionButton(),
                        SizedBox(height: Ds.space.x12),
                        _printedDocumentButton(),
                        SizedBox(height: Ds.space.x24),
                        for (final v in _rows('rows')) _versionCard(v),
                        SizedBox(height: Ds.space.x24),
                        _clauseBlock(),
                        SizedBox(height: Ds.space.x24),
                        _proposalBlock(),
                        SizedBox(height: Ds.space.x32),
                      ],
                    ),
                  ),
      ),
    );
  }

  /// CMD #1986 — the door to everything the PDF prints: recitals, defined
  /// terms, the schedules themselves and every heading, label and note. Pushed
  /// from here rather than declared as its own route_key, so it can never
  /// become a tile whose tap falls through the shell's switch (lesson 203).
  Widget _printedDocumentButton() => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) =>
                        AgreementDocumentScreen(versionId: _selected),
                  )),
          icon: const Icon(Icons.article_outlined),
          label: Text(c('agree_edit.open_label')),
        ),
      );

  Widget _newVersionButton() => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: FilledButton.icon(
          onPressed: _busy ? null : () => _versionSheet(const {}),
          icon: const Icon(Icons.add),
          label: Text(_s(_p, 'new_label')),
        ),
      );

  Widget _versionCard(Map<String, dynamic> v) {
    final id = (v['id'] as num?)?.toInt();
    final isSel = id == _selected;
    final isDraft = _s(v, 'status') == 'draft';
    return PartnerCard(
      onTap: _busy
          ? null
          : () {
              setState(() => _selected = id);
              _load();
            },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_s(v, 'version_label'),
                    style: isSel ? Ds.t.bodyStrong : Ds.t.body),
              ),
              SizedBox(width: Ds.space.x8),
              PartnerChip(
                  text: _s(v, 'status_label'), tone: v['status_tone'] as String?),
            ],
          ),
          if (_s(v, 'title').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(v, 'title'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x4),
          Text(_s(v, 'validity_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(v, 'signed_label'), style: Ds.t.caption),
          if (isDraft) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _versionSheet(v),
                    child: Text(_s(_p, 'save_label')),
                  ),
                ),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _write('agreement_version_publish', {
                              'p': {'id': id}
                            }),
                    child: Text(_s(_p, 'publish_label')),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── the clause list of the selected version ───────────────────────────────
  Widget _clauseBlock() {
    final clauses = _rows('clauses');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(_p, 'clause_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text(_s(_p, 'token_help'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        if (clauses.isEmpty)
          PartnerCard(
              child: Text(_s(_p, 'clause_empty'), style: Ds.t.bodySecondary))
        else
          for (final c in clauses) _clauseCard(c),
        SizedBox(height: Ds.space.x8),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _clauseSheet(const {}),
            icon: const Icon(Icons.add),
            label: Text(_s(_p, 'clause_new_label')),
          ),
        ),
      ],
    );
  }

  Widget _clauseCard(Map<String, dynamic> c) => PartnerCard(
        onTap: _busy ? null : () => _clauseSheet(c),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${_s(c, 'n')}. ${_s(c, 'heading')}',
                      style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                PartnerChip(text: _s(c, 'owner_label')),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Text(_s(c, 'body'), style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x8),
            Text(_s(c, 'flags_label'), style: Ds.t.caption),
          ],
        ),
      );

  // ── the change requests partners have raised ──────────────────────────────
  Widget _proposalBlock() {
    final props = _rows('proposals');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(_p, 'proposals_heading'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        if (props.isEmpty)
          PartnerCard(
              child: Text(_s(_p, 'proposals_empty'), style: Ds.t.bodySecondary))
        else
          for (final pr in props) _proposalCard(pr),
      ],
    );
  }

  Widget _proposalCard(Map<String, dynamic> pr) => PartnerCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                      '${_s(pr, 'clause_n')}. ${_s(pr, 'clause_heading')}',
                      style: Ds.t.bodyStrong),
                ),
                SizedBox(width: Ds.space.x8),
                PartnerChip(
                    text: _s(pr, 'status_label'),
                    tone: pr['status_tone'] as String?),
              ],
            ),
            SizedBox(height: Ds.space.x4),
            Text(_s(pr, 'raised_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Text(_s(pr, 'proposed_body'), style: Ds.t.bodySecondary),
            if (_s(pr, 'note').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(pr, 'note'), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x16),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _write('agreement_proposal_decide', {
                              'p': {'id': pr['id'], 'approve': true}
                            }),
                    child: Text(_s(_p, 'approve_label')),
                  ),
                ),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _rejectSheet(pr),
                    child: Text(_s(_p, 'reject_label')),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  // ── sheets ────────────────────────────────────────────────────────────────
  Future<void> _sheet(Widget Function(BuildContext, StateSetter) body) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.only(
              left: Ds.space.x16,
              right: Ds.space.x16,
              top: Ds.space.x24,
              bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
            ),
            child: SingleChildScrollView(child: body(ctx, setSheet)),
          ),
        ),
      );

  Future<void> _versionSheet(Map<String, dynamic> v) async {
    final title = TextEditingController(text: _s(v, 'title'));
    final from = TextEditingController(text: _s(v, 'effective_from'));
    final to = TextEditingController(text: _s(v, 'effective_to'));
    final renew = TextEditingController(
        text: v['renew_before_days'] == null ? '30' : _s(v, 'renew_before_days'));
    await _sheet(
      (ctx, setSheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s(_p, 'new_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          TextField(
              controller: title,
              decoration: InputDecoration(labelText: _s(_p, 'clause_heading'))),
          SizedBox(height: Ds.space.x12),
          TextField(
              controller: from,
              decoration:
                  InputDecoration(labelText: _s(_p, 'valid_from_hint'))),
          SizedBox(height: Ds.space.x12),
          TextField(
              controller: to,
              decoration: InputDecoration(labelText: _s(_p, 'valid_to_hint'))),
          SizedBox(height: Ds.space.x12),
          TextField(
              controller: renew,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _s(_p, 'renew_hint'))),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await _write('agreement_version_save', {
                        'p': {
                          if (v['id'] != null) 'id': v['id'],
                          'title': title.text.trim(),
                          'effective_from': from.text.trim(),
                          'effective_to': to.text.trim(),
                          'renew_before_days': renew.text.trim(),
                        }
                      });
                      if (ok && ctx.mounted) Navigator.of(ctx).pop();
                    },
              child: Text(_s(_p, 'save_label')),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _clauseSheet(Map<String, dynamic> c) async {
    final heading = TextEditingController(text: _s(c, 'heading'));
    final body = TextEditingController(text: _s(c, 'body'));
    final n = TextEditingController(text: _s(c, 'n'));
    var editable = c['editable_by_partner'] == true;
    var isRequired = c['required'] != false;
    await _sheet(
      (ctx, setSheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s(_p, 'clause_new_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s(_p, 'token_help'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          TextField(
              controller: n,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: _s(_p, 'clause_n_hint'))),
          SizedBox(height: Ds.space.x12),
          TextField(
              controller: heading,
              decoration:
                  InputDecoration(labelText: _s(_p, 'clause_head_hint'))),
          SizedBox(height: Ds.space.x12),
          TextField(
              controller: body,
              maxLines: 6,
              decoration:
                  InputDecoration(labelText: _s(_p, 'clause_body_hint'))),
          SizedBox(height: Ds.space.x12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_s(_p, 'flag_editable_label'), style: Ds.t.body),
            value: editable,
            onChanged: (x) => setSheet(() => editable = x),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_s(_p, 'flag_required_label'), style: Ds.t.body),
            value: isRequired,
            onChanged: (x) => setSheet(() => isRequired = x),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await _write('agreement_clause_save', {
                        'p': {
                          if (c['id'] != null) 'id': c['id'],
                          'version_id': _selected,
                          'n': n.text.trim(),
                          'heading': heading.text.trim(),
                          'body': body.text,
                          'editable_by_partner': editable,
                          'required': isRequired,
                        }
                      });
                      if (ok && ctx.mounted) Navigator.of(ctx).pop();
                    },
              child: Text(_s(_p, 'clause_save_label')),
            ),
          ),
          if (c['id'] != null) ...[
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final ok = await _write('agreement_clause_save', {
                          'p': {'id': c['id'], 'delete': 'true'}
                        });
                        if (ok && ctx.mounted) Navigator.of(ctx).pop();
                      },
                child: Text(_s(_p, 'clause_delete_label'),
                    style: Ds.t.body.copyWith(color: Ds.c.danger)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _rejectSheet(Map<String, dynamic> pr) async {
    final reason = TextEditingController();
    await _sheet(
      (ctx, setSheet) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_s(_p, 'reject_label'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          TextField(
              controller: reason,
              maxLines: 3,
              decoration: InputDecoration(labelText: _s(_p, 'reason_hint'))),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final ok = await _write('agreement_proposal_decide', {
                        'p': {
                          'id': pr['id'],
                          'approve': false,
                          'reason': reason.text.trim(),
                        }
                      });
                      if (ok && ctx.mounted) Navigator.of(ctx).pop();
                    },
              child: Text(_s(_p, 'reject_label')),
            ),
          ),
        ],
      ),
    );
  }
}
