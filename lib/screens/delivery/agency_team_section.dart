// lib/screens/delivery/agency_team_section.dart — CHANGE #630 (PART E)
//
// "My riders" — the agency's roster, its own unassigned stops, and the Add
// rider form (which is the PART A scan flow again, not a second copy of it).
//
// E1 — this widget is only ever built when my_delivery_home() returns
// is_agency:true. It does not test a role, a partner_type string, or anything
// else: DeliveryHomeScreen reads the boolean and decides whether to construct
// it at all.
//
// E2 — ONE read: agency_team(p_date). title, note, status_label, status_colors
// and every count arrive finished.
//
// E3 — `at_capacity` is the backend's boolean. A full rider is shown as
// unavailable and cannot be picked in the hand-over sheet; the app never
// compares pending against capacity itself.
//
// E4 — "Give to rider" is delivery_reassign(p_delivery_id, p_partner_id).
// E5 — "Add rider" is agency_add_partner(p jsonb) — ONE jsonb argument, which
//      is the live signature (verified), not a named-argument list.
//
// The rider's zone is NOT sent: agency_add_partner defaults it to the agency's
// own zone. Choosing one here would be this screen deciding where a rider
// works.

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

Color? _hex(String? h) {
  final s = (h ?? '').trim().replaceFirst('#', '');
  if (s.length != 6 && s.length != 8) return null;
  final v = int.tryParse(s.length == 6 ? 'FF$s' : s, radix: 16);
  return v == null ? null : Color(v);
}

List<Map<String, dynamic>> _list(dynamic v) => v is List
    ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
    : const [];

class AgencyTeamSection extends StatefulWidget {
  /// Refetch the parent (home tiles, stops, map) after a write.
  final Future<void> Function() onChanged;

  /// E6 — the parent plots these on its map. Emitted, not drawn here.
  final void Function(List<Map<String, dynamic>> riders)? onRiders;

  const AgencyTeamSection({super.key, required this.onChanged, this.onRiders});

  @override
  State<AgencyTeamSection> createState() => _AgencyTeamSectionState();
}

class _AgencyTeamSectionState extends State<AgencyTeamSection> {
  bool _loading = true;
  Map<String, dynamic> _payload = const {};
  bool _addOpen = false;

