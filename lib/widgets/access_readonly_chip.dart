// CHANGE #653 — one chip, every tab row.
//
// A login with View on and Write off still opens the screen; this is how the
// screen SAYS so. The word is always the backend's — `access_boot()
// .readonly_badge` on the admin screens, `fulfill_tabs().readonly_badge` on
// the fulfilment pipeline — and the chip prints whatever it is handed.
//
// It takes the label rather than reading the matrix itself on purpose: this
// widget is rendered from `fulfill_pipeline_tabs.dart`, which is deliberately
// import-light so it stays loadable by a Dart VM widget test. Reaching for the
// Access singleton here would drag Supabase into that test binary.

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// The backend's own "View only" word, shown on a tab this login may open but
/// not change. Decides nothing; an empty [label] renders nothing at all.
class AccessReadOnlyChip extends StatelessWidget {
  const AccessReadOnlyChip({super.key, required this.label});

  /// Backend copy, printed verbatim.
  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(left: Ds.space.x8),
      child: Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration:
            BoxDecoration(color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
        child: Text(label, style: Ds.t.caption),
      ),
    );
  }
}
