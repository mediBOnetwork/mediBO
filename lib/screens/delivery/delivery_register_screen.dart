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

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    FulfillLookups.instance.addListener(_onLookups);
    RenderLog.write('c631_delivery_onboarding', 'register_open');
  }

  void _onLookups() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    FulfillLookups.instance.removeListener(_onLookups);
    for (final c in [
      _name, _phone, _email, _vehicle, _zone,
      _address, _city, _state, _pincode, _idType, _idNumber,
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
              else if (_done) ...[
                _notice(_message),
              ] else ...[
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
