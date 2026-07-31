// lib/screens/admin/admin_delivery_partners_section.dart — CHANGE #630,
// moved onto its own tab by #632 (PART B)
//
// Delivery partners: registrations awaiting approval, and the active roster
// for the zone on screen. As of #632 this lives on the "Delivery Partner" tab
// (admin_delivery_partner_tab.dart), not inside the assignment-only Delivery
// tab.
//
// B3 — EDITING A PARTNER. The account id never changes: admin_update_delivery_
// partner() only ever UPDATEs the existing row, so runs/deliveries/earnings
// stay attached. Blank fields mean "leave unchanged" — the backend itself
// coalesces a blank/null input onto the existing value, so the edit sheet only
// sends what the admin actually typed. identity_taken is printed verbatim
// (title/message/hint); "Who has this number?" calls identity_owner_lookup()
// so the admin can see which account already holds it before freeing it up.
//
// A1 — admin_delivery_partners(p_zone). NOTE the asymmetry, which is the
// backend's and is deliberate: `partners` (active) is zone-filtered, `pending`
// is NOT. A registration that has not been approved yet usually has no zone at
// all — that is precisely what the admin is about to set — so scoping the
// pending list by zone would hide every new signup. The header therefore states
// the zone for the ACTIVE list only, and the pending list says nothing about
// zones it does not have.
//
// A3 — THE TYPE OPTIONS AND THEIR EXPLANATIONS ARE THE BACKEND'S.
// type_options[] carries {value, label, note}; the note explains what the role
// means ("Can add its own riders and hand stops to them"). It is rendered as
// supplied — this screen does not describe the roles in its own words, because
// the day the rules change that description would quietly become a lie.
//
// A3 — REFUSALS ARE PRINTED, NEVER PRE-EMPTED. zone_required,
// agency_cannot_nest and bad_type each arrive with their own `message`, shown
// verbatim. The form does not test any of these itself: it submits, and the
// backend answers. That is the only way the two cannot disagree.
//
// ZONE CONTROL — mirrors #609's own semantics rather than inventing a picker.
// zone_picker() tells this app whether the caller may change zone at all
// (can_change) and what the options are. For a zone-pinned admin it returns
// can_change:false with an EMPTY options list, so the approve form shows the
// zone as static text; a caller who does get options gets a dropdown. Either
// way the zone that is submitted came from the backend, not from a list this
// file holds.

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

class AdminDeliveryPartnersSection extends StatefulWidget {
  /// Called after any write, so the host tab can refetch its own queue —
  /// approving a partner changes who can be assigned.
  final Future<void> Function() onChanged;

  const AdminDeliveryPartnersSection({super.key, required this.onChanged});

  @override
  State<AdminDeliveryPartnersSection> createState() =>
      AdminDeliveryPartnersSectionState();
}

