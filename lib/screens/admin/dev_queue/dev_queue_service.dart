import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/dev_console.dart';

/// Thin RPC layer for the Dev Queue tab.
///
/// THE APP RENDERS. IT NEVER DECIDES. — every method here does exactly one
/// thing: call one backend RPC and hand back the payload it returned. No
/// merging, no client-side sorting, no invented fields. The screens render
/// what these return, verbatim.
class DevQueueService {
  /// CHANGE #1761 — the dev-queue control plane lives on its own project
  /// (medibo-dev). RPCs go there through [DevConsole]; the few that read
  /// PRODUCTION's own health (its cron, its DB lane, its regression guard, its
  /// app diagnostics) stay on production, and so do storage and edge functions.
  /// [client] pins the control-plane client (tests).
  DevQueueService({
    SupabaseClient? client,
    SupabaseClient? storageClient,
    DevConsole? console,
  })  : _fixed = client,
        _storage = storageClient,
        _console = console ?? DevConsole.instance;

  final SupabaseClient? _fixed;
  final SupabaseClient? _storage;
  final DevConsole _console;

  /// Resolved lazily: a test that pins [client] never touches
  /// `Supabase.instance`, and falls back to that pinned client for storage.
  SupabaseClient get _prod => _storage ?? _fixed ?? Supabase.instance.client;

  /// RPCs that describe PRODUCTION itself and therefore run there.
  static const Set<String> productionRpcs = {
    'cron_health',
    'cron_budget_card',
    'db_health_status',
    'db_admission_set',
    'rg_guard_card',
    'call_setup_status',
    'auth_diag_list',
    // CHANGE #634 — the coverage ledger reads production's feature_registry,
    // test_coverage and test_runs; the control plane has none of them.
    'test_coverage_home',
    // CHANGE #635 — the journey bot reads production's test_runs,
    // test_results, feature_gaps and the role/hostile/stage tables. Same
    // reason: the control plane has none of them.
    'autotest_home',
    // CHANGE #638 — chaos and session recording sit on production's test
    // session, its idempotency ledger, its webhook log and its DB lane. Every
    // one of those is production's own; the control plane has none of them.
    'chaos_home',
    'chaos_run_all',
    'recording_start',
    'recording_step_add',
    'recording_stop',
    'recording_promote',
    'recording_replay',
    // CHANGE #636 — the safety net judges PRODUCTION's own RPC surface: its
    // pg_proc, its grants, its guards, its money and its stock. Pointing it at
    // the control plane would grade the wrong database and pass.
    'autotest_safety_net_home',
    'autotest_safety_net_run',
    // CHANGE #639 — the triage loop sits on top of every one of those: it reads
    // production's visual_shot, autotest_* results, dev_journey_runs and
    // test_coverage, and the findings table it fills lives there too. Pointing
    // it at the control plane would show an empty inbox and call it clean.
    'triage_inbox',
    'triage_finding_detail',
    'triage_trends',
    'triage_approve',
    'triage_reject',
    'triage_approve_bulk',
  };

  /// The control-plane client (medibo-dev): minted on first use, re-minted
  /// only when the backend-issued ticket is about to expire.
  Future<SupabaseClient> rpcClient() async => _fixed ?? await _console.client();

  /// Production: buckets (`dev-cmd-uploads`, `dev-cmd-proofs`), edge functions,
  /// and the [productionRpcs].
  SupabaseClient get storageClient => _prod;

  /// Which project a named RPC is sent to — the one routing decision in Dart.
  Future<SupabaseClient> clientFor(String fn) async =>
      productionRpcs.contains(fn) ? _prod : await rpcClient();

  Future<dynamic> _rpc(String fn, {Map<String, dynamic>? params}) async =>
      (await clientFor(fn)).rpc(fn, params: params);

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  // ── Reads ──────────────────────────────────────────────────────────────
  /// CHANGE #643 — the list is CARDS. Every key a card draws is here; the log
  /// tail, the spec, the decisions, the screenshots, the step list and the
  /// finish blockers are not, and arrive from [get] when a card is opened.
  /// Measured: a page of 25 went from ~302 kB to ~35 kB.
  ///
  /// [updatedSince] makes the poll a DELTA — the backend returns only the rows
  /// whose clock moved since that timestamp and echoes its own `server_time`
  /// for the next call. `is_delta` on the payload says which kind came back.
  Future<Map<String, dynamic>> list({
    String? status,
    String? search,
    String? batch,
    int? limit,
    String? updatedSince,
  }) async {
    final raw = await _rpc(
      'dev_cmd_list',
      params: {
        'p_status': status,
        'p_search': (search != null && search.isEmpty) ? null : search,
        'p_batch': batch,
        'p_limit': limit,
        'p_updated_since': updatedSince,
      },
    );
    return _asMap(raw);
  }

  /// One command, in full — the detail read. The screen used to find its row by
  /// pulling `dev_cmd_list(limit: 500)` and searching it, which shipped every
  /// other command's build log to draw one page.
  Future<Map<String, dynamic>> get(int id) async =>
      _asMap(await _rpc('dev_cmd_get', params: {'p_id': id}));

