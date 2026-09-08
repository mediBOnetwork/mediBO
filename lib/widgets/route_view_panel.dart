// lib/widgets/route_view_panel.dart — CMD #1917
//
// ONE route component. Today and All plans render THIS widget; there is no
// second implementation of a route card, a stop row, a jump chip or a map any
// more, which is why the two screens can no longer drift apart.
//
// Everything drawn here comes from route_view(route_id): the header (title,
// worker chip, cost chips, warnings, Assign / Message stops / Navigate), the
// map payload, the "Stops 1–10 / 11–20 / 21–25" windows and the stop rows.
// Every stop carries the SAME five actions on both screens — Call, WhatsApp,
// Navigate, Check in, Import customer — with the backend's own labels, its own
// URIs and its own enabled flag. This file composes no display string and
// builds no URI.
//
// THE MAP IS CREATED ONCE PER ROUTE AND KEPT ALIVE:
//   • the payload (polyline, pins, tile config) is cached per route_id for 24h
//     in [RouteViewStore] and reused by BOTH screens;
//   • the live map widget is held by a GlobalKey keyed on the route id, so
//     moving between Today and All plans REPARENTS the same map element
//     instead of building a new one;
//   • tapping only RESIZES it between mini (map_mini_h) and large
//     (map_large_vh × viewport) — it never closes, never rebuilds, and is
//     never disposed on collapse;
//   • a real load is counted server-side by route_map_loaded(), so "the map
//     loaded once for this route" is a number, not a claim.
// A rebuild happens for exactly one reason: the stop ORDER changed, which the
// backend reports as a new stop_signature.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';
import '../screens/admin/route_stop_checkin_sheet.dart'
    show RouteStopCheckInPlan, RouteStopMenuSheet, routeStopToneSoft;
import '../utils/render_log.dart';
import 'native_signed_image.dart';
import 'route_google_map_panel.dart';

/// One cached route_view() payload.
class _RouteViewEntry {
  final Map<String, dynamic> data;
  final DateTime at;
  const _RouteViewEntry(this.data, this.at);
}

/// The 24h per-route cache, shared by every screen in the app.
///
/// The cache is a RENDER fallback, never an authority: a panel always paints
/// the cached payload first and refetches in the background, then repaints.
class RouteViewStore {
  RouteViewStore._();

  static const Duration ttl = Duration(hours: 24);

  static final Map<String, _RouteViewEntry> _cache = {};

  /// route_id -> the GlobalKey that owns that route's ONE live map element.
  static final Map<String, GlobalKey> _mapKeys = {};

  /// route_id -> how many times a map was actually built for it in this app
  /// session. Mirrors route_map_load on the server; surfaced in the render log
  /// so a live check can read it.
  static final Map<String, int> mapLoads = {};

  /// route_id -> the stop_signature the live map was built from. A different
  /// signature is the ONLY thing that rebuilds a map.
  static final Map<String, String> _mapSignature = {};

  static Map<String, dynamic>? peek(String routeId) {
    final e = _cache[routeId];
    if (e == null) return null;
    if (DateTime.now().difference(e.at) > ttl) {
      _cache.remove(routeId);
      return null;
    }
    return e.data;
  }

  static void put(String routeId, Map<String, dynamic> data) =>
      _cache[routeId] = _RouteViewEntry(data, DateTime.now());

  static void invalidate(String routeId) => _cache.remove(routeId);

  static GlobalKey mapKey(String routeId) =>
      _mapKeys.putIfAbsent(routeId, () => GlobalKey());

  /// Called the first time a map element is actually created for [routeId],
  /// or when the stop order forced a rebuild. Counts the load on the server
  /// so the cost is visible outside this session too.
  static void countMapLoad(String routeId, String screen, String signature) {
    final prev = _mapSignature[routeId];
    if (prev == signature && mapLoads.containsKey(routeId)) return;
    _mapSignature[routeId] = signature;
    mapLoads[routeId] = (mapLoads[routeId] ?? 0) + 1;
    RenderLog.write('c1917_map_loads', mapLoads[routeId]!);
    RenderLog.write('c1917_map_load_route', routeId);
    // Fire-and-forget, and never allowed to matter: a map that draws is worth
    // more than a counter that lands, so every failure path here is silent.
    try {
      Supabase.instance.client
          .rpc('route_map_loaded',
              params: {'p_route_id': routeId, 'p_screen': screen})
          .catchError((_) => null);
    } catch (_) {
      // No Supabase (a widget test), no session, no network — the local count
      // in [mapLoads] and the render log still tell the truth.
    }
  }

