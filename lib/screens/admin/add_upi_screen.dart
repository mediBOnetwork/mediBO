// CMD #2250 — "Add UPI" (design frames 2 and 3).
//
// Type (Business VPA / Personal UPI) comes from the payload, and so does every
// label on this form. Scanning the merchant QR is the main path: the bank's own
// upi:// string goes to upi_qr_parse, which returns the UPI ID, payee name and
// merchant code EXACTLY as the bank issued them — nothing on this screen types,
// expands or corrects them. "Send ₹1 test" opens a ₹1 payment and the state
// line (waiting / arrived) is read from upi_test_rupee_state on the server.
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'payment_ui.dart';

class AddUpiScreen extends StatefulWidget {
  /// `pay_payee_screen().form` — every label this screen shows.
  final Map<String, dynamic> form;
  final Future<Map<String, dynamic>> Function(String qr)? parseRpc;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> p)? saveRpc;
  final Future<Map<String, dynamic>> Function(
      String pa, String pn, String mc)? testRpc;

  const AddUpiScreen({
    super.key,
    required this.form,
    this.parseRpc,
    this.saveRpc,
    this.testRpc,
  });

  @override
  State<AddUpiScreen> createState() => _AddUpiScreenState();
}

class _AddUpiScreenState extends State<AddUpiScreen> {
  final _pa = TextEditingController();
  final _pn = TextEditingController();
  String _type = 'business_vpa';
  Map<String, dynamic>? _scan;
  bool _busy = false;
  bool _scanning = false;
  String _testState = '';
  String _testTone = 'muted';

  @override
  void initState() {
    super.initState();
    final types = payRows(widget.form['types']);
    if (types.isNotEmpty) _type = payStr(types.first, 'key');
    RenderLog.write('c2250_add_upi_opened', 1);
  }

