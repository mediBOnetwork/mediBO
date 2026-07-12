import 'dart:async';

import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../models/order_hours_model.dart';
import '../order_hours_state.dart';

/// CHANGE #446 — admin dashboard card: view + control order hours.
class OrderHoursCard extends StatefulWidget {
  const OrderHoursCard({super.key});

  @override
  State<OrderHoursCard> createState() => _OrderHoursCardState();
}

class _OrderHoursCardState extends State<OrderHoursCard> {
  Timer? _tickTimer;
  bool _switchBusy = false;

  @override
  void initState() {
    super.initState();
    _tickTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    super.dispose();
  }

  int? _liveClosesInMin(OrderHoursModel m) {
    if (m.closesInMin == null) return null;
    final elapsed = m.fetchedAt == null
        ? 0
        : DateTime.now().difference(m.fetchedAt!).inMinutes;
    final remaining = m.closesInMin! - elapsed;
    return remaining < 0 ? 0 : remaining;
  }

  String _fmtMin(int mins) {
    final h = mins ~/ 60;
    final m = mins % 60;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

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
        showToast(context, 'Could not update order hours: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _switchBusy = false);
    }
  }

  Future<void> _pickAutoClose(OrderHoursModel model) async {
    final current = _parseTime(model.autoCloseTime) ?? const TimeOfDay(hour: 18, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null) return;
    try {
      await model.setOrderHours(autoCloseTime: _fmtTime(picked));
    } catch (e) {
      if (mounted) showToast(context, 'Could not update auto-close time: $e', isError: true);
    }
  }

  Future<void> _pickAutoOpen(OrderHoursModel model) async {
    final current = _parseTime(model.autoOpenTime) ?? const TimeOfDay(hour: 9, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: current);
    if (picked == null) return;
    try {
      await model.setOrderHours(autoOpenTime: _fmtTime(picked));
    } catch (e) {
      if (mounted) showToast(context, 'Could not update auto-open time: $e', isError: true);
    }
  }

  Future<void> _clearAutoOpen(OrderHoursModel model) async {
    try {
      await model.setOrderHours(clearAutoOpen: true);
    } catch (e) {
      if (mounted) showToast(context, 'Could not clear auto-open time: $e', isError: true);
    }
  }

  Future<void> _editClosedMessage(OrderHoursModel model) async {
    final ctrl = TextEditingController(text: model.closedMessage ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Closed message', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          minLines: 2,
          decoration: const InputDecoration(
            hintText: 'Shown to customers while orders are closed',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B5E20)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      await model.setOrderHours(closedMessage: result);
    } catch (e) {
      if (mounted) showToast(context, 'Could not update closed message: $e', isError: true);
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
        final remaining = _liveClosesInMin(model);

        return Container(
          margin: const EdgeInsets.only(bottom: 20),
          padding: const EdgeInsets.all(16),
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
                      size: 18, color: accent),
                  const SizedBox(width: 8),
                  const Text('ORDER HOURS',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: Color(0xFF374151))),
                  const Spacer(),
                  Text(isOpen ? 'OPEN' : 'CLOSED',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: accent)),
                  const SizedBox(width: 6),
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
              const SizedBox(height: 4),
              Text(
                isOpen
                    ? 'Closes automatically at ${model.autoCloseTime ?? '--:--'}'
                        '${remaining != null ? '  (${_fmtMin(remaining)} left)' : ''}'
                    : 'CLOSED — customers cannot place orders.'
                        '${model.lastClosedAt != null ? ' Since ${model.lastClosedAt}.' : ''}',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 24,
                runSpacing: 10,
                children: [
                  _TimeField(
                    label: 'Auto-close',
                    value: model.autoCloseTime ?? '--:--',
                    onTap: () => _pickAutoClose(model),
                  ),
                  _TimeField(
                    label: 'Auto-open',
                    value: model.autoOpenTime ?? '--:--',
                    helper: model.autoOpenTime == null ? 'reopen manually' : null,
                    onTap: () => _pickAutoOpen(model),
                    onClear: model.autoOpenTime != null ? () => _clearAutoOpen(model) : null,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: () => _editClosedMessage(model),
                child: Row(
                  children: [
                    const Icon(Icons.edit_outlined, size: 14, color: Color(0xFF6B7280)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Closed message: ${(model.closedMessage ?? '').isEmpty ? '(default)' : model.closedMessage}',
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

class _TimeField extends StatelessWidget {
  final String label;
  final String value;
  final String? helper;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _TimeField({
    required this.label,
    required this.value,
    required this.onTap,
    this.helper,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w600)),
        const SizedBox(height: 3),
        GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(value,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              if (onClear != null) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: onClear,
                  child: const Icon(Icons.close, size: 13, color: Color(0xFF9CA3AF)),
                ),
              ],
            ]),
          ),
        ),
        if (helper != null) ...[
          const SizedBox(height: 2),
          Text(helper!, style: const TextStyle(fontSize: 10, color: Color(0xFF9CA3AF))),
        ],
      ],
    );
  }
}
