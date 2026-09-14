// CHANGE #692 — "My documents": the partner agreement a partner SIGNS, and the
// KYC documents a partner UPLOADS.
//
// Until now a zone partner's paperwork existed only as an admin checklist
// (partner_onboarding_step, ticked by the office) and four doc-path columns on
// region_partners. Nothing was signed by the partner, nothing was uploaded by
// the partner, and nothing stopped a zone being handed to a partner who had
// agreed to nothing.
//
// The screen computes NOTHING. `partner_documents_screen()` returns three
// blocks — golive, agreement, kyc — and every heading, chip word, tone, button
// caption, refusal sentence, expiry line and progress string in this file is a
// field of that payload. The one thing decided here is which widget draws a
// tone, and that mapping already lives in partner_ui.dart.
//
// The e-sign is the platform's own WhatsApp OTP: partner_agreement_sign_start()
// sends it through the same login-otp function every other code rides, and
// partner_agreement_sign_verify() is what records the signer's name, the
// timestamp, the IP and an immutable snapshot of the text. This screen never
// decides that a signature happened — `status`/`is_signed` say so.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/download_bytes.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_home_screen.dart' show PartnerFeaturePage;
import 'partner_ui.dart';

/// Test seam. Null in production -> the real RPC.
typedef PartnerDocsApi = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class PartnerDocumentsScreen extends StatefulWidget {
  const PartnerDocumentsScreen({super.key, this.partnerId, this.api});

  /// An admin opens a NAMED partner's documents; a partner opens their own and
  /// the backend refuses any id they try to name.
  final int? partnerId;
  final PartnerDocsApi? api;

  @override
  State<PartnerDocumentsScreen> createState() => _PartnerDocumentsScreenState();
}

