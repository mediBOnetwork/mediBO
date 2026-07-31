// lib/screens/admin/admin_delivery_partners_section.dart — CHANGE #630 (PART B)
//
// "Delivery partners" inside the admin Delivery tab: the registrations waiting
// for approval, and the partners already working.
//
// B1 — ONE read: admin_delivery_partners(p_zone). Nothing on this screen is
// counted, sorted, coloured or phrased here. pending_title, pending_note,
// zone_label, type_label, type_colors and every count arrive finished.
//
// B2 — a pending row shows what the partner typed AND what the scan read, with
// id_doc_path openable, so the admin compares the card against the values
// instead of trusting either.
//
// B3 — approve = admin_set_delivery_partner(). Its three refusals
// (zone_required, agency_cannot_nest, bad_type) each carry their own `message`
// and are printed VERBATIM. The form does not pre-empt them: it does not grey
// out "agency" for a nested partner and does not require a zone before
// enabling submit. The backend refuses, and its sentence is what the admin
// reads.
//
// B5 — an inactive partner gets no rider interface at all, so this section is
// the gate that turns a registration into a working account.
//
// The TYPE options come from type_options[] with their own `note` explaining
// the role. That note is rendered as sent — no wording is authored here.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_zone_scope.dart';
import '../../utils/render_log.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBad => FulfillLookups.instance.color('c_ffb42318', const Color(0xFFB42318));

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

class AdminDeliveryPartnersSection extends StatefulWidget {
  const AdminDeliveryPartnersSection({super.key});

  @override
  State<AdminDeliveryPartnersSection> createState() =>
      _AdminDeliveryPartnersSectionState();
}