  @override
  void dispose() {
    _pa.dispose();
    _pn.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _rpcParse(String qr) async {
    if (widget.parseRpc != null) return widget.parseRpc!(qr);
    final r = await Supabase.instance.client
        .rpc('upi_qr_parse', params: {'p_qr': qr});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcSave(Map<String, dynamic> p) async {
    if (widget.saveRpc != null) return widget.saveRpc!(p);
    final r = await Supabase.instance.client.rpc('upi_account_save', params: p);
    return Map<String, dynamic>.from(r as Map);
  }

  Future<Map<String, dynamic>> _rpcTest(String pa, String pn, String mc) async {
    if (widget.testRpc != null) return widget.testRpc!(pa, pn, mc);
    final r = await Supabase.instance.client.rpc('upi_test_rupee',
        params: {'p_pa': pa, 'p_pn': pn, 'p_mc': mc});
    return Map<String, dynamic>.from(r as Map);
  }

  Future<void> _openScanner() async {
    setState(() => _scanning = true);
    final code = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(payStr(widget.form, 'scan_label'),
                  style: Ds.t.title.copyWith(fontWeight: FontWeight.w700)),
              SizedBox(height: Ds.space.x4),
              Text(payStr(widget.form, 'scan_hint'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              ClipRRect(
                borderRadius: Ds.r.rCard,
                child: SizedBox(
                  height: Ds.space.x48 * 5,
                  child: MobileScanner(
                    onDetect: (cap) {
                      for (final b in cap.barcodes) {
                        final v = b.rawValue;
                        if (v != null && v.isNotEmpty) {
                          Navigator.of(ctx).pop(v);
                          return;
                        }
                      }
                    },
                    errorBuilder: (c, e, w) => Container(
                      color: Ds.c.bg,
                      alignment: Alignment.center,
                      child: Text(payStr(widget.form, 'or_label'),
                          style: Ds.t.caption),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _scanning = false);
    if (code == null || code.isEmpty) return;
    await _parse(code);
  }

  Future<void> _parse(String qr) async {
    setState(() => _busy = true);
    try {
      final r = await _rpcParse(qr);
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] != true) {
        showToast(context, payStr(r, 'message'), isError: true);
        return;
      }
      RenderLog.write('c2250_qr_parsed', 1);
      setState(() {
        _scan = r;
        _pa.text = payStr(r, 'pa');
        _pn.text = payStr(r, 'pn');
        _type = payStr(r, 'account_type');
        _testState = '';
        _testTone = 'muted';
      });
      await _showScanSheet();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _sendTest(StateSetter? sheetSet) async {
    final s = _scan ?? const <String, dynamic>{};
    try {
      final r = await _rpcTest(_pa.text.trim(), _pn.text.trim(), payStr(s, 'mc'));
      if (!mounted) return;
      if (r['ok'] == true) {
        final url = payStr(r, 'upi_url');
        if (url.isNotEmpty) {
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        }
        void apply() {
          _testState = payStr(r, 'state_label');
          _testTone = payStr(r, 'state_tone');
        }

        setState(apply);
        if (sheetSet != null) sheetSet(apply);
      } else if (mounted) {
        showToast(context, payStr(r, 'message'), isError: true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _save({required bool makeActive}) async {
    final pa = _pa.text.trim();
    final pn = _pn.text.trim();
    final s = _scan ?? const <String, dynamic>{};
    setState(() => _busy = true);
    try {
      final r = await _rpcSave({
        'p_pa': pa,
        'p_pn': pn,
        'p_account_type': _type,
        'p_merchant_code': payStr(s, 'mc'),
        'p_qr_params': s['qr_params'] ?? <String, dynamic>{},
        'p_qr_raw': payStr(s, 'qr_raw'),
        'p_make_active': makeActive,
      });
      if (!mounted) return;
      setState(() => _busy = false);
      if (r['ok'] != true) {
        showToast(context, payStr(r, 'message'), isError: true);
        return;
      }
      RenderLog.write('c2250_upi_saved', 1);
      showToast(context, payStr(r, 'message'));
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _showScanSheet() {
    final s = _scan!;
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(payStr(s, 'title'),
                    style: Ds.t.title.copyWith(fontWeight: FontWeight.w700)),
                SizedBox(height: Ds.space.x4),
                Text(payStr(s, 'subtitle'), style: Ds.t.caption),
                SizedBox(height: Ds.space.x16),
                for (final row in payRows(s['rows']))
                  Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: PayKeyValue(
                              label: payStr(row, 'label'),
                              value: payStr(row, 'value')),
                        ),
                        if (row['ok'] == true)
                          Icon(Icons.check_circle,
                              size: Ds.space.x16, color: Ds.c.success),
                      ],
                    ),
                  ),
                if (_testState.isNotEmpty) ...[
                  PayChip(_testState, tone: _testTone),
                  SizedBox(height: Ds.space.x16),
                ],
                Row(children: [
                  Expanded(
                    child: Semantics(
                      identifier: 'upi_send_test',
                      child: PayPrimaryButton(
                          label: payStr(s, 'test_label'),
                          outlined: true,
                          onPressed: () => _sendTest(setSheet)),
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Semantics(
                      identifier: 'upi_save_active',
                      child: PayPrimaryButton(
                        label: payStr(s, 'save_label'),
                        busy: _busy,
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _save(makeActive: true);
                        },
                      ),
                    ),
                  ),
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final f = widget.form;
    final types = payRows(f['types']);
    final canSave = _pa.text.trim().contains('@') && _pn.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: Ds.c.brand),
        title: Text(payStr(f, 'title'),
            style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: Ds.c.divider),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.all(Ds.space.x16),
          children: [
            PaySectionLabel(payStr(f, 'type_label')),
            Row(
              children: [
                for (final t in types) ...[
                  Expanded(
                    child: Semantics(
                      identifier: 'upi_type_${payStr(t, 'key')}',
                      child: InkWell(
                        borderRadius: Ds.r.rButton,
                        onTap: () => setState(() => _type = payStr(t, 'key')),
                        child: Container(
                          constraints:
                              BoxConstraints(minHeight: Ds.touch.minTarget),
                          padding: EdgeInsets.all(Ds.space.x12),
                          decoration: BoxDecoration(
                            color: _type == payStr(t, 'key')
                                ? Ds.c.surface
                                : Ds.c.bg,
                            borderRadius: Ds.r.rButton,
                            border: Border.all(
                                color: _type == payStr(t, 'key')
                                    ? Ds.c.brand
                                    : Ds.c.divider),
                          ),
                          child: Column(
                            children: [
                              Text(payStr(t, 'label'),
                                  textAlign: TextAlign.center,
                                  style: Ds.t.body
                                      .copyWith(fontWeight: FontWeight.w700)),
                              SizedBox(height: Ds.space.x4),
                              Text(payStr(t, 'sub'),
                                  textAlign: TextAlign.center,
                                  style: Ds.t.caption),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (t != types.last) SizedBox(width: Ds.space.x12),
                ],
              ],
            ),
            SizedBox(height: Ds.space.x24),
            Semantics(
              identifier: 'upi_scan_qr',
              child: PayPrimaryButton(
                  label: payStr(f, 'scan_label'),
                  busy: _scanning || _busy,
                  onPressed: _openScanner),
            ),
            SizedBox(height: Ds.space.x8),
            Text(payStr(f, 'scan_hint'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            Row(children: [
              Expanded(child: Divider(color: Ds.c.divider)),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                child: Text(payStr(f, 'or_label'), style: Ds.t.caption),
              ),
              Expanded(child: Divider(color: Ds.c.divider)),
            ]),
            SizedBox(height: Ds.space.x16),
            PaySectionLabel(payStr(f, 'vpa_label')),
            TextField(
              controller: _pa,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: payStr(f, 'vpa_hint')),
            ),
            SizedBox(height: Ds.space.x16),
            PaySectionLabel(payStr(f, 'pn_label')),
            TextField(
              controller: _pn,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(hintText: payStr(f, 'pn_hint')),
            ),
            SizedBox(height: Ds.space.x16),
            PaySectionLabel(payStr(f, 'partner_label')),
            PayCard(
              child: Text(payStr(f, 'partner_value'),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
            ),
            SizedBox(height: Ds.space.x24),
            Semantics(
              identifier: 'upi_save',
              child: PayPrimaryButton(
                label: payStr(f, 'save_label'),
                busy: _busy,
                onPressed: canSave ? () => _save(makeActive: true) : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
