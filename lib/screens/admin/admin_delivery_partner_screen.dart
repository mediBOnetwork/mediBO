// lib/screens/admin/admin_delivery_partner_screen.dart — CHANGE #632
//
// The standalone "Delivery Partners" admin page (home_shell.dart nav item):
// approve or reject a registration, manage the active roster, edit a
// partner's contact/ID details, see performance, and fix missing pharmacy
// locations. This used to be a separate, older approve/reject-by-status flow
// (admin_registration_list/admin_review_registration) that only ever set
// `status` and never actually activated a rider — CHANGE #630's
// admin_set_delivery_partner() is what really activates one (it needs a type
// and a zone first), so that is what backs approval here. Reject still goes
// through admin_review_registration() — it only needs to mark `status`, which
// admin_delivery_partners() now excludes from the pending queue at the source.
//
// The Fulfillment "Delivery" tab (admin_delivery_tab.dart) stays
// assignment-only: order queue, assign, reassign. Nothing about partners
// themselves lives there — it all lives here instead.
//
// Same date/zone scope as every other admin screen: AdminDateScope/
// AdminZoneScope are the only source for p_date/p_zone. This screen builds no
// picker of its own.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/admin_date_scope.dart';
import '../../services/admin_zone_scope.dart';
import '../../utils/render_log.dart';
import 'admin_delivery_partners_section.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43', const Color(0xFF1B7A43));
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb', const Color(0xFFE5E7EB));
Color get _kText => FulfillLookups.instance.color('c_ff111827', const Color(0xFF111827));
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280', const Color(0xFF6B7280));
Color get _kBad => FulfillLookups.instance.color('c_ffb42318', const Color(0xFFB42318));

String _ui(String k) => FulfillLookups.instance.ui(k);

class AdminDeliveryPartnerScreen extends StatefulWidget {
  const AdminDeliveryPartnerScreen({super.key});

  @override
  State<AdminDeliveryPartnerScreen> createState() => _AdminDeliveryPartnerScreenState();
}

class _AdminDeliveryPartnerScreenState extends State<AdminDeliveryPartnerScreen> {
  bool _loading = true;
  bool _allowed = true;
  String _zoneLabel = '';

  // admin_delivery_dashboard() — performance
  Map<String, dynamic> _tiles = const {};
  List<Map<String, dynamic>> _riders = const [];

  // admin_missing_locations()
  int _missingCount = 0;
  String _missingTitle = '';
  String _missingNote = '';
  List<Map<String, dynamic>> _missingRows = const [];