class _PartnerDocumentsScreenState extends State<PartnerDocumentsScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _rpc(String fn, Map<String, dynamic> p) async {
    final api = widget.api;
    if (api != null) return api(fn, p);
    final res = await Supabase.instance.client.rpc(fn, params: p);
    return Map<String, dynamic>.from(res as Map);
  }

  /// The RPC ARGUMENT an admin passes to name a partner. Absent for a partner
  /// signing in as themselves — the backend then resolves their own id and
  /// refuses any id they try to name.
  Map<String, dynamic> _arg() =>
      {if (widget.partnerId != null) 'p_partner_id': widget.partnerId};

  /// The same id inside the jsonb payload the write RPCs take.
  Map<String, dynamic> _body([Map<String, dynamic> extra = const {}]) => {
        if (widget.partnerId != null) 'partner_id': widget.partnerId,
        ...extra,
      };

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final map = await _rpc('partner_documents_screen', _arg());
      final kyc = _map(map['kyc']);
      final agree = _map(map['agreement']);
      // CHANGE #692 follow-up (CMD #998) — the ROUTE arm's own proof.
      //
      // The door (`partner_documents` in shellExtraRouteScreen) and the screen
      // both existed; what could not be PROVEN was that a tap on the tile drew
      // this block instead of falling through the shell's switch and writing
      // `c536_route_unknown`. The admin console already publishes
      // `c692_partner_documents` for its own copy of the card, so the partner's
      // own page publishes the SAME key in the SAME shape: one render-log key
      // answers "did the documents block draw", whichever surface drew it, and
      // `via=` says which one. That is the key the command's proof reads.
      RenderLog.write(
          'c692_partner_documents',
          'card=${map['ok'] == true},'
          'ready=${_map(map['golive'])['ready']},'
          'agreement=${agree['status']},'
          'kyc=${(kyc['rows'] as List?)?.length ?? 0},'
          'via=route');
      if (!mounted) return;
      setState(() {
        _d = map;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Every write: call, print the backend's own message with the backend's own
  /// tone, reload. The screen never decides what happened.
  Future<bool> _write(String fn, Map<String, dynamic> params) async {
    setState(() => _busy = true);
    try {
      final map = await _rpc(fn, params);
      if (!mounted) return false;
      final msg = (map['message'] as String?) ?? '';
      if (msg.isNotEmpty) showToast(context, msg, isError: map['ok'] != true);
      await _load();
      return map['ok'] == true;
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static Map<String, dynamic> _map(Object? v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  static String _s(Map<String, dynamic> m, String k) =>
      (m[k] is String) ? m[k] as String : '';

  @override
  Widget build(BuildContext context) {
    if (_loading) return const PartnerSkeleton(rows: 5);
    final d = _d;
    if (d == null || d['ok'] != true) {
      return PartnerNotice(text: _s(_map(d ?? const {}), 'message'));
    }
    final golive = _map(d['golive']);
    final agreement = _map(d['agreement']);
    final kyc = _map(d['kyc']);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          _GoLiveCard(golive: golive),
          SizedBox(height: Ds.space.x24),
          _AgreementCard(
            data: agreement,
            busy: _busy,
            onSign: () => _signSheet(agreement),
            onOpen: () => _open(
                _s(agreement, 'doc_bucket'), _s(agreement, 'doc_path')),
            onPropose: (clause) => _proposeSheet(agreement, clause),
            onDiff: () => _diffSheet(agreement),
          ),
          SizedBox(height: Ds.space.x24),
          _KycSection(
            data: kyc,
            busy: _busy,
            onUpload: _uploadSheet,
            onOpen: _open,
            onReview: _reviewSheet,
          ),
        ],
      ),
    );
  }

  /// The payload names the bucket and the path; this signs it. An empty pair
  /// opens nothing rather than a guessed URL.
  Future<void> _open(String bucket, String path) async {
    if (bucket.isEmpty || path.isEmpty) return;
    try {
      final url = await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, 300);
      downloadUrl(url, path.split('/').last);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  // ── a clause change the partner is ASKING for ─────────────────────────────
  //
  // CMD #1985. Nothing here is live: agreement_proposal_raise() files it as a
  // proposal and mediBO approves or rejects it with a reason. The partner types
  // their wording; the clause they signed does not move until someone says so.
  Future<void> _proposeSheet(
      Map<String, dynamic> a, Map<String, dynamic> clause) async {
    final body = TextEditingController(text: _s(clause, 'body'));
    final note = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('${_s(clause, 'n')}. ${_s(clause, 'heading')}',
                  style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: body,
                maxLines: 6,
                decoration:
                    InputDecoration(labelText: _s(a, 'propose_hint')),
              ),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: note,
                maxLines: 2,
                decoration:
                    InputDecoration(labelText: _s(a, 'propose_note_hint')),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final ok = await _write('agreement_proposal_raise', {
                            'p': _body({
                              'clause_id': clause['clause_id'],
                              'proposed_body': body.text,
                              'note': note.text.trim(),
                            })
                          });
                          if (ok && ctx.mounted) Navigator.of(ctx).pop();
                        },
                  child: Text(_s(a, 'propose_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── what changed since this partner last signed ───────────────────────────
  //
  // The re-sign ask is only fair if the partner can see what moved. The rows,
  // their words and their tones are agreement_diff()'s; this draws them.
  Future<void> _diffSheet(Map<String, dynamic> a) async {
    final diff = _map(a['diff']);
    final rows = (diff['rows'] as List? ?? const [])
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        builder: (ctx, scroll) => Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: ListView(
            controller: scroll,
            children: [
              Text(_s(diff, 'heading'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(_s(diff, 'summary_label'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              if (rows.isEmpty)
                Text(_s(diff, 'empty_label'), style: Ds.t.bodySecondary)
              else
                for (final r in rows) ...[
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: Ds.space.x8,
                    runSpacing: Ds.space.x4,
                    children: [
                      Text('${_s(r, 'n')}. ${_s(r, 'heading')}',
                          style: Ds.t.bodyStrong),
                      PartnerChip(
                          text: _s(r, 'kind_label'), tone: r['tone'] as String?),
                    ],
                  ),
                  if (_s(r, 'old').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(_s(r, 'old'), style: Ds.t.caption),
                  ],
                  if (_s(r, 'new').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(_s(r, 'new'), style: Ds.t.bodySecondary),
                  ],
                  SizedBox(height: Ds.space.x24),
                ],
            ],
          ),
        ),
      ),
    );
  }

  // ── the e-sign ────────────────────────────────────────────────────────────
  Future<void> _signSheet(Map<String, dynamic> a) async {
    final name = TextEditingController();
    final phone = TextEditingController();
    final code = TextEditingController();
    var sent = a['awaiting_code'] == true;

    await showModalBottomSheet<void>(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(a, 'sign_label'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x16),
              if (!sent) ...[
                TextField(
                  controller: name,
                  decoration: InputDecoration(labelText: _s(a, 'name_hint')),
                ),
                SizedBox(height: Ds.space.x12),
                TextField(
                  controller: phone,
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(labelText: _s(a, 'phone_hint')),
                ),
              ] else
                TextField(
                  controller: code,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(labelText: _s(a, 'code_hint')),
                ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (!sent) {
                            final ok = await _write(
                                'partner_agreement_sign_start',
                                {
                                  'p': _body({
                                    'signer_name': name.text.trim(),
                                    'phone': phone.text.trim(),
                                  })
                                });
                            if (ok) setSheet(() => sent = true);
                          } else {
                            final ok = await _write(
                                'partner_agreement_sign_verify',
                                {
                                  'p': _body({'code': code.text.trim()})
                                });
                            if (ok && ctx.mounted) Navigator.of(ctx).pop();
                          }
                        },
                  child: Text(
                      sent ? _s(a, 'verify_label') : _s(a, 'send_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── an upload ─────────────────────────────────────────────────────────────
  Future<void> _uploadSheet(Map<String, dynamic> row) async {
    final number = TextEditingController(text: _s(row, 'number'));
    final expiry = TextEditingController(text: _s(row, 'expiry_iso'));
    var path = '';
    var fileName = '';

    await showModalBottomSheet<void>(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(row, 'label'), style: Ds.t.subtitle),
              if (_s(row, 'hint').isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(row, 'hint'), style: Ds.t.caption),
              ],
              SizedBox(height: Ds.space.x16),
              if (row['wants_number'] == true) ...[
                TextField(
                  controller: number,
                  decoration:
                      InputDecoration(labelText: _s(row, 'number_hint')),
                ),
                SizedBox(height: Ds.space.x12),
              ],
              if (row['wants_expiry'] == true) ...[
                TextField(
                  controller: expiry,
                  readOnly: true,
                  decoration:
                      InputDecoration(labelText: _s(row, 'expiry_hint')),
                  onTap: () async {
                    final now = DateTime.now();
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: now,
                      firstDate: now,
                      lastDate: DateTime(now.year + 20),
                    );
                    if (picked != null) {
                      setSheet(() => expiry.text =
                          picked.toIso8601String().split('T').first);
                    }
                  },
                ),
                SizedBox(height: Ds.space.x12),
              ],
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final r = await _pick(_s(row, 'doc_key'));
                    if (r != null) {
                      setSheet(() {
                        path = r.$1;
                        fileName = r.$2;
                      });
                    }
                  },
                  icon: const Icon(Icons.attach_file_outlined),
                  label: Text(fileName.isEmpty
                      ? _s(row, 'upload_label')
                      : fileName),
                ),
              ),
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final ok = await _write('partner_kyc_submit', {
                            'p': _body({
                              'doc_key': _s(row, 'doc_key'),
                              'path': path,
                              'file_name': fileName,
                              'number': number.text.trim(),
                              'expiry': expiry.text.trim().isEmpty
                                  ? null
                                  : expiry.text.trim(),
                            })
                          });
                          if (ok && ctx.mounted) Navigator.of(ctx).pop();
                        },
                  child: Text(_s(row, 'upload_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks a file and puts it where `partner_kyc_upload_path()` says. The path
  /// is never composed here.
  Future<(String, String)?> _pick(String docKey) async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'pdf'],
        allowMultiple: false,
        withData: true,
      );
    } catch (_) {}
    final bytes = picked?.files.firstOrNull?.bytes;
    if (bytes == null) return null;
    final pf = picked!.files.first;
    setState(() => _busy = true);
    try {
      final m = await _rpc('partner_kyc_upload_path', {
        'p_doc_key': docKey,
        'p_ext': (pf.extension ?? 'jpg').toLowerCase(),
        // An admin uploading on a partner's behalf names the partner; a
        // partner sends nothing and the backend resolves their own folder.
        ..._arg(),
      });
      if (m['ok'] != true) {
        if (mounted) {
          showToast(context, _s(m, 'message'), isError: true);
        }
        return null;
      }
      await Supabase.instance.client.storage
          .from(m['bucket'] as String)
          .uploadBinary(m['path'] as String, bytes);
      return (m['path'] as String, pf.name);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── the office's verdict ──────────────────────────────────────────────────
  Future<void> _reviewSheet(Map<String, dynamic> row) async {
    final reason = TextEditingController(text: _s(row, 'reject_reason'));
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_s(row, 'label'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: reason,
              decoration: InputDecoration(labelText: _s(row, 'reject_hint')),
            ),
            SizedBox(height: Ds.space.x24),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                          foregroundColor: Ds.c.danger),
                      onPressed: () async {
                        final ok = await _write('partner_kyc_review_set', {
                          'p': {
                            'partner_id': row['partner_id'],
                            'doc_key': _s(row, 'doc_key'),
                            'status': 'rejected',
                            'reason': reason.text.trim(),
                          }
                        });
                        if (ok && ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: Text(_s(row, 'reject_label')),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: () async {
                        final ok = await _write('partner_kyc_review_set', {
                          'p': {
                            'partner_id': row['partner_id'],
                            'doc_key': _s(row, 'doc_key'),
                            'status': 'verified',
                          }
                        });
                        if (ok && ctx.mounted) Navigator.of(ctx).pop();
                      },
                      child: Text(_s(row, 'verify_label')),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── the three blocks ────────────────────────────────────────────────────────

/// Whether this partner may be given orders, and the backend's one sentence
/// saying why not. The sentence is never assembled here.
class _GoLiveCard extends StatelessWidget {
  const _GoLiveCard({required this.golive});

  final Map<String, dynamic> golive;

  @override
  Widget build(BuildContext context) {
    final blockers = (golive['blockers'] as List? ?? const []);
    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                    (golive['heading'] as String?) ?? '', style: Ds.t.subtitle),
              ),
              PartnerChip(
                text: (golive['status_label'] as String?) ?? '',
                tone: golive['status_tone'] as String?,
              ),
            ],
          ),
          for (final b in blockers) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.circle,
                    size: Ds.space.x8,
                    color: partnerToneColor(
                        (b as Map)['tone'] as String?)),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text((b['text'] as String?) ?? '',
                      style: Ds.t.bodySecondary),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// The agreement, as a LIVING document (CMD #1985).
///
/// The card used to draw one blob of prose and a Sign button. It now draws the
/// four things that make the agreement true on the day it is read: the health
/// line (which version is signed, what it is valid to, what is pending), the
/// commercial terms that also drive settlement, the clauses with their tokens
/// already filled in for THIS partner, and — when a fresh signature is being
/// asked for — the reason and a diff of what moved.
///
/// It still decides nothing. `can_sign`, `health_tone`, every label and the
/// void sentence are fields of partner_agreement_card().
class _AgreementCard extends StatelessWidget {
  const _AgreementCard({
    required this.data,
    required this.busy,
    required this.onSign,
    required this.onOpen,
    required this.onPropose,
    required this.onDiff,
  });

  final Map<String, dynamic> data;
  final bool busy;
  final VoidCallback onSign;
  final VoidCallback onOpen;
  final void Function(Map<String, dynamic> clause) onPropose;
  final VoidCallback onDiff;

  String _s(String k) => (data[k] == null) ? '' : data[k].toString();

  List<Map<String, dynamic>> _list(String k) {
    final raw = data[k];
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? Map<String, dynamic>.from(e) : null)
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (data['ok'] != true) {
      return PartnerCard(child: Text(_s('message'), style: Ds.t.bodySecondary));
    }
    final clauses = _list('clauses');
    final terms = _list('terms_rows');
    final props = _list('proposals');
    final hasDiff = (data['diff'] is Map) &&
        ((data['diff'] as Map)['ok'] == true);

    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A Wrap, not a Row: at 360px the heading and a status word as long
          // as "Needs a fresh signature" do not fit on one line, and a phone is
          // where 99% of this is read. The chip drops below instead of
          // overflowing (CMD #1950).
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x4,
            children: [
              Text(_s('heading'), style: Ds.t.subtitle),
              PartnerChip(
                  text: _s('status_label'), tone: data['status_tone'] as String?),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s('sub'), style: Ds.t.caption),

          // The one line that answers "where does this partner stand".
          if (_s('health_line').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('health_line'), style: Ds.t.bodyStrong),
          ],
          if (data['has_version'] == true) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s('version_label'), style: Ds.t.caption),
            Text(_s('validity_label'), style: Ds.t.caption),
          ],

          // Why the earlier signature stopped counting, in the backend's words.
          if (_s('void_reason').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rCard,
              ),
              child: Text(_s('void_reason'), style: Ds.t.bodySecondary),
            ),
          ],

          if (terms.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(_s('terms_heading'), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x8),
            for (final t in terms)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x4,
                  children: [
                    Text((t['label'] ?? '').toString(), style: Ds.t.caption),
                    Text((t['value'] ?? '').toString(), style: Ds.t.bodyStrong),
                  ],
                ),
              ),
          ],

          if (hasDiff) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: onDiff,
                icon: const Icon(Icons.compare_arrows),
                label: Text(
                    ((data['diff'] as Map)['heading'] ?? '').toString()),
              ),
            ),
          ],

          if (clauses.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            _AgreementClauses(
              title: _s('title'),
              clauses: clauses,
              proposeLabel: _s('propose_label'),
              busy: busy,
              onPropose: onPropose,
            ),
          ],

          if (props.isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            Text(_s('proposals_heading'), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x8),
            for (final pr in props)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: Ds.space.x8,
                      runSpacing: Ds.space.x4,
                      children: [
                        Text(
                            '${(pr['clause_n'] ?? '')}. '
                            '${(pr['heading'] ?? '')}',
                            style: Ds.t.body),
                        PartnerChip(
                            text: (pr['status_label'] ?? '').toString(),
                            tone: pr['status_tone'] as String?),
                      ],
                    ),
                    if ((pr['decision_reason'] ?? '').toString().isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text((pr['decision_reason']).toString(),
                          style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
          ],

          if (_s('signed_line').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('signed_line'), style: Ds.t.bodySecondary),
          ],
          if (_s('signed_ip_line').isNotEmpty)
            Text(_s('signed_ip_line'), style: Ds.t.caption),
          if (_s('hash_line').isNotEmpty)
            Text(_s('hash_line'), style: Ds.t.caption),
          if (data['doc_building'] == true) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s('doc_building_label'), style: Ds.t.caption),
          ],
          if (data['has_doc'] == true) ...[
            SizedBox(height: Ds.space.x8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onOpen,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: Text(_s('doc_label')),
              ),
            ),
          ],
          if (data['can_sign'] == true) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: busy ? null : onSign,
                child: Text(_s('sign_label')),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The clauses, collapsed by default so the card stays a card. Each one is
