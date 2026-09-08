// CHANGE #754 — which stage the Fulfil console shows when a payload lands.
//
// This one decision has now been fought over by two changes and lost twice, so
// it lives here as a pure function with a protected test instead of inside a
// setState in a 15,000-line screen:
//
//   • #690 parks a deep link's stage (`/admin/go/<stage>`) until
//     `fulfill_tabs()` answers, then applies it.
//   • #688 lands a FRESH console on `payload.firstStage`, so reordering the
//     bar in Postgres moves where the console opens.
//
// They collided: #690 applied the pending stage and CLEARED the field, and
// #688's guard then read `pendingStage.isEmpty` — which the line above had just
// made true — and overwrote the answer with the first tab. Every
// /admin/go/<stage> link resolved correctly and was replaced by the Ops board
// one statement later, including #690's own `/admin/go/exceptions`.
//
// The rule, in precedence order:
//   1. A stage the CALLER asked for (a deep link, or `initialStage`) wins,
//      whenever the payload actually contains it.
//   2. Otherwise keep the operator where they are — a permission change or a
//      reordered bar must never move somebody's open tab.
//   3. Only a first mount that nobody has steered lands on the backend's own
//      first stage.
//   4. A current stage that is no longer in the payload falls back to the
//      first one rather than rendering nothing.

import 'package:flutter/foundation.dart';

@immutable
class FulfillLanding {
  const FulfillLanding({required this.stage, required this.picked});

  /// The stage to show.
  final String stage;

  /// True when this was somebody's explicit choice (a deep link), so a later
  /// payload must not re-land the console on the backend's first tab.
  final bool picked;
}

/// [stages] is `payload.tabs[].stageKey`, in payload order.
FulfillLanding resolveLandingStage({
  required List<String> stages,
  required String current,
  required String pending,
  required bool landed,
  required bool picked,
  String? initialStage,
  int initialTab = 0,
  bool bounded = false,
}) {
  if (stages.isEmpty) return FulfillLanding(stage: current, picked: picked);

  // 1. The caller's own stage. Clearing `pending` is what used to lose it, so
  //    the answer carries `picked: true` out with it.
  if (pending.isNotEmpty && stages.contains(pending)) {
    return FulfillLanding(stage: pending, picked: true);
  }

  var stage = current;
  var wasPicked = picked;

  // 4. A stage that is gone cannot stay selected.
  if (!stages.contains(stage)) stage = stages.first;

  // 3. The backend's landing stage — first mount, nobody steering, no caller
  //    stage, no legacy tab index and no bounded caller.
  if (!landed &&
      !wasPicked &&
      initialStage == null &&
      initialTab == 0 &&
      !bounded) {
    stage = stages.first;
  }

  return FulfillLanding(stage: stage, picked: wasPicked);
}