  /// A page of the message thread. Media comes back as URLs only.
  Future<Map<String, dynamic>> messages(int id, {int limit = 50, int? afterId}) async =>
      _asMap(await _rpc('dev_cmd_messages',
          params: {'p_id': id, 'p_limit': limit, 'p_after_id': afterId}));
  /// CHANGE #656 — the model/effort picker is DATA. Labels, values, defaults
  /// and the section titles all arrive from dev_model_options(); the sheet
  /// renders them verbatim and never spells a model id or a label in Dart.
  Future<Map<String, dynamic>> modelOptions() async =>
      _asMap(await _rpc('dev_model_options'));

  Future<Map<String, dynamic>> spec(int id) async =>
      _asMap(await _rpc('dev_cmd_spec', params: {'p_id': id}));

  /// CHANGE #571 — the command's OWN spec checklist. Every item, its status,
  /// its status label and its tone are decided by the backend; the screen
  /// prints them. An open item is why a completion was refused.
  Future<Map<String, dynamic>> specItems(int id) async =>
      _asMap(await _rpc('dev_cmd_spec_items', params: {'p_id': id}));

  // ── Bug-Loop Prevention: QA findings + journeys ──────────────────────────
  /// One render-ready payload for a command's QA state: findings[] (severity,
  /// tone, status all server-decided) + journey runs[] with evidence. The
  /// detail screen draws this verbatim — nothing computed here.
  Future<Map<String, dynamic>> qaDetail(int id) async =>
      _asMap(await _rpc('dev_cmd_qa_detail', params: {'p_id': id}));

  /// The known build areas (backend-decided list + labels) for the bug-report
  /// area picker. Rendered verbatim — the app never invents an area name.
  /// CHANGE #273 — cron health. One RPC, rendered verbatim by CronHealthScreen:
  /// the headline, the last dispatcher tick, every registered task's state and
  /// the guard log all arrive as backend strings.
  Future<Map<String, dynamic>> cronHealth() async =>
      _asMap(await _rpc('cron_health'));

  /// CHANGE #301 — the database coordination lane: connections, the longest
  /// open transaction, statement timeouts, who is holding an exclusive or
  /// heavy-read slot, and the watchdog's own alerts. Every word is built in
  /// `db_health_status()`; the section renders it in payload order.
  Future<Map<String, dynamic>> dbHealth() async =>
      _asMap(await _rpc('db_health_status'));

  /// CMD #368 — save one admission-control threshold (or the on/off switch).
  /// The backend clamps every value to its own bounds and returns the stored
  /// block; the caller reloads rather than trusting what it sent.
  Future<Map<String, dynamic>> admissionSet(Map<String, dynamic> patch) async =>
      _asMap(await _rpc('db_admission_set', params: {'p_patch': patch}));

  /// CHANGE #324 — the deploy lane, now a merge queue: who holds the lane and
  /// for how long, what is waiting to be batched, the batch in flight, wait
  /// time vs hold time over the last seven days, any claim still holding a
  /// slot past its TTL, and the recent deploys. Every word and every duration
  /// string is built in `deploy_lane_status()`; the section renders it in
  /// payload order.
  Future<Map<String, dynamic>> deployLane({int limit = 12}) async =>
      _asMap(await _rpc('deploy_lane_status', params: {'p_limit': limit}));

  /// CHANGE #327 — the Build lane: what waited on a FILE.
  /// Its own RPC beside the other two lanes, so a refused read of one never
  /// blanks the others. Every label, count sentence and empty hint is built in
  /// `build_contention_status()`; the section renders it in payload order.
  Future<Map<String, dynamic>> buildLane({int days = 7}) async =>
      _asMap(await _rpc('build_contention_status', params: {'p_days': days}));

  /// CHANGE #1819 — the Waiting lane: what waiting COST, in tokens.
  /// Its own RPC beside the other three lanes, so a refused read of one never
  /// blanks the others. Every label, total, before/after sentence and tone is
  /// built in `dev_wait_report()`; the section prints it in payload order.
  Future<Map<String, dynamic>> waitingLane({int hours = 24}) async =>
      _asMap(await _rpc('dev_wait_report', params: {'p_hours': hours}));

  /// CHANGE #530 — the boot doctor's verdict per runner: what a crash left
  /// behind, what was repaired, and which runners are refusing to claim. Its
  /// own RPC beside the three lanes, so a refused read of one never blanks the
  /// others. Every word and tone is built by `runner_boot_status()`.
  Future<Map<String, dynamic>> runnerBoot({int limit = 12}) async =>
      _asMap(await _rpc('runner_boot_status', params: {'p_limit': limit}));

  /// CHANGE #1268 — one agent id per live session, one building command per
  /// agent. Its own RPC beside the lanes, so a refused read never blanks them.
  /// Every label, tone and caption is built by `dev_agent_sessions_status()`.
  Future<Map<String, dynamic>> runnerSessions() async =>
      _asMap(await _rpc('dev_agent_sessions_status'));

