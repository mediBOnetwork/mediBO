import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// Holds the live order-hours state (order_hours_state() RPC) and keeps it in
/// sync via a realtime subscription on public.order_hours. Shared app-wide —
/// readable by anon and authenticated users; only admins can call
/// [setOrderHours] (enforced server-side by set_order_hours()).
class OrderHoursModel extends ChangeNotifier with WidgetsBindingObserver {
  bool isOpen = false;
  String? autoCloseTime;
  String? autoOpenTime;
  String? closedMessage;
  String? nowIst;
  int? closesInMin;
  String? lastClosedAt;
  String? lastOpenedAt;
  bool loaded = false;
  DateTime? fetchedAt;

  // CHANGE #455 — display-ready fields, printed VERBATIM by the UI. Never
  // composed/concatenated in Dart. null while !loaded (D3 fail-open) or when
  // hours are open (server sends null for all three in that case too).
  bool canOrder = true; // fail OPEN — true until the first successful fetch
  String? buttonLabel;
  String? popupTitle;
  String? popupMessage;
  String? reopenHint;

  // CHANGE #456 B — dashboard card fields. ALL finished strings, printed
  // VERBATIM. No DateFormat, no HH:mm, no countdown maths, no ISO timestamps
  // in Dart — the server has already done every bit of that work.
  String? statusLabel; // "OPEN" | "CLOSED"
  String? statusSince; // "Closed since 12:24 AM" | "Open since ..."
  String? scheduleLabel; // "Opens 6:00 AM  ·  Closes 6:00 PM"
  String? nextChangeLabel; // "Auto-opens in 5h 30m" | null
  String? autoOpenLabel; // "6:00 AM" — 12-hour, ready to print
  String? autoCloseLabel; // "6:00 PM" — 12-hour, ready to print
  String? nowLabel; // "12:30 AM"

  RealtimeChannel? _channel;
  Timer? _debounce;

  OrderHoursModel() {
    _init();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _init() async {
    await refresh();
    _subscribe();
  }

  // D2 — belt and braces: re-fetch on app resume so a dropped realtime socket
  // never leaves a customer stuck on a stale message.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() async {
    try {
      final res = await Supabase.instance.client.rpc('order_hours_state');
      final map = Map<String, dynamic>.from(res as Map);
      isOpen = map['is_open'] as bool? ?? false;
      autoCloseTime = map['auto_close_time'] as String?;
      autoOpenTime = map['auto_open_time'] as String?;
      closedMessage = map['closed_message'] as String?;
      nowIst = map['now_ist'] as String?;
      closesInMin = (map['closes_in_min'] as num?)?.toInt();
      lastClosedAt = map['last_closed_at'] as String?;
      lastOpenedAt = map['last_opened_at'] as String?;
      // CHANGE #455 — the ONLY flag that gates the button (C1), plus the
      // three display-ready strings (C2). D3: on a genuine response, this can
      // legitimately set canOrder=false; FAIL OPEN only covers the catch below.
      canOrder = map['can_order'] as bool? ?? isOpen;
      buttonLabel = map['button_label'] as String?;
      popupTitle = map['popup_title'] as String?;
      popupMessage = map['popup_message'] as String?;
      reopenHint = map['reopen_hint'] as String?;
      // CHANGE #456 B — dashboard card fields, verbatim from the RPC.
      statusLabel = map['status_label'] as String?;
      statusSince = map['status_since'] as String?;
      scheduleLabel = map['schedule_label'] as String?;
      nextChangeLabel = map['next_change_label'] as String?;
      autoOpenLabel = map['auto_open_label'] as String?;
      autoCloseLabel = map['auto_close_label'] as String?;
      nowLabel = map['now_label'] as String?;
      loaded = true;
      fetchedAt = DateTime.now();
      RenderLog.write('c444_is_open', isOpen.toString());
      RenderLog.write('c444_auto_close', autoCloseTime ?? '');
      RenderLog.write('c455_can_order', canOrder.toString());
      RenderLog.write('c455_button_label', buttonLabel ?? '');
      RenderLog.write('c455_popup_msg', popupMessage ?? '');
      RenderLog.write('c456_status', statusLabel ?? '');
      RenderLog.write('c456_open_label', autoOpenLabel ?? '');
      RenderLog.write('c456_close_label', autoCloseLabel ?? '');
      RenderLog.write('c456_schedule', scheduleLabel ?? '');
      notifyListeners();
    } catch (_) {
      // D3 FAIL OPEN on the fetch — never invent a "closed" message on a
      // network error. Leave whatever was last known (or the true defaults
      // above, if this is the very first call) in place; do not flip
      // canOrder to false just because the RPC failed.
    }
  }

  void _subscribe() {
    _channel = Supabase.instance.client
        .channel('order_hours_watch')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'order_hours',
          callback: (_) {
            RenderLog.write('c444_realtime_hit', 1);
            RenderLog.write('c455_realtime', 1);
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), refresh);
          },
        )
        .subscribe((status, [error]) {
          if (status == RealtimeSubscribeStatus.subscribed) {
            RenderLog.write('c455_realtime', 1);
          }
        });
  }

  /// Admin-only. All params optional — pass null to leave unchanged.
  Future<void> setOrderHours({
    bool? isOpen,
    String? autoCloseTime,
    String? autoOpenTime,
    String? closedMessage,
    bool? clearAutoOpen,
  }) async {
    await Supabase.instance.client.rpc('set_order_hours', params: {
      'p_is_open': isOpen,
      'p_auto_close_time': autoCloseTime,
      'p_auto_open_time': autoOpenTime,
      'p_closed_message': closedMessage,
      'p_clear_auto_open': clearAutoOpen,
    });
    await refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }
}
