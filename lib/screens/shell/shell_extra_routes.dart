// lib/screens/shell/shell_extra_routes.dart — CHANGE #570
//
// A route table, not a screen. Four registry rows had promised doors that no
// dispatcher anywhere in the app actually opened:
//
//   admin.delivery_extras   the delivery programme (incentives, agency GST,
//                           training, the vehicle ledger) — CMD #407
//   admin.delivery_waves    auto-assignment waves — CHANGE #405
//   admin.returns_refunds   the returns and refunds console
//   admin.surface_map       the audit that found the other three
//
// The first three had been live tiles on the super-admin dashboard for weeks:
// the screens compiled, their RPCs answered, and tapping the tile fell through
// the shell's switch into the default branch and showed "route unavailable".
// That is the "built for X, missing from X" half of Om's report, and it is why
// surface_route now DECLARES every door and rg_check fails on a tile without
// one.
//
// WHY A SEPARATE FILE. home_shell.dart is held to one concern and under 2,000
// lines by its own protected guard (test/protected/god_file_guard_test.dart —
// four cases inline pushed it to 2,010 and turned that guard red). Registering
// a screen is now a row in this table plus a feature_registry INSERT, and the
// shell keeps one four-line lookup. It is also why two commands that each add
// a screen no longer collide on the shell.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dart:async';

import '../../services/access.dart';
import '../../utils/render_log.dart';
import '../admin/admin_delivery_extras_screen.dart';
import '../admin/order_timeline_screen.dart';
import '../admin/admin_fulfillment_screen.dart';
import '../admin/admin_delivery_waves_screen.dart';
import '../admin/admin_feedback_screen.dart';
import '../admin/returns_refunds_screen.dart';
import '../admin/surface_map_screen.dart';
import '../admin/damage_report_screen.dart';
import '../partner/zone_pnl_screen.dart';
import '../admin/wa_assistant_screen.dart';
import '../admin/search_synonyms_screen.dart';
import '../admin/support_threads_screen.dart';
import '../partner/partner_tasks_screen.dart';
import '../worker/worker_tasks_screen.dart';
import '../admin/kyc_review_screen.dart';
import '../partner/partner_documents_screen.dart';
import '../admin/settlement_invoices_screen.dart'; // CHANGE #695 — tax invoices
import '../partner/partner_issues_screen.dart'; // CHANGE #696 — partner issues
import '../partner/partner_returns_screen.dart'; // CHANGE #710 — returns door

/// CHANGE #697 — the whole-order feedback card's one hook into the shell.
/// `home_shell.dart` sits under a 2,000-line guard (#340 / #327 layer 1) and
/// already imports this file, so the hook is re-exported here rather than
/// costing the shell an import line of its own. WHETHER to ask is
/// `order_feedback_pending()`'s answer — see order_feedback_sheet.dart.
export '../customer/order_feedback_sheet.dart' show maybeAskOrderFeedback;
// CHANGE #790 — the typeahead panel and its controller, re-exported so the
// shell's PART files (shell_header_chrome.dart) can see them without adding a
// line to home_shell.dart, which sits at 1,998 of a hard 2,000-line guard.
export '../../widgets/search_typeahead.dart'
    show SearchSuggestions, SearchSuggestController;