  /// CHANGE #916 — the regression guard, which until now had no surface at
  /// all: its only way to reach Om was to file an urgent "RG red after #N"
  /// command. Verdict, the recent runs in order, what the watcher will do
  /// about a red and the guard alerts of the last day are all built by
  /// `rg_guard_card()`; the section renders them in payload order. Read-only —
  /// it never runs the guard, so opening the screen costs no catalogue scan.
  Future<Map<String, dynamic>> guardCard({int runs = 8}) async =>
      _asMap(await _rpc('rg_guard_card', params: {'p_runs': runs}));

  /// CHANGE #404 — is masked calling actually on, and what is still missing
  /// before real calls flow. Render-ready: every word and tone on the card is
  /// built by this RPC.
  Future<Map<String, dynamic>> maskedCalling() async =>
      _asMap(await _rpc('call_setup_status'));

  /// CHANGE #275 — every Google sign-in failure recorded on a real device,
  /// newest first, already rendered by the backend.
  Future<Map<String, dynamic>> authDiagList({int limit = 50}) async =>
      _asMap(await _rpc('auth_diag_list', params: {'p_limit': limit}));

  /// CMD #1820 — the Token dashboard, whole, in one payload. Every rupee,
  /// token count, percentage, ratio and em-dash on that screen is a string
  /// built by `dev_token_report()`; this method merges nothing, defaults
  /// nothing and formats nothing.
  Future<Map<String, dynamic>> tokenReport(String scope) async =>
      _asMap(await _rpc('dev_token_report', params: {'p_scope': scope}));

  Future<List<Map<String, dynamic>>> areasGet() async =>
      _asList(await _rpc('dev_areas_get'));

  /// CMD #1824 — Build intelligence. One RPC, one fully rendered payload:
  /// tiles, sections, every label, value, sub-line, tone and empty state are
  /// the backend's. This method merges nothing, defaults nothing and formats
  /// nothing.
  Future<Map<String, dynamic>> buildIntelligence() async =>
      _asMap(await _rpc('dev_build_intelligence'));

  /// Apply one open waste proposal. The PIN goes through untouched: pool_set
  /// verifies it, and the returned `message` is what the screen prints.
  Future<Map<String, dynamic>> buildProposalApply(int id, String pin) async =>
      _asMap(await _rpc('dev_build_proposal_apply',
          params: {'p_id': id, 'p_pin': pin}));

  Future<Map<String, dynamic>> buildProposalDismiss(int id) async =>
      _asMap(await _rpc('dev_build_proposal_dismiss', params: {'p_id': id}));

  /// CHANGE #634 — the coverage ledger. One RPC, one payload, printed as it
  /// arrives: this method merges nothing and defaults nothing. It reads
  /// PRODUCTION's own feature_registry and test_coverage, so it is routed
  /// there by [productionRpcs] rather than to the control plane.
  Future<Map<String, dynamic>> testCoverageHome({String filter = 'all'}) async =>
      _asMap(await _rpc('test_coverage_home', params: {'p_filter': filter}));

  /// CHANGE #635 — the journey bot's whole screen, in one payload. Like the
  /// coverage ledger it merges nothing and defaults nothing: the roles, the
  /// hostile variants, the nine pipeline stages, the gaps and the deploy gate
  /// all arrive already worded and already toned.
  Future<Map<String, dynamic>> autotestHome({String filter = 'all'}) async =>
      _asMap(await _rpc('autotest_home', params: {'p_filter': filter}));
  /// CHANGE #636 — the machine-generated safety net. One read, one write, both
  /// against production: `autotest_safety_net_home()` is the whole screen and
  /// `autotest_safety_net_run()` is the button. Nothing here interprets either
  /// payload.
  Future<Map<String, dynamic>> safetyNetHome() async =>
      _asMap(await _rpc('autotest_safety_net_home'));

  Future<Map<String, dynamic>> safetyNetRun() async =>
      _asMap(await _rpc('autotest_safety_net_run', params: {'p_label': null}));

  /// CHANGE #638 — the Chaos lab, in one payload: the seven scenarios with the
  /// last run's verdict on each, the live recording and its steps, every
  /// stopped walkthrough with its own promote decision, and the findings both
  /// halves have filed. Every word, chip, tone and enabled flag is the
  /// backend's — the screen counts nothing.
  Future<Map<String, dynamic>> chaosHome({int? run}) async =>
      _asMap(await _rpc('chaos_home', params: {'p_run': run}));

  /// Run every active scenario. Returns the same payload [chaosHome] does, so
  /// the screen re-renders from the run it just finished.
  Future<Map<String, dynamic>> chaosRunAll({String? label}) async =>
      _asMap(await _rpc('chaos_run_all', params: {'p_label': label}));

  /// Start / stop / promote one recorded walkthrough. The refusals
  /// (test mode off, no session, already recording, nothing recorded) are the
  /// backend's own messages and are shown verbatim.
  Future<Map<String, dynamic>> recordingStart(String label) async =>
      _asMap(await _rpc('recording_start', params: {'p_label': label}));

  Future<Map<String, dynamic>> recordingStep({
    required int recording,
    required String kind,
    required String screen,
    required String action,
    Map<String, dynamic> detail = const {},
    bool ok = true,
  }) async =>
      _asMap(await _rpc('recording_step_add', params: {
        'p_recording': recording,
        'p_kind': kind,
        'p_screen': screen,
        'p_action': action,
        'p_detail': detail,
        'p_ok': ok,
      }));

