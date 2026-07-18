import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/animations.dart';

// CHANGE #498: Dashboard "Notifications" box — per-action WhatsApp toggles.
// Thin client: reads/writes via get_notification_settings / set_notification_setting
// RPCs only. All gating logic lives server-side (RLS + notif_is_enabled).

class _NotifRow {
  final String audience;
  final String actionKey;
  final String label;
  bool enabled;
  final int sort;

  _NotifRow({
    required this.audience,
    required this.actionKey,
    required this.label,
    required this.enabled,
    required this.sort,
  });
}

/// In-memory cache so re-opening/rebuilding the Dashboard doesn't re-fetch.
List<_NotifRow>? _cachedRows;

class NotificationsCard extends StatefulWidget {
  const NotificationsCard({super.key});

  @override
  State<NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<NotificationsCard> {
  static const _green = Color(0xFF1B7A43);
  static const _border = Color(0xFFE5E7EB);

  List<_NotifRow>? _rows;
  bool _loading = true;
  String _audience = 'customer';
  final Set<String> _busyKeys = {};

  @override
  void initState() {
    super.initState();
    if (_cachedRows != null) {
      _rows = _cachedRows;
      _loading = false;
      RenderLog.write('c498_notif_box_rendered', 'cached:${_rows!.length}');
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('get_notification_settings');
      final list = (res as List)
          .map((r) {
            final m = Map<String, dynamic>.from(r as Map);
            return _NotifRow(
              audience: m['audience'] as String? ?? '',
              actionKey: m['action_key'] as String? ?? '',
              label: m['label'] as String? ?? '',
              enabled: m['enabled'] as bool? ?? false,
              sort: (m['sort'] as num?)?.toInt() ?? 0,
            );
          })
          .toList()
        ..sort((a, b) => a.sort.compareTo(b.sort));
      _cachedRows = list;
      if (mounted) {
        setState(() {
          _rows = list;
          _loading = false;
        });
        RenderLog.write('c498_notif_box_rendered', 'loaded:${list.length}');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(_NotifRow row, bool value) async {
    final prev = row.enabled;
    setState(() {
      row.enabled = value;
      _busyKeys.add(row.actionKey);
    });
    try {
      final ok = await Supabase.instance.client.rpc('set_notification_setting', params: {
        'p_audience': row.audience,
        'p_action_key': row.actionKey,
        'p_enabled': value,
      }) as bool? ?? false;
      if (!ok) throw Exception('rpc returned false');
      RenderLog.write('c498_notif_toggle_saved', '${row.audience}:${row.actionKey}:$value');
    } catch (e) {
      if (mounted) {
        setState(() => row.enabled = prev);
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(const SnackBar(content: Text("Couldn't update, try again")));
      }
    } finally {
      if (mounted) setState(() => _busyKeys.remove(row.actionKey));
    }
  }

  Widget _segButton(String label, String value) {
    final selected = _audience == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _audience = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: selected ? _green : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: selected ? Colors.white : const Color(0xFF6B7280),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(_NotifRow row) {
    final busy = _busyKeys.contains(row.actionKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              row.label,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFF111827),
              ),
            ),
          ),
          const SizedBox(width: 8),
          busy
              ? const SizedBox(
                  width: 34,
                  height: 20,
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : Switch(
                  value: row.enabled,
                  activeColor: _green,
                  onChanged: (v) => _toggle(row, v),
                ),
        ],
      ),
    );
  }

  Widget _skeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(4, (i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SkeletonBox(width: 160 - (i * 12.0), height: 12),
                const Spacer(),
                const SkeletonBox(width: 34, height: 18, radius: 10),
              ],
            ),
          )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows ?? const <_NotifRow>[];
    final visible = rows.where((r) => r.audience == _audience).toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_none, size: 16, color: Color(0xFF374151)),
              const SizedBox(width: 7),
              const Text(
                'NOTIFICATIONS',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                  color: Color(0xFF374151),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 10),
            child: Divider(height: 1, color: Color(0xFFE5E7EB)),
          ),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                _segButton('Customer', 'customer'),
                const SizedBox(width: 3),
                _segButton('Supplier', 'supplier'),
              ],
            ),
          ),
          const SizedBox(height: 8),
          if (_loading)
            _skeleton()
          else if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text(
                'No notification settings found.',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              ),
            )
          else
            Column(children: visible.map(_row).toList()),
        ],
      ),
    );
  }
}