  /// A new stop order invalidates the payload AND the map for that route.
  static void orderChanged(String routeId) {
    _cache.remove(routeId);
    _mapSignature.remove(routeId);
  }
}

/// Everything the host screen still owns: the sheets, the writes and the
/// refreshes. Both screens hand the panel the SAME set, which is what makes
/// "the same actions on both screens" true rather than aspirational.
class RouteViewActions {
  final Future<void> Function(String routeId, String stopId) onCheckIn;
  final Future<void> Function(
      String routeId, String stopId, Map<String, dynamic> entry) onSkip;
  final Future<void> Function(String routeId, List<String> stopIds) onReorder;
  final Future<void> Function(String routeId, int leadId) onImportCustomer;
  final Future<void> Function(Map<String, dynamic> route)? onAssign;
  final Future<void> Function(Map<String, dynamic> route)? onMessageStops;

  const RouteViewActions({
    required this.onCheckIn,
    required this.onSkip,
    required this.onReorder,
    required this.onImportCustomer,
    this.onAssign,
    this.onMessageStops,
  });
}

class RouteViewPanel extends StatefulWidget {
  final String routeId;
  final bool isDesktop;

  /// 'today' or 'all_plans' — recorded with the map-load count so the cost is
  /// attributable to the screen that paid it. Not a display string.
  final String screen;

  final RouteViewActions actions;

  /// Extra controls the host screen owns (All plans' two Optimize buttons).
  /// Drawn directly above the map, inside the same card.
  final Widget? headerExtras;

  /// Live worker dots for the map, straight from route_worker_dots().
  final List<Map<String, dynamic>> workers;

  /// Starts large instead of mini. Today's assigned route opens large; a route
  /// expanded on All plans opens mini.
  final bool startLarge;

  const RouteViewPanel({
    super.key,
    required this.routeId,
    required this.isDesktop,
    required this.screen,
    required this.actions,
    this.headerExtras,
    this.workers = const [],
    this.startLarge = false,
  });

  /// Every mounted panel for [routeId] refetches. Used after a check-in, a
  /// skip or a reorder, so the two screens can never show different answers.
  static void refresh(String routeId) {
    RouteViewStore.invalidate(routeId);
    for (final s in _RouteViewPanelState._live) {
      if (s.widget.routeId == routeId) s._load(force: true);
    }
  }

  @override
  State<RouteViewPanel> createState() => _RouteViewPanelState();
}

class _RouteViewPanelState extends State<RouteViewPanel> {
  static final Set<_RouteViewPanelState> _live = {};

  Map<String, dynamic>? _data;
  bool _loading = false;
  int _window = 0;
  late bool _large = widget.startLarge;

  @override
  void initState() {
    super.initState();
    _live.add(this);
    _data = RouteViewStore.peek(widget.routeId);
    _load();
  }

