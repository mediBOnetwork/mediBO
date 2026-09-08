// lib/models/order_timeline_view.dart — CHANGE #689 (feature_gaps #75)
//
// The order timeline's only decisions, in one place a test can reach without a
// widget tree. And there are barely any: order_timeline() already sorted the
// events, worded every label, chose every tone, named the actor and pre-filled
// the action on the step the order is waiting on.
//
// What this class does NOT do is the point of it:
//   * it does not sort — `events` is the payload's order, because the BACKEND
//     decided that a WhatsApp attempt at 14:02 comes after an inquiry at 05:00;
//   * it does not compute lateness, tone, or an age — `late`, `tone` and
//     `age_label` are strings the server sent;
//   * it does not know a supplier's name is secret — the customer's payload
//     simply arrives without one;
//   * it does not know which RPC an action calls — the action carries its own
//     `rpc` and `args`, so a new action is a backend change, not a deploy.

/// One actor block off an event. `has` false means the backend deliberately
/// sent nobody — an absent actor is never a blank row or a dash.
class TimelineActor {
  final bool has;
  final String kind;
  final String name;
  final String phone;
  final String label;

  const TimelineActor({
    required this.has,
    required this.kind,
    required this.name,
    required this.phone,
    required this.label,
  });

  bool get hasPhone => phone.isNotEmpty;

  static const none = TimelineActor(
    has: false,
    kind: '',
    name: '',
    phone: '',
    label: '',
  );

  factory TimelineActor.from(dynamic v) {
    if (v is! Map) return none;
    final m = Map<String, dynamic>.from(v);
    if (m['has'] != true) return none;
    return TimelineActor(
      has: true,
      kind: m['kind']?.toString() ?? '',
      name: m['name']?.toString() ?? '',
      phone: m['phone']?.toString() ?? '',
      label: m['label']?.toString() ?? '',
    );
  }
}

/// One action off an event. The app never chooses the RPC or builds the args:
/// it calls `rpc` with `args` exactly as they arrived.
class TimelineAction {
  final bool has;
  final String kind;
  final String label;
  final String tone;
  final String rpc;
  final Map<String, dynamic> args;

  const TimelineAction({
    required this.has,
    required this.kind,
    required this.label,
    required this.tone,
    required this.rpc,
    required this.args,
  });

  static const none = TimelineAction(
    has: false,
    kind: '',
    label: '',
    tone: '',
    rpc: '',
    args: {},
  );

  factory TimelineAction.from(dynamic v) {
    if (v is! Map) return none;
    final m = Map<String, dynamic>.from(v);
    // An action with no rpc or no label is not an action. Refusing to draw it
    // is how a half-built payload stays invisible instead of throwing.
    if (m['has'] != true) return none;
    final rpc = m['rpc']?.toString() ?? '';
    final label = m['label']?.toString() ?? '';
    if (rpc.isEmpty || label.isEmpty) return none;
    return TimelineAction(
      has: true,
      kind: m['kind']?.toString() ?? '',
      label: label,
      tone: m['tone']?.toString() ?? '',
      rpc: rpc,
      args: m['args'] is Map
          ? Map<String, dynamic>.from(m['args'] as Map)
          : const {},
    );
  }
}

/// One row of the timeline, printed as it arrived.
class TimelineEvent {
  final String stage;
  final String label;
  final String detail;
  final String tsLabel;
  final String ageLabel;
  final String tone;
  final bool late;
  final String lateLabel;
  final bool isCurrent;
  final TimelineActor actor;
  final TimelineAction action;

  const TimelineEvent({
    required this.stage,
    required this.label,
    required this.detail,
    required this.tsLabel,
    required this.ageLabel,
    required this.tone,
    required this.late,
    required this.lateLabel,
    required this.isCurrent,
    required this.actor,
    required this.action,
  });

  bool get hasDetail => detail.isNotEmpty;

  factory TimelineEvent.from(Map<String, dynamic> m) => TimelineEvent(
    stage: m['stage']?.toString() ?? '',
    label: m['label']?.toString() ?? '',
    detail: m['detail']?.toString() ?? '',
    tsLabel: m['ts_label']?.toString() ?? '',
    ageLabel: m['age_label']?.toString() ?? '',
    tone: m['tone']?.toString() ?? '',
    late: m['late'] == true,
    lateLabel: m['late_label']?.toString() ?? '',
    isCurrent: m['is_current'] == true,
    actor: TimelineActor.from(m['actor']),
    action: TimelineAction.from(m['action']),
  );
}

/// The whole `order_timeline()` payload, as far as the timeline block cares.
class OrderTimelineView {
  final bool ok;
  final String access;
  final bool canAct;
  final String heading;
  final String emptyLabel;
  final String privacyNote;
  final List<TimelineEvent> events;

  const OrderTimelineView({
    required this.ok,
    required this.access,
    required this.canAct,
    required this.heading,
    required this.emptyLabel,
    required this.privacyNote,
    required this.events,
  });

  static const empty = OrderTimelineView(
    ok: false,
    access: 'none',
    canAct: false,
    heading: '',
    emptyLabel: '',
    privacyNote: '',
    events: [],
  );

  /// `access: 'none'` is not an error to shout about — it is the backend
  /// saying this viewer has no business seeing the timeline, so the block is
  /// simply absent.
  bool get visible => ok && access != 'none';

  bool get isEmpty => events.isEmpty;

  factory OrderTimelineView.from(dynamic v) {
    if (v is! Map) return empty;
    final m = Map<String, dynamic>.from(v);
    final raw = m['events'];
    return OrderTimelineView(
      ok: m['ok'] != false,
      access: m['access']?.toString() ?? 'none',
      canAct: m['can_act'] == true,
      heading: m['events_heading']?.toString() ?? '',
      emptyLabel: m['events_empty']?.toString() ?? '',
      privacyNote: m['privacy_note']?.toString() ?? '',
      events: raw is List
          ? raw
                .whereType<Map>()
                .map((e) => TimelineEvent.from(Map<String, dynamic>.from(e)))
                .toList(growable: false)
          : const <TimelineEvent>[],
    );
  }
}

/// What came back from `order_timeline_act`. A reassign answers `needsChoice`
/// with the riders it will accept — the app draws that list and calls back with
/// the id, so no rider is ever picked in Dart.
class TimelineActionResult {
  final bool ok;
  final bool needsChoice;
  final String choiceKey;
  final String title;
  final String message;
  final List<Map<String, dynamic>> choices;
  final Map<String, dynamic> timeline;

  const TimelineActionResult({
    required this.ok,
    required this.needsChoice,
    required this.choiceKey,
    required this.title,
    required this.message,
    required this.choices,
    required this.timeline,
  });

  factory TimelineActionResult.from(dynamic v) {
    if (v is! Map) {
      return const TimelineActionResult(
        ok: false,
        needsChoice: false,
        choiceKey: '',
        title: '',
        message: '',
        choices: [],
        timeline: {},
      );
    }
    final m = Map<String, dynamic>.from(v);
    final ch = m['choices'];
    return TimelineActionResult(
      ok: m['ok'] == true,
      needsChoice: m['needs_choice'] == true,
      choiceKey: m['choice_key']?.toString() ?? '',
      title: m['title']?.toString() ?? '',
      message: m['message']?.toString() ?? '',
      choices: ch is List
          ? ch
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList(growable: false)
          : const <Map<String, dynamic>>[],
      timeline: m['timeline'] is Map
          ? Map<String, dynamic>.from(m['timeline'] as Map)
          : const {},
    );
  }
}
