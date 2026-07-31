// lib/screens/delivery/delivery_home_screen.dart — CHANGE #629 (PART B, D, E)
//
// The rider / agency interface. A delivery partner logs into the SAME mediBO
// app and lands here instead of the storefront, exactly as a supplier lands on
// the supplier shell.
//
// B1 — the role signal is my_delivery_run().is_partner, a BACKEND boolean.
// There is no role test in this file and none in the shell that routes to it.
// A rider sees only their own work, so there is no zone picker and no date
// picker: my_delivery_run() defaults to IST today and scopes to the caller.
//
// B2 — the layout is fixed by the spec, top to bottom: MAP, then the batch
// chips, then the stop list. That order is the widget order below.
//
// B3 — pin_color is rendered verbatim by DeliveryRunMapPanel. There is no
// status -> colour mapping anywhere in this file; likewise status_label and
// status_colors are printed as received.
//
// B7 / D7 — COST DISCIPLINE. The GPS heartbeat is a Supabase RPC and nothing
// else: it never calls Google. The single Google Directions call happens once
// per trip start (and after a reassignment), through the Route tab's existing
// edge function — never per stop, never per heartbeat.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../services/device_location.dart';
import '../../user_state.dart';
import '../../utils/render_log.dart';
import 'agency_team_section.dart'; // C630: PART D
import 'delivery_google_route.dart';
import 'delivery_home_panel.dart'; // C630: PART B + C
import 'delivery_proof_sheet.dart';
import 'delivery_run_map_panel.dart';

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

class DeliveryHomeScreen extends StatefulWidget {
  const DeliveryHomeScreen({super.key});

  @override
  State<DeliveryHomeScreen> createState() => _DeliveryHomeScreenState();
}

