// lib/screens/delivery/delivery_register_screen.dart — CHANGE #631 (PART A)
//
// The delivery-partner registration form, reached at /delivery-register.
//
// A1(a) — it carries the "Scan Aadhaar / Driving licence" control at the top.
// A3    — every field the scan fills stays EDITABLE. There is no read-only flag
//         and no "locked because scanned" state anywhere below: the scan only
//         assigns text to controllers the user can still type into.
// A5/A6 — `ocr_payload` and `id_doc_path` ride along on submit, untouched.
//
// delivery_partner_register(p jsonb) stamps auth.uid() itself, so this screen
// needs a signed-in credential — it asks for one rather than inventing an
// anonymous path. That is the RPC's own contract, verified against the live
// function, not an assumption made here.
//
// NOTHING is validated in Dart. The RPC owns "what is required" and returns its
// own message; this form submits what was typed and prints the answer.
//
// CMD #453 (feature_gaps 96, 97): the screen is now the applicant's STATUS
// surface too. my_delivery_application() decides everything printed here — the
// verdict, its tone, the reviewer's reason, whether re-applying is offered —
// and the invite row below it lets a rider an agency created attach their own
// login (delivery_claim_invite), which is what made those rows unusable.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import 'delivery_id_scan.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));

String _ui(String k) => FulfillLookups.instance.ui(k);

class DeliveryRegisterScreen extends StatefulWidget {
  const DeliveryRegisterScreen({super.key});

  @override
  State<DeliveryRegisterScreen> createState() => _DeliveryRegisterScreenState();
}

class _DeliveryRegisterScreenState extends State<DeliveryRegisterScreen> {
  // One controller per field the payload carries. The scan writes into these;
  // so does the keyboard. Nothing distinguishes the two afterwards — which is
  // exactly the point of A3.
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _vehicle = TextEditingController();
  final _zone = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _pincode = TextEditingController();
  final _idType = TextEditingController();
  final _idNumber = TextEditingController();

  /// A5/A6 — carried from the scan to the submit, never rendered as a field.
  Map<String, dynamic> _ocrPayload = const {};
  String _idDocPath = '';

  bool _busy = false;
  bool _done = false;
  String _message = '';

  /// my_delivery_application() verbatim. Empty until it answers; `_appLoading`
  /// keeps the form from flashing before the verdict arrives.
  Map<String, dynamic> _app = const {};
  bool _appLoading = true;
  /// Set only when the applicant taps "apply again" on a rejected application.
  bool _reapply = false;

