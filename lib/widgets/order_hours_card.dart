import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../models/order_hours_model.dart';
import '../services/ui_copy.dart';
import '../order_hours_state.dart';

/// CHANGE #456 B — admin dashboard card: view + control order hours. Every
/// string on this card is printed VERBATIM from order_hours_state() — no
/// client-side time formatting, no countdown maths, no ISO timestamps.
class OrderHoursCard extends StatefulWidget {
  const OrderHoursCard({super.key});

  @override
  State<OrderHoursCard> createState() => _OrderHoursCardState();
}

class _OrderHoursCardState extends State<OrderHoursCard> {
  bool _switchBusy = false;

  Future<void> _toggle(OrderHoursModel model) async {
    final target = !model.isOpen;
    setState(() {
      model.isOpen = target; // optimistic
      _switchBusy = true;
    });
    try {
      await model.setOrderHours(isOpen: target);
    } catch (e) {
      if (mounted) {
        setState(() => model.isOpen = !target); // revert
        showToast(context, cf('order_hours.toast_update_failed', {'error': '$e'}), isError: true);
      }
    } finally {
      if (mounted) setState(() => _switchBusy = false);
    }
  }

  Future<void> _editClosedMessage(OrderHoursModel model) async {
    final ctrl = TextEditingController(text: model.closedMessage ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c('order_hours.dialog_closed_message_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          minLines: 2,
          decoration: InputDecoration(
            hintText: c('order_hours.field_closed_message_hint'),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(c('order_hours.btn_cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B5E20)),
            child: Text(c('order_hours.btn_save')),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      await model.setOrderHours(closedMessage: result);
    } catch (e) {
      if (mounted) showToast(context, cf('order_hours.toast_closed_message_failed', {'error': '$e'}), isError: true);
    }
  }

  static TimeOfDay? _parseTime(String? hhmm) {
    if (hhmm == null || !hhmm.contains(':')) return null;
    final parts = hhmm.split(':');
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h, minute: m);
  }

  static String _fmtTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // CHANGE #456 B3 — combined schedule sheet: both times together, 12-hour
  // pickers (forced via the MediaQuery override below), Clear auto-open.
  Future<void> _editSchedule(OrderHoursModel model) async {
    TimeOfDay? openTime = _parseTime(model.autoOpenTime);
    TimeOfDay? closeTime = _parseTime(model.autoCloseTime) ?? const TimeOfDay(hour: 18, minute: 0);
    bool clearOpen = false;

    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(c('order_hours.dialog_schedule_title'),
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ScheduleTimeRow(
                label: c('order_hours.label_opens_at'),
                time: clearOpen ? null : openTime,
                placeholder: c('order_hours.placeholder_reopen_manually'),
                onTap: () async {
                  final picked = await showTimePicker(
                    context: ctx,
                    initialTime: openTime ?? const TimeOfDay(hour: 9, minute: 0),
                    builder: (c, child) => MediaQuery(
                      data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: false),
                      child: child!,
                    ),
                  );
                  if (picked != null) setSheet(() { openTime = picked; clearOpen = false; });
                },
              ),
              const SizedBox(height: 10),
              _ScheduleTimeRow(
                label: c('order_hours.label_closes_at'),
                time: closeTime,
                onTap: () async {
                  final picked = await showTimePicker(
                    context: ctx,
                    initialTime: closeTime ?? const TimeOfDay(hour: 18, minute: 0),
                    builder: (c, child) => MediaQuery(
                      data: MediaQuery.of(c).copyWith(alwaysUse24HourFormat: false),
                      child: child!,
                    ),
                  );
                  if (picked != null) setSheet(() => closeTime = picked);
                },
              ),
              const SizedBox(height: 4),
              TextButton(
                onPressed: () => setSheet(() { clearOpen = true; openTime = null; }),
                child: Text(c('order_hours.btn_clear_auto_open'),
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFFDC2626))),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(c('order_hours.btn_cancel'))),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B5E20)),
              child: Text(c('order_hours.btn_save')),
            ),
          ],
        ),
      ),
    );
    if (save != true) return;
    try {
      await model.setOrderHours(
        autoCloseTime: closeTime != null ? _fmtTime(closeTime!) : null,
        autoOpenTime: clearOpen ? null : (openTime != null ? _fmtTime(openTime!) : null),
        clearAutoOpen: clearOpen,
      );
    } catch (e) {
      if (mounted) showToast(context, cf('order_hours.toast_schedule_failed', {'error': '$e'}), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = OrderHoursState.of(context);
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) {
        if (!model.loaded) {
          return const SizedBox.shrink();
        }
        final isOpen = model.isOpen;
        final bg = isOpen ? const Color(0xFFECFDF5) : const Color(0xFFFEF2F2);
        final border = isOpen ? const Color(0xFFA7F3D0) : const Color(0xFFFECACA);
        final accent = isOpen ? const Color(0xFF1B7A43) : const Color(0xFFDC2626);

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(isOpen ? Icons.storefront_outlined : Icons.storefront,
                      size: 16, color: accent),
                  const SizedBox(width: 7),
                  Text(c('order_hours.card_title'),
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Color(0xFF374151))),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(model.statusLabel ?? (isOpen ? c('order_hours.status_open') : c('order_hours.status_closed')),
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent)),
                  ),
                  const SizedBox(width: 8),
                  _switchBusy
                      ? const SizedBox(
                          width: 34, height: 20,
                          child: Center(
                              child: SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2))))
                      : Switch(
                          value: isOpen,
                          onChanged: (_) => _toggle(model),
                          activeColor: const Color(0xFF1B7A43),
                        ),
                ],
              ),
              if (model.statusSince != null) ...[
                const SizedBox(height: 2),
                Text(model.statusSince!,
                    style: const TextStyle(fontSize: 12.5, color: Color(0xFF374151))),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: Color(0xFFE5E7EB)),
              ),
              GestureDetector(
                onTap: () => _editSchedule(model),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(model.scheduleLabel ?? '',
                          style: const TextStyle(
                              fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                    ),
                    const SizedBox(width: 8),
                    Text(c('order_hours.btn_edit'),
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1B7A43))),
                  ],
                ),
              ),
              if (model.nextChangeLabel != null) ...[
                const SizedBox(height: 3),
                Text(model.nextChangeLabel!,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ],
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1, color: Color(0xFFE5E7EB)),
              ),
              GestureDetector(
                onTap: () => _editClosedMessage(model),
                child: Row(
                  children: [
                    const Icon(Icons.edit_outlined, size: 13, color: Color(0xFF6B7280)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        cf('order_hours.closed_message_summary', {'message': (model.closedMessage ?? '').isEmpty ? c('order_hours.closed_message_default') : (model.closedMessage ?? '')}),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ScheduleTimeRow extends StatelessWidget {
  final String label;
  final TimeOfDay? time;
  final String? placeholder;
  final VoidCallback onTap;

  const _ScheduleTimeRow({
    required this.label,
    required this.time,
    required this.onTap,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
        ),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F6F8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Text(
              time?.format(context) ??
                  (placeholder ?? c('order_hours.placeholder_time_empty')),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
            ),
          ),
        ),
      ],
    );
  }
}
