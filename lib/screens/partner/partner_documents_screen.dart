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
import '../../utils/download_bytes.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
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
      RenderLog.write(
          'partner_documents',
          'ok=${map['ok']} kyc_rows=${(kyc['rows'] as List?)?.length ?? 0} '
          'agreement=${agree['status']} '
          'golive=${_map(map['golive'])['ready']}');
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

/// The agreement: its version line, its text, and the one action the backend
/// says is open — `can_sign` is a flag, never a status word read in Dart.
class _AgreementCard extends StatelessWidget {
  const _AgreementCard({
    required this.data,
    required this.busy,
    required this.onSign,
    required this.onOpen,
  });

  final Map<String, dynamic> data;
  final bool busy;
  final VoidCallback onSign;
  final VoidCallback onOpen;

  String _s(String k) => (data[k] is String) ? data[k] as String : '';

  @override
  Widget build(BuildContext context) {
    if (data['ok'] != true) {
      return PartnerCard(child: Text(_s('message'), style: Ds.t.bodySecondary));
    }
    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s('heading'), style: Ds.t.subtitle)),
              PartnerChip(
                  text: _s('status_label'), tone: data['status_tone'] as String?),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s('sub'), style: Ds.t.caption),
          if (data['has_version'] == true) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('version_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            _AgreementBody(title: _s('title'), body: _s('body')),
          ],
          if (_s('signed_line').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s('signed_line'), style: Ds.t.bodySecondary),
          ],
          if (_s('signed_ip_line').isNotEmpty)
            Text(_s('signed_ip_line'), style: Ds.t.caption),
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

/// The agreement text, collapsed by default so the card stays a card. The
/// heading is the backend's document title; nothing here is written in Dart.
class _AgreementBody extends StatelessWidget {
  const _AgreementBody({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) return const SizedBox.shrink();
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Ds.c.divider),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.only(bottom: Ds.space.x8),
        title: Text(title, style: Ds.t.bodyStrong),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text(body, style: Ds.t.bodySecondary),
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