/// The screen a route_key opens, or null when this table does not own it —
/// null means "keep looking", never "broken", so the shell's own switch and
/// its backend-worded default branch stay in charge of an unknown route.
Widget? shellExtraRouteScreen(String routeKey) => switch (routeKey) {
      'delivery_extras' => const AdminDeliveryExtrasScreen(),
      'delivery_waves' => const AdminDeliveryWavesScreen(),
      'returns_refunds' => const ReturnsRefundsScreen(),
      'surface_map' => const SurfaceMapScreen(),
      // CHANGE #697 — the Feedback desk. order_feedback_screen() pins a
      // partner to their own zone and refuses anyone else, so the door is
      // opened here and the authorisation stays in the RPC.
      'feedback' => const AdminFeedbackScreen(),
      // CHANGE #707 — the fulfilment stage's owner, from both ends.
      //
      // These two were written against partnerDestination(), the resolver in
      // partner_home_screen.dart — and #653 removed the last thing that CALLED
      // that resolver when it retired the partner surface. So both screens
      // compiled, both RPCs answered, and both tiles fell through the shell's
      // switch into "route unavailable": the exact shape this file was created
      // for in #570, one more time. The door is here, where the shell already
      // looks, and surface_route declares it so rg_check can see it.
      //
      // Authorisation is NOT here. fulfil_task_board() answers a caller who is
      // neither office nor a partner with can_write:false and its own refusal
      // sentence, and fulfil_my_tasks() refuses anyone who is not a worker —
      // so the door being open to a role is never the thing that decides what
      // that role may read or write.
      'fulfil_tasks' => const PartnerTasksScreen(),
      'my_tasks' => const WorkerTasksScreen(),
      // CHANGE #705 — the KYC review console. kyc_review_queue() gates it
      // itself (an admin, or a partner holding partner.kyc_review, zone-scoped)
      // and answers `not_authorized` with its own sentence, so the door is
      // opened here and the authorisation stays in the RPC.
      'kyc_review' => const KycReviewScreen(),
      // CHANGE #692 — the partner's OWN agreement + KYC documents.
      //
      // The backend has emitted this tile since the migration landed:
      // feature_registry `partner.documents` -> route_key
      // `partner_documents`, and access_role_default gives a partner
      // view+write on it. Its surface_route row names THIS function as
      // `handled_by`, and the door was the one piece that never landed
      // — so the tile drew, the tap fell through the shell's switch and
      // a partner got the backend's "route unavailable" sentence on a
      // feature whose whole point is to unblock their own zone. Same
      // shape as #707 above, one more time.
      //
      // Authorisation is NOT here. partner_documents_screen() resolves
      // the partner from the CALLER and answers anyone else with its
      // own refusal, so opening the door to a role decides nothing
      // about what that role may read or sign.
      'partner_documents' => const PartnerDocumentsPage(),
      // CHANGE #713 — the other end of every customer conversation: the
      // messages waiting on an answer, and the calls somebody owes a customer.
      //
      // ONE door for the partner and for the office. thread_inbox() answers a
      // partner with their own zone and the office with all of them and
      // refuses anyone who is neither, so the door being open to a role
      // decides nothing about what that role reads.
      'order_threads' => const SupportThreadsScreen(),
      // CHANGE #709 — the damage report. damage_report() gates it itself (an
      // admin, or a partner holding partner.fulfil_tasks, zone-scoped) and
      // answers not_authorized with its own sentence, so the door is opened
      // here and the authorisation stays in the RPC.
      'damage_report' => const DamageReportScreen(),
      // CHANGE #694 — Zone P&L. zone_pnl() fences itself (mediBO sees every
      // zone, a partner only its own) and the screen renders its refusal,
      // the same story as damage_report above.
      'zone_pnl' => const ZonePnlScreen(),
      // CHANGE #694 — the PARTNER's door onto the same screen.
      //
      // This route was wired only in partnerDestination(), and that resolver
      // has had no caller since #653 merged the partner surface into this
      // shell — the same mistake #707, #692 and #695 each document above. So
      // feature_registry emitted the `partner.zone_pnl` tile, access_role_default
      // gave a partner view on it, zone_pnl() answered a partner with its own
      // zone and its partner_visible lines — and the tap fell through this
      // switch. Verified live before the fix: /admin/go/partner_zone_pnl as
      // test.partner1 never reached the screen.
      //
      // Same screen, not a copy: zone_pnl() resolves the zone from the caller's
      // own partner row, so this door needs no argument and decides nothing.
      'partner_zone_pnl' => const ZonePnlScreen(),
      // CHANGE #714 — the WhatsApp assistant console. wa_assistant_console()
      // gates on get_my_role() and the screen renders its refusal, the same
      // story as damage_report above.
      'wa_assistant' => const WaAssistantScreen(),
      // CHANGE #790 — Admin → Search synonyms. search_synonyms_list() gates
      // itself on get_my_role() and the screen renders its refusal, the same
      // story as damage_report above.
      'search_synonyms' => const SearchSynonymsScreen(),
      // CHANGE #695 — the GST tax invoice raised on every settled period, its
      // credit notes and the monthly GSTR-1 register.
      //
      // Declared here and NOT in partnerDestination(), which is the mistake
      // #710 shipped to live change #1074 hours before this: that resolver has
      // had no caller since #653 merged the partner surface into this shell, so
      // a route wired only there is a registry tile that does nothing on tap.
      //
      // Authorisation is not the door. settlement_invoices() clamps a partner
      // to their own id - the p_partner_id parameter is a filter for the office
      // and never a way in - and refuses anyone who is neither office nor
      // partner with its own sentence.
      'settlement_invoices' => const SettlementInvoicesScreen(),
      // CHANGE #696 — the mediBO <-> partner escalation channel, one door for
      // both directions. The registry row carries roles_allowed
      // {admin, super_admin, partner}, so the SAME tile is what a partner taps
      // to raise an issue and what the office taps to work the queue.
      //
      // Authorisation is not the door, again: partner_ticket_list() answers a
      // partner with their OWN tickets and the office with every zone, and
      // refuses anyone who is neither with its own sentence — the screen never
      // decides who may read what.
      'partner_issues' => const PartnerIssuesScreen(),
      // CHANGE #710 — stock going BACK to a supplier, and the debit note it
      // raises.
      //
      // This arm is the whole reason #710 needed a second pass. The route was
      // wired into partnerDestination() in partner_home_screen.dart, which is
      // where a partner route used to be declared — and #653 retired the last
      // caller of that resolver when it merged the partner surface into this
      // shell. So feature_registry shipped the tile, access_role_default
      // granted it to admin, super_admin and partner, PartnerReturnsScreen
      // compiled and every RPC answered, and the tap fell through
      // _handleAdminNav into "route unavailable": proven on live change #1074,
      // where /admin/go/supplier_returns rendered the storefront home. The
      // third time this file's own comments describe the same failure.
      //
      // Authorisation is NOT here. partner_return_console() zone-clamps a
      // partner to their own returns and refuses anyone who is neither office
      // nor partner with its own sentence, so the door being open to a role
      // decides nothing about what that role may read or write.
      'supplier_returns' => const PartnerReturnsScreen(),
      _ => null,
    };

