// CMD #432 — the UPI QR surface: one card, four places, zero decisions.
//
// The pharmacy is paid DIRECTLY. There is no gateway between the patient's bank
// and the shop's, which means there is also no webhook, so this file is careful
// about two things:
//
//   1. IT NEVER BUILDS A upi:// STRING. `upi_qr_string()` in the database is
//      the only place that concatenates one. What arrives here is a finished
//      `qr_string`; the widget hands it to the QR painter and prints the rows
//      the payload sent. It does not know the parameter order, does not format
//      the amount, and cannot drift from what the receipt PDF draws.
//   2. IT NEVER CLAIMS A PAYMENT ARRIVED. "Payment received" is a person's
//      statement, so the button writes `pos_payment_confirm` and then renders
//      the backend's own attributed sentence. There is no optimistic state, no
//      local "paid" flag, and nothing here calls anything verified.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design_tokens.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// The backend names a tone; this maps the NAME to the theme.
Color _tone(String t) => switch (t) {
  'success' => Ds.c.success,
  'warning' => Ds.c.warning,
  'danger' => Ds.c.danger,
  _ => Ds.c.info,
};

Color _toneSoft(String t) => switch (t) {
  'success' => Ds.c.successSoft,
  'warning' => Ds.c.warningSoft,
  'danger' => Ds.c.dangerSoft,
  _ => Ds.c.infoSoft,
};

BoxDecoration _card() => BoxDecoration(
  color: Ds.c.surface,
  borderRadius: Ds.r.rCard,
  boxShadow: Ds.elevation.e1,
);

/// One `_upi_qr_block()` payload. `has:false` is not an error — it is the shop
/// saying it has no confirmed VPA yet, and it carries its own words for that.
class UpiQrView {
  final bool has;
  final String reason, title, sub, qrString, vpa, payee, hint, cta;
  final List<Map<String, dynamic>> rows;

  const UpiQrView({
    this.has = false,
    this.reason = '',
    this.title = '',
    this.sub = '',
    this.qrString = '',
    this.vpa = '',
    this.payee = '',
    this.hint = '',
    this.cta = '',
    this.rows = const [],
  });

  factory UpiQrView.fromPayload(Object? p) {
    final m = _m(p);
    return UpiQrView(
      has: m['has'] == true,
      reason: _s(m['reason']),
      title: _s(m['title']),
      sub: _s(m['sub']),
      qrString: _s(m['qr_string']),
      vpa: _s(m['vpa']),
      payee: _s(m['payee']),
      hint: _s(m['hint']),
      cta: _s(m['cta']),
      rows: _rows(m['rows']),
    );
  }

  /// A QR is drawable only when the BACKEND said so and sent a string. Neither
  /// half alone is enough: `has:true` with no string would paint an empty box.
  bool get canDraw => has && qrString.isNotEmpty;
}

/// The QR itself. Nothing else in the app draws one of these.
class UpiQrImage extends StatelessWidget {
  final UpiQrView view;
  final double size;
  const UpiQrImage({super.key, required this.view, this.size = 200});

  // White is not a theme choice here and does not follow the design tokens on
  // purpose: a QR is only reliably scannable as dark modules on a white quiet
  // zone, and a phone camera reading a surface-tinted code in dark mode fails.
  // It is the one place in this file where the pixels have a job other than
  // looking right.
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(Ds.space.x8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: Ds.r.rCard,
      border: Border.all(color: Ds.c.divider),
    ),
    child: QrImageView(
      data: view.qrString,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      backgroundColor: Colors.white,
      padding: EdgeInsets.zero,
    ),
  );
}

/// Title, code, and the payload's own rows — the amount row arrives already
/// formatted, so the card never sees a number it has to turn into rupees.
class UpiQrCard extends StatelessWidget {
  final UpiQrView view;
  final VoidCallback? onSetup;
  final double size;

  const UpiQrCard({
    super.key,
    required this.view,
    this.onSetup,
    this.size = 200,
  });

