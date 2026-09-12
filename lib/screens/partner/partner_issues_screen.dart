// lib/screens/partner/partner_issues_screen.dart — CHANGE #696
//
// The mediBO <-> partner escalation channel, from both ends, in ONE screen.
// partner_ticket_list() answers a partner with their own issues and the office
// with every partner's, so this file holds no zone filter, no role branch and
// no "am I an admin" question — `view` is the backend's word for which side is
// reading, and it is used only to log what rendered.
//
// Nothing here composes a sentence. Category names, the status word (which
// differs by WHO is reading — "Waiting on you" vs "Waiting on them"), the SLA
// line and its colour, the outcome list, every toast and every refusal arrive
// finished in the payload. The one thing Dart decides is which SCREEN a linked
// object opens, for the same reason the nav icon map lives in Dart: a Widget is
// not a string Postgres can hold.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../services/partner_ticket_api.dart';
import '../../utils/file_pick_io.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../admin/admin_supplier_page.dart';
import '../admin/order_timeline_screen.dart';
import '../admin/settlement_screen.dart';
import 'partner_ui.dart';

/// The queue: every issue this side can see, the closest to breaching first.
class PartnerIssuesScreen extends StatefulWidget {
  const PartnerIssuesScreen({super.key});

  @override
  State<PartnerIssuesScreen> createState() => _PartnerIssuesScreenState();
}

class _PartnerIssuesScreenState extends State<PartnerIssuesScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  String _filter = 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final d = await PartnerTicketApi.list(filter: _filter);
      RenderLog.write(
          'c696_issue_list',
          'ok=${d['ok']} view=${d['view']} filter=$_filter '
              'rows=${ticketRows(d['rows']).length}');
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final ok = d != null && d['ok'] == true;
    // Pushed as a bare route by shellExtraRouteScreen(), so it owns its own
    // Scaffold — the same as SupportThreadsScreen next to it.
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(ticketStr(d ?? const {}, 'title'))),
      floatingActionButton: (ok && ticketBool(d, 'can_raise'))
          ? FloatingActionButton.extended(
              onPressed: () async {
                final raised = await showPartnerIssueRaise(context);
                if (raised == true) await _load();
              },
              backgroundColor: Ds.c.brand,
              icon: const Icon(Icons.add),
              label: Text(ticketStr(d, 'raise_cta')),
            )
          : null,
      body: _body(d, ok),
    );
  }

  Widget _body(Map<String, dynamic>? d, bool ok) {
    if (_loading) return const PartnerSkeleton(rows: 6);
    if (!ok) {
      return PartnerNotice(
        text: ticketStr(d ?? const {}, 'message'),
        onRetry: _load,
        retryLabel: ticketStr(d ?? const {}, 'retry_label'),
      );
    }
    final rows = ticketRows(d!['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
          child: Text(ticketStr(d, 'subtitle'), style: Ds.t.caption),
        ),
        IssueFilterRow(
          items: ticketRows(d['filters']),
          selected: _filter,
          onTap: (k) {
            setState(() => _filter = k);
            _load();
          },
        ),
        Expanded(
          child: rows.isEmpty
              ? PartnerNotice(
                  title: ticketStr(d, 'empty_title'),
                  text: ticketStr(d, 'empty_note'),
                )
              : ListView(
                  padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x8,
                      Ds.space.x16, Ds.space.x48 + Ds.space.x24),
                  children: [
                    for (final r in rows)
                      PartnerCard(
                        onTap: () async {
                          await openPartnerIssue(context, ticketStr(r, 'id'));
                          await _load();
                        },
                        child: IssueRow(r: r),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// The filter chips. Keys and labels are the payload's; a key this build has
/// never heard of is still tappable, because nothing here switches on one.
class IssueFilterRow extends StatelessWidget {
  const IssueFilterRow(
      {super.key,
      required this.items,
      required this.selected,
      required this.onTap});

  final List<Map<String, dynamic>> items;
  final String selected;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget + Ds.space.x8,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        children: [
          for (final f in items)
            Padding(
              padding: EdgeInsets.only(right: Ds.space.x8),
              child: ChoiceChip(
                selected: ticketStr(f, 'key') == selected,
                onSelected: (_) => onTap(ticketStr(f, 'key')),
                label: Text('${ticketStr(f, 'label')} · ${f['count'] ?? 0}'),
              ),
            ),
        ],
      ),
    );
  }
}

/// One issue, as the queue prints it. Every word and both tones are the row's.
class IssueRow extends StatelessWidget {
  const IssueRow({super.key, required this.r});

  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final partner = ticketStr(r, 'partner_label');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(ticketStr(r, 'subject'),
                  style: Ds.t.bodyStrong,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            SizedBox(width: Ds.space.x8),
            Text(ticketStr(r, 'ref'), style: Ds.t.caption),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            PartnerChip(text: ticketStr(r, 'category_label')),
            PartnerChip(
                text: ticketStr(r, 'priority_label'),
                tone: ticketStr(r, 'priority_tone')),
            PartnerChip(
                text: ticketStr(r, 'status_label'),
                tone: ticketStr(r, 'status_tone')),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        Row(
          children: [
            Expanded(
              child: Text(ticketStr(r, 'sla_label'),
                  style: Ds.t.caption
                      .copyWith(color: partnerToneColor(ticketStr(r, 'sla_tone')))),
            ),
            Text(ticketStr(r, 'age_label'), style: Ds.t.caption),
          ],
        ),
        if (partner.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text('$partner · ${ticketStr(r, 'owner_label')}', style: Ds.t.caption),
        ],
      ],
    );
  }
}