class _AdminDeliveryPartnersSectionState
    extends State<AdminDeliveryPartnersSection> {
  bool _loading = true;
  bool _allowed = false;
  Map<String, dynamic> _payload = const {};

  List<Map<String, dynamic>> get _pending => _list(_payload['pending']);
  List<Map<String, dynamic>> get _partners => _list(_payload['partners']);
  List<Map<String, dynamic>> get _typeOptions => _list(_payload['type_options']);

  @override
  void initState() {
    super.initState();
    AdminZoneScope.instance.addListener(_onZone);
    _load();
  }

  @override
  void dispose() {
    AdminZoneScope.instance.removeListener(_onZone);
    super.dispose();
  }

  void _onZone() => _load();

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_delivery_partners',
        params: {'p_zone': AdminZoneScope.instance.selectedZoneId},
      );
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _payload = m;
        _allowed = m['allowed'] == true;
        _loading = false;
      });
      RenderLog.write('c630_delivery_onboarding',
          'admin_partners;pending=${m['pending_count'] ?? 0};'
          'active=${m['partner_count'] ?? 0}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c630_delivery_onboarding', 'admin_partners_err');
    }
  }

  // ── B2: the original card the partner scanned ─────────────────────────────

  /// `partner-docs` is a public bucket, so the stored path resolves to a URL
  /// the admin can open. The path itself is opaque to the app — it is echoed
  /// back exactly as the backend stored it.
  Future<void> _openDoc(String path) async {
    if (path.isEmpty) return;
    try {
      final url =
          Supabase.instance.client.storage.from('partner-docs').getPublicUrl(path);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  // ── B3/B4: the one write ──────────────────────────────────────────────────

  Future<void> _apply(Map<String, dynamic> params) async {
    try {
      final res =
          await Supabase.instance.client.rpc('admin_set_delivery_partner', params: params);
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      // zone_required / agency_cannot_nest / bad_type each carry `message`;
      // ok:true carries its own sentence too. Either way the backend's words.
      final msg = m['message']?.toString() ?? '';
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(msg),
          backgroundColor: m['ok'] == true ? null : _kBad,
        ));
      }
      RenderLog.write('c630_delivery_onboarding',
          'set_partner;ok=${m['ok'] == true};err=${m['error'] ?? ''}');
      if (m['ok'] == true) await _load();
    } catch (_) {}
  }

  Future<void> _approve(Map<String, dynamic> row) async {
    final params = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _ApproveSheet(
        partnerId: row['partner_id']?.toString() ?? '',
        name: row['full_name']?.toString() ?? '',
        typeOptions: _typeOptions,
      ),
    );
    if (params != null) await _apply(params);
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading || !_allowed) return const SizedBox.shrink();

    final pendingTitle = _payload['pending_title']?.toString() ?? '';
    final pendingNote = _payload['pending_note']?.toString() ?? '';
    final pendingCount = (_payload['pending_count'] as num?)?.toInt() ?? 0;
    final partnerCount = (_payload['partner_count'] as num?)?.toInt() ?? 0;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: Text(_ui('dlv_partners_title'),
              style:
                  TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _kText)),
        ),
        Text(_payload['zone_label']?.toString() ?? '',
            style: TextStyle(fontSize: 12, color: _kSub)),
      ]),

      // ── B2: awaiting approval
      const SizedBox(height: 12),
      Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(
              child: Text(pendingTitle,
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
            ),
            Text('$pendingCount', style: TextStyle(fontSize: 13, color: _kSub)),
          ]),
          if (pendingNote.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(pendingNote, style: TextStyle(fontSize: 13, color: _kSub)),
          ],
          const SizedBox(height: 12),
          if (_pending.isEmpty)
            Text(_ui('dlv_no_pending'), style: TextStyle(fontSize: 13, color: _kSub))
          else
            for (final r in _pending) _pendingRow(r),
        ]),
      ),

      // ── B4: active
      const SizedBox(height: 16),
      Row(children: [
        Expanded(
          child: Text(_ui('dlv_active_title'),
              style:
                  TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
        ),
        Text('$partnerCount', style: TextStyle(fontSize: 13, color: _kSub)),
      ]),
      const SizedBox(height: 8),
      if (_partners.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(_ui('dlv_no_partners'),
              style: TextStyle(fontSize: 13, color: _kSub)),
        )
      else
        for (final p in _partners) _partnerRow(p),
    ]);
  }

  Widget _pendingRow(Map<String, dynamic> r) {
    final docPath = r['id_doc_path']?.toString() ?? '';
    final sub = [
      r['phone']?.toString() ?? '',
      r['vehicle_type']?.toString() ?? '',
      r['city']?.toString() ?? '',
    ].where((x) => x.isNotEmpty).join(' · ');
    final idLine = [
      r['id_doc_type']?.toString() ?? '',
      r['id_doc_number']?.toString() ?? '',
    ].where((x) => x.isNotEmpty).join(' · ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF9FAFB),
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['full_name']?.toString() ?? '',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
              if (sub.isNotEmpty)
                Text(sub, style: TextStyle(fontSize: 12.5, color: _kSub)),
              if (idLine.isNotEmpty)
                Text(idLine, style: TextStyle(fontSize: 12.5, color: _kSub)),
            ]),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _approve(r),
            child: Text(_ui('dlv_approve'), style: const TextStyle(fontSize: 13)),
          ),
        ]),
        // B2 — the scanned card itself, one tap away.
        if (docPath.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: _kText,
              side: BorderSide(color: _kBorder),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _openDoc(docPath),
            icon: const Icon(Icons.image_outlined, size: 16),
            label: Text(_ui('dlv_view_id'), style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ]),
    );
  }

  Widget _partnerRow(Map<String, dynamic> p) {
    final colors = p['type_colors'] is Map
        ? Map<String, dynamic>.from(p['type_colors'] as Map)
        : const <String, dynamic>{};
    final typeLabel = p['type_label']?.toString() ?? '';
    final parent = p['parent_agency_name']?.toString() ?? '';
    final riderCount = (p['rider_count'] as num?)?.toInt() ?? 0;
    final openStops = (p['open_stops'] as num?)?.toInt() ?? 0;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p['full_name']?.toString() ?? '',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
              const SizedBox(height: 2),
              Wrap(spacing: 8, runSpacing: 4, children: [
                if (typeLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(typeLabel,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: _hex(colors['fg']?.toString()) ?? _kText)),
                  ),
                Text(p['zone_label']?.toString() ?? '',
                    style: TextStyle(fontSize: 12.5, color: _kSub)),
                if (parent.isNotEmpty)
                  Text(parent, style: TextStyle(fontSize: 12.5, color: _kSub)),
                if (p['on_shift'] == true)
                  Text(_ui('dlv_on_shift'),
                      style: TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w500, color: _kGreen)),
              ]),
              const SizedBox(height: 2),
              Text('$riderCount ${_ui('dlv_riders_suffix')} · '
                  '$openStops ${_ui('dlv_open_stops')}',
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
            ]),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _apply({
              'p_partner_id': p['partner_id']?.toString() ?? '',
              'p_is_active': false,
            }),
            child: Text(_ui('dlv_deactivate'),
                style: TextStyle(fontSize: 12.5, color: _kBad)),
          ),
        ]),
      ]),
    );
  }
}

