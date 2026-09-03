import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #705 — the KYC review console: the documents a pharmacy or a supplier
/// uploaded, and the verdict on each.
///
/// Reachable by an admin and by a partner holding `partner.kyc_review`; the
/// backend does the gating (`kyc_review_queue` answers `not_authorized` with
/// its own sentence) and the zone scoping, so this file never asks who is
/// looking. The tabs, the counts, the status words, both button captions and
/// the rejection hint are all payload strings. A rejection cannot be sent
/// without a reason — and that check is the backend's too; this only keeps the
/// button disabled until there is text to send.
///
/// The document itself is opened at the bucket+path the payload names, through
/// a signed URL minted here — the screen never builds a URL of its own.
class KycReviewScreen extends StatefulWidget {
  const KycReviewScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<KycReviewScreen> createState() => _KycReviewScreenState();
}

class _KycReviewScreenState extends State<KycReviewScreen> {
  bool _loading = true;
  bool _busy = false;
  String _status = 'pending';
  Map<String, dynamic> _payload = const {};
  Map<String, dynamic> _drive = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  String _s(String k) => (_payload[k] ?? '').toString();
  String _d(String k) => (_drive[k] ?? '').toString();

  List<Map<String, dynamic>> get _rows => ((_payload['rows'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final q = _asMap(await KycReviewScreen.rpc(
          'kyc_review_queue', {'p_status': _status, 'p_limit': 50, 'p_offset': 0}));
      final d = _asMap(await KycReviewScreen.rpc('kyc_drive_card'));
      if (!mounted) return;
      setState(() {
        _payload = q ?? const {};
        _drive = d ?? const {};
        _loading = false;
      });
      RenderLog.write('c705_kyc_review', _rows.length);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verdict(Map<String, dynamic> row, String status,
      [String? reason]) async {
    setState(() => _busy = true);
    try {
      final res = _asMap(await KycReviewScreen.rpc('kyc_review_set', {
        'p_doc_id': row['doc_id'],
        'p_status': status,
        'p_reason': reason,
      }));
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = (res?['message'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      await _load();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDoc(Map<String, dynamic> row) async {
    try {
      final url = await Supabase.instance.client.storage
          .from((row['bucket'] ?? '').toString())
          .createSignedUrl((row['path'] ?? '').toString(), 300);
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: SelectableText(url, style: Ds.t.caption),
          ),
        ),
      );
    } catch (_) {/* a missing object is not a crash */}
  }

  Future<void> _reject(Map<String, dynamic> row) async {
    final ctl = TextEditingController();
    final reason = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16, Ds.space.x16,
            MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s('reason_label'), style: Ds.t.title),
            SizedBox(height: Ds.space.x8),
            Text(_s('reason_hint'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x16),
            TextField(controller: ctl, maxLines: 3, autofocus: true),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(ctl.text.trim()),
                child: Text((row['reject_label'] ?? '').toString()),
              ),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (reason != null && reason.isNotEmpty) {
      await _verdict(row, 'rejected', reason);
    }
  }

  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s('title'))),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  for (var i = 0; i < 4; i++)
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x12),
                      child: Container(
                        height: Ds.space.x48,
                        decoration: BoxDecoration(
                            color: Ds.c.surface, borderRadius: Ds.r.rCard),
                      ),
                    ),
                ],
              )
            : _payload['ok'] != true
                ? ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [Text(_s('message'), style: Ds.t.bodySecondary)],
                  )
                : ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (_drive['ok'] == true) _driveCard(),
                      _tabs(),
                      SizedBox(height: Ds.space.x16),
                      if (_rows.isEmpty)
                        Text(_s('empty_note'), style: Ds.t.bodySecondary)
                      else
                        for (final r in _rows) ...[
                          _card(r),
                          SizedBox(height: Ds.space.x12),
                        ],
                    ],
                  ),
      ),
    );
  }

  Widget _driveCard() => Container(
        margin: EdgeInsets.only(bottom: Ds.space.x24),
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_d('title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
            Text(_d('subtitle'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
            Text(_d('progress_label'), style: Ds.t.body),
            SizedBox(height: Ds.space.x4),
            Text(_d('deadline_label'), style: Ds.t.caption),
            if (_drive['can_send'] == true) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          final res = _asMap(
                              await KycReviewScreen.rpc('kyc_drive_send'));
                          if (!mounted) return;
                          setState(() => _busy = false);
                          final m = (res?['message'] ?? '').toString();
                          if (m.isNotEmpty) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(content: Text(m)));
                          }
                          await _load();
                        },
                  child: Text(_d('send_label')),
                ),
              ),
            ],
          ],
        ),
      );

  Widget _tabs() {
    final tabs = ((_payload['tabs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    return Wrap(
      spacing: Ds.space.x8,
      children: [
        for (final t in tabs)
          ChoiceChip(
            label: Text((t['label'] ?? '').toString()),
            selected: _status == (t['key'] ?? '').toString(),
            onSelected: (_) {
              setState(() => _status = (t['key'] ?? '').toString());
              _load();
            },
          ),
      ],
    );
  }

  Widget _card(Map<String, dynamic> r) {
    String v(String k) => (r[k] ?? '').toString();
    final canWrite = _payload['can_write'] == true && v('status') == 'pending';
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
            children: [
              Expanded(child: Text(v('owner_name'), style: Ds.t.subtitle)),
              Text(v('status_label'),
                  style: Ds.t.caption.copyWith(color: _tone(v('status_tone')))),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text('${v('kind_label')} · ${v('owner_city')}', style: Ds.t.caption),
          if (v('number').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text('${v('number_label')}: ${v('number')}', style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x4),
          Text(v('expiry_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(v('submitted_label'), style: Ds.t.caption),
          if (v('reason').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(v('reason'),
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: () => _openDoc(r),
                    child: Text(v('view_label')),
                  ),
                ),
              ),
              if (canWrite) ...[
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _reject(r),
                      child: Text(v('reject_label')),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: _busy ? null : () => _verdict(r, 'verified'),
                      child: Text(v('verify_label')),
                    ),
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
