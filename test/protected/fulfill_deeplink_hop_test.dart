// test/protected/fulfill_deeplink_hop_test.dart — CHANGE #632
//
// THE BUG CLASS: two ends of a feature ship and the hop between them does not.
//
// #537 built both halves of "the new-order alert opens the order where it
// actually is". The alert learned to hand over the order's uuid
// (AdminAlertOverlay.onOrderStageTap), Fulfill learned to open on a named
// stage (AdminFulfillmentScreen.openStage / initialStage), and the backend
// learned to answer where an order is (fulfill_order_stage). The two lines
// that JOIN them live in home_shell.dart, which was leased by another command
// for the whole of that build — so the button kept dropping the admin on the
// customer list, every RPC in the feature worked, and nothing was red.
//
// What this file holds down is the joint, not the ends:
//   1. `fulfillment:<stage_key>` is split back into a route the access matrix
//      knows plus a seed — never carried whole past the View gate.
//   2. Everything else survives the hop untouched, seed included.
//   3. A stage named outright beats the registry's route->stage pairing.
//   4. The shell still calls the hop, still passes the seed, and still hands
//      AdminAlertOverlay an onOrderStageTap — the three lines whose ABSENCE
//      is the entire subject of this change.
//
// Pure + source assertions only: no network, no Supabase, no widgets.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pharma_b2b/screens/shell/shell_extra_routes.dart';

void main() {
  group('CHANGE #632 — the stage hop', () {
    test('a colon form splits into the gated route plus the stage', () {
      final (route, seed) = shellFulfillHop('fulfillment:warehouse', null);
      expect(route, 'fulfillment',
          reason: 'the View gate must see a route the matrix has registered');
      expect(seed, 'warehouse');
    });

    test('the colon form NEVER reaches the gate whole', () {
      // Access.routeCanView() leaves an unregistered key alone by design, so
      // 'fulfillment:warehouse' would sail past a View=off on fulfillment.
      // That is why the split happens before the gate and not after it.
      final (route, _) = shellFulfillHop('${kFulfillStagePrefix}dispute', null);
      expect(route.contains(':'), isFalse);
    });

    test('a stage of no characters is still the fulfillment route', () {
      final (route, seed) = shellFulfillHop(kFulfillStagePrefix, null);
      expect(route, 'fulfillment');
      expect(seed, '');
    });

    test('every other route passes through untouched, seed and all', () {
      expect(shellFulfillHop('customers', null), ('customers', null));
      expect(shellFulfillHop('customer_360', 'abc'), ('customer_360', 'abc'));
      // The deep-link shape /admin/go/fulfillment/<stage> already arrives as
      // route + seed (AdminGoLink parks the tail as the subject). The hop must
      // not touch it — it is already in the shape the hop produces.
      expect(shellFulfillHop('fulfillment', 'pack'), ('fulfillment', 'pack'));
    });
  });

  group('CHANGE #632 — the shell actually makes the hop', () {
    final shell = File('lib/screens/home_shell.dart').readAsStringSync();

    test('_handleAdminNav splits the colon form before the View gate', () {
      final hop = shell.indexOf('shellFulfillHop(');
      final gate = shell.indexOf('Access.instance.routeCanView(route)');
      expect(hop, greaterThan(-1),
          reason: 'the shell stopped calling the hop — the colon form is dead '
              'again and this is exactly how #537 shipped half-wired');
      expect(gate, greaterThan(-1));
      expect(hop, lessThan(gate),
          reason: 'splitting AFTER the gate is a door around the gate');
    });

    test('the seed reaches shellOpenFulfillStage', () {
      expect(shell, contains('shellOpenFulfillStage(\n        route, seed,'),
          reason: 'without the seed, /admin/go/fulfillment/<stage> opens '
              'whichever tab that login used last');
    });

    test('the new-order alert is handed the stage tap, not just a list', () {
      expect(shell, contains('onOrderStageTap:'),
          reason: 'this one missing line is the whole of CHANGE #632');
      expect(shell, contains('shellOpenOrderStage(id, _handleAdminNav)'));
      // The list fallback stays: an alert that carries no order uuid still has
      // somewhere to go, which is what onOrderTap is for.
      expect(shell, contains("onOrderTap: () => _handleAdminNav('customers')"));
    });
  });

  group('CHANGE #632 — the backend owns where an order is', () {
    final src =
        File('lib/screens/shell/shell_extra_routes.dart').readAsStringSync();

    test('the stage comes from fulfill_order_stage and nowhere else', () {
      expect(src, contains("rpc('fulfill_order_stage'"));
      // No Dart guess from the alert's own fields, and no invented default
      // stage: an unanswerable call opens Fulfill on the backend's own first
      // stage instead of asserting one here.
      expect(src, contains("navigate(stage.isEmpty ? 'fulfillment'"));
    });

    test('a named stage beats the registry pairing', () {
      expect(
          src,
          contains(
              "var stage = routeKey == 'fulfillment' ? (seed ?? '') : '';"),
          reason: 'fulfillment carries no route->stage pairing of its own, so '
              'a dropped seed silently becomes "last tab used"');
    });
  });
}