class AdminDeliveryPartnersSectionState
    extends State<AdminDeliveryPartnersSection> {
  bool _loading = true;
  bool _allowed = true;
  // CHANGE #632: this section now lives on its own dedicated "Delivery
  // Partner" tab rather than collapsed inside the Delivery (assignment) tab,
  // so it opens expanded — there is no queue left to bury.
  bool _open = true;

  String _zoneLabel = '';
  int? _zoneId;
  List<Map<String, dynamic>> _pending = const [];
  List<Map<String, dynamic>> _partners = const [];
  List<Map<String, dynamic>> _typeOptions = const [];
  String _pendingTitle = '';
  String _pendingNote = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> reload() => _load();

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_delivery_partners',
        params: {'p_zone': AdminZoneScope.instance.selectedZoneId},
      );
      if (!mounted) return;
      if (res is! Map) {
        setState(() => _loading = false);
        return;
      }
      final m = Map<String, dynamic>.from(res);
      setState(() {
        _allowed = m['allowed'] != false;
        _zoneLabel = m['zone_label']?.toString() ?? '';
        _zoneId = (m['zone_id'] as num?)?.toInt();
        _pending = _list(m['pending']);
        _partners = _list(m['partners']);
        _typeOptions = _list(m['type_options']);
        _pendingTitle = m['pending_title']?.toString() ?? '';
        _pendingNote = m['pending_note']?.toString() ?? '';
        _loading = false;
      });
      RenderLog.write('c630_delivery_partners',
          'allowed=$_allowed;zone=$_zoneLabel;pending=${_pending.length};active=${_partners.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c630_delivery_partners_err', e.toString());
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Deactivate. The same RPC that approves — one write path, one set of rules.
  Future<void> _deactivate(String partnerId) async {
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_set_delivery_partner',
        params: {'p_partner_id': partnerId, 'p_is_active': false},
      );
      if (!mounted) return;
      await _load();
      await widget.onChanged();
      if (res is Map) {
        // ok:false carries `message` too — both are printed the same way.
        _toast(res['message']?.toString() ?? '');
      }
    } catch (_) {}
  }

  Future<void> _openApprove(Map<String, dynamic> row) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ApproveSheet(
        row: row,
        typeOptions: _typeOptions,
        defaultZoneId: _zoneId,
        defaultZoneLabel: _zoneLabel,
      ),
    );
    if (saved == true) {
      await _load();
      await widget.onChanged();
    }
  }

  /// B3 — the account id in [row] never changes; this only updates contact/ID
  /// fields on the SAME row.
  Future<void> _openEdit(Map<String, dynamic> row) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _EditPartnerSheet(row: row),
    );
    if (saved == true) {
      await _load();
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_allowed) return const SizedBox.shrink();

    final pendingCount = _pending.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Icon(Icons.badge_outlined, size: 18, color: _kSub),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_ui('dlv_partners_title'),
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w800, color: _kText)),
              ),
              // The pending badge is a count of the list the backend sent, not
              // a status this file worked out.
              if (pendingCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF59E0B),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$pendingCount',
                      style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Colors.white)),
                ),
              const SizedBox(width: 6),
              Icon(_open ? Icons.expand_less : Icons.expand_more, color: _kSub),
            ]),
          ),
        ),
        if (_open) ...[
          Divider(height: 1, color: _kBorder),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── pending ──────────────────────────────────────────────
                  if (_pendingTitle.isNotEmpty)
                    Text(_pendingTitle,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _kText)),
                  if (_pendingNote.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(_pendingNote,
                        style: TextStyle(fontSize: 11.5, color: _kSub)),
                  ],
                  const SizedBox(height: 8),
                  if (_pending.isEmpty)
                    Text(_ui('dlv_no_pending'),
                        style: TextStyle(fontSize: 12.5, color: _kSub))
                  else
                    for (final r in _pending) _pendingRow(r),

                  const SizedBox(height: 18),
                  Divider(height: 1, color: _kBorder),
                  const SizedBox(height: 12),

                  // ── active, for THIS zone ────────────────────────────────
                  Row(children: [
                    Expanded(
                      child: Text(_ui('dlv_active_title'),
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: _kText)),
                    ),
                    Text(_zoneLabel,
                        style: TextStyle(fontSize: 11.5, color: _kSub)),
                  ]),
                  const SizedBox(height: 8),
                  if (_partners.isEmpty)
                    Text(_ui('dlv_no_partners'),
                        style: TextStyle(fontSize: 12.5, color: _kSub))
                  else
                    for (final p in _partners) _activeRow(p),
                ],
              ),
            ),
        ],
      ]),
    );
  }

  Widget _pendingRow(Map<String, dynamic> r) {
    final docPath = r['id_doc_path']?.toString() ?? '';
    final docType = r['id_doc_type']?.toString() ?? '';
    final docNumber = r['id_doc_number']?.toString() ?? '';
    final vehicle = r['vehicle_type']?.toString() ?? '';
    final city = r['city']?.toString() ?? '';
    final phone = r['phone']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        border: Border.all(color: const Color(0xFFF59E0B)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(r['full_name']?.toString() ?? '',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
        const SizedBox(height: 2),
        Text(
          [phone, vehicle, city].where((x) => x.isNotEmpty).join(' · '),
          style: TextStyle(fontSize: 11.5, color: _kSub),
        ),
        if (docType.isNotEmpty || docNumber.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text([docType, docNumber].where((x) => x.isNotEmpty).join(' · '),
              style: TextStyle(fontSize: 11.5, color: _kSub)),
        ],
        const SizedBox(height: 8),
        Row(children: [
          // A2 — open the scanned ID so the admin can actually verify it.
          // Only offered when there IS one; Tittu, the first registration, has
          // no document at all.
          if (docPath.isNotEmpty)
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                side: BorderSide(color: _kBorder),
                foregroundColor: _kText,
              ),
              onPressed: () => _openDoc(docPath),
              icon: const Icon(Icons.badge_outlined, size: 15),
              label: Text(_ui('dlv_view_id'), style: const TextStyle(fontSize: 12)),
            ),
          if (docPath.isNotEmpty) const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () => _openApprove(r),
            child: Text(_ui('dlv_approve'), style: const TextStyle(fontSize: 12.5)),
          ),
        ]),
      ]),
    );
  }

  /// `partner-docs` is a PUBLIC bucket, so the stored path resolves through
  /// getPublicUrl and opens in a new tab. Opening it as a link rather than
  /// rendering it inline also sidesteps the signed-URL CORS trap that silently
  /// blanks Image.network on web.
  Future<void> _openDoc(String path) async {
    try {
      final url =
          Supabase.instance.client.storage.from('partner-docs').getPublicUrl(path);
      if (url.isEmpty) return;
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _activeRow(Map<String, dynamic> p) {
    final typeLabel = p['type_label']?.toString() ?? '';
    final colors = p['type_colors'] is Map
        ? Map<String, dynamic>.from(p['type_colors'] as Map)
        : const <String, dynamic>{};
    final parent = p['parent_agency_name']?.toString() ?? '';
    final riderCount = (p['rider_count'] as num?)?.toInt() ?? 0;
    final openStops = (p['open_stops'] as num?)?.toInt() ?? 0;
    final onShift = p['on_shift'] == true;
    final isAgency = p['partner_type']?.toString() == 'agency';

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
            child: Text(p['full_name']?.toString() ?? '',
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
          ),
          if (typeLabel.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(typeLabel,
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _hex(colors['fg']?.toString()) ?? _kText)),
            ),
        ]),
        const SizedBox(height: 3),
        Text(
          [
            p['phone']?.toString() ?? '',
            p['zone_label']?.toString() ?? '',
            if (parent.isNotEmpty) parent,
          ].where((x) => x.isNotEmpty).join(' · '),
          style: TextStyle(fontSize: 11.5, color: _kSub),
        ),
        const SizedBox(height: 6),
        Row(children: [
          if (isAgency) ...[
            Text('$riderCount ${_ui('dlv_riders_suffix')}',
                style: TextStyle(fontSize: 11.5, color: _kSub)),
            const SizedBox(width: 10),
          ],
          Text('$openStops ${_ui('dlv_open_stops')}',
              style: TextStyle(fontSize: 11.5, color: _kSub)),
          if (onShift) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFFE1F5EE),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_ui('dlv_on_shift'),
                  style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F6E56))),
            ),
          ],
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: _kText,
            ),
            onPressed: () => _openEdit(p),
            child: Text(_ui('dlv_edit'), style: const TextStyle(fontSize: 12)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: _kBad,
            ),
            onPressed: () => _deactivate(p['partner_id']?.toString() ?? ''),
            child: Text(_ui('dlv_deactivate'), style: const TextStyle(fontSize: 12)),
          ),
        ]),
      ]),
    );
  }
}

