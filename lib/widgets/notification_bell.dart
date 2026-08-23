// CHANGE #298 — the bell. Its only job is to show the backend's unread count
// and open the inbox. The count, its label and the tooltip are all strings the
// backend produced (notif_inbox_unread); nothing here is computed or worded in
// Dart — not even the "99+" cap, which the backend applies.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../screens/notifications_inbox_screen.dart';

class NotificationBell extends StatefulWidget {
  const NotificationBell({super.key, this.onOpened});

  /// Fired after the inbox closes, so a shell can refresh anything else.
  final VoidCallback? onOpened;

  @override
  State<NotificationBell> createState() => NotificationBellState();
}

class NotificationBellState extends State<NotificationBell> {
  Map<String, dynamic>? _state;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  /// Public so the shell can refresh the badge when a foreground push lands.
  Future<void> refresh() async {
    try {
      final res = await Supabase.instance.client.rpc('notif_inbox_unread');
      if (!mounted || res is! Map) return;
      setState(() => _state = Map<String, dynamic>.from(res));
    } catch (_) {
      // A bell that cannot count is still a bell — it must never throw into
      // the app bar.
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    final show = (s?['show'] as bool?) ?? false;
    final label = (s?['label'] as String?) ?? '';
    final tooltip = (s?['tooltip'] as String?) ?? '';

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