/// The one route that must reach its stage before the matrix has loaded.
const Map<String, String> _coldBootStages = {'exceptions': 'exceptions'};

/// CHANGE #754 — a route whose screen now lives in the Fulfill pipeline opens
/// Fulfill on that stage, wherever the link came from: an old nav row, a
/// bookmark, a `/admin/go/<route>` URL, a partner console tile.
///
/// Customer orders, Supplier inquiry and Supplier orders all moved into
/// Fulfill and their old entry points kept opening the screens they used to
/// live on. The pairing is the BACKEND's — `access_boot().routes[].stage`
/// matches a route to the fulfill_tab feature that shares its canonical key —
/// so moving the NEXT screen into Fulfill is a registry edit and not a deploy.
///
/// Returns true when it took the route. [goToPage] is the shell's own page
/// switch; this shard has no state of its own, which is the point: it lives
/// here so `home_shell.dart` stays a shell and not the ninth concern again
/// (#340 / CHANGE #327 layer 1).
bool shellOpenFulfillStage(
    String routeKey, String? seed, void Function(int index) goToPage) {
  // CHANGE #632 — a stage NAMED outright wins over the registry pairing. Two
  // callers name one: `/admin/go/fulfillment/<stage_key>`, whose tail
  // AdminGoLink parks as the seed, and the new-order alert, which asks the
  // backend where its order is and says `fulfillment:<stage_key>`. `fulfillment`
  // carries no pairing of its own, so before this the seed was simply dropped
  // and the link opened whichever tab that login had used last.
  var stage = routeKey == 'fulfillment' ? (seed ?? '') : '';
  if (stage.isEmpty) stage = Access.instance.fulfillStageForRoute(routeKey);
  // A deep link can land BEFORE access_boot() answers, and an unresolved
  // matrix carries no pairing at all. #690 hand-wrote a branch in the shell for
  // exactly that cold boot; it lives here now so the shell keeps shrinking, and
  // it is a fallback rather than a source — the resolved matrix always wins.
  if (stage.isEmpty && !Access.instance.matrix.resolved) {
    stage = _coldBootStages[routeKey] ?? '';
  }
  if (stage.isEmpty) return false;
  RenderLog.write('c754_route_to_fulfill', '$routeKey>$stage');
  goToPage(10);
  WidgetsBinding.instance.addPostFrameCallback(
      (_) => AdminFulfillmentScreen.openStage(stage));
  return true;
}

/// CHANGE #632 — the route shape that names a Fulfill stage outright.
///
/// `fulfillment:<stage_key>`. It exists because the shell's nav takes ONE
/// string, and a caller that already knows the stage (the new-order alert,
/// once it has asked the backend) has nowhere else to put it.
const String kFulfillStagePrefix = 'fulfillment:';

