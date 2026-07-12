import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/render_log.dart';

/// Holds the live order-hours state (order_hours_state() RPC) and keeps it in
/// sync via a realtime subscription on public.order_hours. Shared app-wide —
/// readable by anon and authenticated users; only admins can call
/// [setOrderHours] (enforced server-side by set_order_hours()).
class OrderHoursModel extends ChangeNotifier {
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

  RealtimeChannel? _channel;
  Timer? _debounce;

  OrderHoursModel() {
    _init();
  }

  Future<void> _init() async {
    await refresh();
    _subscribe();
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
      loaded = true;
      fetchedAt = DateTime.now();
      RenderLog.write('c444_is_open', isOpen.toString());
      RenderLog.write('c444_auto_close', autoCloseTime ?? '');
      notifyListeners();
    } catch (_) {
      // Keep last-known state on transient failure; caller UI stays as-is.
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
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 300), refresh);
          },
        )
        .subscribe();
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
    _debounce?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }
}
