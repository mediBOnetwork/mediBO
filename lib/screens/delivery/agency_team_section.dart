// lib/screens/delivery/agency_team_section.dart — CHANGE #630 (PART D)
//
// The agency's roster and its own unhanded stops. Replaces the add-a-rider form
// that #629 shipped as _MyRidersSection: that could only ADD, and an agency's
// real job is to see who is free and pass work to them.
//
// D1 — this widget is only ever mounted when my_delivery_home() says
// is_agency. It is not self-gating on a role, and it does not test partner_type
// itself; the parent renders it or does not. agency_team() independently
// refuses a non-agency caller (allowed:false), so the two agree by construction
// rather than by coincidence.
//
// D3 — at_capacity comes from the backend (max_stops vs pending). A rider at
// capacity is shown as unavailable and cannot be chosen in the hand-over sheet.
// This file does NOT compare pending to capacity — that comparison already
// happened in SQL, and doing it twice is how the two answers start to differ.
//
// D4 — handing a stop to a rider is delivery_reassign(), the SAME RPC the admin
// uses. There is no agency-specific write path, so an agency cannot acquire
// powers the admin screen does not have.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import 'delivery_id_scan.dart'; // C631: PART A — scan Aadhaar / driving licence

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

class AgencyTeamSection extends StatefulWidget {
  /// Refetch the rider screen — handing a stop away changes the map and stops.
  final Future<void> Function() onChanged;

  /// The agency's own riders, lifted so the parent can plot them (D6).
  final void Function(List<Map<String, dynamic>> riders)? onRiders;

  const AgencyTeamSection({super.key, required this.onChanged, this.onRiders});

  @override
  State<AgencyTeamSection> createState() => AgencyTeamSectionState();
}

class AgencyTeamSectionState extends State<AgencyTeamSection> {
  bool _loading = true;
  bool _allowed = true;
  String _title = '';
  String _note = '';
  List<Map<String, dynamic>> _riders = const [];
  List<Map<String, dynamic>> _myStops = const [];

  bool _addOpen = false;
  bool _busy = false;
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _vehicleCtrl = TextEditingController();

  // CHANGE #631 (PART A1b) — the fields an Aadhaar / driving-licence scan can
  // fill. They are ordinary controllers, typeable whether or not a scan ran.
  final _idTypeCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();

