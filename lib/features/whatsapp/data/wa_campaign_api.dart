// CHANGE — WhatsApp campaign builder + tracking link redirect.
//
// Every campaign RPC in one place, as injectable function types. Screens take
// these as nullable constructor params: production leaves them null and gets
// the Supabase call below, tests pass a stub and never touch the network.
//
// These wrappers do exactly one thing — call the RPC and hand back the jsonb as
// a Map. No defaulting, no reshaping, no renaming of fields, no swallowing of
// an `error` key into a thrown exception. The screen renders what the backend
// said, including the error strings, so a wrapper that "helpfully" normalised a
// payload would be the app deciding.
//
// PARAMETER NAMES ARE NOT UNIFORM AND MUST NOT BE GUESSED. Verified against
// pg_proc on 2026-08-04:
//   wa_campaign_preflight(p_campaign_id uuid)          <- NOT p_id
//   wa_campaign_dry_run  (p_campaign_id uuid, p_n int) <- NOT p_id
//   wa_campaign_schedule (p_id uuid, p_at timestamptz)
//   wa_campaign_action   (p_id uuid, p_action text)
//   wa_campaign_detail   (p_id uuid, p_limit int)
// A wrong name is not a compile error — Postgres reports "function does not
// exist" at runtime, which reads like a permissions problem and wastes a night.
import 'package:supabase_flutter/supabase_flutter.dart';

typedef WaCampaignsScreenRpc = Future<Map<String, dynamic>> Function();
typedef WaTemplatesScreenRpc = Future<Map<String, dynamic>> Function();
typedef WaTemplateTokensRpc = Future<List<dynamic>> Function();
typedef WaCampaignPreflightRpc = Future<Map<String, dynamic>> Function(String id);
typedef WaCampaignDryRunRpc = Future<Map<String, dynamic>> Function(String id, int n);
typedef WaCampaignScheduleRpc = Future<Map<String, dynamic>> Function(String id, DateTime? at);
typedef WaCampaignActionRpc = Future<Map<String, dynamic>> Function(String id, String action);
typedef WaCampaignDetailRpc = Future<Map<String, dynamic>> Function(String id, int limit);
typedef WaCampaignEstimateRpc = Future<Map<String, dynamic>> Function(int recipients, String category);
typedef WaLinkClickRpc = Future<Map<String, dynamic>> Function(String code);
typedef WaCampaignSaveRpc = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);

// CHANGE — budget, control group, repeat, saved segments and drip sequences.
//
// Same rule as above: verified parameter names, no reshaping. Note
// wa_campaign_holdout takes p_campaign_id (like preflight and dry_run), while
// wa_drip_action takes p_id (like wa_campaign_action). They are not uniform and
// were not guessed.
typedef WaCampaignHoldoutRpc = Future<Map<String, dynamic>> Function(String id);
typedef WaAudiencesScreenRpc = Future<Map<String, dynamic>> Function();
typedef WaAudienceSaveRpc = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);
typedef WaAudienceDeleteRpc = Future<Map<String, dynamic>> Function(String id);
typedef WaDripsScreenRpc = Future<Map<String, dynamic>> Function();
typedef WaDripSaveRpc = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);
typedef WaDripStepSaveRpc = Future<Map<String, dynamic>> Function(Map<String, dynamic> params);
typedef WaDripActionRpc = Future<Map<String, dynamic>> Function(String id, String action);

/// Not every payload in this family carries an `ok` key: wa_audiences_screen
/// and wa_drips_screen return their rows bare, and only speak up with
/// {error, message} when something is wrong. Treating a missing `ok` as a
/// failure would blank two working screens, so absence is not an answer here —
/// only an explicit `error`, or an explicit `ok:false`, is.
///
/// The returned string is the backend's own sentence, rendered verbatim.
String? waPayloadError(Map<String, dynamic> res) {
  if (res['error'] != null) {
    return (res['message'] ?? res['error']).toString();
  }
  if (res.containsKey('ok') && res['ok'] != true) {
    return (res['message'] ?? res['error'] ?? '').toString();
  }
  return null;
}

Map<String, dynamic> _asMap(dynamic res) =>
    res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

List<dynamic> _asList(dynamic res) => res is List ? res : const <dynamic>[];

SupabaseClient get _db => Supabase.instance.client;

Future<Map<String, dynamic>> waCampaignsScreen() async =>
    _asMap(await _db.rpc('wa_campaigns_screen'));

Future<Map<String, dynamic>> waTemplatesScreen() async =>
    _asMap(await _db.rpc('wa_templates_screen'));

Future<List<dynamic>> waTemplateTokens() async =>
    _asList(await _db.rpc('wa_template_tokens'));

Future<Map<String, dynamic>> waCampaignPreflight(String id) async =>
    _asMap(await _db.rpc('wa_campaign_preflight', params: {'p_campaign_id': id}));

Future<Map<String, dynamic>> waCampaignDryRun(String id, int n) async =>
    _asMap(await _db.rpc('wa_campaign_dry_run',
        params: {'p_campaign_id': id, 'p_n': n}));

Future<Map<String, dynamic>> waCampaignSchedule(String id, DateTime? at) async =>
    _asMap(await _db.rpc('wa_campaign_schedule',
        params: {'p_id': id, 'p_at': at?.toUtc().toIso8601String()}));

Future<Map<String, dynamic>> waCampaignAction(String id, String action) async =>
    _asMap(await _db.rpc('wa_campaign_action',
        params: {'p_id': id, 'p_action': action}));

Future<Map<String, dynamic>> waCampaignDetail(String id, int limit) async =>
    _asMap(await _db.rpc('wa_campaign_detail',
        params: {'p_id': id, 'p_limit': limit}));

Future<Map<String, dynamic>> waCampaignEstimate(int recipients, String category) async =>
    _asMap(await _db.rpc('wa_campaign_estimate',
        params: {'p_recipients': recipients, 'p_category': category}));

/// Granted to anon — this is the only campaign RPC a logged-out phone calls.
Future<Map<String, dynamic>> waLinkClick(String code) async =>
    _asMap(await _db.rpc('wa_link_click', params: {'p_code': code}));

/// `params` is passed straight through: the builder assembles the arguments
/// and this wrapper does not second-guess which of them may be null.
Future<Map<String, dynamic>> waCampaignSave(Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_campaign_save', params: params));

// ── budget / control group / repeat / segments / sequences ──────────────────

Future<Map<String, dynamic>> waCampaignHoldout(String id) async =>
    _asMap(await _db.rpc('wa_campaign_holdout', params: {'p_campaign_id': id}));

Future<Map<String, dynamic>> waAudiencesScreen() async =>
    _asMap(await _db.rpc('wa_audiences_screen'));

Future<Map<String, dynamic>> waAudienceSave(Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_audience_save', params: params));

Future<Map<String, dynamic>> waAudienceDelete(String id) async =>
    _asMap(await _db.rpc('wa_audience_delete', params: {'p_id': id}));

Future<Map<String, dynamic>> waDripsScreen() async =>
    _asMap(await _db.rpc('wa_drips_screen'));

Future<Map<String, dynamic>> waDripSave(Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_drip_save', params: params));

Future<Map<String, dynamic>> waDripStepSave(Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_drip_step_save', params: params));

Future<Map<String, dynamic>> waDripAction(String id, String action) async =>
    _asMap(await _db.rpc('wa_drip_action',
        params: {'p_id': id, 'p_action': action}));
