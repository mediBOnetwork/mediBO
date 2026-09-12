import 'package:flutter/material.dart';
import '../design_tokens.dart';
import '../services/delivery_offline_queue.dart';

/// CHANGE #1017 (6) — the offline banner with the queued-action count.
///
/// Shown ONLY while actions are queued (the queue is the offline signal that
/// already exists — delivery_replay's client_action_id queue, #453). The
/// sentence is the backend's `copy.offline_banner` with {n} filled; the widget
/// words nothing. When the queue drains the banner leaves; no spinner, no popup.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.template});
  final String template;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: DeliveryOfflineQueue.instance.pending,
        builder: (context, n, _) {
          if (n <= 0 || template.isEmpty) return const SizedBox.shrink();
          return Material(
            color: Ds.c.warningSoft,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x8),
              child: Row(children: [
                Icon(Icons.cloud_off_outlined, size: Ds.space.x16 + Ds.space.x4, color: Ds.c.warning),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(template.replaceAll('{n}', '$n'),
                      style: Ds.t.caption.copyWith(color: Ds.c.text),
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
              ]),
            ),
          );
        },
      );
}