  /// A5/A6 — carried from the scan to agency_add_partner, never rendered.
  Map<String, dynamic> _ocrPayload = const {};
  String _idDocPath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _vehicleCtrl.dispose();
    _idTypeCtrl.dispose();
    _idNumberCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    super.dispose();
  }

  /// A3 — the scan FILLS the form and nothing more. No field is disabled here
  /// or anywhere below, so a misread value can always be corrected.
  void _applyScan(IdScanResult r) {
    void put(TextEditingController c, String key) {
      final v = r.prefill[key]?.toString() ?? '';
      // An empty read must not wipe something already typed.
      if (v.trim().isNotEmpty) c.text = v;
    }

    // The edge function's `prefill` keys already ARE these field names — a
    // straight assignment, no mapping and no renaming.
    put(_nameCtrl, 'full_name');
    put(_idTypeCtrl, 'id_doc_type');
    put(_idNumberCtrl, 'id_doc_number');
    put(_addressCtrl, 'address');
    put(_cityCtrl, 'city');
    put(_stateCtrl, 'state');

    setState(() {
      _ocrPayload = r.ocrPayload;
      _idDocPath = r.idDocPath;
    });
    RenderLog.write('c631_delivery_onboarding', 'agency_prefill;doc=${r.docType}');
  }

  Future<void> reload() => _load();

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('agency_team');
      if (!mounted) return;
      if (res is! Map) {
        setState(() => _loading = false);
        return;
      }
      final m = Map<String, dynamic>.from(res);
      final riders = _list(m['riders']);
      setState(() {
        _allowed = m['allowed'] != false;
        _title = m['title']?.toString() ?? '';
        _note = m['note']?.toString() ?? '';
        _riders = riders;
        _myStops = _list(m['my_stops']);
        _loading = false;
      });
      // D6 — the parent plots these on the SAME map, no second map widget.
      widget.onRiders?.call(riders);
      RenderLog.write('c630_agency_team',
          'allowed=$_allowed;riders=${riders.length};my_stops=${_myStops.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c630_agency_team_err', e.toString());
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── D5: add a rider ───────────────────────────────────────────────────────

  Future<void> _addRider() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // agency_add_partner takes ONE jsonb. zone_id is omitted deliberately:
      // the RPC inherits the agency's own zone when it is absent, which is the
      // only correct answer — a rider must not land in a zone the agency does
      // not work, and this form has no business choosing one.
      final res = await Supabase.instance.client.rpc('agency_add_partner', params: {
        'p': {
          'full_name': _nameCtrl.text.trim(),
          'phone': _phoneCtrl.text.trim(),
          'vehicle_type': _vehicleCtrl.text.trim(),
          'id_doc_type': _idTypeCtrl.text.trim(),
          'id_doc_number': _idNumberCtrl.text.trim(),
          'address': _addressCtrl.text.trim(),
          'city': _cityCtrl.text.trim(),
          'state': _stateCtrl.text.trim(),
          // A5/A6 — the whole scan payload and the stored image, verbatim, so
          // an admin can compare the card against the typed values later.
          'id_doc_path': _idDocPath,
          'ocr_payload': _ocrPayload,
        },
      });
      if (!mounted) return;
      final msg = res is Map ? (res['message']?.toString() ?? '') : '';
      RenderLog.write('c631_delivery_onboarding',
          'agency_add;ok=${res is Map && res['ok'] == true};'
          'ocr=${_ocrPayload.isNotEmpty};doc_path=${_idDocPath.isNotEmpty}');
      if (res is Map && res['ok'] == true) {
        _nameCtrl.clear();
        _phoneCtrl.clear();
        _vehicleCtrl.clear();
        _idTypeCtrl.clear();
        _idNumberCtrl.clear();
        _addressCtrl.clear();
        _cityCtrl.clear();
        _stateCtrl.clear();
        _ocrPayload = const {};
        _idDocPath = '';
        setState(() => _addOpen = false);
        await _load();
        await widget.onChanged();
      }
      // name_required and every other refusal print exactly as sent.
      _toast(msg);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// A3 — every add-rider field is a plain, always-enabled TextField. There is
  /// no `enabled:` and no `readOnly:` to flip, so a scanned value stays
  /// correctable.
  Widget _addField(
    TextEditingController c,
    String labelKey, {
    TextInputType? keyboard,
    int lines = 1,
  }) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      maxLines: lines,
      decoration: InputDecoration(
        labelText: _ui(labelKey),
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }

  // ── D4: hand a stop to a rider ────────────────────────────────────────────

  Future<void> _giveToRider(Map<String, dynamic> stop) async {
    // Only riders the backend did NOT mark at_capacity can receive work.
    final available = _riders.where((r) => r['at_capacity'] != true).toList();

    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Text(_ui('dlv_give_to_rider'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 2),
          Text(stop['pharmacy_name']?.toString() ?? '',
              style: TextStyle(fontSize: 12.5, color: _kSub)),
          const SizedBox(height: 14),
          if (available.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Text(_ui('dlv_no_riders'),
                  style: TextStyle(fontSize: 13, color: _kSub)),
            )
          else
            for (final r in available)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListTile(
                  dense: true,
                  onTap: () =>
                      Navigator.of(ctx).pop(r['partner_id']?.toString() ?? ''),
                  title: Text(r['name']?.toString() ?? '',
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: _kText)),
                  subtitle: Text(r['status_label']?.toString() ?? '',
                      style: TextStyle(fontSize: 11.5, color: _kSub)),
                  trailing: Text('${(r['pending'] as num?)?.toInt() ?? 0}',
                      style: TextStyle(fontSize: 12, color: _kSub)),
                ),
              ),
        ],
      ),
    );
    if (picked == null || picked.isEmpty) return;

    try {
      final res = await Supabase.instance.client.rpc('delivery_reassign', params: {
        'p_delivery_id': stop['delivery_id']?.toString() ?? '',
        'p_partner_id': picked,
      });
      if (!mounted) return;
      RenderLog.write('c630_agency_handover', '1');
      await _load();
      await widget.onChanged();
      if (res is Map) _toast(res['message']?.toString() ?? '');
    } catch (_) {}
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_title.isNotEmpty ? _title : _ui('dlv_my_riders'),
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w800, color: _kText)),
              if (_note.isNotEmpty)
                Text(_note, style: TextStyle(fontSize: 11.5, color: _kSub)),
            ]),
          ),
          TextButton(
            onPressed: () => setState(() => _addOpen = !_addOpen),
            child: Text(_addOpen ? _ui('dlv_cancel') : _ui('dlv_add_rider')),
          ),
        ]),

        if (_addOpen) ...[
          const SizedBox(height: 8),
          // A1(b) — the SAME scan control the public registration form uses.
          DeliveryIdScanCard(onScanned: _applyScan),
          const SizedBox(height: 10),
          _addField(_nameCtrl, 'dlv_rider_name'),
          const SizedBox(height: 8),
          _addField(_phoneCtrl, 'dlv_rider_phone', keyboard: TextInputType.phone),
          const SizedBox(height: 8),
          _addField(_vehicleCtrl, 'dlv_rider_vehicle'),
          const SizedBox(height: 8),
          _addField(_idTypeCtrl, 'dlv_reg_id_type'),
          const SizedBox(height: 8),
          _addField(_idNumberCtrl, 'dlv_reg_id_number'),
          const SizedBox(height: 8),
          _addField(_addressCtrl, 'dlv_reg_address', lines: 2),
          const SizedBox(height: 8),
          _addField(_cityCtrl, 'dlv_reg_city'),
          const SizedBox(height: 8),
          _addField(_stateCtrl, 'dlv_reg_state'),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : _addRider,
            child: Text(_ui('dlv_rider_save')),
          ),
        ],

        const SizedBox(height: 12),
        if (_riders.isEmpty)
          Text(_ui('dlv_no_riders'), style: TextStyle(fontSize: 12.5, color: _kSub))
        else
          for (final r in _riders) _riderRow(r),

        // D4 — the agency's own stops, each handed on with one tap.
        if (_myStops.isNotEmpty) ...[
          const SizedBox(height: 14),
          Divider(height: 1, color: _kBorder),
          const SizedBox(height: 10),
          Text(_ui('dlv_my_stops'),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: _kText)),
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
    final atCapacity = r['at_capacity'] == true;
    final onShift = r['on_shift'] == true;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r['name']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
          ),
          // D3 — "unavailable", straight from at_capacity.
          if (atCapacity)
            Container(
              margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFFBE9E7),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_ui('dlv_at_capacity'),
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFB42318))),
            ),
          if ((r['status_label']?.toString() ?? '').isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(r['status_label']!.toString(),
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: _hex(colors['fg']?.toString()) ?? _kText)),
            ),
        ]),
        const SizedBox(height: 3),
        Text(
          [
            r['phone']?.toString() ?? '',
            r['vehicle']?.toString() ?? '',
            if (onShift) _ui('dlv_on_shift'),
          ].where((x) => x.isNotEmpty).join(' · '),
          style: TextStyle(fontSize: 11.5, color: _kSub),
        ),
        const SizedBox(height: 5),
        Row(children: [
          _stat(_ui('dlv_tile_delivered'), r['delivered'], const Color(0xFF0F6E56)),
          const SizedBox(width: 10),
          _stat(_ui('dlv_tile_failed'), r['failed'], const Color(0xFFB42318)),
          const SizedBox(width: 10),
          _stat(_ui('dlv_open_stops'), r['pending'], _kSub),
        ]),
      ]),
    );
  }

  Widget _stat(String label, dynamic value, Color c) => Text(
        '$label ${(value as num?)?.toInt() ?? 0}',
        style: TextStyle(fontSize: 11.5, color: c),
      );

  Widget _stopRow(Map<String, dynamic> s) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s['pharmacy_name']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            Text(s['order_code']?.toString() ?? '',
                style: TextStyle(fontSize: 11.5, color: _kSub)),
          ]),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            side: BorderSide(color: _kBorder),
            foregroundColor: _kText,
          ),
          onPressed: () => _giveToRider(s),
          child: Text(_ui('dlv_give_to_rider'),
              style: const TextStyle(fontSize: 12)),
        ),
      ]),
    );
  }
}