  @override
  Widget build(BuildContext context) {
    if (!view.canDraw) return _NoVpa(view: view, onSetup: onSetup);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (view.title.isNotEmpty) ...[
            Text(view.title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
          ],
          if (view.sub.isNotEmpty) ...[
            Text(view.sub, style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
          ],
          Center(
            child: UpiQrImage(view: view, size: size),
          ),
          SizedBox(height: Ds.space.x12),
          for (final r in view.rows) ...[
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(_s(r['label']), style: Ds.t.caption)),
                  SizedBox(width: Ds.space.x12),
                  Flexible(
                    child: Text(
                      _s(r['value']),
                      textAlign: TextAlign.right,
                      style: r['strong'] == true
                          ? Ds.t.bodyStrong
                          : Ds.t.bodySecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// No confirmed VPA. The words are the backend's; the button is the only thing
/// this widget contributes.
class _NoVpa extends StatelessWidget {
  final UpiQrView view;
  final VoidCallback? onSetup;
  const _NoVpa({required this.view, this.onSetup});

  @override
  Widget build(BuildContext context) {
    if (view.title.isEmpty && view.hint.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(view.title, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          Text(view.hint, style: Ds.t.bodySecondary),
          if (onSetup != null && view.cta.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton(onPressed: onSetup, child: Text(view.cta)),
            ),
          ],
        ],
      ),
    );
  }
}

/// The whole UPI panel for ONE bill: the QR, the honesty prompt, and the single
/// tap that records a human's word for it.
class PosUpiPanel extends StatefulWidget {
  /// `pos_sale_detail(...)['upi']`.
  final Map<String, dynamic> upi;

  /// Calls `pos_payment_confirm` and returns its payload.
  final Future<Map<String, dynamic>> Function() onConfirm;
  final VoidCallback? onSetup;

  const PosUpiPanel({
    super.key,
    required this.upi,
    required this.onConfirm,
    this.onSetup,
  });

  @override
  State<PosUpiPanel> createState() => _PosUpiPanelState();
}

class _PosUpiPanelState extends State<PosUpiPanel> {
  late Map<String, dynamic> _upi = widget.upi;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant PosUpiPanel old) {
    super.didUpdateWidget(old);
    if (old.upi != widget.upi) _upi = widget.upi;
  }

  Future<void> _confirm() async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = await widget.onConfirm();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      // The confirmed state — and the sentence naming who marked it — comes
      // back from the server. Nothing is assumed here.
      if (res['ok'] == true && res['upi'] is Map) {
        _upi = _m(res['upi']);
      }
    });
    final msg = _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_upi['show'] != true) return const SizedBox.shrink();
    final view = UpiQrView.fromPayload(_upi['qr']);
    final confirmed = _upi['is_confirmed'] == true;
    final tone = _s(_upi['tone']);
    final statusLabel = confirmed
        ? _s(_upi['confirmed_label'])
        : _s(_upi['pending_label']);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UpiQrCard(view: view, onSetup: widget.onSetup),
        if (statusLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12,
              vertical: Ds.space.x8,
            ),
            decoration: BoxDecoration(
              color: _toneSoft(tone),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              statusLabel,
              style: Ds.t.caption.copyWith(color: _tone(tone)),
            ),
          ),
        ],
        if (view.canDraw && !confirmed && _upi['can_confirm'] == true) ...[
          SizedBox(height: Ds.space.x12),
          Text(_s(_upi['ask_patient']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: _busy ? null : _confirm,
              child: Text(
                _busy ? _s(_upi['confirm_busy']) : _s(_upi['confirm_label']),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// The setup card — the ONE place the shop's VPA is entered, wherever it is
/// shown from. Editing is the OWNER's alone: `can_edit` is the backend's answer
/// and this widget only obeys it (the RPC refuses a staff login regardless).
class PharmacyUpiSetupCard extends StatefulWidget {
  /// `pharmacy_upi_get()` — {setup, shop_qr, history}.
  final Map<String, dynamic> data;

  /// `pharmacy_upi_save(p_vpa, p_name)`.
  final Future<Map<String, dynamic>> Function(String vpa, String name) onSave;

  /// `pharmacy_upi_confirm(p_vpa)`.
  final Future<Map<String, dynamic>> Function(String vpa) onConfirm;

  const PharmacyUpiSetupCard({
    super.key,
    required this.data,
    required this.onSave,
    required this.onConfirm,
  });

  @override
  State<PharmacyUpiSetupCard> createState() => _PharmacyUpiSetupCardState();
}

class _PharmacyUpiSetupCardState extends State<PharmacyUpiSetupCard> {
  final _vpa = TextEditingController();
  final _name = TextEditingController();
  late Map<String, dynamic> _data = widget.data;
  bool _busy = false;
  String _prompt = '';

  Map<String, dynamic> get _setup => _m(_data['setup']);

  @override
  void initState() {
    super.initState();
    _vpa.text = _s(_setup['vpa']);
    _name.text = _s(_setup['name']);
  }

  /// A parent that reloads `pharmacy_upi_get()` must be believed. The guard
  /// matters: without it, a routine parent rebuild would throw away the setup
  /// block a save had just returned and put the stale one back on screen.
  @override
  void didUpdateWidget(covariant PharmacyUpiSetupCard old) {
    super.didUpdateWidget(old);
    if (old.data != widget.data) {
      _data = widget.data;
      final vpa = _s(_setup['vpa']);
      if (vpa.isNotEmpty && vpa != _vpa.text) _vpa.text = vpa;
    }
  }

  @override
  void dispose() {
    _vpa.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(Future<Map<String, dynamic>> Function() call) async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic> res;
    try {
      res = await call();
    } catch (_) {
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['setup'] is Map) _data = {..._data, 'setup': _m(res['setup'])};
      if (res['shop_qr'] is Map) {
        _data = {..._data, 'shop_qr': _m(res['shop_qr'])};
      }
      _prompt = _s(res['confirm_prompt']);
    });
    final msg = _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _setup;
    final canEdit = s['can_edit'] == true;
    final history = _rows(_data['history']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: _card(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(_s(s['title']), style: Ds.t.subtitle)),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8,
                      vertical: Ds.space.x4,
                    ),
                    decoration: BoxDecoration(
                      color: _toneSoft(_s(s['state_tone'])),
                      borderRadius: Ds.r.rChip,
                    ),
                    child: Text(
                      _s(s['state_label']),
                      style: Ds.t.caption.copyWith(
                        color: _tone(_s(s['state_tone'])),
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: Ds.space.x8),
              Text(_s(s['hint']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: _vpa,
                enabled: canEdit && !_busy,
                style: Ds.t.body,
                decoration: InputDecoration(
                  labelText: _s(s['vpa_label']),
                  labelStyle: Ds.t.caption,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: _name,
                enabled: canEdit && !_busy,
                style: Ds.t.body,
                decoration: InputDecoration(
                  labelText: _s(s['name_label']),
                  labelStyle: Ds.t.caption,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              if (!canEdit && _s(s['locked_hint']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Text(_s(s['locked_hint']), style: Ds.t.caption),
              ],
              if (canEdit) ...[
                SizedBox(height: Ds.space.x16),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            () => widget.onSave(
                              _vpa.text.trim(),
                              _name.text.trim(),
                            ),
                          ),
                    child: Text(_s(s['save_label'])),
                  ),
                ),
                if (_prompt.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x12),
                  Text(_prompt, style: Ds.t.caption),
                ],
                if (s['has_vpa'] == true && s['confirmed'] != true) ...[
                  SizedBox(height: Ds.space.x12),
                  SizedBox(
                    width: double.infinity,
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () =>
                                _run(() => widget.onConfirm(_vpa.text.trim())),
                      child: Text(_s(s['confirm_label'])),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        SizedBox(height: Ds.space.x24),
        UpiQrCard(view: UpiQrView.fromPayload(_data['shop_qr'])),
        SizedBox(height: Ds.space.x24),
        Text(_s(s['history_title']), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        if (history.isEmpty)
          Text(_s(s['history_empty']), style: Ds.t.caption)
        else
          Container(
            decoration: _card(),
            child: Column(
              children: [
                for (var i = 0; i < history.length; i++)
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.all(Ds.space.x12),
                    decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : Border(top: BorderSide(color: Ds.c.divider)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s(history[i]['label']), style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text(
                          '${_s(history[i]['who'])} · ${_s(history[i]['at'])}',
                          style: Ds.t.caption,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