  Future<Map<String, dynamic>> recordingStop(int recording,
          {String outcome = 'ok', String note = ''}) async =>
      _asMap(await _rpc('recording_stop', params: {
        'p_recording': recording,
        'p_outcome': outcome,
        'p_note': note,
      }));

  Future<Map<String, dynamic>> recordingPromote(int recording,
          {String? title, String area = 'platform'}) async =>
      _asMap(await _rpc('recording_promote', params: {
        'p_recording': recording,
        'p_title': title,
        'p_area': area,
      }));

  /// CMD #1851 — replay a recorded walkthrough: every RPC it recorded is called
  /// again with the arguments it was given, the answers are compared against
  /// the ones it got, and every write is rolled back. The verdict, the step
  /// that diverged and the words for it are all the backend's.
  Future<Map<String, dynamic>> recordingReplay(int recording) async =>
      _asMap(await _rpc('recording_replay', params: {'p_recording': recording}));

  /// The journey library: every enabled journey, optionally scoped to an area.
  /// Rendered verbatim in the Journey Library screen.
  Future<List<Map<String, dynamic>>> journeysGet({String? area}) async =>
      _asList(await _rpc('journeys_get', params: {'p_area': area}));

  // ── CHANGE #639: triage ────────────────────────────────────────────────
  /// The triage inbox, rendered verbatim. Every label, chip and button caption
  /// on the screen is in this payload.
  Future<Map<String, dynamic>> triageInbox({
    String? status = 'new',
    String? surface,
    String? severity,
    int limit = 30,
    int offset = 0,
  }) async =>
      _asMap(await _rpc('triage_inbox', params: {
        'p_status': status,
        'p_surface': surface,
        'p_severity': severity,
        'p_limit': limit,
        'p_offset': offset,
      }));

  Future<Map<String, dynamic>> triageTrends({int weeks = 8}) async =>
      _asMap(await _rpc('triage_trends', params: {'p_weeks': weeks}));

  /// Approve / reject are the ONLY two writes this screen makes. They go under
  /// Om's own session on purpose: the backend's `_triage_human()` refuses
  /// service_role, so a bot can never approve its own finding.
  Future<Map<String, dynamic>> triageApprove(List<int> ids) async =>
      _asMap(await _rpc('triage_approve', params: {'p_ids': ids}));

  Future<Map<String, dynamic>> triageReject(List<int> ids, String reason) async =>
      _asMap(await _rpc('triage_reject',
          params: {'p_ids': ids, 'p_reason': reason}));

  Future<Map<String, dynamic>> triageApproveBulk(
          {String? surface, String? severity}) async =>
      _asMap(await _rpc('triage_approve_bulk',
          params: {'p_surface': surface, 'p_severity': severity}));

  /// A finding's screenshot. The bucket and path are the payload's; nothing
  /// here builds a URL out of a feature name.
  Future<String?> triageShotUrl(String bucket, String path) async {
    if (bucket.isEmpty || path.isEmpty) return null;
    try {
      return await _prod.storage.from(bucket).createSignedUrl(path, 900);
    } catch (_) {
      return null;
    }
  }

  /// File a bug → backend creates a linked fix command + journey stub and
  /// returns the created command id. The app only sends the text + area.
  Future<Map<String, dynamic>> bugReport(String text, String area) async =>
      _asMap(
        await _rpc(
          'bug_report',
          params: {'p_text': text, 'p_area': area, 'p_from_command': null},
        ),
      );

  /// Waive a failed QA gate with the deploy PIN. Backend re-checks the PIN and
  /// returns its verdict, rendered verbatim.
  Future<Map<String, dynamic>> qaWaive(int id, String pin) async => _asMap(
    await _rpc('qa_waive', params: {'p_command_id': id, 'p_pin': pin}),
  );