  List<Map<String, dynamic>> get _riders => _list(_payload['riders']);
  List<Map<String, dynamic>> get _myStops => _list(_payload['my_stops']);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('agency_team');
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _payload = m;
        _loading = false;
      });
      RenderLog.write('c630_delivery_onboarding',
          'agency_team;riders=${m['rider_count'] ?? 0};stops=${m['my_stop_count'] ?? 0}');
      // E6 — hand the positions up; the map is the parent's.
      widget.onRiders?.call(_riders);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── E4: hand a stop to a rider ────────────────────────────────────────────

  Future<void> _give(Map<String, dynamic> stop) async {
    final partnerId = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _RiderPickSheet(riders: _riders),
    );
    if (partnerId == null || partnerId.isEmpty) return;
    try {
      final res = await Supabase.instance.client.rpc('delivery_reassign', params: {
        'p_delivery_id': stop['delivery_id']?.toString() ?? '',
        'p_partner_id': partnerId,
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      _toast(m['message']?.toString() ?? '');
      RenderLog.write('c630_delivery_onboarding', 'reassign;ok=${m['ok'] == true}');
      if (m['ok'] == true) {
        await _load();
        await widget.onChanged();
      }
    } catch (_) {}
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_payload['title']?.toString() ?? '',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
              if ((_payload['note']?.toString() ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(_payload['note']!.toString(),
                    style: TextStyle(fontSize: 12.5, color: _kSub)),
              ],
            ]),
          ),
          TextButton(
            onPressed: () => setState(() => _addOpen = !_addOpen),
            child: Text(_addOpen ? _ui('dlv_cancel') : _ui('dlv_add_rider')),
          ),
        ]),

        // E5 — the PART A scan flow, then agency_add_partner.
        if (_addOpen) ...[
          const SizedBox(height: 12),
          _AddRiderForm(
            onAdded: () async {
              setState(() => _addOpen = false);
              await _load();
              await widget.onChanged();
            },
            onMessage: _toast,
          ),
        ],

        // E3 — the roster.
        const SizedBox(height: 16),
        if (_riders.isEmpty)
          Text(_ui('dlv_no_riders'), style: TextStyle(fontSize: 13, color: _kSub))
        else
          for (final r in _riders) _riderRow(r),

        // E4 — stops the agency still holds.
        if (_myStops.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(_ui('dlv_my_stops'),
              style:
                  TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
          const SizedBox(height: 8),
          for (final s in _myStops) _stopRow(s),
        ],
      ]),
    );
  }

  Widget _riderRow(Map<String, dynamic> r) {
    final colors = r['status_colors'] is Map
        ? Map<String, dynamic>.from(r['status_colors'] as Map)
        : const <String, dynamic>{};
    final statusLabel = r['status_label']?.toString() ?? '';
    final atCapacity = r['at_capacity'] == true;
    final sub = [
      r['phone']?.toString() ?? '',
      r['vehicle']?.toString() ?? '',
    ].where((x) => x.isNotEmpty).join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r['name']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
            if (sub.isNotEmpty)
              Text(sub, style: TextStyle(fontSize: 12.5, color: _kSub)),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              if (statusLabel.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                          color: _hex(colors['fg']?.toString()) ?? _kText)),
                ),
              if (r['on_shift'] == true)
                Text(_ui('dlv_on_shift'),
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w500, color: _kGreen)),
              // E3 — the backend's own "full" flag, printed as a state.
              if (atCapacity)
                Text(_ui('dlv_at_capacity'),
                    style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: _kSub)),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${(r['delivered'] as num?)?.toInt() ?? 0} / '
              '${(r['pending'] as num?)?.toInt() ?? 0}',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: _kText)),
          Text('${(r['failed'] as num?)?.toInt() ?? 0}',
              style: TextStyle(fontSize: 12, color: _kSub)),
        ]),
      ]),
    );
  }

  Widget _stopRow(Map<String, dynamic> s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['pharmacy_name']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
            if ((s['address']?.toString() ?? '').isNotEmpty)
              Text(s['address']!.toString(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
          ]),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: _kGreen,
            side: BorderSide(color: _kGreen),
            visualDensity: VisualDensity.compact,
          ),
          onPressed: () => _give(s),
          child: Text(_ui('dlv_give_to_rider'), style: const TextStyle(fontSize: 12.5)),
        ),
      ]),
    );
  }
}

// ── E4: who gets the stop ─────────────────────────────────────────────────────

class _RiderPickSheet extends StatelessWidget {
  final List<Map<String, dynamic>> riders;
  const _RiderPickSheet({required this.riders});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF5F6F8),
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 40, height: 4,
          decoration:
              BoxDecoration(color: _kBorder, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(_ui('dlv_pick_rider'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
        ),
        const SizedBox(height: 12),
        if (riders.isEmpty)
          Text(_ui('dlv_no_riders'), style: TextStyle(fontSize: 13, color: _kSub))
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final r in riders)
                  ListTile(
                    // E3 — a full rider is unavailable. The flag is the
                    // backend's; this only renders it.
                    enabled: r['at_capacity'] != true,
                    title: Text(r['name']?.toString() ?? '',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
                    subtitle: Text(
                      [
                        r['status_label']?.toString() ?? '',
                        if (r['at_capacity'] == true) _ui('dlv_at_capacity'),
                      ].where((x) => x.isNotEmpty).join(' · '),
                      style: TextStyle(fontSize: 12.5, color: _kSub),
                    ),
                    onTap: () =>
                        Navigator.of(context).pop(r['partner_id']?.toString() ?? ''),
                  ),
              ],
            ),
          ),
      ]),
    );
  }
}

