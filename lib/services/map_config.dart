// lib/services/map_config.dart — CHANGE #634
//
// ONE backend-owned answer to "how do I draw a map?", for every map surface in
// the app. Before this file, five map screens each carried their own provider
// choice and their own API key, so one misconfigured key broke all five at once
// in five different places.
//
// THE APP RENDERS, IT NEVER DECIDES: nothing here picks a provider, a tile
// server, a key, a centre or a zoom. Every one of those values is read verbatim
// from map_config_get(). Switching the whole app from OSM tiles to the Google
// JS API is an UPDATE on the config row — no rebuild, no deploy.
//
// Fetched ONCE per session and cached (A3). Concurrent callers share the same
// in-flight future, so five maps opening at once still make one RPC.

import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

class MapConfig {
  /// 'osm' | 'google' | anything the backend adds later. Never branched on in
  /// Dart — [usesGoogleJs] is the boolean the backend computed for us.
  final String provider;

  /// The ONLY thing that selects a render path. A backend boolean, not an
  /// inference from [provider].
  final bool usesGoogleJs;

  /// Injected into the Maps JS loader when [usesGoogleJs] is true. Empty on the
  /// tile path — there is nothing to key.
  final String browserKey;

  final String tileUrl;
  final String tileUrlRetina;
  final String attribution;
  final double maxZoom;
  final double defaultLat;
  final double defaultLng;
  final double defaultZoom;

  /// A7 — the copy a map prints when it has no coordinates to plot, for
  /// surfaces that have no empty state of their own. Backend text; changing it
  /// is an UPDATE on map_config, not a deploy.
  final String emptyLabel;

  /// Keyless Google Maps deep link, e.g.
  /// https://www.google.com/maps/dir/?api=1&destination={lat},{lng}
  /// This is why Directions kept working while tiles failed — it never touches
  /// the JS API. See [navUrl].
  final String navDeeplinkTemplate;

  /// Keyless "show me this point" link (as opposed to turn-by-turn), e.g.
  /// https://www.google.com/maps?q={lat},{lng}. Same reasoning as
  /// [navDeeplinkTemplate]: it deep-links to the Google Maps app and never
  /// touches the Maps JavaScript API. See [pointUrl].
  final String pointDeeplinkTemplate;

  const MapConfig({
    required this.provider,
    required this.usesGoogleJs,
    required this.browserKey,
    required this.tileUrl,
    required this.tileUrlRetina,
    required this.attribution,
    required this.maxZoom,
    required this.defaultLat,
    required this.defaultLng,
    required this.defaultZoom,
    required this.emptyLabel,
    required this.navDeeplinkTemplate,
    required this.pointDeeplinkTemplate,
  });

  static double _d(dynamic v, double fallback) =>
      (v is num) ? v.toDouble() : (double.tryParse('$v') ?? fallback);

  /// Parses the map_config_get() payload. The `?? ''` / `?? 0` guards are NOT
  /// fallback decisions — they exist only because a JSON field can arrive
  /// absent during a backend deploy, and a map that throws is worse than a map
  /// that draws nothing. Every real value comes from the row.
  factory MapConfig.fromJson(Map<String, dynamic> j) {
    final center = (j['default_center'] as Map?) ?? const {};
    return MapConfig(
      provider: j['provider']?.toString() ?? '',
      usesGoogleJs: j['uses_google_js'] == true,
      browserKey: j['browser_key']?.toString() ?? '',
      tileUrl: j['tile_url']?.toString() ?? '',
      tileUrlRetina: j['tile_url_retina']?.toString() ?? '',
      attribution: j['attribution']?.toString() ?? '',
      maxZoom: _d(j['max_zoom'], 19),
      defaultLat: _d(center['lat'], 0),
      defaultLng: _d(center['lng'], 0),
      defaultZoom: _d(j['default_zoom'], 12),
      emptyLabel: j['empty_label']?.toString() ?? '',
      navDeeplinkTemplate: j['nav_deeplink_template']?.toString() ?? '',
      pointDeeplinkTemplate: j['point_deeplink_template']?.toString() ?? '',
    );
  }

  bool get hasTiles => tileUrl.isNotEmpty;

  /// A5 — the directions URL, built from the backend template. KEYLESS by
  /// construction: the only thing substituted is the destination coordinate.
  /// Returns '' when the backend sent no template, so callers hide the button
  /// rather than open a URL this file invented.
  String navUrl(double lat, double lng) => _fill(navDeeplinkTemplate, lat, lng);

  /// A5 — the "view this location" URL, same keyless construction as [navUrl].
  String pointUrl(double lat, double lng) => _fill(pointDeeplinkTemplate, lat, lng);

  static String _fill(String template, double lat, double lng) {
    if (template.isEmpty) return '';
    return template
        .replaceAll('{lat}', lat.toString())
        .replaceAll('{lng}', lng.toString());
  }
}

class MapConfigService {
  MapConfigService._();

  static MapConfig? _cached;
  static Future<MapConfig>? _inFlight;

  /// The config, if it has already landed. Null means "not fetched yet" — a
  /// caller seeing null must WAIT (see [load]), never substitute its own
  /// provider or key.
  static MapConfig? get cached => _cached;

  /// Fetch-once-per-session. Every concurrent caller shares one RPC.
  static Future<MapConfig> load() {
    final c = _cached;
    if (c != null) return Future<MapConfig>.value(c);
    return _inFlight ??= _fetch();
  }

  static Future<MapConfig> _fetch() async {
    try {
      final res = await Supabase.instance.client
          .rpc('map_config_get')
          .timeout(const Duration(seconds: 12));
      final cfg = MapConfig.fromJson(Map<String, dynamic>.from(res as Map));
      _cached = cfg;
      // Written here, not in a map widget, so a curl of /render-log proves the
      // one config landed even on a session that never opens a map screen.
      RenderLog.write('c634_map_config', cfg.provider);
      RenderLog.write('c634_map_google_js', cfg.usesGoogleJs ? 1 : 0);
      return cfg;
    } catch (e) {
      // Do not cache a failure — the next map to mount retries.
      _inFlight = null;
      RenderLog.write('c634_map_config', 'error');
      rethrow;
    } finally {
      if (_cached != null) _inFlight = null;
    }
  }

  /// Cleared on auth change alongside the rest of the account state, so an
  /// account switch can never render on the previous session's config.
  static void clear() {
    _cached = null;
    _inFlight = null;
  }
}