// ── A3: the approve form ──────────────────────────────────────────────────────

class _ApproveSheet extends StatefulWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> typeOptions;
  final int? defaultZoneId;
  final String defaultZoneLabel;

  const _ApproveSheet({
    required this.row,
    required this.typeOptions,
    required this.defaultZoneId,
    required this.defaultZoneLabel,
  });

  @override
  State<_ApproveSheet> createState() => _ApproveSheetState();
}

class _ApproveSheetState extends State<_ApproveSheet> {
  String _type = '';
  int? _zoneId;
  final _maxStopsCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  bool _busy = false;

  /// The backend's refusal, held verbatim.
  String _error = '';

  @override
  void initState() {
    super.initState();
    // Default to the first option the backend listed — its order, not ours.
    _type = widget.typeOptions.isNotEmpty
        ? (widget.typeOptions.first['value']?.toString() ?? '')
        : '';
    _zoneId = widget.defaultZoneId;
  }

  @override
  void dispose() {
    _maxStopsCtrl.dispose();
    _rateCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // NOTHING is validated here. zone_required / agency_cannot_nest / bad_type
      // are the backend's calls, and its sentence is what the admin reads.
      final res = await Supabase.instance.client.rpc(
        'admin_set_delivery_partner',
        params: {
          'p_partner_id': widget.row['partner_id']?.toString() ?? '',
          'p_partner_type': _type.isEmpty ? null : _type,
          'p_zone_id': _zoneId,
          'p_is_active': true,
          'p_max_stops': int.tryParse(_maxStopsCtrl.text.trim()),
          'p_per_drop_rate': double.tryParse(_rateCtrl.text.trim()),
        },
      );
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        RenderLog.write('c630_partner_approved', res['partner_type']?.toString() ?? '');
        final msg = res['message']?.toString() ?? '';
        Navigator.of(context).pop(true);
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      if (res is Map) {
        RenderLog.write('c630_partner_refused', res['error']?.toString() ?? '');
        setState(() => _error = res['message']?.toString() ?? '');
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zoneOptions = AdminZoneScope.instance.options;
    final canChangeZone = AdminZoneScope.instance.canChange && zoneOptions.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, ctrl) => ListView(
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
            Text(widget.row['full_name']?.toString() ?? '',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText)),
            const SizedBox(height: 14),

            // The refusal, printed exactly as it arrived.
            if (_error.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBE9E7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(_error,
                    style: TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600, color: _kBad)),
              ),
              const SizedBox(height: 14),
            ],

            Text(_ui('dlv_type'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _kSub)),
            const SizedBox(height: 6),
            // A3 — each option renders its OWN note. The roles are explained by
            // the backend, never described here.
            for (final o in widget.typeOptions)
              _typeTile(
                value: o['value']?.toString() ?? '',
                label: o['label']?.toString() ?? '',
                note: o['note']?.toString() ?? '',
              ),

            const SizedBox(height: 16),
            Text(_ui('dlv_zone'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: _kSub)),
            const SizedBox(height: 6),
            if (canChangeZone)
              // A caller the backend says may change zone gets its list.
              DropdownButtonFormField<int?>(
                initialValue: _zoneId,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  for (final z in zoneOptions)
                    DropdownMenuItem<int?>(
                      value: (z['zone_id'] as num?)?.toInt(),
                      child: Text(z['label']?.toString() ?? ''),
                    ),
                ],
                onChanged: (v) => setState(() => _zoneId = v),
              )
            else
              // #609: can_change false -> static text, no tap target. The zone
              // submitted is still the backend's own effective zone.
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: _kBorder),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(widget.defaultZoneLabel,
                    style: TextStyle(fontSize: 13.5, color: _kText)),
              ),

            const SizedBox(height: 14),
            TextField(
              controller: _maxStopsCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: _ui('dlv_max_stops'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _rateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _ui('dlv_per_drop'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_ui('dlv_approve_submit'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _typeTile({
    required String value,
    required String label,
    required String note,
  }) {
    final sel = _type == value;
    return GestureDetector(
      onTap: () => setState(() => _type = value),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: sel ? _kGreen.withValues(alpha: 0.06) : Colors.transparent,
          border: Border.all(color: sel ? _kGreen : _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(sel ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 18, color: sel ? _kGreen : _kSub),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
              if (note.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(note, style: TextStyle(fontSize: 11.5, color: _kSub)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── B3: edit a partner's contact/ID details ───────────────────────────────────

class _EditPartnerSheet extends StatefulWidget {
  final Map<String, dynamic> row;

  const _EditPartnerSheet({required this.row});

  @override
  State<_EditPartnerSheet> createState() => _EditPartnerSheetState();
}

class _EditPartnerSheetState extends State<_EditPartnerSheet> {
  final _nameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _vehicleCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _stateCtrl = TextEditingController();
  final _idTypeCtrl = TextEditingController();
  final _idNumberCtrl = TextEditingController();
  bool _busy = false;

  /// The backend's refusal, held verbatim.
  String _errorTitle = '';
  String _errorMessage = '';
  String _errorHint = '';
  bool _canLookup = false;

  /// identity_owner_lookup()'s own answer, printed verbatim once fetched.
  String _lookupMessage = '';
  bool _lookupBusy = false;

  @override
  void initState() {
    super.initState();
    // Only full_name/phone are on the active-roster row this sheet opened
    // from; every other field starts blank, which the backend reads as "no
    // change" — the admin only ever submits what they actually typed.
    _nameCtrl.text = widget.row['full_name']?.toString() ?? '';
    _phoneCtrl.text = widget.row['phone']?.toString() ?? '';
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    _vehicleCtrl.dispose();
    _addressCtrl.dispose();
    _cityCtrl.dispose();
    _stateCtrl.dispose();
    _idTypeCtrl.dispose();
    _idNumberCtrl.dispose();
    super.dispose();
  }

  String? _val(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _errorTitle = '';
      _errorMessage = '';
      _errorHint = '';
      _canLookup = false;
      _lookupMessage = '';
    });
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_update_delivery_partner',
        params: {
          'p_partner_id': widget.row['partner_id']?.toString() ?? '',
          'p_full_name': _val(_nameCtrl),
          'p_phone': _val(_phoneCtrl),
          'p_email': _val(_emailCtrl),
          'p_vehicle_type': _val(_vehicleCtrl),
          'p_address': _val(_addressCtrl),
          'p_city': _val(_cityCtrl),
          'p_state': _val(_stateCtrl),
          'p_id_doc_type': _val(_idTypeCtrl),
          'p_id_doc_number': _val(_idNumberCtrl),
          'p_id_doc_path': null,
        },
      );
      if (!mounted) return;
      if (res is Map && res['ok'] == true) {
        RenderLog.write('c632_partner_edited',
            'changed=${(res['credentials_changed'] as List?)?.join(',') ?? ''}');
        final msg = res['message']?.toString() ?? '';
        Navigator.of(context).pop(true);
        if (msg.isNotEmpty) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      if (res is Map) {
        final code = res['error']?.toString() ?? '';
        RenderLog.write('c632_partner_edit_refused', code);
        setState(() {
          _errorTitle = res['title']?.toString() ?? '';
          _errorMessage = res['message']?.toString() ?? '';
          _errorHint = res['hint']?.toString() ?? '';
          // The lookup only makes sense for the refusal it exists for, and
          // only when there is something to look up.
          _canLookup = code == 'identity_taken' &&
              (_val(_phoneCtrl) != null || _val(_emailCtrl) != null);
        });
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// B3 — "Who has this number?" reads identity_owner_lookup() verbatim; it
  /// does not decide anything, it only shows the admin what the backend found
  /// so they know which account to free the identity from first.
  Future<void> _lookup(String identity) async {
    if (_lookupBusy || identity.isEmpty) return;
    setState(() {
      _lookupBusy = true;
      _lookupMessage = '';
    });
    try {
      final res = await Supabase.instance.client
          .rpc('identity_owner_lookup', params: {'p_identity': identity});
      if (!mounted) return;
      if (res is Map) {
        final ownerName = res['owner_name']?.toString() ?? '';
        final typeLabel = res['type_label']?.toString() ?? '';
        final message = res['message']?.toString() ?? '';
        setState(() => _lookupMessage = [
              message,
              [ownerName, typeLabel].where((x) => x.isNotEmpty).join(' · '),
            ].where((x) => x.isNotEmpty).join(' — '));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _lookupBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, ctrl) => ListView(
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
            Text(_ui('dlv_edit_partner_title'),
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText)),
            const SizedBox(height: 14),

            // The refusal, printed exactly as it arrived.
            if (_errorMessage.isNotEmpty || _errorTitle.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(11),
                decoration: BoxDecoration(
                  color: const Color(0xFFFBE9E7),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_errorTitle.isNotEmpty)
                    Text(_errorTitle,
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800, color: _kBad)),
                  if (_errorMessage.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(_errorMessage,
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600, color: _kBad)),
                  ],
                  if (_errorHint.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(_errorHint, style: TextStyle(fontSize: 12, color: _kBad)),
                  ],
                  if (_canLookup) ...[
                    const SizedBox(height: 8),
                    Row(children: [
                      if (_val(_phoneCtrl) != null)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            side: BorderSide(color: _kBad),
                            foregroundColor: _kBad,
                          ),
                          onPressed: _lookupBusy ? null : () => _lookup(_val(_phoneCtrl)!),
                          child: Text(_ui('dlv_who_has_this'),
                              style: const TextStyle(fontSize: 12)),
                        ),
                      if (_val(_phoneCtrl) != null && _val(_emailCtrl) != null)
                        const SizedBox(width: 8),
                      if (_val(_emailCtrl) != null)
                        OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            side: BorderSide(color: _kBad),
                            foregroundColor: _kBad,
                          ),
                          onPressed: _lookupBusy ? null : () => _lookup(_val(_emailCtrl)!),
                          child: Text(_ui('dlv_who_has_this'),
                              style: const TextStyle(fontSize: 12)),
                        ),
                    ]),
                  ],
                  if (_lookupBusy) ...[
                    const SizedBox(height: 8),
                    const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                  if (_lookupMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_lookupMessage,
                        style: TextStyle(
                            fontSize: 12.5, fontWeight: FontWeight.w600, color: _kBad)),
                  ],
                ]),
              ),
              const SizedBox(height: 14),
            ],

            TextField(
              controller: _nameCtrl,
              decoration: InputDecoration(
                labelText: _ui('dlv_rider_name'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: _ui('dlv_rider_phone'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: _ui('dlv_reg_email'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _vehicleCtrl,
              decoration: InputDecoration(
                labelText: _ui('dlv_rider_vehicle'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _addressCtrl,
              decoration: InputDecoration(
                labelText: _ui('dlv_reg_address'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _cityCtrl,
                  decoration: InputDecoration(
                    labelText: _ui('dlv_reg_city'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _stateCtrl,
                  decoration: InputDecoration(
                    labelText: _ui('dlv_reg_state'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _idTypeCtrl,
                  decoration: InputDecoration(
                    labelText: _ui('dlv_reg_id_type'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _idNumberCtrl,
                  decoration: InputDecoration(
                    labelText: _ui('dlv_reg_id_number'),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _busy ? null : _submit,
              child: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_ui('dlv_save_changes'),
                      style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}