  Future<List<Map<String, dynamic>>> templates() async {
    final raw = await _rpc('dev_cmd_template_list');
    final list = raw is List ? raw : (raw is Map ? (raw['rows'] ?? []) : []);
    return (list as List)
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  // ── Writes ─────────────────────────────────────────────────────────────
  Future<Map<String, dynamic>> bulkAdd(
    List<Map<String, dynamic>> items, {
    bool force = false,
  }) async => _asMap(
    await _rpc(
      'dev_cmd_bulk_add',
      params: {'p_items': items, 'p_force': force},
    ),
  );

  // ── Generate-Command drafts (ask-doubt-before-building) ──────────────────
  /// Open a draft: the runner reads the backend and writes back the open
  /// questions. Returns {id}. The app then polls [draftGet] until it is ready.
  Future<Map<String, dynamic>> draftCreate(
    String spec,
    String mode,
    int? count,
    Map<String, dynamic> opts,
  ) async => _asMap(
    await _rpc(
      'draft_create',
      params: {
        'p_spec': spec,
        'p_mode': mode,
        'p_count': count,
        'p_opts': opts,
      },
    ),
  );

  /// The full draft row (status/questions/emit_multi/receipt) — rendered
  /// verbatim by the Questions screen. Polled while status is `generating`.
  Future<Map<String, dynamic>> draftGet(int id) async =>
      _asMap(await _rpc('draft_get', params: {'p_id': id}));

  /// Submit the answers → the backend deterministically composes the final
  /// command(s) and adds them to the queue. Returns {result, receipt}. The app
  /// only sends [{idx, answer}] rows; a blank answer means "use the
  /// recommendation" (the backend fills it).
  Future<Map<String, dynamic>> draftSubmit(
    int id,
    List<Map<String, dynamic>> answers, {
    bool acceptSplit = true,
    bool savePrefs = true,
  }) async => _asMap(
    await _rpc(
      'draft_submit',
      params: {
        'p_id': id,
        'p_answers': answers,
        'p_accept_split': acceptSplit,
        'p_save_prefs': savePrefs,
      },
    ),
  );

  /// The drafts inbox: {generating[], ready[], failed[]}. Polled by the
  /// Dev Queue screen so Om can open a ready draft without waiting on the
  /// blocking loader.
  Future<Map<String, dynamic>> draftsInbox() async =>
      _asMap(await _rpc('drafts_inbox'));

  /// CHANGE #349 — the labelled tools surface. One payload: the groups, the
  /// labels, the descriptions, the icon keys and the drafts badge. A tool the
  /// registry does not list is not in it, which is the whole gate.
  Future<Map<String, dynamic>> devTools() async =>
      _asMap(await _rpc('dev_tools'));

  Future<void> draftCancel(int id) async =>
      _rpc('draft_cancel', params: {'p_id': id});

  Future<void> reorder(List<int> ids) async =>
      _rpc('dev_cmd_reorder', params: {'p_ids': ids});

  Future<void> update(int id, Map<String, dynamic> patch) async =>
      _rpc('dev_cmd_update', params: {'p_id': id, 'p_patch': patch});

  Future<void> pause(int id) async =>
      _rpc('dev_cmd_pause', params: {'p_id': id});
  Future<void> resume(int id) async =>
      _rpc('dev_cmd_resume', params: {'p_id': id});
  Future<void> cancel(int id) async =>
      _rpc('dev_cmd_cancel', params: {'p_id': id});
  Future<void> delete(int id) async =>
      _rpc('dev_cmd_delete', params: {'p_id': id});
  Future<void> deleteCancelled() async => _rpc('dev_cmd_delete_cancelled');
  Future<void> approve(int id) async =>
      _rpc('dev_cmd_approve', params: {'p_id': id});
  Future<void> reject(int id, String reason) async =>
      _rpc('dev_cmd_reject', params: {'p_id': id, 'p_reason': reason});
  Future<void> requestAndroid(int id, {String buildType = 'apk'}) async =>
      _rpc(
        'dev_cmd_request_android',
        params: {'p_id': id, 'p_build_type': buildType},
      );
  Future<void> requestDebug(int id) async =>
      _rpc('dev_cmd_request_debug', params: {'p_id': id});
  Future<void> reply(
    int id,
    String body, {
    List<String> images = const [],
    List<Map<String, dynamic>> attachments = const [],
  }) async => _rpc(
    'dev_cmd_reply',
    params: {
      'p_command_id': id,
      'p_body': body,
      'p_images': images,
      'p_attachments': attachments,
    },
  );

  /// Upload any file (image / video / pdf / document) to the private uploads
  /// bucket and return {path, kind, name} — the backend stores this verbatim and
  /// the UI renders images inline, everything else as a tappable file chip.
  Future<Map<String, dynamic>> uploadAttachment(
    Uint8List bytes,
    String name,
  ) async {
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final path = '${DateTime.now().microsecondsSinceEpoch}_$safe';
    final ext = safe.contains('.') ? safe.split('.').last.toLowerCase() : '';
    String kind = 'file';
    String mime = 'application/octet-stream';
    if (['jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'].contains(ext)) {
      kind = 'image';
      mime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    } else if (['mp4', 'mov', 'webm', 'avi', 'mkv', 'm4v'].contains(ext)) {
      kind = 'video';
      mime = 'video/mp4';
    } else if (ext == 'pdf') {
      kind = 'pdf';
      mime = 'application/pdf';
    }
    await _prod.storage
        .from(uploadsBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return {'path': path, 'kind': kind, 'name': name};
  }

  /// A short-lived (15-minute) signed URL to open a stored attachment
  /// (video / pdf / doc). Generated on demand each view — never persisted —
  /// so a tight expiry cannot break a stored link. (CHANGE #92 hardening.)
  Future<String> attachmentUrl(String path) =>
      _prod.storage.from(uploadsBucket).createSignedUrl(path, 900);

  Future<Map<String, dynamic>> rollback(int id) async =>
      _asMap(await _rpc('dev_cmd_rollback', params: {'p_id': id}));

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
    await _prod.storage
        .from(uploadsBucket)
        .uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  Future<void> templateSave(String name, String spec) async =>
      _rpc('dev_cmd_template_save', params: {'p_name': name, 'p_spec': spec});

  /// Signed URL for a screenshot stored in the dev-cmd-proofs bucket.
  /// 15-minute expiry, generated on demand each view. (CHANGE #92 hardening.)
  Future<String> proofUrl(String path) =>
      _prod.storage.from('dev-cmd-proofs').createSignedUrl(path, 900);

  /// Rolling-window session token/cost usage vs the configurable budget —
  /// rendered verbatim (all strings + percent come from the backend).
  Future<Map<String, dynamic>> sessionUsage() async =>
      _asMap(await _rpc('dev_cmd_session_usage'));

  /// Ask the VM to pull a FRESH usage reading now (fired when the panel opens).
  /// The app only records the intent; the VM poller does the rate-limited fetch
  /// and pushes the result, which the next sessionUsage() render picks up.
  Future<void> requestUsageRefresh() async {
    try {
      await _rpc('dev_request_usage_refresh');
    } catch (_) {
      /* best-effort signal; the background poller still refreshes */
    }
  }

  // ── Worker pool plane (parallel build) ──────────────────────────────────
  /// The live pool snapshot: {config, state, leases}. `state` is what the VM
  /// orchestrator last published (active_workers, workers[], quota, load,
  /// shrink) — render-ready. The app never infers pool shape; it draws this.
  Future<Map<String, dynamic>> poolGet() async =>
      _asMap(await _rpc('pool_get'));

  /// Change one or more pool-config fields (cap / auto / billing_mode /
  /// idle_shutdown_min). PIN-gated by the backend — the app only passes the
  /// admin's patch + PIN and renders the verdict it returns.
  Future<Map<String, dynamic>> poolSet(
    Map<String, dynamic> patch,
    String pin,
  ) async => _asMap(
    await _rpc('pool_set', params: {'p_patch': patch, 'p_pin': pin}),
  );

  /// The files a command currently holds a lease on, while it builds — rendered
  /// verbatim as path chips in the row detail. Empty list when nothing locked.
  Future<List<Map<String, dynamic>>> leaseList(int commandId) async =>
      _asList(await _rpc('lease_list', params: {'p_command_id': commandId}));

  // ── Portable Memory plane (#182) ─────────────────────────────────────────
  /// The full agent-memory list: {screen_title, subtitle, labels, scopes,
  /// sections_hint, rows[]} — every string backend-owned, rendered verbatim by
  /// the Memory screen. One RPC, render-ready.
  Future<Map<String, dynamic>> memoryList() async =>
      _asMap(await _rpc('memory_list'));

  /// Upsert one rule (scope+section). Backend bumps version + audits. Returns
  /// the verdict ({ok, message, version}) rendered verbatim.
  Future<Map<String, dynamic>> memoryPut(
    String scope,
    String section,
    String body,
    int priority,
  ) async => _asMap(
    await _rpc(
      'memory_put',
      params: {
        'p_scope': scope,
        'p_section': section,
        'p_body': body,
        'p_priority': priority,
      },
    ),
  );

  /// Delete one rule by id. Backend audits. Returns {ok, message}.
  Future<Map<String, dynamic>> memoryDelete(String id) async =>
      _asMap(await _rpc('memory_delete', params: {'p_id': id}));

  // ── Permanent Conversations plane (#183) ─────────────────────────────────
  /// All threads, render-ready ({screen_title, labels, rows[]}). One RPC.
  Future<Map<String, dynamic>> threadList() async =>
      _asMap(await _rpc('thread_list'));

  /// One thread's full history ({thread, messages[]}) — rendered verbatim.
  Future<Map<String, dynamic>> threadOpen(String id) async =>
      _asMap(await _rpc('thread_open', params: {'p_id': id}));

  /// Semantic search across ALL threads. Embeds the query via the `embed` edge
  /// function (gte-small, 384-dim, no GCP) then runs pgvector cosine search. If
  /// embedding is unavailable the backend falls back to full-text — same RPC,
  /// so the caller never has to decide.
  Future<Map<String, dynamic>> conversationSearch(String query) async {
    List<dynamic>? emb;
    try {
      final res = await _prod.functions.invoke('embed', body: {'input': query});
      final d = res.data;
      if (d is Map && d['embedding'] is List) emb = d['embedding'] as List;
    } catch (_) {
      /* fall back to full-text below */
    }
    return _asMap(
      await _rpc(
        'conversation_search',
        params: {'p_query': query, 'p_embedding': emb, 'p_limit': 20},
      ),
    );
  }

  /// Mark a thread to be resumed by the next agent session. Returns the verdict.
  Future<Map<String, dynamic>> threadMarkResume(String id) async =>
      _asMap(await _rpc('thread_mark_resume', params: {'p_id': id}));

  // ── Runner control plane ────────────────────────────────────────────────
  Future<Map<String, dynamic>> ctlGet() async =>
      _asMap(await _rpc('dev_ctl_get'));

  /// CHANGE #1593 — the autoscaler's decision, taken again NOW.
  ///
  /// The health card's numbers are the last probe's, up to a minute old. This
  /// asks the backend to run the same decide step against the current vitals,
  /// so "why is it not climbing?" has an answer that does not require waiting
  /// for the next probe. It decides nothing here: every word, the brake name
  /// and the deciding metric arrive in the payload.
  Future<Map<String, dynamic>> autoscaleState() async =>
      _asMap(await _rpc('runner_autoscale_state'));

  /// CHANGE #1401 — the Runner card's re-login tap, the SAME RPC the Cron
  /// health panel calls, so the two surfaces can never start different logins.
  /// The backend starts `claude auth login` on the VM and answers with the
  /// whole claude_auth block again; the caller renders what comes back and
  /// guesses nothing about the states in between.
  Future<Map<String, dynamic>> claudeAuthRelogin() async =>
      _asMap(await _rpc('claude_auth_relogin_request'));

  /// Flip one toggle (vm|claude|workflow → on|off). Returns the backend verdict.
  ///
  /// CMD #1864 — a 'vm' flip no longer hands the caller a cloud errand. The
  /// control plane makes the EC2 call itself (`call_edge:false`) and answers
  /// with the vm block, the poll cadence and its own toast; the caller chases
  /// [vmPoll] until the payload says `settled`.
  Future<Map<String, dynamic>> ctlSet(String key, String value) async => _asMap(
    await _rpc('dev_ctl_set', params: {'p_key': key, 'p_value': value}),
  );

  /// CMD #1864 — one poll of the live EC2 state, run BY the control plane.
  ///
  /// vm-control writes `vm_status` with a service client for whichever project
  /// it lives in, and the copy holding a working AWS key is production's — so a
  /// browser calling it directly could never feed the chip, which reads the
  /// control plane. `dev_vm_poll` collects that reply on the control plane,
  /// writes it there, and returns the render-ready block plus the cadence to
  /// ask again on. Nothing about the answer is interpreted here.
  Future<Map<String, dynamic>> vmPoll() async => _asMap(await _rpc('dev_vm_poll'));

  /// Start/stop/status the builder VM via the vm-control edge function (carries
  /// the user's JWT; the function re-checks super_admin). Which cloud it drives
  /// is the backend's business — since CHANGE #224 that is AWS EC2, selected by
  /// `vm_identity.cloud`, and the caller never knows or cares.
  ///
  /// A refusal is DATA, not an exception: the function words its own outcome in
  /// `message` (e.g. "AWS access key not saved yet…") and returns a non-2xx for
  /// it, which the SDK throws. Unwrapping that body here is what lets the UI
  /// print the backend's guidance verbatim instead of a generic Dart fallback.
  Future<Map<String, dynamic>> vmControl(String action) async {
    try {
      final res = await _prod.functions.invoke(
        'vm-control',
        body: {'action': action},
      );
      final d = res.data;
      final m = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
      return {...m, 'ok': true};
    } on FunctionException catch (e) {
      final d = e.details;
      final m = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
      return {...m, 'ok': false};
    }
  }

  /// Official per-model API list rates (USD/Mtok in+out, fast variants where
  /// present) plus usd_inr and the source note — rendered read-only in the
  /// Rates sheet. Prices come from here, never from Dart literals.
  Future<Map<String, dynamic>> ratesGet() async =>
      _asMap(await _rpc('dev_rates_get'));

  // ── GCP Control plane (all render-ready from the live backend) ────────────
  Future<Map<String, dynamic>> gcpGet() async =>
      _asMap(await _rpc('dev_gcp_get'));

  /// Run the monthly cloud waste scan NOW via the `cloud-waste-scan` edge
  /// function (carries the user's JWT; the function re-checks super_admin and
  /// holds the AWS key, which is deliberately nowhere on the builder VM). It is
  /// READ-ONLY — it lists, prices and deletes nothing. Returns the same
  /// rendered payload `dev_gcp_get().waste` serves.
  Future<Map<String, dynamic>> wasteScan() async {
    final res = await _prod.functions
        .invoke('cloud-waste-scan', body: {'action': 'run'});
    final d = res.data;
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  /// One-tap GCP action (enable_api|restart_vm|resize_disk|quotas|billing_now).
  /// restart_vm carries the PIN. Enqueues an urgent gcp command; returns {id,...}.
  Future<Map<String, dynamic>> gcpAction(String action, {String? pin}) async =>
      _asMap(
        await _rpc(
          'dev_gcp_action',
          params: {'p_action': action, 'p_pin': pin},
        ),
      );

  Future<List<Map<String, dynamic>>> secretList() async =>
      _asList(await _rpc('secret_list'));
  Future<void> secretSet(String name, String value) async =>
      _rpc('secret_set', params: {'p_name': name, 'p_value': value});

  Future<Map<String, dynamic>> pinSet(String oldPin, String newPin) async =>
      _asMap(
        await _rpc('sec_pin_set', params: {'p_old': oldPin, 'p_new': newPin}),
      );
  Future<Map<String, dynamic>> freeze() async =>
      _asMap(await _rpc('sec_freeze'));
  Future<Map<String, dynamic>> unfreeze(String pin) async =>
      _asMap(await _rpc('sec_unfreeze', params: {'p_pin': pin}));
  Future<Map<String, dynamic>> budgetCapSet(num cap, String pin) async =>
      _asMap(
        await _rpc(
          'sec_budget_cap_set',
          params: {'p_cap': cap, 'p_pin': pin},
        ),
      );

  Future<List<Map<String, dynamic>>> auditList({
    String? search,
    int limit = 100,
  }) async => _asList(
    await _rpc(
      'sec_audit_list',
      params: {'p_limit': limit, 'p_search': search},
    ),
  );

  Future<void> scheduleSave(Map<String, dynamic> row) async =>
      _rpc('gcp_schedule_save', params: {'p': row});
  Future<void> scheduleDelete(int id) async =>
      _rpc('gcp_schedule_delete', params: {'p_id': id});

  // ── Play Store (CHANGE #280) ───────────────────────────────────────────
  // Two calls, no client logic: the screen payload, and the button.
  Future<Map<String, dynamic>> playState({int limit = 20}) async =>
      _asMap(await _rpc('play_state', params: {'p_limit': limit}));

  Future<Map<String, dynamic>> playPublishRequest({
    String track = 'production',
    String? notes,
  }) async => _asMap(
    await _rpc(
      'play_publish_request',
      params: {'p_track': track, 'p_notes': notes},
    ),
  );

  // ── the three release buttons (CHANGE #281) ────────────────────────────
  // One RPC each, no arguments the client invented. Whether a button may be
  // tapped at all is `can_test` / `can_promote` inside playState() — never a
  // rule computed here.
  Future<Map<String, dynamic>> playTestRequest({String? notes}) async =>
      _asMap(await _rpc('play_test_request', params: {'p_notes': notes}));

  Future<Map<String, dynamic>> playPromoteRequest({String? notes}) async =>
      _asMap(await _rpc('play_promote_request', params: {'p_notes': notes}));

  Future<Map<String, dynamic>> playAutoPublishSet(bool on) async =>
      _asMap(await _rpc('play_autopublish_set', params: {'p_on': on}));

  Future<Map<String, dynamic>> playRefreshRequest() async =>
      _asMap(await _rpc('play_refresh_request'));

  // ── The three reads CMD #1843 surfaced (wiring only) ─────────────────────
  // Each is ONE existing RPC returned verbatim. The rest of the audit's list
  // was already on screen (dev_ctl_get() carries health / disk / build_branch /
  // blocked / context, StripV3Card owns strip_v3_card, RunnerOpsCard owns
  // runner_ops_card, and Cron health owns the lane, boot and agent sessions),
  // so nothing there is fetched twice.
  Future<Map<String, dynamic>> deployLaneBatches({int limit = 8}) async =>
      _asMap(await _rpc('deploy_lane_batches', params: {'p_limit': limit}));
  Future<Map<String, dynamic>> cloudWasteGet() async =>
      _asMap(await _rpc('dev_cloud_waste_get'));
  Future<Map<String, dynamic>> rcHealth() async =>
      _asMap(await _rpc('dev_rc_health'));

  // ── The three controls CMD #1863's audit found with no button or card ────
  // Same rule as #1843: ONE existing RPC each, rendered verbatim, no new
  // backend. The rest of that audit's list was already reachable — 27 called
  // by name here, and five more (health / disk / blocked / build_branch /
  // context) ride inside `dev_ctl_get()`, so nothing below is fetched twice.
  //
  // Three of the audited names are deliberately NOT here: `deploy_status()` is
  // a rawer, label-less subset of `deploy_lane_status()`, which is already on
  // the Deploy lane card; `qa_report` refuses anything but service_role, so no
  // button using the app's console ticket could ever call it; and
  // `dev_cmd_retry` does not exist on either project — retry lives inside
  // `dev_cmd_fail`. All three need backend work this wiring-only change bans.

  /// CMD #1863 — "stop after this command". `strip_v3_drain_set(p_id)` writes
  /// `drain_after` and returns `strip_v3_card()`; a null id clears it. The
  /// Runners card has PRINTED the resulting `drain_label` since #1367 — there
  /// was simply never a way to set it.
  Future<Map<String, dynamic>> drainAfter(int? id) async =>
      _asMap(await _rpc('strip_v3_drain_set', params: {'p_id': id}));

  /// CMD #1863 — the build-branch ledger: every branch that has existed, how
  /// long it lived, how many builds used it and why it was created. The
  /// Runners panel's BuildBranchCard shows the LIVE branch and its recent
  /// attempts; this is the history behind that one line.
  Future<Map<String, dynamic>> buildBranchLog({int days = 7}) async =>
      _asMap(await _rpc('build_branch_log', params: {'p_days': days}));

  /// CMD #1863 — the standing lessons for a command's area. Every runner reads
  /// these before it builds (`devcmd.sh lessons_get`); nothing ever put them in
  /// front of Om. An absent area asks for all of them, which is what the
  /// backend does with a null `p_area`.
  Future<List<Map<String, dynamic>>> lessons({String? area, int? cmd}) async =>
      _asList(await _rpc('dev_lessons_get',
          params: {'p_area': (area != null && area.isEmpty) ? null : area,
                   'p_cmd': cmd}));

  /// CMD #1843 — the delete half of the template list, which had a backend and
  /// no button. Save and list were already wired.
  Future<void> templateDelete(int id) async =>
      _rpc('dev_cmd_template_delete', params: {'p_id': id});

  List<Map<String, dynamic>> _asList(dynamic v) =>
      (v as List?)
          ?.whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList() ??
      const [];
}
