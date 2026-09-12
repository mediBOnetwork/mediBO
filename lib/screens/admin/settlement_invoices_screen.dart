import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// CHANGE #695 — the GST tax invoice raised on every settled period.
///
/// ONE screen for both sides. `settlement_invoices()` decides the scope: an
/// admin sees every partner's documents, a partner sees their own and cannot
/// widen it by passing somebody else's id. So there is no role branch here —
/// the payload's `is_admin` only decides which BUTTONS the backend already
/// said are available (`can_wa`, `can_credit_note`), never what is fetched.
///
/// Nothing on this screen is computed. Every rupee, the CGST/SGST-versus-IGST
/// line, the status word and its tone, the direction sentence and every button
/// label arrive finished. A rate change or a re-worded status is an UPDATE.
class SettlementInvoicesScreen extends StatefulWidget {
  const SettlementInvoicesScreen({super.key});

  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<SettlementInvoicesScreen> createState() =>
      _SettlementInvoicesScreenState();
}

class _SettlementInvoicesScreenState extends State<SettlementInvoicesScreen> {
  Map<String, dynamic> _p = const {};
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  static Map<String, dynamic> _asMap(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Future<void> _load() async {
    try {
      final res = await SettlementInvoicesScreen.rpc('settlement_invoices');
      if (!mounted) return;
      setState(() {
        _p = _asMap(res);
        _loading = false;
      });
      RenderLog.write('c695_settlement_invoices',
          'ok=${_p['ok']};rows=${(_p['rows'] as List?)?.length ?? 0}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Ask for the PDF, then poll on the BACKEND's own `poll_ms` until it says
  /// ready. The screen invents no timeout of its own and builds no URL: the
  /// bucket and the path are the payload's, and the signed link is minted from
  /// them.
  Future<void> _download(Map<String, dynamic> row) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var res = _asMap(await SettlementInvoicesScreen.rpc(
          'settlement_invoice_request', {'p_invoice_id': row['invoice_id']}));
      var guard = 0;
      while (res['ok'] == true &&
          res['status'] == 'building' &&
          guard < 40 &&
          mounted) {
        guard++;
        final ms = int.tryParse('${res['poll_ms'] ?? 1500}') ?? 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        res = _asMap(await SettlementInvoicesScreen.rpc(
            'settlement_invoice_request', {'p_invoice_id': row['invoice_id']}));
      }
      if (!mounted) return;
      final msg = _s(res, 'message');
      if (res['ok'] != true || res['status'] != 'ready') {
        if (msg.isNotEmpty) showToast(context, msg, isError: true);
        return;
      }
      final url = await Supabase.instance.client.storage
          .from(_s(res, 'bucket'))
          .createSignedUrl(
              _s(res, 'path'), int.tryParse('${res['expires_s'] ?? 300}') ?? 300);
      if (!mounted) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _call(String fn, Map<String, dynamic> params) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = _asMap(await SettlementInvoicesScreen.rpc(fn, params));
      if (!mounted) return;
      final msg = _s(r, 'message');
      if (msg.isNotEmpty) showToast(context, msg, isError: r['ok'] != true);
      if (r['ok'] == true) await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The month's register, as the CA files it. The rows and the CSV are built
  /// together in SQL so the file and the screen can never disagree; this only
  /// shows the count and hands the text to a share sheet.
  Future<void> _register() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = _asMap(
          await SettlementInvoicesScreen.rpc('settlement_invoice_register'));
      if (!mounted) return;
      if (r['ok'] != true) {
        showToast(context, _s(r, 'message'), isError: true);
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: Ds.c.surface,
          title: Text('${_s(r, 'heading')} · ${_s(r, 'month_label')}',
              style: Ds.t.subtitle),
          content: SizedBox(
            width: 520,
            child: SelectableText(
              (r['count'] as int? ?? 0) == 0
                  ? _s(r, 'empty_text')
                  : _s(r, 'csv'),
              style: Ds.t.caption,
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _tone(String t) => switch (t) {
        'danger' => Ds.c.danger,
        'warning' => Ds.c.warning,
        'success' => Ds.c.success,
        _ => Ds.c.textSecondary,
      };

  Color _toneSoft(String t) => switch (t) {
        'danger' => Ds.c.dangerSoft,
        'warning' => Ds.c.warningSoft,
        'success' => Ds.c.successSoft,
        _ => Ds.c.bg,
      };

  @override
  Widget build(BuildContext context) {
    final rows = (_p['rows'] as List?) ?? const [];
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_p, 'heading'), style: Ds.t.subtitle),
        actions: [
          if (_p['is_admin'] == true)
            TextButton(
              onPressed: _busy ? null : _register,
              child: Text(_s(_p, 'register_label'),
                  style: Ds.t.body.copyWith(color: Ds.c.brand)),
            ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : rows.isEmpty
              ? _empty()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: EdgeInsets.all(Ds.space.x16),
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _card(_asMap(rows[i])),
                  ),
                ),
    );
  }

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          4,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 * 2,
              decoration: BoxDecoration(
                  color: Ds.c.surface, borderRadius: Ds.r.rCard),
            ),
          ),
        ),
      );

  Widget _empty() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_s(_p, 'empty_text'),
              textAlign: TextAlign.center, style: Ds.t.body),
        ),
      );

  Widget _card(Map<String, dynamic> r) {
    final tone = _s(r, 'status_tone');
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(r, 'invoice_no'), style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      '${_s(r, 'kind_label')} · ${_s(r, 'date_label')}',
                      style: Ds.t.caption,
                    ),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Text(_s(r, 'total_value'), style: Ds.t.body),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(_s(r, 'direction_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(r, 'tax_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          // A Wrap, not a Row. Three backend-labelled actions beside the status
          // chip overflow a 360px phone by ~53px, and a label's length is the
          // BACKEND's to choose - a Row would turn a re-worded button into a
          // rendering overflow on a screen nobody re-tested.
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                    color: _toneSoft(tone), borderRadius: Ds.r.rChip),
                child: Text(_s(r, 'status_label'),
                    style: Ds.t.caption.copyWith(color: _tone(tone))),
              ),
              if (r['can_download'] == true)
                _action(_s(r, 'download_label'), () => _download(r)),
              if (r['can_wa'] == true)
                _action(
                  _s(r, 'wa_label'),
                  () => _call('settlement_invoice_wa',
                      {'p_invoice_id': r['invoice_id']}),
                ),
              if (r['can_credit_note'] == true)
                _action(
                  _s(r, 'credit_note_label'),
                  () => _call('settlement_invoice_credit_note',
                      {'p_invoice_id': r['invoice_id']}),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 48px tall so every action clears the 44x44 touch target on a phone.
  Widget _action(String label, VoidCallback onTap) => SizedBox(
        height: Ds.space.x48,
        child: TextButton(
          onPressed: _busy ? null : onTap,
          child: Text(label, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
        ),
      );
}