// ── E5: add a rider, with the PART A scan ─────────────────────────────────────

class _AddRiderForm extends StatefulWidget {
  final Future<void> Function() onAdded;
  final void Function(String) onMessage;

  const _AddRiderForm({required this.onAdded, required this.onMessage});

  @override
  State<_AddRiderForm> createState() => _AddRiderFormState();
}

class _AddRiderFormState extends State<_AddRiderForm> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _vehicle = TextEditingController();
  final _address = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _idType = TextEditingController();
  final _idNumber = TextEditingController();

  Map<String, dynamic> _ocrPayload = const {};
  String _idDocPath = '';
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [
      _name, _phone, _email, _vehicle,
      _address, _city, _state, _idType, _idNumber,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// A3 — same rule as the registration form: fill, never lock.
  void _applyScan(IdScanResult r) {
    void put(TextEditingController c, String key) {
      final v = r.prefill[key]?.toString() ?? '';
      if (v.trim().isNotEmpty) c.text = v;
    }

    put(_name, 'full_name');
    put(_idType, 'id_doc_type');
    put(_idNumber, 'id_doc_number');
    put(_address, 'address');
    put(_city, 'city');
    put(_state, 'state');

    setState(() {
      _ocrPayload = r.ocrPayload;
      _idDocPath = r.idDocPath;
    });
    RenderLog.write('c630_delivery_onboarding', 'agency_prefill;doc=${r.docType}');
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('agency_add_partner', params: {
        'p': {
          'full_name': _name.text.trim(),
          'phone': _phone.text.trim(),
          'email': _email.text.trim(),
          'vehicle_type': _vehicle.text.trim(),
          'address': _address.text.trim(),
          'city': _city.text.trim(),
          'state': _state.text.trim(),
          'id_doc_type': _idType.text.trim(),
          'id_doc_number': _idNumber.text.trim(),
          // A5/A6 — through, verbatim.
          'id_doc_path': _idDocPath,
          'ocr_payload': _ocrPayload,
        },
      });
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      // name_required / not_an_agency each carry their own message.
      widget.onMessage(m['message']?.toString() ?? '');
      RenderLog.write('c630_delivery_onboarding',
          'agency_add;ok=${m['ok'] == true};ocr=${_ocrPayload.isNotEmpty};'
          'doc_path=${_idDocPath.isNotEmpty}');
      if (m['ok'] == true) await widget.onAdded();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // A1(b) — the same scan control the public form uses.
      DeliveryIdScanCard(onScanned: _applyScan),
      const SizedBox(height: 12),
      _field(_name, 'dlv_rider_name'),
      _field(_phone, 'dlv_rider_phone', keyboard: TextInputType.phone),
      _field(_email, 'dlv_reg_email', keyboard: TextInputType.emailAddress),
      _field(_vehicle, 'dlv_rider_vehicle'),
      _field(_idType, 'dlv_reg_id_type'),
      _field(_idNumber, 'dlv_reg_id_number'),
      _field(_address, 'dlv_reg_address', lines: 2),
      _field(_city, 'dlv_reg_city'),
      _field(_state, 'dlv_reg_state'),
      const SizedBox(height: 4),
      SizedBox(
        height: 46,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _kGreen,
            foregroundColor: Colors.white,
          ),
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Text(_ui('dlv_rider_save'),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        ),
      ),
    ]);
  }

  Widget _field(
    TextEditingController c,
    String labelKey, {
    TextInputType? keyboard,
    int lines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        keyboardType: keyboard,
        maxLines: lines,
        style: TextStyle(fontSize: 14.5, color: _kText),
        decoration: InputDecoration(
          labelText: _ui(labelKey),
          filled: true,
          fillColor: const Color(0xFFF5F6F8),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
}
