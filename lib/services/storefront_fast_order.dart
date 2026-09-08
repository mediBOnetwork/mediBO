// CMD #409 — the three fast-ordering paths, in ONE service.
//
// Barcode scan-to-cart, voice search and recently-viewed all do the same two
// things and nothing else: call a backend RPC and hand back what it said. Every
// title, message and hint below is a FIELD on the payload — there is not one
// display string in this file, and there must never be one. A miss, a refusal
// and a silence all arrive already worded.
import 'dart:convert';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// What a scan resolved to. `ok` false is a normal outcome, not an exception:
/// an unknown barcode, an off-sale product and an empty read each arrive with
/// their own [title] and [message] from `storefront_ui_label`.
class ScanResult {
  final bool ok;
  final String error;
  final String title;
  final String message;
  final String hint;
  final String barcode;
  final String productId;

  /// The SAME card block every storefront rail renders (`_sf_cards`), so the
  /// sheet shows the real price, the real availability and the real ADD pill.
  final Map<String, dynamic>? card;

  const ScanResult({
    required this.ok,
    this.error = '',
    this.title = '',
    this.message = '',
    this.hint = '',
    this.barcode = '',
    this.productId = '',
    this.card,
  });

  static ScanResult fromMap(Map<String, dynamic> m) => ScanResult(
        ok: m['ok'] == true,
        error: m['error']?.toString() ?? '',
        title: m['title']?.toString() ?? '',
        message: m['message']?.toString() ?? '',
        hint: m['hint']?.toString() ?? '',
        barcode: m['barcode']?.toString() ?? '',
        productId: m['product_id']?.toString() ?? '',
        card: m['card'] is Map
            ? Map<String, dynamic>.from(m['card'] as Map)
            : null,
      );
}

/// The mic sheet's whole contract: which language to ask for, how long it may
/// listen, and every word it prints.
class VoiceSearchConfig {
  final String lang;
  final int maxSeconds;
  final String title;
  final String hint;
  final String listening;
  final String working;
  final String stopLabel;
  final String cancelLabel;
  final String deniedTitle;
  final String deniedMessage;
  final String errorMessage;

  const VoiceSearchConfig({
    this.lang = 'en-IN',
    this.maxSeconds = 8,
    this.title = '',
    this.hint = '',
    this.listening = '',
    this.working = '',
    this.stopLabel = '',
    this.cancelLabel = '',
    this.deniedTitle = '',
    this.deniedMessage = '',
    this.errorMessage = '',
  });

  static const VoiceSearchConfig none = VoiceSearchConfig();

  static VoiceSearchConfig fromMap(Map<String, dynamic> m) => VoiceSearchConfig(
        lang: m['lang']?.toString() ?? 'en-IN',
        maxSeconds: (m['max_seconds'] as num?)?.toInt() ?? 8,
        title: m['title']?.toString() ?? '',
        hint: m['hint']?.toString() ?? '',
        listening: m['listening']?.toString() ?? '',
        working: m['working']?.toString() ?? '',
        stopLabel: m['stop_label']?.toString() ?? '',
        cancelLabel: m['cancel_label']?.toString() ?? '',
        deniedTitle: m['denied_title']?.toString() ?? '',
        deniedMessage: m['denied_message']?.toString() ?? '',
        errorMessage: m['error_message']?.toString() ?? '',
      );
}

/// What the mic heard, after the backend applied the counting vocabulary.
class VoiceSearchResult {
  final bool ok;
  final String error;
  final String query;
  final String transcript;
  final String heardLabel;
  final String message;

  const VoiceSearchResult({
    required this.ok,
    this.error = '',
    this.query = '',
    this.transcript = '',
    this.heardLabel = '',
    this.message = '',
  });

  static VoiceSearchResult fromMap(Map<String, dynamic> m) => VoiceSearchResult(
        ok: m['ok'] == true,
        error: m['error']?.toString() ?? '',
        query: m['query']?.toString() ?? '',
        transcript: m['transcript']?.toString() ?? '',
        heardLabel: m['heard_label']?.toString() ?? '',
        message: m['message']?.toString() ?? '',
      );
}

/// The recently-viewed rail. `has` is the BACKEND's answer to "is there
/// anything to show" — the app never infers it from the list length, because
/// the backend applies availability after it picks the ids.
class RecentRail {
  final bool has;
  final String title;
  final String accentWord;
  final String subtitle;
  final List<Map<String, dynamic>> items;

  const RecentRail({
    this.has = false,
    this.title = '',
    this.accentWord = '',
    this.subtitle = '',
    this.items = const [],
  });

  static const RecentRail none = RecentRail();

  static RecentRail fromMap(Map<String, dynamic> m) => RecentRail(
        has: m['has'] == true,
        title: m['title']?.toString() ?? '',
        accentWord: m['accent_word']?.toString() ?? '',
        subtitle: m['subtitle']?.toString() ?? '',
        items: (m['items'] as List?)
                ?.whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(growable: false) ??
            const [],
      );
}

class StorefrontFastOrder {
  StorefrontFastOrder._();

  static SupabaseClient get _db => Supabase.instance.client;

  /// A scanned code, resolved by the backend. The camera reads bytes; which
  /// product they mean — and whether this viewer may buy it — is decided in
  /// `storefront_barcode_resolve`.
  static Future<ScanResult> resolveBarcode(String code) async {
    final res =
        await _db.rpc('storefront_barcode_resolve', params: {'p_barcode': code});
    return ScanResult.fromMap(Map<String, dynamic>.from(res as Map));
  }

  static Future<VoiceSearchConfig> voiceConfig() async {
    final res = await _db.rpc('voice_search_config');
    return VoiceSearchConfig.fromMap(Map<String, dynamic>.from(res as Map));
  }

  /// The clip goes to the SAME edge function warehouse counting uses, in its
  /// `search` mode; the transcript that comes back is then corrected against
  /// the SAME medicine vocabulary counting was taught.
  static Future<VoiceSearchResult> transcribeSearch(
    Uint8List bytes,
    String mime, {
    required String lang,
  }) async {
    final res = await _db.functions.invoke('voice-receive', body: {
      'mode': 'search',
      'lang': lang,
      'mime_type': mime,
      'audio_base64': base64Encode(bytes),
    });
    final data = res.data;
    final heard = (data is Map ? data['query'] : null)?.toString() ?? '';
    return resolveVoiceQuery(heard, lang: lang);
  }

  /// Split out so a test can drive the vocabulary path with no audio and no
  /// edge function — the transcript is the only input that matters.
  static Future<VoiceSearchResult> resolveVoiceQuery(
    String transcript, {
    required String lang,
  }) async {
    final res = await _db.rpc('voice_search_resolve',
        params: {'p_transcript': transcript, 'p_lang': lang});
    return VoiceSearchResult.fromMap(Map<String, dynamic>.from(res as Map));
  }

  /// One product open. Fire-and-forget on purpose: a customer must never wait
  /// on, or be shown an error from, their own view history.
  static Future<void> recordView(String productId) async {
    final id = int.tryParse(productId);
    if (id == null) return;
    try {
      await _db.rpc('recently_viewed_record', params: {'p_product_id': id});
    } catch (_) {
      // History is a convenience. It never interrupts the product page.
    }
  }

  static Future<RecentRail> recentRail({int limit = 12}) async {
    try {
      final res =
          await _db.rpc('recently_viewed_rail', params: {'p_limit': limit});
      return RecentRail.fromMap(Map<String, dynamic>.from(res as Map));
    } catch (_) {
      return RecentRail.none;
    }
  }
}
