// CMD #1876 — the two pure decisions behind "assign a route and tell people".
//
// Everything a person READS here is the backend's: route_message_stops()
// writes sent_label / skipped_label / summary_label and every per-stop label,
// and route_plan_assign() writes the WhatsApp verdict. These classes exist so
// that fact is testable: they carry strings through untouched and refuse to
// invent one, and they hold the ONE thing the client legitimately decides —
// which link shape opens which screen.

/// The result of `route_message_stops(route_id)`.
///
/// Counts are carried as the backend sent them AND as the backend worded them.
/// Nothing here pluralises, sums or re-formats: `sentLabel` is printed, never
/// `'$sent sent'`.
class RouteMessageResult {
  final bool ok;
  final String title;
  final int sent;
  final int skipped;
  final int total;
  final String sentLabel;
  final String skippedLabel;
  final String summaryLabel;
  final String errorMessage;
  final List<RouteMessageRow> rows;

  const RouteMessageResult({
    required this.ok,
    required this.title,
    required this.sent,
    required this.skipped,
    required this.total,
    required this.sentLabel,
    required this.skippedLabel,
    required this.summaryLabel,
    required this.errorMessage,
    required this.rows,
  });

  static String _s(Object? v) => v == null ? '' : v.toString();
  static int _i(Object? v) => v is num ? v.toInt() : int.tryParse(_s(v)) ?? 0;

  factory RouteMessageResult.fromPayload(Map<String, dynamic> p) {
    final raw = (p['rows'] as List?) ?? const [];
    return RouteMessageResult(
      ok: p['ok'] == true,
      title: _s(p['title']),
      sent: _i(p['sent']),
      skipped: _i(p['skipped']),
      total: _i(p['total']),
      sentLabel: _s(p['sent_label']),
      skippedLabel: _s(p['skipped_label']),
      summaryLabel: _s(p['summary_label']),
      errorMessage: _s(p['message']),
      rows: raw
          .whereType<Map>()
          .map((e) => RouteMessageRow.fromPayload(Map<String, dynamic>.from(e)))
          .toList(growable: false),
    );
  }

  /// Rows arrive in the backend's own order (route stop sequence). Never sorted
  /// here — the sequence IS the walking order the worker will follow.
  List<RouteMessageRow> get orderedRows => rows;
}

/// One stop's outcome. `tone` names a design token pair, `label` is the words.
class RouteMessageRow {
  final int seq;
  final String name;
  final bool ok;
  final String tone;
  final String label;
  final String reason;

  const RouteMessageRow({
    required this.seq,
    required this.name,
    required this.ok,
    required this.tone,
    required this.label,
    required this.reason,
  });

  factory RouteMessageRow.fromPayload(Map<String, dynamic> p) =>
      RouteMessageRow(
        seq: RouteMessageResult._i(p['seq']),
        name: RouteMessageResult._s(p['name']),
        ok: p['ok'] == true,
        // An unknown tone falls back to the CAUTIOUS one: a skip must never
        // render as a success because a new tone name reached an old build.
        tone: p['tone'] == 'success' ? 'success' : 'warning',
        label: RouteMessageResult._s(p['label']),
        reason: RouteMessageResult._s(p['reason']),
      );
}

/// What `/admin/customers?…` should open.
///
/// The assignment WhatsApp links at ONE route (`?tab=routes&route=<uuid>`);
/// every other link is the older tab-only shape. A route id wins over `tab`,
/// because opening the route already selects the tab that holds it.
class RouteDeepLink {
  final String? tab;
  final String? routeId;
  const RouteDeepLink({this.tab, this.routeId});

  bool get opensRoute => (routeId ?? '').isNotEmpty;

  factory RouteDeepLink.parse(String search) {
    final q = Uri.splitQueryString(
        search.startsWith('?') ? search.substring(1) : search);
    final route = (q['route'] ?? '').trim();
    final tab = (q['tab'] ?? '').trim();
    return RouteDeepLink(
      tab: tab.isEmpty ? null : tab,
      routeId: route.isEmpty ? null : route,
    );
  }
}

/// The WhatsApp verdict `route_plan_assign()` returns alongside the assignment.
///
/// `label` is the only thing a person sees, and it is always the backend's —
/// including when the send did not happen, so a blocked template reads as a
/// sentence instead of vanishing.
class RouteAssignResult {
  final bool ok;
  final String assignmentId;
  final String message;
  final bool waSent;
  final String waLabel;
  final String waReason;
  final String routeLink;

  const RouteAssignResult({
    required this.ok,
    required this.assignmentId,
    required this.message,
    required this.waSent,
    required this.waLabel,
    required this.waReason,
    required this.routeLink,
  });

  factory RouteAssignResult.fromPayload(Map<String, dynamic> p) {
    final wa = (p['wa'] is Map)
        ? Map<String, dynamic>.from(p['wa'] as Map)
        : const <String, dynamic>{};
    return RouteAssignResult(
      ok: p['ok'] == true,
      assignmentId: RouteMessageResult._s(p['assignment_id']),
      message: RouteMessageResult._s(p['message']),
      waSent: wa['ok'] == true,
      waLabel: RouteMessageResult._s(wa['label']),
      waReason: RouteMessageResult._s(wa['reason']),
      routeLink: RouteMessageResult._s(p['route_link']),
    );
  }
}