/// already resolved for this partner — `{{partner}}` became their own name in
/// the backend, never here. A clause the version marks editable_by_partner
/// carries the one action a partner has on the text: ask for a change.
class _AgreementClauses extends StatelessWidget {
  const _AgreementClauses({
    required this.title,
    required this.clauses,
    required this.proposeLabel,
    required this.busy,
    required this.onPropose,
  });

  final String title;
  final List<Map<String, dynamic>> clauses;
  final String proposeLabel;
  final bool busy;
  final void Function(Map<String, dynamic> clause) onPropose;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Ds.c.divider),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.only(bottom: Ds.space.x8),
        title: Text(title, style: Ds.t.bodyStrong),
        children: [
          for (final c in clauses)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${(c['n'] ?? '')}. ${(c['heading'] ?? '')}',
                      style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text((c['body'] ?? '').toString(),
                      style: Ds.t.bodySecondary),
                  if (c['editable_by_partner'] == true) ...[
                    SizedBox(height: Ds.space.x8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        height: Ds.touch.minTarget,
                        child: TextButton.icon(
                          onPressed: busy ? null : () => onPropose(c),
                          icon: const Icon(Icons.edit_outlined),
                          label: Text(proposeLabel),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The document list. Rows render in PAYLOAD order — the backend sorts them and
/// the screen never re-sorts.
class _KycSection extends StatelessWidget {
  const _KycSection({
    required this.data,
    required this.busy,
    required this.onUpload,
    required this.onOpen,
    required this.onReview,
  });

  final Map<String, dynamic> data;
  final bool busy;
  final void Function(Map<String, dynamic> row) onUpload;
  final void Function(String bucket, String path) onOpen;
  final void Function(Map<String, dynamic> row) onReview;

  String _s(String k) => (data[k] is String) ? data[k] as String : '';

  @override
  Widget build(BuildContext context) {
    if (data['ok'] != true) {
      return PartnerCard(child: Text(_s('message'), style: Ds.t.bodySecondary));
    }
    final rows = (data['rows'] as List? ?? const []);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(_s('heading'), style: Ds.t.subtitle)),
            PartnerChip(
                text: _s('summary_label'), tone: data['summary_tone'] as String?),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(_s('sub'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(_s('progress_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x16),
        for (final r in rows)
          _KycRow(
            row: {
              ...Map<String, dynamic>.from(r as Map),
              'partner_id': data['partner_id'],
            },
            busy: busy,
            onUpload: onUpload,
            onOpen: onOpen,
            onReview: onReview,
          ),
      ],
    );
  }
}

class _KycRow extends StatelessWidget {
  const _KycRow({
    required this.row,
    required this.busy,
    required this.onUpload,
    required this.onOpen,
    required this.onReview,
  });

  final Map<String, dynamic> row;
  final bool busy;
  final void Function(Map<String, dynamic> row) onUpload;
  final void Function(String bucket, String path) onOpen;
  final void Function(Map<String, dynamic> row) onReview;

  String _s(String k) => (row[k] is String) ? row[k] as String : '';

  @override
  Widget build(BuildContext context) {
    return PartnerCard(
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
                    Text(_s('label'), style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(_s('required_label'), style: Ds.t.caption),
                  ],
                ),
              ),
              PartnerChip(
                  text: _s('status_label'), tone: row['status_tone'] as String?),
            ],
          ),
          if (_s('number').isNotEmpty || _s('expiry_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              [_s('number'), _s('expiry_label')]
                  .where((t) => t.isNotEmpty)
                  .join(' · '),
              style: Ds.t.caption,
            ),
          ],
          if (_s('uploaded_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s('uploaded_label'), style: Ds.t.caption),
          ],
          if (_s('reject_line').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s('reject_line'),
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              if (row['has_file'] == true)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: () => onOpen(_s('bucket'), _s('path')),
                    child: Text(_s('view_label')),
                  ),
                ),
              if (row['can_upload'] == true)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy ? null : () => onUpload(row),
                    child: Text(_s('upload_label')),
                  ),
                ),
              if (row['can_review'] == true)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: busy ? null : () => onReview(row),
                    child: Text(_s('verify_label')),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The routed page. `partner_documents` is a route_key like any other; the
/// shell opens this and the Scaffold's title is the label the ACCESS MATRIX
/// gave the feature, so renaming "My documents" is a registry edit rather than
/// a deploy. The screen inside brings no Scaffold of its own, exactly like
/// every other partner destination.
class PartnerDocumentsPage extends StatelessWidget {
  const PartnerDocumentsPage({super.key, this.partnerId});

  final int? partnerId;

  @override
  Widget build(BuildContext context) => PartnerFeaturePage(
        title: c('partner_kyc.heading'),
        child: PartnerDocumentsScreen(partnerId: partnerId),
      );
}
