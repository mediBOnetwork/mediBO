import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Thin RPC layer for the Dev Queue tab.
///
/// THE APP RENDERS. IT NEVER DECIDES. — every method here does exactly one
/// thing: call one backend RPC and hand back the payload it returned. No
/// merging, no client-side sorting, no invented fields. The screens render
/// what these return, verbatim.
class DevQueueService {
  DevQueueService({SupabaseClient? client})
      : _c = client ?? Supabase.instance.client;

  final SupabaseClient _c;

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  // ── Reads ──────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> list({
    String? status,
    String? search,
    String? batch,
    int? limit,
  }) async {
    final raw = await _c.rpc('dev_cmd_list', params: {
      'p_status': status,
      'p_search': (search != null && search.isEmpty) ? null : search,
      'p_batch': batch,
      'p_limit': limit,
    });
    return _asMap(raw);
  }

  Future<Map<String, dynamic>> spec(int id) async =>
      _asMap(await _c.rpc('dev_cmd_spec', params: {'p_id': id}));

  // ── Bug-Loop Prevention: QA findings + journeys ──────────────────────────
  /// One render-ready payload for a command's QA state: findings[] (severity,
  /// tone, status all server-decided) + journey runs[] with evidence. The
  /// detail screen draws this verbatim — nothing computed here.
  Future<Map<String, dynamic>> qaDetail(int id) async =>
      _asMap(await _c.rpc('dev_cmd_qa_detail', params: {'p_id': id}));

  /// The known build areas (backend-decided list + labels) for the bug-report
  /// area picker. Rendered verbatim — the app never invents an area name.
  Future<List<Map<String, dynamic>>> areasGet() async =>
      _asList(await _c.rpc('dev_areas_get'));

  /// The journey library: every enabled journey, optionally scoped to an area.
  /// Rendered verbatim in the Journey Library screen.
  Future<List<Map<String, dynamic>>> journeysGet({String? area}) async =>
      _asList(await _c.rpc('journeys_get', params: {'p_area': area}));

  /// File a bug → backend creates a linked fix command + journey stub and
  /// returns the created command id. The app only sends the text + area.
  Future<Map<String, dynamic>> bugReport(String text, String area) async =>
      _asMap(await _c.rpc('bug_report',
          params: {'p_text': text, 'p_area': area, 'p_from_command': null}));

  /// Waive a failed QA gate with the deploy PIN. Backend re-checks the PIN and
  /// returns its verdict, rendered verbatim.
  Future<Map<String, dynamic>> qaWaive(int id, String pin) async =>
      _asMap(await _c.rpc('qa_waive', params: {'p_command_id': id, 'p_pin': pin}));

  Future<List<Map<String, dynamic>>> templates() async {
    final raw = await _c.rpc('dev_cmd_template_list');
    final list = raw is List ? raw : (raw is Map ? (raw['rows'] ?? []) : []);
    return (list as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ── Writes ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> bulkAdd(List<Map<String, dynamic>> items,
          {bool force = false}) async =>
      _asMap(await _c
          .rpc('dev_cmd_bulk_add', params: {'p_items': items, 'p_force': force}));

  // ── Generate-Command drafts (ask-doubt-before-building) ──────────────────
  /// Open a draft: the runner reads the backend and writes back the open
  /// questions. Returns {id}. The app then polls [draftGet] until it is ready.
  Future<Map<String, dynamic>> draftCreate(
          String spec, String mode, int? count, Map<String, dynamic> opts) async =>
      _asMap(await _c.rpc('draft_create', params: {
        'p_spec': spec,
        'p_mode': mode,
        'p_count': count,
        'p_opts': opts,
      }));

  /// The full draft row (status/questions/emit_multi/receipt) — rendered
  /// verbatim by the Questions screen. Polled while status is `generating`.
  Future<Map<String, dynamic>> draftGet(int id) async =>
      _asMap(await _c.rpc('draft_get', params: {'p_id': id}));

  /// Submit the answers → the backend deterministically composes the final
  /// command(s) and adds them to the queue. Returns {result, receipt}. The app
  /// only sends [{idx, answer}] rows; a blank answer means "use the
  /// recommendation" (the backend fills it).
  Future<Map<String, dynamic>> draftSubmit(int id, List<Map<String, dynamic>> answers,
          {bool acceptSplit = true, bool savePrefs = true}) async =>
      _asMap(await _c.rpc('draft_submit', params: {
        'p_id': id,
        'p_answers': answers,
        'p_accept_split': acceptSplit,
        'p_save_prefs': savePrefs,
      }));

  /// The drafts inbox: {generating[], ready[], failed[]}. Polled by the
  /// Dev Queue screen so Om can open a ready draft without waiting on the
  /// blocking loader.
  Future<Map<String, dynamic>> draftsInbox() async =>
      _asMap(await _c.rpc('drafts_inbox'));

  Future<void> draftCancel(int id) async =>
      _c.rpc('draft_cancel', params: {'p_id': id});

  Future<void> reorder(List<int> ids) async =>
      _c.rpc('dev_cmd_reorder', params: {'p_ids': ids});

  Future<void> update(int id, Map<String, dynamic> patch) async =>
      _c.rpc('dev_cmd_update', params: {'p_id': id, 'p_patch': patch});

  Future<void> pause(int id) async =>
      _c.rpc('dev_cmd_pause', params: {'p_id': id});
  Future<void> resume(int id) async =>
      _c.rpc('dev_cmd_resume', params: {'p_id': id});
  Future<void> cancel(int id) async =>
      _c.rpc('dev_cmd_cancel', params: {'p_id': id});
  Future<void> delete(int id) async =>
      _c.rpc('dev_cmd_delete', params: {'p_id': id});
  Future<void> deleteCancelled() async => _c.rpc('dev_cmd_delete_cancelled');
  Future<void> approve(int id) async =>
      _c.rpc('dev_cmd_approve', params: {'p_id': id});
  Future<void> reject(int id, String reason) async =>
      _c.rpc('dev_cmd_reject', params: {'p_id': id, 'p_reason': reason});
  Future<void> requestAndroid(int id, {String buildType = 'apk'}) async =>
      _c.rpc('dev_cmd_request_android',
          params: {'p_id': id, 'p_build_type': buildType});
  Future<void> requestDebug(int id) async =>
      _c.rpc('dev_cmd_request_debug', params: {'p_id': id});
  Future<void> reply(int id, String body,
          {List<String> images = const [],
          List<Map<String, dynamic>> attachments = const []}) async =>
      _c.rpc('dev_cmd_reply', params: {
        'p_command_id': id,
        'p_body': body,
        'p_images': images,
        'p_attachments': attachments,
      });

  /// Upload any file (image / video / pdf / document) to the private uploads
  /// bucket and return {path, kind, name} — the backend stores this verbatim and
  /// the UI renders images inline, everything else as a tappable file chip.
  Future<Map<String, dynamic>> uploadAttachment(
      Uint8List bytes, String name) async {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${DateTime.now().microsecondsSinceEpoch}_$safe';
    final ext = safe.contains('.') ? safe.split('.').last.toLowerCase() : '';
    String kind = 'file';
    String mime = 'application/octet-stream';
    if (['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'].contains(ext)) {
      kind = 'image';
      mime = ext == 'png' ? 'image/png' : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    } else if (['mp4', 'mov', 'webm', 'avi', 'mkv', 'm4v'].contains(ext)) {
      kind = 'video';
      mime = 'video/mp4';
    } else if (ext == 'pdf') {
      kind = 'pdf';
      mime = 'application/pdf';
    }
    await _c.storage.from(uploadsBucket).uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: mime, upsert: true));
    return {'path': path, 'kind': kind, 'name': name};
  }

  /// A short-lived (15-minute) signed URL to open a stored attachment
  /// (video / pdf / doc). Generated on demand each view — never persisted —
  /// so a tight expiry cannot break a stored link. (CHANGE #92 hardening.)
  Future<String> attachmentUrl(String path) =>
      _c.storage.from(uploadsBucket).createSignedUrl(path, 900);

  Future<Map<String, dynamic>> rollback(int id) async =>
      _asMap(await _c.rpc('dev_cmd_rollback', params: {'p_id': id}));

  /// Upload one admin-picked image to the private dev-cmd-uploads bucket and
  /// return the stored path. The backend keys attachments by these paths; the
  /// UI renders them back through a signed URL. Business logic stays server-side
  /// — this is a raw storage put, nothing decided here.
  static const String uploadsBucket = 'dev-cmd-uploads';
  Future<String> uploadImage(Uint8List bytes, String name) async {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${DateTime.now().microsecondsSinceEpoch}_$safe';
    final ext = safe.contains('.') ? safe.split('.').last.toLowerCase() : 'jpg';
    final mime = ext == 'png'
        ? 'image/png'
        : ext == 'webp'
            ? 'image/webp'
            : 'image/jpeg';
    await _c.storage.from(uploadsBucket).uploadBinary(path, bytes,
        fileOptions: FileOptions(contentType: mime, upsert: true));
    return path;
  }

  Future<void> templateSave(String name, String spec) async =>
      _c.rpc('dev_cmd_template_save', params: {'p_name': name, 'p_spec': spec});

  /// Signed URL for a screenshot stored in the dev-cmd-proofs bucket.
  /// 15-minute expiry, generated on demand each view. (CHANGE #92 hardening.)
  Future<String> proofUrl(String path) => _c.storage
      .from('dev-cmd-proofs')
      .createSignedUrl(path, 900);

  /// Rolling-window session token/cost usage vs the configurable budget —
  /// rendered verbatim (all strings + percent come from the backend).
  Future<Map<String, dynamic>> sessionUsage() async =>
      _asMap(await _c.rpc('dev_cmd_session_usage'));

  /// Ask the VM to pull a FRESH usage reading now (fired when the panel opens).
  /// The app only records the intent; the VM poller does the rate-limited fetch
  /// and pushes the result, which the next sessionUsage() render picks up.
  Future<void> requestUsageRefresh() async {
    try {
      await _c.rpc('dev_request_usage_refresh');
    } catch (_) {/* best-effort signal; the background poller still refreshes */}
  }

  // ── Worker pool plane (parallel build) ──────────────────────────────────
  /// The live pool snapshot: {config, state, leases}. `state` is what the VM
  /// orchestrator last published (active_workers, workers[], quota, load,
  /// shrink) — render-ready. The app never infers pool shape; it draws this.
  Future<Map<String, dynamic>> poolGet() async =>
      _asMap(await _c.rpc('pool_get'));

  /// Change one or more pool-config fields (cap / auto / billing_mode /
  /// idle_shutdown_min). PIN-gated by the backend — the app only passes the
  /// admin's patch + PIN and renders the verdict it returns.
  Future<Map<String, dynamic>> poolSet(
          Map<String, dynamic> patch, String pin) async =>
      _asMap(await _c.rpc('pool_set', params: {'p_patch': patch, 'p_pin': pin}));

  /// The files a command currently holds a lease on, while it builds — rendered
  /// verbatim as path chips in the row detail. Empty list when nothing locked.
  Future<List<Map<String, dynamic>>> leaseList(int commandId) async =>
      _asList(await _c.rpc('lease_list', params: {'p_command_id': commandId}));

  // ── Portable Memory plane (#182) ─────────────────────────────────────────
  /// The full agent-memory list: {screen_title, subtitle, labels, scopes,
  /// sections_hint, rows[]} — every string backend-owned, rendered verbatim by
  /// the Memory screen. One RPC, render-ready.
  Future<Map<String, dynamic>> memoryList() async =>
      _asMap(await _c.rpc('memory_list'));

  /// Upsert one rule (scope+section). Backend bumps version + audits. Returns
  /// the verdict ({ok, message, version}) rendered verbatim.
  Future<Map<String, dynamic>> memoryPut(
          String scope, String section, String body, int priority) async =>
      _asMap(await _c.rpc('memory_put', params: {
        'p_scope': scope,
        'p_section': section,
        'p_body': body,
        'p_priority': priority,
      }));

  /// Delete one rule by id. Backend audits. Returns {ok, message}.
  Future<Map<String, dynamic>> memoryDelete(String id) async =>
      _asMap(await _c.rpc('memory_delete', params: {'p_id': id}));

  // ── Runner control plane ────────────────────────────────────────────────
  Future<Map<String, dynamic>> ctlGet() async =>
      _asMap(await _c.rpc('dev_ctl_get'));

  /// Flip one toggle (vm|claude|workflow → on|off). Returns the backend verdict
  /// (for 'vm' it carries call_edge:true + action so the caller invokes the fn).
  Future<Map<String, dynamic>> ctlSet(String key, String value) async =>
      _asMap(await _c.rpc('dev_ctl_set', params: {'p_key': key, 'p_value': value}));

  /// Start/stop/status the GCP VM via the vm-control edge function (carries the
  /// user's JWT; the function re-checks super_admin and uses GCP_SA_KEY).
  Future<Map<String, dynamic>> vmControl(String action) async {
    final res = await _c.functions
        .invoke('vm-control', body: {'action': action});
    final d = res.data;
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  /// Official per-model API list rates (USD/Mtok in+out, fast variants where
  /// present) plus usd_inr and the source note — rendered read-only in the
  /// Rates sheet. Prices come from here, never from Dart literals.
  Future<Map<String, dynamic>> ratesGet() async =>
      _asMap(await _c.rpc('dev_rates_get'));

  // ── GCP Control plane (all render-ready from the live backend) ────────────
  Future<Map<String, dynamic>> gcpGet() async =>
      _asMap(await _c.rpc('dev_gcp_get'));

  /// One-tap GCP action (enable_api|restart_vm|resize_disk|quotas|billing_now).
  /// restart_vm carries the PIN. Enqueues an urgent gcp command; returns {id,...}.
  Future<Map<String, dynamic>> gcpAction(String action, {String? pin}) async =>
      _asMap(await _c.rpc('dev_gcp_action',
          params: {'p_action': action, 'p_pin': pin}));

  Future<List<Map<String, dynamic>>> secretList() async =>
      _asList(await _c.rpc('secret_list'));
  Future<void> secretSet(String name, String value) async =>
      _c.rpc('secret_set', params: {'p_name': name, 'p_value': value});

  Future<Map<String, dynamic>> pinSet(String oldPin, String newPin) async =>
      _asMap(await _c.rpc('sec_pin_set', params: {'p_old': oldPin, 'p_new': newPin}));
  Future<Map<String, dynamic>> freeze() async => _asMap(await _c.rpc('sec_freeze'));
  Future<Map<String, dynamic>> unfreeze(String pin) async =>
      _asMap(await _c.rpc('sec_unfreeze', params: {'p_pin': pin}));
  Future<Map<String, dynamic>> budgetCapSet(num cap, String pin) async =>
      _asMap(await _c.rpc('sec_budget_cap_set', params: {'p_cap': cap, 'p_pin': pin}));

  Future<List<Map<String, dynamic>>> auditList({String? search, int limit = 100}) async =>
      _asList(await _c.rpc('sec_audit_list',
          params: {'p_limit': limit, 'p_search': search}));

  Future<void> scheduleSave(Map<String, dynamic> row) async =>
      _c.rpc('gcp_schedule_save', params: {'p': row});
  Future<void> scheduleDelete(int id) async =>
      _c.rpc('gcp_schedule_delete', params: {'p_id': id});

  List<Map<String, dynamic>> _asList(dynamic v) => (v as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];
}
