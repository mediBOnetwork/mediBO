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