class _DeliveryHomeScreenState extends State<DeliveryHomeScreen>
    with WidgetsBindingObserver {
  bool _loading = true;
  Map<String, dynamic> _run = const {};

  /// CHANGE #630: my_delivery_home() — shift, tiles, earnings. A SEPARATE
  /// payload from _run, and deliberately not merged: they answer different
  /// questions (who am I today vs what is on this trip) and merging them would
  /// create a composite this app owns and could get wrong.
  Map<String, dynamic> _home = const {};

  /// The agency's riders, lifted out of AgencyTeamSection so they can be
  /// plotted on the ONE map this screen already has (D6).
  List<Map<String, dynamic>> _agencyRiders = const [];

  List<Map<String, dynamic>> _stops = const [];
  List<Map<String, dynamic>> _batches = const [];

  /// null = the "All" chip. Otherwise the batch's `key`.
  int? _batch;

  /// delivery_run_map().road_polyline for the current run (D5).
  String _roadPolyline = '';

  /// The rider's own position, for the map's origin marker.
  double? _meLat;
  double? _meLng;

  Timer? _heartbeat;
  StreamSubscription? _watch;
  bool _busy = false;

  /// Guards the arrival popup so one pending stop cannot open two dialogs.
  bool _respondOpen = false;

  String get _runId => _run['run_id']?.toString() ?? '';

  /// CHANGE #630 (B5) — the trip button no longer branches on run_status.
  /// my_delivery_run() now answers directly: trip_action ('start'|'finish'|
  /// 'none'), the WORD on the button, and whether it is enabled. #629 derived
  /// all three from the status string, which meant this app held an opinion
  /// about when a trip may start — and it was a WEAKER opinion than the
  /// backend's, which also requires at least one accepted stop. A rider with
  /// only unaccepted stops used to get a live "Start trip" button that the RPC
  /// would then refuse.
  String get _tripAction => _run['trip_action']?.toString() ?? 'none';
  bool get _tripEnabled => _run['trip_button_enabled'] == true;

  /// "Is the trip running?" — asked as the backend's own can_finish, which is
  /// true exactly when the run is started. Drives the GPS heartbeat.
  bool get _runStarted => _run['can_finish'] == true;

  /// D1 — the agency section is gated on my_delivery_home()'s is_agency.
  bool get _isAgency => _home['is_agency'] == true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FulfillLookups.instance.ensureLoaded();
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopHeartbeat();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  // ── load ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    final client = Supabase.instance.client;
    try {
      // Both payloads in one round trip. They are kept separate — see _home.
      final results = await Future.wait([
        client.rpc('my_delivery_run'),
        client.rpc('my_delivery_home'),
      ]);
      if (!mounted) return;
      final res = results[0];
      if (res is! Map) {
        setState(() => _loading = false);
        return;
      }
      final m = Map<String, dynamic>.from(res);
      final h = results[1] is Map
          ? Map<String, dynamic>.from(results[1] as Map)
          : <String, dynamic>{};
      setState(() {
        _run = m;
        _home = h;
        _stops = _list(m['stops']);
        _batches = _list(m['batches']);
        _loading = false;
      });
      RenderLog.write('c629_delivery_run',
          'partner=${m['is_partner']};agency=${h['is_agency']};'
          'trip=${m['trip_action']};stops=${_stops.length}');

      // The heartbeat follows the run's state, never a local flag.
      if (_runStarted) {
        _startHeartbeat();
      } else {
        _stopHeartbeat();
      }

      await _loadRunMap();
      if (mounted) _maybePromptResponse();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c629_delivery_run_err', e.toString());
    }
  }

  /// D5 — the road polyline the backend last stored for this run.
  Future<void> _loadRunMap() async {
    final id = _runId;
    if (id.isEmpty) {
      if (mounted && _roadPolyline.isNotEmpty) setState(() => _roadPolyline = '');
      return;
    }
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_run_map', params: {'p_run_id': id});
      if (!mounted || res is! Map) return;
      setState(() => _roadPolyline = res['road_polyline']?.toString() ?? '');
    } catch (_) {
      // No polyline -> the map draws pins only. Never a blocked screen.
    }
  }

  List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  // ── B7: location heartbeat ────────────────────────────────────────────────

  void _startHeartbeat() {
    if (_heartbeat != null) return;
    _push();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) => _push());
    // …and on significant movement, which the browser reports itself.
    _watch = DeviceLocation.watch((fix) => _send(fix));
    RenderLog.write('c629_delivery_heartbeat', 'started');
  }

  void _stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
    try {
      _watch?.cancel();
    } catch (_) {}
    _watch = null;
  }

  Future<void> _push() async {
    final fix = await DeviceLocation.current();
    if (fix != null) _send(fix);
  }

  Future<void> _send(DeviceFix fix) async {
    if (mounted) {
      setState(() {
        _meLat = fix.lat;
        _meLng = fix.lng;
      });
    }
    try {
      await Supabase.instance.client.rpc('delivery_update_location', params: {
        'p_lat': fix.lat,
        'p_lng': fix.lng,
        'p_heading': fix.heading,
        'p_accuracy': fix.accuracy,
      });
    } catch (_) {
      // A dropped heartbeat is not an error the rider can act on.
    }
  }

  // ── B6: trip ──────────────────────────────────────────────────────────────

  Future<void> _startTrip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // p_run_id is omitted — the RPC resolves the caller's own open run.
      final res = await Supabase.instance.client.rpc('delivery_start_run');
      if (!mounted) return;
      if (res is Map) {
        _toast(res['message']?.toString() ?? '');
        final id = res['run_id']?.toString() ?? '';
        await _load();
        // D6 — automatic, on trip start. No "optimise" button exists.
        if (id.isNotEmpty) await _optimise(id);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishTrip() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await Supabase.instance.client.rpc('delivery_finish_run');
      if (!mounted) return;
      _stopHeartbeat();
      if (res is Map) {
        // The response's own sentence says how many came back as returns.
        _toast(res['message']?.toString() ?? '');
      }
      await _load();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// D — one Google call, then re-read so the list shows the stored order.
  Future<void> _optimise(String runId) async {
    await DeliveryGoogleRoute.optimise(runId);
    if (!mounted) return;
    await _load();
  }

  // ── B5: accept / reject, as an arrival popup ──────────────────────────────

  void _maybePromptResponse() {
    if (_respondOpen) return;
    Map<String, dynamic>? pending;
    for (final s in _stops) {
      if (s['needs_response'] == true) {
        pending = s;
        break;
      }
    }
    if (pending == null) return;
    _respondOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _respondOpen = false;
        return;
      }
      await _showRespondDialog(pending!);
      _respondOpen = false;
      if (mounted) await _load(); // next pending stop, if any
    });
  }

  Future<void> _showRespondDialog(Map<String, dynamic> stop) async {
    final reasonCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(_ui('dlv_respond_title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(stop['pharmacy_name']?.toString() ?? '',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
            if ((stop['address']?.toString() ?? '').isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(stop['address']!.toString(),
                  style: TextStyle(fontSize: 12.5, color: _kSub)),
            ],
            const SizedBox(height: 10),
            Text(_ui('dlv_respond_note'),
                style: TextStyle(fontSize: 12.5, color: _kSub)),
            const SizedBox(height: 10),
            TextField(
              controller: reasonCtrl,
              decoration: InputDecoration(
                labelText: _ui('dlv_reject_reason'),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _respond(stop, 'reject', reasonCtrl.text.trim());
            },
            child: Text(_ui('dlv_reject'),
                style: const TextStyle(color: Color(0xFFB42318))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _kGreen,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await _respond(stop, 'accept', '');
            },
            child: Text(_ui('dlv_accept')),
          ),
        ],
      ),
    );
    reasonCtrl.dispose();
  }

  Future<void> _respond(Map<String, dynamic> stop, String action, String reason) async {
    try {
      final res = await Supabase.instance.client.rpc('delivery_respond', params: {
        'p_delivery_id': stop['delivery_id']?.toString() ?? '',
        'p_action': action,
        'p_reason': reason.isEmpty ? null : reason,
      });
      if (!mounted) return;
      if (res is Map) _toast(res['message']?.toString() ?? '');
      RenderLog.write('c629_delivery_respond', action);
    } catch (_) {}
  }

  // ── B4: row actions ───────────────────────────────────────────────────────

  Future<void> _open(String url) async {
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _deliver(Map<String, dynamic> stop) async {
    final changed = await showDeliveryProofSheet(context, stop: stop);
    if (changed && mounted) await _load();
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  /// The stops the selected batch chip covers. `from`/`to` are the backend's
  /// own 1-based ordinals over its own ordering — this applies the chip the
  /// backend defined, it does not re-sort or re-group the data.
  List<Map<String, dynamic>> get _visibleStops {
    final b = _batch;
    if (b == null) return _stops;
    for (final chip in _batches) {
      if ((chip['key'] as num?)?.toInt() == b) {
        final from = (chip['from'] as num?)?.toInt() ?? 1;
        final to = (chip['to'] as num?)?.toInt() ?? _stops.length;
        final out = <Map<String, dynamic>>[];
        for (var i = 0; i < _stops.length; i++) {
          final ordinal = i + 1;
          if (ordinal >= from && ordinal <= to) out.add(_stops[i]);
        }
        return out;
      }
    }
    return _stops;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF5F6F8),
        body: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43))),
      );
    }

    final visible = _visibleStops;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: _kText,
        elevation: 0.5,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_ui('dlv_home_title'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            Text(_run['partner_name']?.toString() ?? '',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w400, color: _kSub)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _ui('dlv_refresh'),
            onPressed: _load,
            icon: const Icon(Icons.refresh, size: 20),
          ),
          TextButton(
            onPressed: () => UserState.read(context).signOut(),
            child: Text(_ui('dlv_sign_out'), style: TextStyle(fontSize: 12.5, color: _kSub)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
          children: [
            // ── CHANGE #630 (PART B): the home strip sits ABOVE the map, as
            // the spec puts it — shift, today's tiles, earnings, History.
            DeliveryHomePanel(home: _home, onChanged: _load),
            const SizedBox(height: 12),

            // ── B2 (1): the map. Rider pins keep their backend pin_color; an
            // agency's riders are added as extra markers on this SAME map
            // rather than a second one (D6).
            DeliveryRunMapPanel(
              stops: _stops,
              extraMarkers: _agencyRiders,
              roadPolyline: _roadPolyline,
              originLat: _meLat,
              originLng: _meLng,
              height: 250,
            ),

            const SizedBox(height: 12),
            _tripBar(),

            // ── B2 (2): the batch chips.
            if (_batches.isNotEmpty) ...[
              const SizedBox(height: 12),
              _batchChips(),
            ],

            // ── B2 (3): the stop list.
            const SizedBox(height: 12),
            if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 36),
                child: Center(
                  child: Text(
                    _stops.isEmpty
                        ? (_run['empty_title']?.toString() ?? '')
                        : _ui('dlv_no_stops'),
                    style: TextStyle(fontSize: 13, color: _kSub),
                  ),
                ),
              )
            else
              for (final s in visible) _stopRow(s),

            // ── PART D: agency roster + hand-over. Mounted ONLY when
            // my_delivery_home() says is_agency.
            if (_isAgency) ...[
              const SizedBox(height: 20),
              AgencyTeamSection(
                onChanged: _load,
                onRiders: (riders) {
                  if (!mounted) return;
                  setState(() => _agencyRiders = riders);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// B5/B6 — every part of this button is the backend's answer.
  ///
  ///   the word      -> trip_button_label ("Start trip" / "Finish trip" /
  ///                    "Trip completed" / "Nothing to deliver")
  ///   the action    -> trip_action ('start' | 'finish' | 'none')
  ///   the enabling  -> trip_button_enabled
  ///
  /// Note the label is shown even when the button is DISABLED: "Nothing to
  /// deliver" is information the rider needs, and it is a sentence the backend
  /// wrote. #629 rendered no button at all in that state, so a rider with
  /// nothing assigned just saw a gap.
  Widget _tripBar() {
    final label = _run['trip_button_label']?.toString() ?? '';
    if (label.isEmpty) return const SizedBox.shrink();

    final isFinish = _tripAction == 'finish';
    final enabled = _tripEnabled && !_busy;

    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: isFinish ? Colors.white : _kGreen,
          foregroundColor: isFinish ? _kText : Colors.white,
          side: isFinish ? BorderSide(color: _kBorder) : null,
          disabledBackgroundColor: const Color(0xFFF3F4F6),
          disabledForegroundColor: _kSub,
          padding: const EdgeInsets.symmetric(vertical: 14),
        ),
        onPressed: enabled ? _onTrip : null,
        child: _busy
            ? const SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      ),
    );
  }

  /// Dispatches on trip_action. 'none' is unreachable from the UI (the button
  /// is disabled) but is still handled rather than assumed away.
  Future<void> _onTrip() async {
    switch (_tripAction) {
      case 'start':
        await _startTrip();
      case 'finish':
        await _finishTrip();
      default:
        return;
    }
  }

  Widget _batchChips() {
    Widget chip(String label, bool sel, VoidCallback onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: sel ? _kGreen : Colors.white,
                border: Border.all(color: sel ? _kGreen : _kBorder),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : _kSub)),
            ),
          ),
        );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        chip(_ui('dlv_batch_all'), _batch == null, () => setState(() => _batch = null)),
        for (final b in _batches)
          chip(
            b['label']?.toString() ?? '',
            _batch == (b['key'] as num?)?.toInt(),
            () => setState(() => _batch = (b['key'] as num?)?.toInt()),
          ),
      ]),
    );
  }

  Widget _stopRow(Map<String, dynamic> s) {
    final actions = s['actions'] is Map
        ? Map<String, dynamic>.from(s['actions'] as Map)
        : const <String, dynamic>{};
    final imageUrl = s['image_url']?.toString() ?? '';
    final canDeliver = s['can_deliver'] == true;
    final needsResponse = s['needs_response'] == true;

    final colors = s['status_colors'] is Map
        ? Map<String, dynamic>.from(s['status_colors'] as Map)
        : const <String, dynamic>{};
    final statusLabel = s['status_label']?.toString() ?? '';

    final call = actions['call_number']?.toString() ?? '';
    final wa = actions['whatsapp_number']?.toString() ?? '';
    final dir = actions['directions_url']?.toString() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: needsResponse ? _kGreen : _kBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((s['seq'] as num?) != null)
            Container(
              width: 24, height: 24,
              margin: const EdgeInsets.only(right: 8, top: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _hex(s['pin_color']?.toString()) ?? _kBorder,
                shape: BoxShape.circle,
              ),
              child: Text('${(s['seq'] as num).toInt()}',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
            ),
          if (imageUrl.isNotEmpty) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                imageUrl,
                width: 44, height: 44, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(width: 44, height: 44),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s['pharmacy_name']?.toString() ?? '',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
              if ((s['address']?.toString() ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(s['address']!.toString(),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: _kSub)),
              ],
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(s['total_display']?.toString() ?? '',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            Text('${(s['item_count'] as num?)?.toInt() ?? 0}',
                style: TextStyle(fontSize: 11, color: _kSub)),
          ]),
        ]),

        if (statusLabel.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _hex(colors['bg']?.toString()) ?? Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(statusLabel,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: _hex(colors['fg']?.toString()) ?? _kText)),
            ),
          ),
        ],

        // B5 — prominent, and also reachable from the row itself.
        if (needsResponse) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kGreen,
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  await _respond(s, 'accept', '');
                  await _load();
                },
                child: Text(_ui('dlv_accept')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFB42318),
                  side: BorderSide(color: _kBorder),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () async {
                  await _respond(s, 'reject', '');
                  await _load();
                },
                child: Text(_ui('dlv_reject')),
              ),
            ),
          ]),
        ],

        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (call.isNotEmpty)
            _actionBtn(Icons.call_outlined, _ui('dlv_call'), () => _open('tel:$call')),
          if (wa.isNotEmpty)
            // The 91 prefix is the wa.me URL's country segment, per the spec's
            // own contract for this action — a URL, not a label on screen.
            _actionBtn(Icons.chat_outlined, _ui('dlv_whatsapp'),
                () => _open('https://wa.me/91$wa')),
          if (dir.isNotEmpty)
            _actionBtn(Icons.directions_outlined, _ui('dlv_directions'), () => _open(dir)),
        ]),

        // B4 — only when the backend says so.
        if (canDeliver) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onPressed: () => _deliver(s),
              child: Text(_ui('dlv_mark_delivered'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: _kText,
        side: BorderSide(color: _kBorder),
        visualDensity: VisualDensity.compact,
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12.5)),
    );
  }
}
