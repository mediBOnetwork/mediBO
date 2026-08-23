// CHANGE #298 — the inbox's decisions, extracted so they can be tested on the
// Dart VM without Supabase (the protected-suite rule: a widget that resists
// mocking hands its decisions to a pure class).
//
// The rule these types encode: the app renders, it never decides. Every string
// below is carried through from the payload; none is authored here, and a key
// the backend did not send renders as ABSENT, never as a Dart default word.

/// One notification_log row as the inbox draws it.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.eventKey,
    required this.title,
    required this.body,
    required this.deepLink,
    required this.channelLabel,
    required this.whenLabel,
    required this.unread,
    required this.status,
  });

  final int id;
  final String eventKey;
  final String title;
  final String body;
  final String deepLink;
  final String channelLabel;
  final String whenLabel;
  final bool unread;
  final String status;

  /// Absence is explicit: an empty body is NOT rendered as a placeholder line.
  bool get hasBody => body.isNotEmpty;
  bool get hasChannel => channelLabel.isNotEmpty;

  /// A row only navigates when the BACKEND gave it somewhere to go. '/' is the
  /// app home and is deliberately treated as "nowhere": the whole point of
  /// spec item 5 is that a notification never dumps you on the home screen.
  bool get canOpen => deepLink.isNotEmpty && deepLink != '/';

  /// The route handed to the navigator. An absolute backend link (a supplier
  /// form on medibo.in) is reduced to its path so the in-app router can match
  /// it; the app never rewrites, cases or trims the link beyond that.
  String? get route {
    if (!canOpen) return null;
    if (deepLink.startsWith('http')) {
      final uri = Uri.tryParse(deepLink);
      if (uri == null) return null;
      final p = uri.path;
      return p.isEmpty ? null : p;
    }
    return deepLink;
  }

  static InboxItem fromJson(Map<String, dynamic> j) => InboxItem(
        id: (j['id'] as num?)?.toInt() ?? 0,
        eventKey: j['event_key'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String? ?? '',
        deepLink: (j['deep_link'] as String? ?? '').trim(),
        channelLabel: j['channel_label'] as String? ?? '',
        whenLabel: j['when_label'] as String? ?? '',
        unread: j['unread'] as bool? ?? false,
        status: j['status'] as String? ?? '',
      );
}

/// One page of notif_inbox_list(). Paging is the BACKEND's has_more, never a
/// client-side "did I get a full page" guess.
class InboxPage {
  const InboxPage({
    required this.ok,
    required this.title,
    required this.emptyTitle,
    required this.emptyHint,
    required this.markAllLabel,
    required this.loadMoreLabel,
    required this.items,
    required this.total,
    required this.hasMore,
  });

  final bool ok;
  final String title;
  final String emptyTitle;
  final String emptyHint;
  final String markAllLabel;
  final String loadMoreLabel;
  final List<InboxItem> items;
  final int total;
  final bool hasMore;

  bool get isEmpty => items.isEmpty;

  /// "Mark all read" only exists when the backend sent the caption AND there
  /// is something on screen to mark.
  bool get showMarkAll => markAllLabel.isNotEmpty && items.isNotEmpty;

  static InboxPage fromJson(Map<String, dynamic> j) => InboxPage(
        ok: j['ok'] as bool? ?? false,
        title: j['title'] as String? ?? '',
        emptyTitle: j['empty_title'] as String? ?? '',
        emptyHint: j['empty_hint'] as String? ?? '',
        markAllLabel: j['mark_all'] as String? ?? '',
        loadMoreLabel: j['load_more'] as String? ?? '',
        items: (j['items'] as List? ?? const [])
            .map((e) => InboxItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        total: (j['total'] as num?)?.toInt() ?? 0,
        hasMore: j['has_more'] as bool? ?? false,
      );

  /// Appending the next page must never duplicate a row the list already
  /// shows — the same boundary hazard company_notify_test holds down.
  static List<InboxItem> append(List<InboxItem> existing, List<InboxItem> next) {
    final seen = existing.map((e) => e.id).toSet();
    return [...existing, ...next.where((e) => seen.add(e.id))];
  }
}
