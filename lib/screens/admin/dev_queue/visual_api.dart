import 'package:supabase_flutter/supabase_flutter.dart';

import 'dev_queue_service.dart';

/// CHANGE #637 — the visual lane's four calls, and WHERE they are sent.
///
/// The Dev Queue app talks to two projects: the control plane (medibo-dev) for
/// the queue itself, and PRODUCTION for anything that describes production.
/// These four describe production — the pictures, the approved baselines and
/// the request that opens a browser — so every one of them goes to
/// [DevQueueService.storageClient], the production client, exactly as
/// `test_coverage_home` does through the service's own `productionRpcs` set.
///
/// It lives beside the screen rather than inside DevQueueService only because
/// that file was held by another command's lease while this one was built; the
/// routing fact is stated once, here, and it belongs in `productionRpcs` the
/// next time that file is open. Nothing else in this class decides anything:
/// each method is one RPC and its payload, returned untouched.
class VisualBaselinesApi {
  final DevQueueService service;
  const VisualBaselinesApi(this.service);

  SupabaseClient get _prod => service.storageClient;

  Map<String, dynamic> _one(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  /// `visual_baseline_home(p_filter)` — the whole screen, already worded.
  Future<Map<String, dynamic>> home(String filter) async =>
      _one(await _prod.rpc('visual_baseline_home', params: {'p_filter': filter}));

  /// `visual_baseline_approve(p_shot_id)` — this run's picture becomes the
  /// approved one, and the backend closes the finding it raised.
  Future<Map<String, dynamic>> approve(int shotId) async =>
      _one(await _prod.rpc('visual_baseline_approve', params: {'p_shot_id': shotId}));

  /// `visual_baseline_approve_run(p_run_id)` — a deliberate redesign, in one tap.
  Future<Map<String, dynamic>> approveRun(int runId) async =>
      _one(await _prod.rpc('visual_baseline_approve_run', params: {'p_run_id': runId}));

  /// `visual_run_request(p_lane)` — the dispatcher cannot open a browser, so
  /// the screen QUEUES a pass the same way the nightly schedule does.
  Future<Map<String, dynamic>> runRequest(String lane) async =>
      _one(await _prod.rpc('visual_run_request', params: {'p_lane': lane}));
}