  final _invite = TextEditingController();
  bool _inviteBusy = false;
  String _inviteMessage = '';

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    FulfillLookups.instance.addListener(_onLookups);
    RenderLog.write('c631_delivery_onboarding', 'register_open');
    _loadApplication();
  }

  /// The one RPC this screen reads. It answers for a signed-out caller too, so
  /// there is no branch here that decides what a visitor may see.
  Future<void> _loadApplication() async {
    try {
      final res = await Supabase.instance.client.rpc('my_delivery_application');
      if (!mounted) return;
      setState(() {
        _app = res is Map ? Map<String, dynamic>.from(res) : const {};
        _appLoading = false;
      });
      RenderLog.write('c453_delivery_application',
          'has=${_app['has'] == true};status=${_app['status'] ?? ''}');
    } catch (_) {
      if (!mounted) return;
      setState(() => _appLoading = false);
    }
  }

  Future<void> _claimInvite() async {
    if (_inviteBusy) return;
    setState(() {
      _inviteBusy = true;
      _inviteMessage = '';
    });
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_claim_invite', params: {'p_code': _invite.text.trim()});
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() => _inviteMessage = m['message']?.toString() ?? '');
      RenderLog.write('c453_delivery_invite', 'claim;ok=${m['ok'] == true}');
      if (m['ok'] == true) await _loadApplication();
    } catch (e) {
      if (!mounted) return;
      setState(() => _inviteMessage = e.toString());
    } finally {
      if (mounted) setState(() => _inviteBusy = false);
    }
  }

  void _onLookups() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FulfillLookups.instance.removeListener(_onLookups);
    for (final c in [
      _name, _phone, _email, _vehicle, _zone,
      _address, _city, _state, _pincode, _idType, _idNumber, _invite,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── A3: the scan fills the form, and that is all it does ──────────────────

  void _applyScan(IdScanResult r) {
    // The edge function's `prefill` keys already ARE these field names, so this
    // is a straight assignment — no mapping, no renaming, no invention.
    var filled = 0;
    void put(TextEditingController c, String key) {
      final v = r.prefill[key]?.toString() ?? '';
      // An empty read must not wipe something already typed.
      if (v.trim().isNotEmpty) {
        c.text = v;
        filled++;
      }
    }

    put(_name, 'full_name');
    put(_idType, 'id_doc_type');
    put(_idNumber, 'id_doc_number');
    put(_address, 'address');
    put(_city, 'city');
    put(_state, 'state');
    put(_pincode, 'pincode');

    setState(() {
      _ocrPayload = r.ocrPayload;
      _idDocPath = r.idDocPath;
    });
    RenderLog.write('c631_delivery_onboarding',
        'register_prefill;fields=$filled;doc=${r.docType}');
  }

  // ── submit ────────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'delivery_partner_register',
        params: {
          'p': {
            'full_name': _name.text.trim(),
            'phone': _phone.text.trim(),
            'email': _email.text.trim(),
            'vehicle_type': _vehicle.text.trim(),
            'delivery_zone': _zone.text.trim(),
            'address': _address.text.trim(),
            'city': _city.text.trim(),
            'state': _state.text.trim(),
            'pincode': _pincode.text.trim(),
            'id_doc_type': _idType.text.trim(),
            'id_doc_number': _idNumber.text.trim(),
            // A5/A6 — through, verbatim.
            'id_doc_path': _idDocPath,
            'ocr_payload': _ocrPayload,
          },
        },
      );
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _message = m['message']?.toString() ?? '';
        _done = m['ok'] == true;
      });
      RenderLog.write('c631_delivery_onboarding',
          'register_submit;ok=${m['ok'] == true};ocr=${_ocrPayload.isNotEmpty};'
          'doc_path=${_idDocPath.isNotEmpty}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = e.toString());
      RenderLog.write('c631_delivery_onboarding', 'register_err');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final signedIn = Supabase.instance.client.auth.currentSession != null;
    // The backend decides whether there is an application to show and whether
    // the form should be offered at all; this widget only asks and renders.
    final hasApplication = _app['has'] == true;
    final showForm = !hasApplication || (_app['can_register'] == true && _reapply);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0.5,
        title: Text(_ui('dlv_reg_title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (!signedIn)
                _notice(_ui('dlv_reg_signin'))
              else if (_appLoading)
                _skeleton()
              else if (_done) ...[
                _notice(_message),
              ] else ...[
                if (hasApplication) ...[
                  _statusCard(),
                  SizedBox(height: Ds.space.x24),
                ],
                if (!hasApplication) ...[
                  _inviteCard(),
                  SizedBox(height: Ds.space.x24),
                ],
              ],
              if (signedIn && !_appLoading && !_done && showForm) ...[
                Text(_ui('dlv_reg_note'),
                    style: TextStyle(fontSize: 13, color: _kSub)),
                const SizedBox(height: 16),

                // A1(a) — the scan control, above the fields it fills.
                DeliveryIdScanCard(onScanned: _applyScan),

                const SizedBox(height: 16),
                _field(_name, 'dlv_rider_name'),
                _field(_phone, 'dlv_rider_phone', keyboard: TextInputType.phone),
                _field(_email, 'dlv_reg_email', keyboard: TextInputType.emailAddress),
                _field(_vehicle, 'dlv_rider_vehicle'),
                _field(_zone, 'dlv_reg_zone'),
                _field(_idType, 'dlv_reg_id_type'),
                _field(_idNumber, 'dlv_reg_id_number'),
                _field(_address, 'dlv_reg_address', lines: 2),
                _field(_city, 'dlv_reg_city'),
                _field(_state, 'dlv_reg_state'),
                _field(_pincode, 'dlv_reg_pincode', keyboard: TextInputType.number),

                if (_message.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  _notice(_message),
                ],

                const SizedBox(height: 16),
                SizedBox(
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_ui('dlv_reg_submit'),
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The verdict card. Every string, and the tone that colours it, is
  /// my_delivery_application()'s — this file maps a NAMED tone to a token and
  /// prints the rest.
  Widget _statusCard() {
    final tone = _app['status_tone']?.toString() ?? '';
    final Color accent = tone == 'success'
        ? Ds.c.success
        : tone == 'danger'
            ? Ds.c.danger
            : Ds.c.warning;
    final Color soft = tone == 'success'
        ? Ds.c.successSoft
        : tone == 'danger'
            ? Ds.c.dangerSoft
            : Ds.c.warningSoft;

    String v(String k) => _app[k]?.toString() ?? '';

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(v('title'), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x12),
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x4),
          decoration: BoxDecoration(color: soft, borderRadius: Ds.r.rChip),
          child: Text(v('status_label'),
              style: Ds.t.caption.copyWith(color: accent)),
        ),
        SizedBox(height: Ds.space.x12),
        Text(v('status_message'), style: Ds.t.body),
        if (v('name').isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(v('name'), style: Ds.t.bodyStrong),
        ],
        if (v('submitted_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(v('submitted_label'), style: Ds.t.caption),
        ],
        if (v('reviewed_label').isNotEmpty)
          Text(v('reviewed_label'), style: Ds.t.caption),
        if (_app['can_register'] == true && !_reapply) ...[
          SizedBox(height: Ds.space.x16),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: () => setState(() => _reapply = true),
              child: Text(v('reapply_cta')),
            ),
          ),
        ],
      ]),
    );
  }

  /// The invite row. An agency-created rider has a row in the register but no
  /// login attached to it; this is how they attach their own.
  Widget _inviteCard() {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_app['invite_prompt']?.toString() ?? '', style: Ds.t.body),
        SizedBox(height: Ds.space.x12),
        Row(children: [
          Expanded(child: _field(_invite, 'dlv_invite_code')),
          SizedBox(width: Ds.space.x8),
          SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: _inviteBusy ? null : _claimInvite,
              child: Text(_ui('dlv_invite_submit')),
            ),
          ),
        ]),
        if (_inviteMessage.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_inviteMessage, style: Ds.t.caption),
        ],
      ]),
    );
  }

  /// A skeleton, not a bare spinner — the verdict is one RPC away.
  Widget _skeleton() => Container(
        height: Ds.touch.minTarget * 3,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
      );

  /// Every field is a plain, always-enabled TextField. A3 lives here: there is
  /// no `enabled:` and no `readOnly:` to flip, so a scanned value can always be
  /// corrected.
  Widget _field(
    TextEditingController c,
    String labelKey, {
    TextInputType? keyboard,
    int lines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        maxLines: lines,
        style: TextStyle(fontSize: 15, color: _kText),
        decoration: InputDecoration(
          labelText: _ui(labelKey),
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _kBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _kBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: _kGreen),
          ),
        ),
      ),
    );
  }

  Widget _notice(String text) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: TextStyle(fontSize: 14, color: _kText)),
      );
}