// ── B3: the approval form ─────────────────────────────────────────────────────

class _ApproveSheet extends StatefulWidget {
  final String partnerId;
  final String name;
  final List<Map<String, dynamic>> typeOptions;

  const _ApproveSheet({
    required this.partnerId,
    required this.name,
    required this.typeOptions,
  });

  @override
  State<_ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends State<_ApproveSheet> {
  String? _type;
  int? _zoneId;
  final _maxStops = TextEditingController();
  final _rate = TextEditingController();

  @override
  void dispose() {
    _maxStops.dispose();
    _rate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final zones = AdminZoneScope.instance.options;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, ctrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFFF5F6F8),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Center(
              child: Container(
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: _kBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(widget.name,
                style:
                    TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(height: 16),

            // TYPE — each option carries its own explanatory note, rendered
            // exactly as the backend wrote it.
            Text(_ui('dlv_type'),
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _kSub)),
            const SizedBox(height: 8),
            for (final o in widget.typeOptions) _typeTile(o),

            const SizedBox(height: 16),
            Text(_ui('dlv_zone'),
                style: TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600, color: _kSub)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: _kBorder),
                borderRadius: BorderRadius.circular(8),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int?>(
                  isExpanded: true,
                  value: _zoneId,
                  hint: Text(_ui('dlv_zone'),
                      style: TextStyle(fontSize: 14, color: _kSub)),
                  items: [
                    // Only real zones — "All zones" is a filter, not a posting.
                    for (final z in zones)
                      if ((z['zone_id'] as num?) != null)
                        DropdownMenuItem<int?>(
                          value: (z['zone_id'] as num).toInt(),
                          child: Text(z['label']?.toString() ?? '',
                              style: TextStyle(fontSize: 14, color: _kText)),
                        ),
                  ],
                  onChanged: (v) => setState(() => _zoneId = v),
                ),
              ),
            ),

            const SizedBox(height: 12),
            _numField(_maxStops, 'dlv_max_stops'),
            const SizedBox(height: 12),
            _numField(_rate, 'dlv_per_drop'),

            const SizedBox(height: 20),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                ),
                // Never disabled on a missing zone or type: zone_required and
                // bad_type are the BACKEND's answers, and the admin must see
                // them in the backend's own words rather than meet a dead
                // button that explains nothing.
                onPressed: () => Navigator.of(context).pop(<String, dynamic>{
                  'p_partner_id': widget.partnerId,
                  'p_partner_type': _type,
                  'p_zone_id': _zoneId,
                  'p_is_active': true,
                  'p_max_stops': int.tryParse(_maxStops.text.trim()),
                  'p_per_drop_rate': num.tryParse(_rate.text.trim()),
                }),
                child: Text(_ui('dlv_approve_submit'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(_ui('dlv_cancel'), style: TextStyle(color: _kSub)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeTile(Map<String, dynamic> o) {
    final value = o['value']?.toString() ?? '';
    final selected = _type == value;
    return GestureDetector(
      onTap: () => setState(() => _type = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: selected ? _kGreen : _kBorder, width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            size: 18,
            color: selected ? _kGreen : _kSub,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(o['label']?.toString() ?? '',
                  style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600, color: _kText)),
              // The role explanation, verbatim.
              if ((o['note']?.toString() ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(o['note']!.toString(),
                    style: TextStyle(fontSize: 12.5, color: _kSub)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _numField(TextEditingController c, String labelKey) => TextField(
        controller: c,
        keyboardType: TextInputType.number,
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
      );
}
