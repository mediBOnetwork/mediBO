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

/// `params` is passed straight through: the builder assembles the ten arguments
/// and this wrapper does not second-guess which of them may be null.
Future<Map<String, dynamic>> waCampaignSave(Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_campaign_save', params: params));
