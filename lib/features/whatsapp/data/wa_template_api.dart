import 'dart:typed_data';

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

  /// Test seam for the storage upload behind the media header.
  @visibleForTesting
  static Future<void> Function(
      String bucket, String path, Uint8List bytes, String mime)? uploadTransport;

  /// Test seam for the storage signer behind the sample viewer. A widget test
  /// can hand back a URL — or a failure — without a Supabase client or network.
  @visibleForTesting
  static Future<String?> Function(String bucket, String path, int expiresIn)?
      signerTransport;

  /// The bucket the sample file is uploaded to. The RPC defaults to the same
  /// name server-side; it is named once here so the two cannot drift.
  static const String mediaBucket = 'whatsapp-media';

  // ── plumbing ───────────────────────────────────────────────────────────────

  /// An RPC returning `jsonb` arrives as a Map; one declared RETURNS TABLE
  /// arrives as a single-element List. Both shapes are normalised here so no
  /// caller has to know which it got.
  static Map<String, dynamic> _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    if (data is Map) return data.cast<String, dynamic>();
    return const <String, dynamic>{};
  }

  /// True when [res] is an error ENVELOPE rather than a payload.
  ///
  /// Detected by the ABSENCE of the payload's own required field, never by the
  /// presence of `error`. wa_template_header_status and wa_policy_review_latest
  /// both carry a nullable `error` INSIDE their success payload — the upload /
  /// review failure text — so "has an error key" would misread every healthy
  /// response as a failure and blank the section.
  static bool isError(Map<String, dynamic> res, String requiredKey) =>
      res[requiredKey] == null && (res['error'] ?? '').toString().isNotEmpty;

  /// The backend's own sentence for a refusal. Empty when it sent none — the
  /// caller then changes nothing rather than inventing wording.
  static String errorMessage(Map<String, dynamic> res) =>
      (res['message'] ?? '').toString();

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
  /// The bubble is rendered from this — never assembled in Dart. This is the
  /// LIVE preview: it re-renders the unsaved components as the admin types.
  static Future<Map<String, dynamic>> preview(
    List<dynamic> components, [
    List<dynamic>? vars,
  ]) =>
      _rpc('wa_template_preview', {
        'p_components': components,
        'p_vars': vars,
      });

  /// The SAVED row's whole preview in one call, already render-ready:
  ///   {header, body_raw, body_rendered, footer, buttons:[{text,kind,kind_label}],
  ///    rendered_note, char_count}
  /// where header is null | {format:'TEXT',text} |
  ///   {format:'IMAGE'|'DOCUMENT'|'VIDEO', is_image, is_pdf, is_video,
  ///    media_url, storage_bucket, storage_path, file_label, size_label,
  ///    expires_label, expired, placeholder_label, missing_label}.
  ///
  /// Reads the row, so it only answers once the template has an id — the sample
  /// file (and the handle Meta issues for it) live on the row, not in the
  /// components the editor is holding.
  static Future<Map<String, dynamic>> templatePreview(String id) =>
      _rpc('wa_template_preview', {'p_template_id': id});

  // ── submit gate ────────────────────────────────────────────────────────────

  /// {can_submit, count, why_label, blockers:[{issue,fix}], warnings:[]}
  ///
  /// Reads the SAVED row, so it only has an answer once the template has an id.
  /// This is the single source of "may I submit" — the editor never adds a
  /// reason of its own on top.
  static Future<Map<String, dynamic>> submitBlockers(String id) =>
      _rpc('wa_template_submit_blockers', {'p_template_id': id});

  // ── media header ───────────────────────────────────────────────────────────

  /// {header_format, has_sample, file_label, size_label, expires_label,
  ///  expired, status, status_label, tone, error, can_submit, blocker}
  static Future<Map<String, dynamic>> headerStatus(String id) =>
      _rpc('wa_template_header_status', {'p_template_id': id});

  /// {formats:[{value,label,accepts,mime,max_mb,needs_sample}], rules:[],
  ///  template_saved, can_upload, upload_label, blocked_reason}
  ///
  /// The id is what makes can_upload/blocked_reason answerable: a sample file
  /// attaches to a SAVED template, so an unsaved editor passes null and gets
  /// back the reason it cannot upload yet, in the backend's own words.
  static Future<Map<String, dynamic>> mediaSpec([String? id]) =>
      _rpc('wa_template_media_spec',
          {'p_template_id': (id == null || id.isEmpty) ? null : id});

  /// {ok, job_id, format, message} | {error, message}
  static Future<Map<String, dynamic>> setHeaderMedia({
    required String id,
    required String storagePath,
    required String mime,
    required int bytes,
  }) =>
      _rpc('wa_template_set_header_media', {
        'p_template_id': id,
        'p_storage_path': storagePath,
        'p_mime': mime,
        'p_bytes': bytes,
      });

  /// Puts the sample file in storage. Nothing here checks the size or the type
  /// — wa_template_set_header_media refuses with its own message if it must.
  static Future<void> uploadMedia({
    required String path,
    required Uint8List bytes,
    required String mime,
  }) async {
    final t = uploadTransport;
    if (t != null) return t(mediaBucket, path, bytes, mime);
    await Supabase.instance.client.storage.from(mediaBucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
  }

  /// A viewable link to a sample file in a PRIVATE bucket. The bucket and path
  /// are the backend's own — this only asks storage to sign what the preview
  /// payload named. Returns null when signing fails, so the caller falls back
  /// to the file label rather than showing a broken image. Re-signed on every
  /// screen open (the URL expires), never cached.
  static Future<String?> signedUrl(
    String bucket,
    String path, {
    int expiresIn = 3600,
  }) async {
    final t = signerTransport;
    if (t != null) return t(bucket, path, expiresIn);
    try {
      return await Supabase.instance.client.storage
          .from(bucket)
          .createSignedUrl(path, expiresIn);
    } catch (_) {
      return null;
    }
  }

  // ── duplicate check ────────────────────────────────────────────────────────

  /// {rows:[{name,language,status,pct,label,tone}], top_pct, tone, blocking, summary}
  static Future<Map<String, dynamic>> similar(String body, String? excludeId) =>
      _rpc('wa_template_similar', {
        'p_body': body,
        'p_exclude_id': excludeId,
      });

  // ── AI policy review ───────────────────────────────────────────────────────

  /// {ok, review_id, message} | {error, message}
  static Future<Map<String, dynamic>> policyReviewStart(String id) =>
      _rpc('wa_policy_review_start', {'p_template_id': id});

  /// {status, label, tone, verdict:{risk, verdict_label,
  ///  likely_rejection_reason, category_advice, issues:[], suggested_body}}
  static Future<Map<String, dynamic>> policyReviewLatest(String id) =>
      _rpc('wa_policy_review_latest', {'p_template_id': id});

  // ── writes ─────────────────────────────────────────────────────────────────

  /// {ok, template} | {error:'invalid', issues[]} |
  /// {error:'bad_name'|'pending_review'|'not_found'|'not_authorized', message}
  ///
  /// `tokenMap` is the list of value KEYS this template uses, positionally: the
  /// key at index 0 is what {{1}} in the body means. It is NOT derived from the
  /// body text here — it is the map wa_body_insert_token / wa_body_renumber
  /// handed back, passed straight through. See [bodyInsertToken].
  static Future<Map<String, dynamic>> save({
    String? id,
    required String name,
    required String language,
    required String category,
    required List<dynamic> components,
    List<dynamic>? tokenMap,
  }) =>
      _rpc('wa_template_save', {
        'p_id': id,
        'p_name': name,
        'p_language': language,
        'p_category': category,
        'p_components': components,
        'p_token_map': tokenMap ?? const <dynamic>[],
      });

  /// {ok, template, note} | {error:'exists', message}
  static Future<Map<String, dynamic>> clone(String id, String language) =>
      _rpc('wa_template_clone', {'p_id': id, 'p_language': language});

  /// {ok} | {error:'delete_at_meta', message}
  static Future<Map<String, dynamic>> deleteLocal(String id) =>
      _rpc('wa_template_delete_local', {'p_id': id});

  // ── the body's numbered variables ──────────────────────────────────────────
  //
  // Meta accepts NUMBERED variables only — {{1}}, {{2}}. A named one is literal
  // text, so a template carrying {{customer_name}} sends a pharmacy a message
  // that reads, character for character, "{{customer_name}}". Choosing the
  // number is therefore not a formatting nicety, it is the whole correctness of
  // the message, and both RPCs below own it end to end. Nothing in this app
  // counts placeholders, picks the next free number, or rebuilds the map.

  /// Inserts value [key] into [body] at [cursor].
  ///
  /// {body, cursor, inserted, token_map, label, preview_value} | {error, message}
  ///
  /// The RPC picks the next free number, REUSES the number the value already
  /// has when it appears in the message twice, and returns the caret position
  /// after the inserted text. [tokenMap] is the map as it stands now; the
  /// returned `token_map` replaces it.
  static Future<Map<String, dynamic>> bodyInsertToken({
    required String body,
    required int cursor,
    required String key,
    required List<dynamic> tokenMap,
  }) =>
      _rpc('wa_body_insert_token', {
        'p_body': body,
        'p_cursor': cursor,
        'p_key': key,
        'p_token_map': tokenMap,
      });

  /// Closes the gap a deleted variable leaves behind. {body, token_map, changed}
  ///
  /// Deleting {{1}} out of the middle leaves {{2}},{{3}} — and Meta rejects a
  /// template whose numbering has a hole. This renumbers to {{1}},{{2}} and
  /// rebuilds the map to match. `changed:false` means the body was already
  /// correct and nothing should be replaced.
  static Future<Map<String, dynamic>> bodyRenumber(
    String body,
    List<dynamic> tokenMap,
  ) =>
      _rpc('wa_body_renumber', {
        'p_body': body,
        'p_token_map': tokenMap,
      });

  // ── values (the {{...}} picker) ────────────────────────────────────────────
  //
  // wa_template_tokens() is deliberately NOT called from this file. It returned
  // a fixed list of nine values, so a value that was not on it (a delivery
  // person's name) could not be inserted at all — and inserting a bare {{2}}
  // instead sent a customer a message reading "{{2}}". These RPCs return the
  // live, editable, searchable set instead.

  /// The whole picker in one payload: rows[], search, sample_from, empty_copy,
  /// source_kinds[], formats[]. A null `search` loads everything.
  ///
  /// Every row arrives render-ready — label, example, source_label,
  /// coverage_label and coverage_tone are all decided by the backend.
  ///
  /// A row's `insert_as` is deliberately NOT used. It held a NAMED placeholder
  /// ({{customer_name}}), which Meta treats as literal text — the pharmacy
  /// received those characters. wa_body_insert_token does the inserting now.
  static Future<Map<String, dynamic>> tokensScreen([String? search]) =>
      _rpc('wa_tokens_screen', {'p_search': search});

  /// {ok, key, insert_as, sample, resolves, warning} | {error, message}
  ///
  /// The RPC is what checks that `sourceRef` actually exists — this app never
  /// validates a field name itself, it renders whatever verdict comes back.
  static Future<Map<String, dynamic>> tokenSave({
    required String key,
    required String label,
    required String sourceKind,
    String? sourceRef,
    String? group,
    String? format,
    String? fallback,
    String? example,
    int? sort,
  }) =>
      _rpc('wa_token_save', {
        'p_key': key,
        'p_label': label,
        'p_source_kind': sourceKind,
        'p_source_ref': sourceRef,
        'p_group': group,
        'p_format': format,
        'p_fallback': fallback,
        'p_example': example,
        'p_sort': sort,
      });

  /// {ok} | {error, message, templates[]} — templates[] lists what still uses it.
  static Future<Map<String, dynamic>> tokenDelete(String key) =>
      _rpc('wa_token_delete', {'p_key': key});

  /// {ok, enabled}
  static Future<Map<String, dynamic>> tokenToggle(String key, bool enabled) =>
      _rpc('wa_token_toggle', {'p_key': key, 'p_enabled': enabled});

  /// Starts the AI lookup for a value the admin could not find. {ok, job_id, status}
  static Future<Map<String, dynamic>> tokenAiSearch(String query) =>
      _rpc('wa_token_ai_search', {'p_query': query});

  /// {status, query, status_label, error, result:{matches[], proposal, note}}
  static Future<Map<String, dynamic>> tokenSearchResult(String jobId) =>
      _rpc('wa_token_search_result', {'p_job_id': jobId});

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
