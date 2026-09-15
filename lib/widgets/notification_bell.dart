// CHANGE #298 — the bell. Its only job is to show the backend's unread count
// and open the inbox. The count, its label and the tooltip are all strings the
// backend produced (notif_inbox_unread); nothing here is computed or worded in
// Dart — not even the "99+" cap, which the backend applies.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';
import '../screens/notifications_inbox_screen.dart';

/// CMD #1914 — the unread count is a VALUE, not a widget.
///
/// Om moved the bell off the mobile header and into the profile dropdown, and
/// the count went with it: the fetch lived inside the bell's own State, so a
/// header without a bell had no unread number to put on the avatar and a
/// foreground push had nothing to refresh. The count is a notifier now. The
/// bell still draws it, the avatar's dot draws it, and the dropdown row draws
/// it — none of them owns it, and every string in it is still the backend's
/// (`notif_inbox_unread`), including the "99+" cap.
class NotifUnread {
  NotifUnread._();

  /// The last answer. Empty until the first one lands; every reader treats a
  /// missing key as "nothing to show", never as an error.
  static final ValueNotifier<Map<String, dynamic>> value =
      ValueNotifier<Map<String, dynamic>>(const {});

  /// Test seam — same shape the screens use.
  @visibleForTesting
  static Future<dynamic> Function()? transport;

  static Future<void> refresh() async {
    try {
      final t = transport;
      final res = t != null
          ? await t()
          : await Supabase.instance.client.rpc('notif_inbox_unread');
      if (res is! Map) return;
      final m = Map<String, dynamic>.from(res);
      // Proof key: the value is the backend's own count, so the render-log
      // shows what is being shown.
      RenderLog.write('c298_bell', (m['count'] as num?)?.toInt() ?? 0);
      value.value = m;
    } catch (_) {
      // A count that cannot be counted is still not an error on the chrome.
    }
  }

  static bool get show => (value.value['show'] as bool?) ?? false;
  static String get label => (value.value['label'] as String?) ?? '';
  static String get tooltip => (value.value['tooltip'] as String?) ?? '';
}

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, this.onOpened});

  /// Fired after the inbox closes, so a shell can refresh anything else.
  final VoidCallback? onOpened;

  @override
  State<NotificationBell> createState() => NotificationBellState();
}

class NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Public so the shell can refresh the badge when a foreground push lands.
  Future<void> refresh() => NotifUnread.refresh();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: NotifUnread.value,
      builder: (context, s, _) => _bell(
        context,
        (s['show'] as bool?) ?? false,
        (s['label'] as String?) ?? '',
        (s['tooltip'] as String?) ?? '',
      ),
    );
  }

  Widget _bell(
      BuildContext context, bool show, String label, String tooltip) {
    return SizedBox(
      width: Ds.touch.minTarget,
      height: Ds.touch.minTarget,
      child: Stack(
        alignment: Alignment.center,
        children: [
          IconButton(
            tooltip: tooltip.isEmpty ? null : tooltip,
            icon: const Icon(Icons.notifications_none_rounded),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const NotificationsInboxScreen(),
              ));
              if (!mounted) return;
              await refresh();
              widget.onOpened?.call();
            },
          ),
          if (show && label.isNotEmpty)
            Positioned(
              top: Ds.space.x4,
              right: Ds.space.x4,
              child: Container(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
                constraints: BoxConstraints(minWidth: Ds.space.x16),
                decoration: BoxDecoration(
                  color: Ds.c.danger,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: Ds.t.caption.copyWith(
                    color: Ds.c.surface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