/// Split `fulfillment:<stage_key>` back into the route the access matrix knows
/// and the stage as a seed, so the shell's own View gate still runs on
/// `fulfillment` itself.
///
/// This is not cosmetic. `routeCanView()` deliberately leaves an UNREGISTERED
/// key alone — hiding a destination the backend has not catalogued yet would
/// delete it — and `fulfillment:warehouse` is not a registered key, so a colon
/// form carried past the gate would be a door around the gate. Everything else
/// is returned untouched, seed included.
(String, String?) shellFulfillHop(String route, String? seed) =>
    route.startsWith(kFulfillStagePrefix)
        ? ('fulfillment', route.substring(kFulfillStagePrefix.length))
        : (route, seed);

/// CHANGE #632 — the new-order alert's "View orders" button, finished.
///
/// #537 built both ends and neither one hop: the alert learned to hand over
/// the order's uuid (AdminAlertOverlay.onOrderStageTap), Fulfill learned to
/// open on a named stage (AdminFulfillmentScreen.openStage), and the button
/// still dropped the admin on the customer list to go and find the order by
/// eye, because the two lines that join them live in `home_shell.dart` and
/// that file was leased for the whole of #537's build.
///
/// WHERE the order is, is the BACKEND's answer — `fulfill_order_stage()` reads
/// disputes, deliveries, packing, bags, arrivals, shop counts, supplier orders
/// and inquiries in that order — never a guess from the alert's own fields. An
/// order that has already reached Pack opens on Pack.
///
/// A refusal, an order that no longer exists, or no network at all is not an
/// error the admin has to read: Fulfill still opens, on the stage it would
/// have opened on anyway. That is strictly what the button promised, and it is
/// the customer list this replaces that was the actual dead end.
Future<void> shellOpenOrderStage(
    String orderId, void Function(String route) navigate) async {
  var stage = '';
  try {
    final res = await Supabase.instance.client
        .rpc('fulfill_order_stage', params: {'p_order_id': orderId});
    if (res is Map && res['ok'] == true) {
      stage = (res['stage_key'] as String?) ?? '';
    }
  } catch (_) {
    // Deliberately swallowed — the fallback below IS the error handling.
  }
  RenderLog.write('c632_order_stage', stage.isEmpty ? 'none' : stage);
  navigate(stage.isEmpty ? 'fulfillment' : '$kFulfillStagePrefix$stage');
}

/// CHANGE #754 — run [then] once the access matrix has answered.
///
/// A deep link is consumed in the shell's first frame, and `access_boot()` is
/// still in flight then: `/admin/go/inquiry` fell straight through to the
/// "not in your app yet" branch on a cold boot, because the route -> Fulfill
/// stage pairing lives in that answer. #690 papered over the one route it
/// cared about with a hand-written case; this waits for the answer instead.
///
/// [timeout] is the safety net, not the path: a matrix that never resolves
/// (anonymous, or a failed boot call) must not swallow the link entirely — the
/// route is then handled exactly as it was before this change.
void shellWhenAccessResolved(void Function() then,
    {Duration timeout = const Duration(seconds: 5)}) {
  if (Access.instance.matrix.resolved) {
    then();
    return;
  }
  var fired = false;
  late void Function() listener;
  void run(String how) {
    if (fired) return;
    fired = true;
    Access.instance.removeListener(listener);
    RenderLog.write('c754_deep_link_wait', how);
    then();
  }

  listener = () {
    if (Access.instance.matrix.resolved) run('resolved');
  };
  Access.instance.addListener(listener);
  Timer(timeout, () => run('timeout'));
}


/// CHANGE #689 (feature_gaps #75) — "where is CPO260726NIT123O1", asked as a
/// question. Lives here for the same reason the four routes above do:
/// home_shell.dart is held under 2,000 lines by its own guard, so a route's
/// SCREEN and its import belong in the shard and only the `case` stays in the
/// switch — which is what test/protected/admin_nav_reachability_test.dart
/// reads to prove the tile is not a dead tap.
///
/// [seed] is the order code a deep link carried (/admin/go/order_timeline/CPO…).
/// Empty is not a missing argument: the backend answers an empty query with the
/// most recent orders, so the screen opens on something useful either way.
void shellOpenOrderTimeline(BuildContext context, String? seed) {
  Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => OrderTimelineScreen(seed: (seed ?? '').trim())));
}
