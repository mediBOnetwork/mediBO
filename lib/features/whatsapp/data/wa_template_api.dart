import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Data access for the WhatsApp template manager.
///
/// Every method here returns the backend payload UNTOUCHED. Nothing in this
/// file maps a status to a label, a tone to a colour, formats a date, or
/// assembles preview text — wa_templates_screen() and wa_template_preview()
/// already decided all of that. See CLAUDE.md: the app renders, it never
/// decides.
///
/// Both edge functions are called through supabase.functions.invoke, which
/// attaches the live session's JWT itself. They authorise admins internally.
class WaTemplateApi {
  WaTemplateApi._();

  /// Test seam, same shape as CartModel.rpcTransport: a widget test can feed a
  /// payload in without a network or a Supabase client.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic> params)?
      rpcTransport;

  /// Test seam for the two edge functions (wa-templates, wa-campaign-send).
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic> body)?
      fnTransport;

  // ── plumbing ───────────────────────────────────────────────────────────────

  /// An RPC returning `jsonb` arrives as a Map; one declared RETURNS TABLE
  /// arrives as a single-element List. Both shapes are normalised here so no
  /// caller has to know which it got.
  static Map<String, dynamic> _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    if (data is Map) return data.cast<String, dynamic>();
    return const <String, dynamic>{};
  }

  static Future<Map<String, dynamic>> _rpc(
    String fn, [
    Map<String, dynamic> params = const {},
  ]) async {
    final t = rpcTransport;
    if (t != null) return _asMap(await t(fn, params));
    return _asMap(
        await Supabase.instance.client.rpc(fn, params: params));
  }

  static Future<Map<String, dynamic>> _fn(
    String fn,
    Map<String, dynamic> body,
  ) async {
    final t = fnTransport;
    if (t != null) return _asMap(await t(fn, body));
    final res =
        await Supabase.instance.client.functions.invoke(fn, body: body);
    return _asMap(res.data);
  }

  // ── reads ──────────────────────────────────────────────────────────────────

  /// The whole screen in one payload: counts, chips, templates, starters,
  /// tokens, button_spec, categories, languages, alerts, copy, empty.
  static Future<Map<String, dynamic>> screen() => _rpc('wa_templates_screen');

  /// Called on a debounce as the admin types. Returns {ok, errors[], warnings[]}.
  static Future<Map<String, dynamic>> validate(
    List<dynamic> components,
    String category,
  ) =>
      _rpc('wa_template_validate', {
        'p_components': components,
        'p_category': category,
      });

  /// Returns {header, body, body_raw, footer, buttons[], used_values[]}.
  /// The bubble is rendered from this — never assembled in Dart.
  static Future<Map<String, dynamic>> preview(
    List<dynamic> components, [
    List<dynamic>? vars,
  ]) =>
      _rpc('wa_template_preview', {
        'p_components': components,
        'p_vars': vars,
      });

  // ── writes ─────────────────────────────────────────────────────────────────

  /// {ok, template} | {error:'invalid', issues[]} |
  /// {error:'bad_name'|'pending_review'|'not_found'|'not_authorized', message}
  static Future<Map<String, dynamic>> save({
    String? id,
    required String name,
    required String language,
    required String category,
    required List<dynamic> components,
  }) =>
      _rpc('wa_template_save', {
        'p_id': id,
        'p_name': name,
        'p_language': language,
        'p_category': category,
        'p_components': components,
      });

  /// {ok, template, note} | {error:'exists', message}
  static Future<Map<String, dynamic>> clone(String id, String language) =>
      _rpc('wa_template_clone', {'p_id': id, 'p_language': language});

  /// {ok} | {error:'delete_at_meta', message}
  static Future<Map<String, dynamic>> deleteLocal(String id) =>
      _rpc('wa_template_delete_local', {'p_id': id});

  // ── edge functions ─────────────────────────────────────────────────────────

  /// {status:'ok', meta_id, template_status} |
  /// {error:'submit_failed', meta:{message,title,code}}
  static Future<Map<String, dynamic>> submit(String id) =>
      _fn('wa-templates', {'action': 'submit', 'id': id});

  /// {status:'ok', deleted:'meta'|'local'}
  static Future<Map<String, dynamic>> deleteRemote(String id) =>
      _fn('wa-templates', {'action': 'delete', 'id': id});

  /// {status:'ok'|'partial', synced, errors[]}
  static Future<Map<String, dynamic>> sync() =>
      _fn('wa-templates', {'action': 'sync'});

  /// {status:'ok', wamid} — or an error body rendered verbatim.
  static Future<Map<String, dynamic>> testSend({
    required String to,
    required String templateName,
    required String language,
    required List<dynamic> variables,
  }) =>
      _fn('wa-campaign-send', {
        'test_to': to,
        'template_name': templateName,
        'language': language,
        'variables': variables,
      });
}