  final _partnersKey = GlobalKey<AdminDeliveryPartnersSectionState>();

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    AdminDateScope.instance.addListener(_onScopeChanged);
    AdminZoneScope.instance.addListener(_onScopeChanged);
    AdminDateScope.instance.ensureLoaded();
    AdminZoneScope.instance.ensureLoaded();
    _load();
  }

  @override
  void dispose() {
    AdminDateScope.instance.removeListener(_onScopeChanged);
    AdminZoneScope.instance.removeListener(_onScopeChanged);
    super.dispose();
  }

  void _onScopeChanged() {
    _load();
    _partnersKey.currentState?.reload();
  }

  Map<String, dynamic> get _dashboardScope => {
        'p_date': AdminDateScope.instance.dateYmd,
        'p_zone': AdminZoneScope.instance.selectedZoneId,
      };

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final client = Supabase.instance.client;
    try {
      final results = await Future.wait([
        client.rpc('admin_delivery_dashboard', params: _dashboardScope),
        client.rpc('admin_missing_locations'),
      ]);
      if (!mounted) return;

      final d = results[0] is Map ? Map<String, dynamic>.from(results[0] as Map) : <String, dynamic>{};
      final m = results[1] is Map ? Map<String, dynamic>.from(results[1] as Map) : <String, dynamic>{};

      setState(() {
        _allowed = d['allowed'] != false;
        _zoneLabel = d['zone_label']?.toString() ?? '';
        _tiles = d['tiles'] is Map ? Map<String, dynamic>.from(d['tiles'] as Map) : const {};
        _riders = _list(d['riders']);

        _missingCount = (m['missing_count'] as num?)?.toInt() ?? 0;
        _missingTitle = m['title']?.toString() ?? '';
        _missingNote = m['note']?.toString() ?? '';
        _missingRows = _list(m['rows']);
        _loading = false;
      });

      RenderLog.write('c632_delivery_partners_screen',
          'allowed=$_allowed;zone=$_zoneLabel;date=${AdminDateScope.instance.dateYmd ?? ''};'
          'riders=${_riders.length};missing=$_missingCount');
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c632_delivery_partners_screen_err', e.toString());
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  // ── missing locations ─────────────────────────────────────────────────────

  Future<void> _openMissingLocations() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MissingLocationsSheet(
        title: _missingTitle,
        note: _missingNote,
        rows: _missingRows,
      ),
    );
    await _load();
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('Delivery Partners',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, color: Color(0xFF374151)), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF1B5E20)))
          : !_allowed
              ? const SizedBox.shrink()
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _header(),
                      const SizedBox(height: 12),
                      AdminDeliveryPartnersSection(
                        key: _partnersKey,
                        onChanged: _load,
                      ),
                      if (_missingCount > 0) ...[
                        _missingBanner(),
                        const SizedBox(height: 12),
                      ],
                      if (_tiles.isNotEmpty || _riders.isNotEmpty) ...[
                        _dashboardStrip(),
                        if (_riders.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _ridersStrip(),
                        ],
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _header() {
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_zoneLabel,
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
          const SizedBox(height: 2),
          Text(AdminDateScope.instance.longLabel,
              style: TextStyle(fontSize: 12, color: _kSub)),
        ]),
      ),
    ]);
  }

  Widget _missingBanner() {
    return InkWell(
      onTap: _openMissingLocations,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFF59E0B)),
        ),
        child: Row(children: [
          const Icon(Icons.location_off_outlined, size: 20, color: Color(0xFF92400E)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_missingTitle,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFF92400E))),
              if (_missingNote.isNotEmpty)
                Text(_missingNote,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
            ]),
          ),
          const Icon(Icons.chevron_right, color: Color(0xFF92400E)),
        ]),
      ),
    );
  }

  /// Tiles, counted by admin_delivery_dashboard(). The labels are the
  /// payload's own keys; no total is added up here.
  Widget _dashboardStrip() {
    const order = ['assigned', 'out', 'delivered', 'failed', 'rto', 'unaccepted', 'total'];
    final tiles = <Widget>[];
    for (final k in order) {
      if (!_tiles.containsKey(k)) continue;
      tiles.add(Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('${(_tiles[k] as num?)?.toInt() ?? 0}',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: _kText)),
          Text(_ui('dlv_tile_$k'), style: TextStyle(fontSize: 11, color: _kSub)),
        ]),
      ));
    }
    if (tiles.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: tiles),
    );
  }

  /// Per-rider performance. Every field the backend sends is rendered:
  /// delivered/failed/pending, success_label, avg_minutes, last_seen, and a
  /// map link when lat/lng are present.
  Widget _ridersStrip() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final r in _riders) _riderTile(r),
      ]),
    );
  }

  Widget _riderTile(Map<String, dynamic> r) {
    final avgMinutes = (r['avg_minutes'] as num?)?.toInt();
    final lastSeen = r['last_seen']?.toString() ?? '';
    final lat = (r['lat'] as num?)?.toDouble();
    final lng = (r['lng'] as num?)?.toDouble();

    return Container(
      width: 190,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(r['name']?.toString() ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
          ),
          if (lat != null && lng != null)
            InkWell(
              onTap: () => _openMap(lat, lng),
              child: Icon(Icons.location_on_outlined, size: 16, color: _kSub),
            ),
        ]),
        Text(r['type_label']?.toString() ?? '',
            style: TextStyle(fontSize: 11, color: _kSub)),
        const SizedBox(height: 6),
        Row(children: [
          _miniStat('${(r['delivered'] as num?)?.toInt() ?? 0}', _kGreen),
          const SizedBox(width: 6),
          _miniStat('${(r['failed'] as num?)?.toInt() ?? 0}', _kBad),
          const SizedBox(width: 6),
          _miniStat('${(r['pending'] as num?)?.toInt() ?? 0}', _kSub),
          const Spacer(),
          Text(r['success_label']?.toString() ?? '',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: _kText)),
        ]),
        if (avgMinutes != null || lastSeen.isNotEmpty) ...[
          const SizedBox(height: 6),
          if (avgMinutes != null)
            Text(FulfillLookups.instance.uiFill('dlv_avg_minutes', {'n': avgMinutes}),
                style: TextStyle(fontSize: 11, color: _kSub)),
          if (lastSeen.isNotEmpty)
            Text('${_ui('dlv_last_seen')}: $lastSeen',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: _kSub)),
        ],
      ]),
    );
  }

  Future<void> _openMap(double lat, double lng) async {
    try {
      await launchUrl(Uri.parse('https://www.google.com/maps?q=$lat,$lng'),
          mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _miniStat(String v, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(v, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
      );
}

// ── missing locations ──────────────────────────────────────────────────────────

class _MissingLocationsSheet extends StatefulWidget {
  final String title;
  final String note;
  final List<Map<String, dynamic>> rows;

  const _MissingLocationsSheet({
    required this.title,
    required this.note,
    required this.rows,
  });

  @override
  State<_MissingLocationsSheet> createState() => _MissingLocationsSheetState();
}

class _MissingLocationsSheetState extends State<_MissingLocationsSheet> {
  /// pharmacy_id currently being edited.
  String _open = '';
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _latCtrl.dispose();
    _lngCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  /// p_maps_url takes a PASTED Google Maps link and the backend extracts the
  /// coordinates. No URL is parsed here: this app has no idea what a Maps
  /// link looks like, and must not acquire one.
  Future<void> _save(String pharmacyId) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final url = _urlCtrl.text.trim();
      final res = await Supabase.instance.client.rpc('pharmacy_set_location', params: {
        'p_pharmacy_id': pharmacyId,
        'p_lat': double.tryParse(_latCtrl.text.trim()),
        'p_lng': double.tryParse(_lngCtrl.text.trim()),
        'p_maps_url': url.isEmpty ? null : url,
      });
      if (!mounted) return;
      final msg = res is Map ? (res['message']?.toString() ?? '') : '';
      if (res is Map && res['ok'] == true) {
        setState(() {
          _open = '';
          _latCtrl.clear();
          _lngCtrl.clear();
          _urlCtrl.clear();
        });
      }
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
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
            Text(widget.title,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: _kText)),
            if (widget.note.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(widget.note, style: TextStyle(fontSize: 12.5, color: _kSub)),
            ],
            const SizedBox(height: 14),
            for (final r in widget.rows) _row(r),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final id = r['pharmacy_id']?.toString() ?? '';
    final isOpen = _open == id;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(r['pharmacy_name']?.toString() ?? '',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: _kText)),
              if ((r['address']?.toString() ?? '').isNotEmpty)
                Text(r['address']!.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _kSub)),
            ]),
          ),
          TextButton(
            onPressed: () => setState(() {
              _open = isOpen ? '' : id;
              _latCtrl.clear();
              _lngCtrl.clear();
              _urlCtrl.clear();
            }),
            child: Text(_ui('dlv_fix_location'), style: const TextStyle(fontSize: 12.5)),
          ),
        ]),
        if (isOpen) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              labelText: _ui('dlv_maps_link'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _latCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: _ui('dlv_lat'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _lngCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: InputDecoration(
                  labelText: _ui('dlv_lng'),
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : () => _save(id),
            child: Text(_ui('dlv_save_location')),
          ),
        ],
      ]),
    );
  }
}