// ── raising one ─────────────────────────────────────────────────────────────

/// Returns true when an issue was raised, so the caller reloads its queue.
Future<bool?> showPartnerIssueRaise(BuildContext context) => showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => const PartnerIssueRaiseSheet(),
    );

class PartnerIssueRaiseSheet extends StatefulWidget {
  const PartnerIssueRaiseSheet({super.key});

  @override
  State<PartnerIssueRaiseSheet> createState() => _PartnerIssueRaiseSheetState();
}

class _PartnerIssueRaiseSheetState extends State<PartnerIssueRaiseSheet> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _busy = false;
  String _category = '';
  String _priority = '';
  String _partner = '';
  final _subject = TextEditingController();
  final _body = TextEditingController();
  final _link = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    _link.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await PartnerTicketApi.newTicket();
      RenderLog.write('c696_issue_new',
          'ok=${d['ok']} cats=${ticketRows(d['categories']).length}');
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
        final cats = ticketRows(d['categories']);
        if (cats.isNotEmpty) {
          _category = ticketStr(cats.first, 'code');
          _priority = ticketStr(cats.first, 'priority');
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Map<String, dynamic> get _cat {
    for (final c in ticketRows(_d?['categories'])) {
      if (ticketStr(c, 'code') == _category) return c;
    }
    return const {};
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final res = await PartnerTicketApi.raise(
        category: _category,
        subject: _subject.text,
        body: _body.text,
        priority: _priority,
        partnerId: _partner.isEmpty ? null : _partner,
        linkKind: ticketStr(_cat, 'link_kind'),
        linkRef: _link.text.trim(),
      );
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() => _busy = false);
        showToast(context, ticketStr(res, 'message'), isError: true);
        return;
      }
      RenderLog.write('c696_issue_raised', ticketStr(res, 'ref'));
      showToast(context, ticketStr(res, 'toast'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    // The sheet's own loading height, built from the spacing scale rather
    // than a hand-picked pixel count (DESIGN.md — no bare numerics).
    final sheetMinHeight = Ds.space.x48 * 5;
    if (_loading) {
      return SizedBox(
          height: sheetMinHeight, child: const PartnerSkeleton(rows: 3));
    }
    if (d == null || d['ok'] != true) {
      return SizedBox(
        height: sheetMinHeight,
        child: PartnerNotice(text: ticketStr(d ?? const {}, 'message')),
      );
    }
    final cats = ticketRows(d['categories']);
    final pris = ticketRows(d['priorities']);
    final partners = ticketRows(d['partners']);
    final needsPartner = ticketBool(d, 'needs_partner');
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16 + MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(ticketStr(d, 'title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            if (needsPartner) ...[
              Text(ticketStr(d, 'partner_label'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              DropdownButtonFormField<String>(
                initialValue: _partner.isEmpty ? null : _partner,
                items: [
                  for (final p in partners)
                    DropdownMenuItem(
                        value: ticketStr(p, 'id'),
                        child: Text(ticketStr(p, 'label'))),
                ],
                onChanged: (v) => setState(() => _partner = v ?? ''),
              ),
              SizedBox(height: Ds.space.x16),
            ],
            Text(ticketStr(d, 'category_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final c in cats)
                  ChoiceChip(
                    selected: ticketStr(c, 'code') == _category,
                    onSelected: (_) => setState(() {
                      _category = ticketStr(c, 'code');
                      _priority = ticketStr(c, 'priority');
                    }),
                    label: Text(ticketStr(c, 'label')),
                  ),
              ],
            ),
            if (ticketStr(_cat, 'hint').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(ticketStr(_cat, 'hint'), style: Ds.t.caption),
            ],
            if (ticketStr(_cat, 'sla_label').isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(ticketStr(_cat, 'sla_label'),
                  style: Ds.t.caption.copyWith(color: Ds.c.brand)),
            ],
            SizedBox(height: Ds.space.x16),
            Text(ticketStr(d, 'priority_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              children: [
                for (final p in pris)
                  ChoiceChip(
                    selected: ticketStr(p, 'code') == _priority,
                    onSelected: (_) => setState(() => _priority = ticketStr(p, 'code')),
                    label: Text(ticketStr(p, 'label')),
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _subject,
              decoration:
                  InputDecoration(hintText: ticketStr(d, 'subject_hint')),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _body,
              minLines: 3,
              maxLines: 6,
              decoration: InputDecoration(hintText: ticketStr(d, 'body_hint')),
            ),
            if (ticketStr(_cat, 'link_kind') != 'none') ...[
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: _link,
                decoration: InputDecoration(hintText: ticketStr(d, 'link_hint')),
              ),
            ],
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(ticketStr(d, 'submit_cta')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── one issue, with its timeline ────────────────────────────────────────────

Future<void> openPartnerIssue(BuildContext context, String id) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (_) => PartnerIssueScreen(ticketId: id)));

class PartnerIssueScreen extends StatefulWidget {
  const PartnerIssueScreen({super.key, required this.ticketId});

  final String ticketId;

  @override
  State<PartnerIssueScreen> createState() => _PartnerIssueScreenState();
}

class _PartnerIssueScreenState extends State<PartnerIssueScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _busy = false;
  final _reply = TextEditingController();
  final List<Map<String, dynamic>> _pending = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final d = await PartnerTicketApi.get(widget.ticketId);
      RenderLog.write(
          'c696_issue_open',
          'ok=${d['ok']} msgs=${ticketRows(d['messages']).length} '
              'close=${d['can_close']}');
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final res = await PartnerTicketApi.reply(widget.ticketId, _reply.text,
          attachments: List<Map<String, dynamic>>.from(_pending));
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() => _busy = false);
        showToast(context, ticketStr(res, 'message'), isError: true);
        return;
      }
      _reply.clear();
      _pending.clear();
      showToast(context, ticketStr(res, 'toast'));
      setState(() => _busy = false);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  /// The bucket AND the folder are the backend's (`upload`), so a partner can
  /// only ever write under their own prefix and this file composes no path.
  Future<void> _attach() async {
    final up = ticketMap(_d ?? const {}, 'upload');
    final bucket = ticketStr(up, 'bucket');
    final folder = ticketStr(up, 'folder');
    if (bucket.isEmpty || folder.isEmpty) return;
    try {
      final f = await pickImportFile();
      if (f == null) return;
      final path =
          '$folder/${DateTime.now().millisecondsSinceEpoch}-${f.name}';
      await Supabase.instance.client.storage
          .from(bucket)
          .uploadBinary(path, f.bytes);
      if (!mounted) return;
      setState(() => _pending.add({
            'bucket': bucket,
            'path': path,
            'name': f.name,
            'open_label': ticketStr(_d ?? const {}, 'attach_cta'),
          }));
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _close() async {
    final d = _d;
    if (d == null) return;
    final done = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => PartnerIssueCloseSheet(
          d: ticketMap(d, 'close'), ticketId: widget.ticketId),
    );
    if (done == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final ok = d != null && d['ok'] == true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(ok ? ticketStr(d, 'ref') : ''),
        actions: [
          if (ok && ticketBool(d, 'can_close'))
            TextButton(
              onPressed: _close,
              child: Text(ticketStr(ticketMap(d, 'close'), 'cta')),
            ),
        ],
      ),
      body: _loading
          ? const PartnerSkeleton(rows: 5)
          : !ok
              ? PartnerNotice(text: ticketStr(d ?? const {}, 'message'))
              : _body(d!),
    );
  }

  Widget _body(Map<String, dynamic> d) {
    final row = ticketMap(d, 'row');
    final link = ticketMap(d, 'link');
    final closed = ticketStr(d, 'closed_line');
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(Ds.space.x16),
            children: [
              PartnerCard(child: IssueRow(r: row)),
              Text(ticketStr(d, 'raised_line'), style: Ds.t.caption),
              if (ticketBool(link, 'has')) ...[
                SizedBox(height: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton.icon(
                    onPressed: () => openIssueLink(context, link),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(
                        '${ticketStr(link, 'label')} · ${ticketStr(link, 'cta')}'),
                  ),
                ),
              ],
              if (closed.isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                PartnerChip(text: closed, tone: 'success'),
              ],
              SizedBox(height: Ds.space.x24),
              Text(ticketStr(d, 'timeline_title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x12),
              for (final m in ticketRows(d['messages'])) IssueMessage(m: m),
            ],
          ),
        ),
        if (ticketBool(d, 'can_reply'))
          Container(
            color: Ds.c.surface,
            padding: EdgeInsets.all(Ds.space.x12),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_pending.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: Ds.space.x8,
                        children: [
                          for (final a in _pending)
                            PartnerChip(text: ticketStr(a, 'name'), tone: 'info'),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: ticketStr(d, 'attach_cta'),
                        onPressed: _busy ? null : _attach,
                        icon: const Icon(Icons.attach_file),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _reply,
                          minLines: 1,
                          maxLines: 4,
                          decoration: InputDecoration(
                              hintText: ticketStr(d, 'compose_hint')),
                        ),
                      ),
                      SizedBox(width: Ds.space.x8),
                      SizedBox(
                        height: Ds.touch.minTarget,
                        child: FilledButton(
                          onPressed: _busy ? null : _send,
                          child: Text(ticketStr(d, 'send_cta')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// One message. A system line is centred and tinted; a message from the side
/// reading it sits on the right. Both facts are the payload's (`kind`, `mine`).
class IssueMessage extends StatelessWidget {
  const IssueMessage({super.key, required this.m});

  final Map<String, dynamic> m;

  @override
  Widget build(BuildContext context) {
    final body = ticketStr(m, 'body');
    if (ticketBool(m, 'is_system')) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Center(
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            decoration:
                BoxDecoration(color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
            child: Text(body,
                style: Ds.t.caption.copyWith(color: Ds.c.info),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }
    final mine = ticketBool(m, 'mine');
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text('${ticketStr(m, 'actor_label')} · ${ticketStr(m, 'when_label')}',
              style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Container(
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
                color: mine ? Ds.c.brandSoft : Ds.c.surface,
                borderRadius: Ds.r.rCard),
            child: Text(body, style: Ds.t.body),
          ),
          for (final a in ticketRows(m['attachments']))
            Padding(
              padding: EdgeInsets.only(top: Ds.space.x8),
              child: IssueAttachment(a: a),
            ),
        ],
      ),
    );
  }
}

/// An attachment is the backend's bucket + path. This widget never builds a
/// URL: it asks the platform for a signed one at tap time, which is the rule
/// every private bucket in this app follows.
class IssueAttachment extends StatelessWidget {
  const IssueAttachment({super.key, required this.a});

  final Map<String, dynamic> a;

  /// Injectable opener, so the protected test can assert on the bucket and
  /// path that would have opened, with no network.
  static Future<void> Function(String bucket, String path)? openFn;

  static Future<void> _open(String bucket, String path) async {
    if (openFn != null) return openFn!(bucket, path);
    if (bucket.isEmpty || path.isEmpty) return;
    final url = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, 3600);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final name = ticketStr(a, 'name');
    final label = ticketStr(a, 'open_label');
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton.icon(
        onPressed: () => _open(ticketStr(a, 'bucket'), ticketStr(a, 'path')),
        icon: const Icon(Icons.attachment_outlined),
        label: Text(name.isEmpty ? label : name),
      ),
    );
  }
}

/// The linked object, in one tap. The KIND is the backend's; which widget that
/// kind opens is Dart's, for the same reason the nav icon map is — a Widget is
/// not a string Postgres can hold. A kind this build has never heard of opens
/// nothing rather than throwing.
void openIssueLink(BuildContext context, Map<String, dynamic> link) {
  final kind = ticketStr(link, 'kind');
  final ref = ticketStr(link, 'ref');
  final Widget? screen = switch (kind) {
    'order' => OrderTimelineScreen(seed: ref),
    'supplier' => AdminSupplierPage(supplierId: ref),
    'settlement' => const SettlementScreen(),
    _ => null,
  };
  if (screen == null) return;
  RenderLog.write('c696_issue_link', kind);
  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => screen));
}

/// Closing: the outcome code is required, and it is what the partner scorecard
/// counts. The list, its words and the refusal are all the backend's.
class PartnerIssueCloseSheet extends StatefulWidget {
  const PartnerIssueCloseSheet(
      {super.key, required this.d, required this.ticketId});

  final Map<String, dynamic> d;
  final String ticketId;

  @override
  State<PartnerIssueCloseSheet> createState() => _PartnerIssueCloseSheetState();
}

class _PartnerIssueCloseSheetState extends State<PartnerIssueCloseSheet> {
  String _outcome = '';
  bool _busy = false;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    try {
      final res =
          await PartnerTicketApi.close(widget.ticketId, _outcome, _note.text);
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() => _busy = false);
        showToast(context, ticketStr(res, 'message'), isError: true);
        return;
      }
      RenderLog.write('c696_issue_closed', _outcome);
      showToast(context, ticketStr(res, 'toast'));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.d;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(ticketStr(d, 'title'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(ticketStr(d, 'hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final o in ticketRows(d['outcomes']))
                ChoiceChip(
                  selected: ticketStr(o, 'code') == _outcome,
                  onSelected: (_) => setState(() => _outcome = ticketStr(o, 'code')),
                  label: Text(ticketStr(o, 'label')),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _note,
            decoration: InputDecoration(hintText: ticketStr(d, 'note_hint')),
          ),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(ticketStr(d, 'submit')),
            ),
          ),
        ],
      ),
    );
  }
}