  @override
  void dispose() {
    _live.remove(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RouteViewPanel old) {
    super.didUpdateWidget(old);
    if (old.routeId != widget.routeId) {
      _window = 0;
      _data = RouteViewStore.peek(widget.routeId);
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    if (_loading) return;
    if (!force && _data != null) {
      // Cached payload is already on screen; refetch quietly behind it.
    }
    setState(() => _loading = _data == null);
    try {
      final res = await Supabase.instance.client
          .rpc('route_view', params: {'p_route_id': widget.routeId});
      if (!mounted) return;
      final m =
          res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      RouteViewStore.put(widget.routeId, m);
      setState(() {
        _data = m;
        _loading = false;
      });
      RenderLog.write('c1917_route_view', (m['stops'] as List?)?.length ?? 0);
      RenderLog.write('c1917_screen', widget.screen);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Map<String, dynamic> get _header {
    final h = _data?['header'];
    return h is Map ? Map<String, dynamic>.from(h) : <String, dynamic>{};
  }

  List<Map<String, dynamic>> get _stops =>
      ((_data?['stops'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _windows =>
      ((_data?['windows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  String _s(String key) => _data?[key]?.toString() ?? '';

  double _num(String key, double fallback) {
    final v = _data?[key];
    return v is num ? v.toDouble() : fallback;
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
        child: Center(
          child: SizedBox(
            width: Ds.space.x24,
            height: Ds.space.x24,
            child: CircularProgressIndicator(
                color: Ds.c.brand, strokeWidth: Ds.space.hairline * 2),
          ),
        ),
      );
    }
    if (data['ok'] != true) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Text(_s('empty_label'), style: Ds.t.bodySecondary),
      );
    }
    RenderLog.write('c1917_panel', widget.screen);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _buildHeader(),
        if (widget.headerExtras != null) ...[
          SizedBox(height: Ds.space.x12),
          widget.headerExtras!,
        ],
        SizedBox(height: Ds.space.x16),
        _buildMap(),
        SizedBox(height: Ds.space.x16),
        _buildWindows(),
        _buildStops(),
      ]),
    );
  }

  // ── Header: title, worker, cost, warnings, Assign / Message / Navigate ──

  Widget _buildHeader() {
    final h = _header;
    final worker = h['worker_label']?.toString() ?? '';
    final assigned = h['assigned'] == true;
    final assignLabel = h['assign_label']?.toString() ?? '';
    final msgLabel = h['msg_stops_label']?.toString() ?? '';
    final dayWarning = h['day_warning']?.toString() ?? '';
    final closed = h['closed_label']?.toString() ?? '';
    final next = h['next_label']?.toString() ?? '';
    final nextSub = h['next_sub']?.toString() ?? '';
    final navUri = h['nav_uri']?.toString() ?? '';
    final canNav = h['can_navigate'] == true && navUri.isNotEmpty;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Text(h['title']?.toString() ?? '',
              style: Ds.t.subtitle, overflow: TextOverflow.ellipsis),
        ),
        if (assigned && worker.isNotEmpty)
          _chip(worker, Ds.c.infoSoft)
        else if (!assigned && h['can_assign'] == true && assignLabel.isNotEmpty)
          TextButton.icon(
            onPressed: widget.actions.onAssign == null
                ? null
                : () => widget.actions.onAssign!(_routeRow()),
            icon: Icon(Icons.person_add_alt_1, size: Ds.space.x16),
            label: Text(assignLabel, style: Ds.t.caption),
          ),
      ]),
      SizedBox(height: Ds.space.x4),
      Text(h['subtitle']?.toString() ?? '', style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
        if ((h['cost_label']?.toString() ?? '').isNotEmpty)
          _chip(h['cost_label'].toString(), Ds.c.brandSoft),
        if ((h['converted_label']?.toString() ?? '').isNotEmpty)
          _chip(h['converted_label'].toString(), Ds.c.successSoft),
        if ((h['cost_per_converted_label']?.toString() ?? '').isNotEmpty)
          _chip(h['cost_per_converted_label'].toString(), Ds.c.bg),
      ]),
      if (dayWarning.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        _chip(dayWarning, Ds.c.warningSoft),
      ],
      if (closed.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        _chip(closed, Ds.c.dangerSoft),
      ],
      SizedBox(height: Ds.space.x12),
      Text(h['progress_label']?.toString() ?? '', style: Ds.t.bodyStrong),
      if (next.isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(next, style: Ds.t.body, overflow: TextOverflow.ellipsis),
        if (nextSub.isNotEmpty)
          Text(nextSub, style: Ds.t.caption, overflow: TextOverflow.ellipsis),
      ],
      SizedBox(height: Ds.space.x12),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: ElevatedButton.icon(
              onPressed: canNav
                  ? () => launchUrl(Uri.parse(navUri),
                      mode: LaunchMode.externalApplication)
                  : null,
              icon: const Icon(Icons.navigation_rounded),
              label: Text(h['nav_label']?.toString() ?? '',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        if (msgLabel.isNotEmpty && widget.actions.onMessageStops != null) ...[
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: () => widget.actions.onMessageStops!(_routeRow()),
                icon: Icon(Icons.campaign_outlined, size: Ds.space.x16),
                label: Text(msgLabel,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ),
          ),
        ],
      ]),
    ]);
  }

  /// The shape the host screens' own sheets (Assign, Message stops) already
  /// take — route_id plus the header, so nothing there needed rewriting.
  Map<String, dynamic> _routeRow() => {
        'route_id': widget.routeId,
        'plan_id': _data?['plan_id'],
        ..._header,
      };

  Widget _chip(String label, Color bg) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(label, style: Ds.t.caption),
      );

  // ── Map: one instance per route, resized, never rebuilt ────────────────

  Widget _buildMap() {
    final map = _data?['map'];
    if (map is! Map || map['error'] != null) {
      return SizedBox(
        height: _num('map_mini_h', 180),
        child: Center(
            child: Text(_s('map_empty_label'), style: Ds.t.bodySecondary)),
      );
    }
    final mapData = Map<String, dynamic>.from(map);
    final signature = _s('stop_signature');
    RouteViewStore.countMapLoad(widget.routeId, widget.screen, signature);

    final mini = _num('map_mini_h', 180);
    final large = MediaQuery.of(context).size.height * _num('map_large_vh', 0.6);
    final h = _large ? large : mini;
    final hint =
        _large ? _s('map_collapse_label') : _s('map_expand_label');

    // ONE map element for this route, addressed by a GlobalKey. Moving
    // between Today and All plans reparents it; changing `height` only
    // resizes the box around it.
    final panel = RouteGoogleMapPanel(
      key: RouteViewStore.mapKey(widget.routeId),
      mapData: mapData,
      isDesktop: widget.isDesktop,
      height: h,
      workers: widget.workers,
      onTapStop: (_) => setState(() => _large = !_large),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if ((mapData['label']?.toString() ?? '').isNotEmpty)
        Text(mapData['label'].toString(), style: Ds.t.bodyStrong),
      if ((mapData['summary']?.toString() ?? '').isNotEmpty)
        Text(mapData['summary'].toString(), style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      Stack(children: [
        AnimatedSize(
          duration: Ds.motion.standard,
          curve: Ds.motion.curve,
          alignment: Alignment.topCenter,
          child: panel,
        ),
        // Mini is a PREVIEW: the whole surface is one tap target that
        // enlarges it. Large is the live map, with a corner control that
        // shrinks it again. Neither path ever removes the map.
        if (!_large)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _large = true),
            ),
          ),
        Positioned(
          right: Ds.space.x8,
          top: Ds.space.x8,
          child: Material(
            color: Ds.c.surface,
            borderRadius: Ds.r.rChip,
            child: InkWell(
              borderRadius: Ds.r.rChip,
              onTap: () => setState(() => _large = !_large),
              child: Padding(
                padding: EdgeInsets.all(Ds.space.x8),
                child: Icon(
                    _large
                        ? Icons.close_fullscreen_rounded
                        : Icons.open_in_full_rounded,
                    size: Ds.space.x16,
                    color: Ds.c.text),
              ),
            ),
          ),
        ),
      ]),
      if (hint.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(hint, style: Ds.t.caption),
      ],
      _buildLegs(mapData),
    ]);
  }

  Widget _buildLegs(Map<String, dynamic> mapData) {
    final legs = ((mapData['legs'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (legs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8),
      child: Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: legs.map((leg) {
          final url = leg['url']?.toString() ?? '';
          return OutlinedButton(
            onPressed: url.isEmpty
                ? null
                : () => launchUrl(Uri.parse(url),
                    mode: LaunchMode.externalApplication),
            child: Text(leg['label']?.toString() ?? '', style: Ds.t.caption),
          );
        }).toList(),
      ),
    );
  }

  // ── Jump chips: "Stops 1–10 / 11–20 / 21–25", sized by the backend ─────

  Widget _buildWindows() {
    final w = _windows;
    if (w.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c1917_windows', w.length);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final win in w)
            _segBtn(win['label']?.toString() ?? '',
                (win['index'] as num?)?.toInt() == _window,
                () => setState(
                    () => _window = (win['index'] as num?)?.toInt() ?? 0)),
        ],
      ),
    );
  }

  Widget _segBtn(String label, bool on, VoidCallback onTap) => SizedBox(
        height: Ds.touch.minTarget,
        child: on
            ? FilledButton(onPressed: onTap, child: Text(label))
            : OutlinedButton(onPressed: onTap, child: Text(label)),
      );

  // ── Stops ───────────────────────────────────────────────────────────────

  /// The index in the full active list that the current window starts at.
  int _windowOffset() {
    final w = _windows;
    if (w.isEmpty) return 0;
    final sel = w.firstWhere((e) => (e['index'] as num?)?.toInt() == _window,
        orElse: () => w.first);
    return ((sel['from'] as num?)?.toInt() ?? 1) - 1;
  }

  List<Map<String, dynamic>> _inWindow(List<Map<String, dynamic>> rows) {
    final w = _windows;
    if (w.isEmpty) return rows;
    final sel = w.firstWhere(
        (e) => (e['index'] as num?)?.toInt() == _window,
        orElse: () => w.first);
    final from = ((sel['from'] as num?)?.toInt() ?? 1) - 1;
    final to = (sel['to'] as num?)?.toInt() ?? rows.length;
    if (from >= rows.length) return rows;
    return rows.sublist(from, to > rows.length ? rows.length : to);
  }

  Widget _buildStops() {
    final all = _stops;
    final active = all.where((s) => s['skipped'] != true).toList();
    final parked = all.where((s) => s['skipped'] == true).toList();
    final canReorder = _data?['can_reorder'] == true;
    final visible = _inWindow(active);
    // A windowed list still drags: the row's index is window-local, so the
    // window's own offset is added back before the whole order is posted.
    final offset = _windowOffset();
    final hint = _s('reorder_hint');
    final empty = _s('empty_label');

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(_s('stops_title'), style: Ds.t.subtitle)),
        Text(_s('count_label'), style: Ds.t.caption),
      ]),
      if (hint.isNotEmpty && canReorder) ...[
        SizedBox(height: Ds.space.x4),
        Text(hint, style: Ds.t.caption),
      ],
      if (all.isEmpty && empty.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Text(empty, style: Ds.t.bodySecondary),
      ],
      if (visible.isNotEmpty)
        canReorder
            ? ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                padding: EdgeInsets.only(top: Ds.space.x12),
                itemCount: visible.length,
                onReorder: (o, n) =>
                    _reorder(active, o + offset, n + offset),
                proxyDecorator: (child, _, _) =>
                    Material(type: MaterialType.transparency, child: child),
                itemBuilder: (_, i) => Padding(
                  key: ValueKey(visible[i]['stop_id']?.toString() ?? '$i'),
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: _stopRow(visible[i], index: i, canReorder: true),
                ),
              )
            : Padding(
                padding: EdgeInsets.only(top: Ds.space.x12),
                child: Column(
                  children: [
                    for (final s in visible)
                      Padding(
                        padding: EdgeInsets.only(bottom: Ds.space.x12),
                        child: _stopRow(s),
                      ),
                  ],
                ),
              ),
      for (final s in parked) ...[
        SizedBox(height: Ds.space.x12),
        _stopRow(s),
      ],
    ]);
  }

  Future<void> _reorder(
      List<Map<String, dynamic>> active, int oldIndex, int newIndex) async {
    final moved = RouteStopCheckInPlan.move(active, oldIndex, newIndex);
    final ids = moved
        .map((e) => e['stop_id']?.toString() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    RouteViewStore.orderChanged(widget.routeId);
    await widget.actions.onReorder(widget.routeId, ids);
    RouteViewPanel.refresh(widget.routeId);
  }

  /// ONE stop row. Both screens get this exact widget: photo, name, address,
  /// score chip, status chip and the five actions.
  Widget _stopRow(Map<String, dynamic> st,
      {int? index, bool canReorder = false}) {
    final stopId = st['stop_id']?.toString() ?? '';
    final skipped = st['skipped'] == true;
    final photoUrl = st['photo_url']?.toString() ?? '';
    final scoreLabel = st['score_label']?.toString() ?? '';
    final eta = st['eta_label']?.toString() ?? '';
    final closed = st['closed_label']?.toString() ?? '';
    final skippedLabel = st['skipped_label']?.toString() ?? '';
    final note = st['note_label']?.toString() ?? '';
    final actions = ((st['actions'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final photoH = widget.isDesktop ? Ds.space.x48 * 3.5 : Ds.space.x48 * 2.9;

    final card = Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: st['is_closed_at_eta'] == true ? Ds.c.dangerSoft : Ds.c.bg,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider, width: Ds.space.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Photo, with the sequence badge and the score chip over it.
        SizedBox(
          height: photoH,
          width: double.infinity,
          child: Stack(fit: StackFit.expand, children: [
            if (photoUrl.isNotEmpty)
              NativeSignedImage(url: photoUrl, cacheKey: photoUrl)
            else
              Container(
                color: Ds.c.bg,
                child: Center(
                  child: Icon(Icons.storefront_outlined,
                      size: Ds.space.x32, color: Ds.c.textSecondary),
                ),
              ),
            Positioned(
              left: Ds.space.x8,
              bottom: Ds.space.x8,
              child: _chip(st['seq_label']?.toString() ?? '',
                  skipped ? Ds.c.bg : Ds.c.brandSoft),
            ),
            if (scoreLabel.isNotEmpty)
              Positioned(
                right: Ds.space.x8,
                top: Ds.space.x8,
                child: _chip(scoreLabel, Ds.c.surface),
              ),
          ]),
        ),
        Padding(
          padding: EdgeInsets.all(Ds.space.x12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(st['name']?.toString() ?? '',
                          style: Ds.t.bodyStrong,
                          overflow: TextOverflow.ellipsis),
                      if ((st['address']?.toString() ?? '').isNotEmpty)
                        Text(st['address'].toString(),
                            style: Ds.t.caption,
                            overflow: TextOverflow.ellipsis),
                    ]),
              ),
              if (eta.isNotEmpty) Text(eta, style: Ds.t.caption),
            ]),
            SizedBox(height: Ds.space.x8),
            Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
              _chip(st['status_label']?.toString() ?? '',
                  routeStopToneSoft(st['status_tone']?.toString())),
              if (closed.isNotEmpty) _chip(closed, Ds.c.warningSoft),
              if (skippedLabel.isNotEmpty)
                _chip(skippedLabel, Ds.c.warningSoft),
            ]),
            if (note.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(note, style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            // THE five actions — same set, same order, both screens.
            Row(
              children: [
                for (final a in actions)
                  Expanded(child: _action(stopId, a)),
              ],
            ),
          ]),
        ),
      ]),
    );

    if (index == null) return card;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      if (canReorder)
        ReorderableDragStartListener(
          index: index,
          child: Padding(
            padding: EdgeInsets.only(right: Ds.space.x8),
            child: Icon(Icons.drag_indicator,
                size: Ds.space.x24, color: Ds.c.textSecondary),
          ),
        ),
      Expanded(
        child: GestureDetector(
          onLongPress: () => _openMenu(stopId, st),
          child: card,
        ),
      ),
    ]);
  }

  static const Map<String, IconData> _actionIcons = {
    'call': Icons.call,
    'whatsapp': Icons.chat,
    'navigate': Icons.navigation_outlined,
    'checkin': Icons.check_circle,
    'import_customer': Icons.person_add_alt_1,
  };

  Widget _action(String stopId, Map<String, dynamic> a) {
    final key = a['key']?.toString() ?? '';
    final enabled = a['enabled'] != false;
    final uri = a['uri']?.toString() ?? '';
    VoidCallback? tap;
    if (enabled) {
      switch (key) {
        case 'checkin':
          tap = () => widget.actions.onCheckIn(widget.routeId, stopId);
          break;
        case 'import_customer':
          final leadId = (a['lead_id'] as num?)?.toInt();
          if (leadId != null) {
            tap = () =>
                widget.actions.onImportCustomer(widget.routeId, leadId);
          }
          break;
        default:
          if (uri.isNotEmpty) {
            tap = () => launchUrl(Uri.parse(uri),
                mode: LaunchMode.externalApplication);
          }
      }
    }
    final on = tap != null;
    return Tooltip(
      message: a['reason']?.toString() ?? '',
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x4 / 2),
        child: InkWell(
          onTap: tap,
          borderRadius: Ds.r.rChip,
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
            decoration: BoxDecoration(
              color: on ? Ds.c.brandSoft : Ds.c.bg,
              borderRadius: Ds.r.rChip,
              border: Border.all(
                  color: on ? Ds.c.brand : Ds.c.divider,
                  width: Ds.space.hairline),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(_actionIcons[key] ?? Icons.circle_outlined,
                  size: Ds.space.x16,
                  color: on ? Ds.c.brand : Ds.c.textSecondary),
              SizedBox(height: Ds.space.x4 / 2),
              Text(a['label']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Ds.t.caption),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _openMenu(String stopId, Map<String, dynamic> st) async {
    final entry = await RouteStopMenuSheet.open(context, st);
    if (entry == null || !mounted) return;
    RouteViewStore.orderChanged(widget.routeId);
    await widget.actions.onSkip(widget.routeId, stopId, entry);
    RouteViewPanel.refresh(widget.routeId);
  }
}
