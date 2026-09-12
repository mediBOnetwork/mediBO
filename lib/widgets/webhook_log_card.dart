// CHANGE #300 — the Razorpay webhook delivery log, as a card.
//
// #293 wrote every delivery to razorpay_webhook_log and built
// rzp_webhook_log_recent() to read it back; nothing ever called it, so the log
// that answers "did Razorpay reach us, and did we act on it?" was invisible.
//
// This card decides NOTHING. It does not turn `handled` into a word, does not
// pluralise a count, and does not choose which colour "acted on" is: the
// payload carries status_label and status_tone and the card prints them. That
// is why a wording change here is an UPDATE to razorpay_copy, not a deploy.
import 'package:flutter/material.dart';
import 'package:pharma_b2b/design_tokens.dart';

class WebhookLogCard extends StatelessWidget {
  /// rzp_webhook_log_recent() verbatim.
  final Map<String, dynamic> payload;

  const WebhookLogCard({super.key, required this.payload});

  /// A tone the backend has not taught us is neutral, never a guess and never
  /// a throw — a new tone name must not break a screen mid-release.
  static Color toneBg(String tone) => switch (tone) {
        'success' => Ds.c.successSoft,
        'warning' => Ds.c.warningSoft,
        'danger' => Ds.c.dangerSoft,
        _ => Ds.c.bg,
      };

  static Color toneFg(String tone) => switch (tone) {
        'success' => Ds.c.success,
        'warning' => Ds.c.warning,
        'danger' => Ds.c.danger,
        _ => Ds.c.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final rows = (payload['rows'] as List?) ?? const [];

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(top: Ds.space.x24),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('${payload['title'] ?? ''}', style: Ds.t.subtitle)),
            Text('${payload['count_label'] ?? ''}', style: Ds.t.caption),
          ]),
          SizedBox(height: Ds.space.x4),
          Text('${payload['subtitle'] ?? ''}', style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          // `has` is the BACKEND's emptiness, not rows.isEmpty — a page of the
          // log can be empty while the table is not.
          if (payload['has'] != true)
            Text('${payload['empty'] ?? ''}', style: Ds.t.body)
          else
            ...rows.map((r) => _row((r as Map).cast<String, dynamic>())),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> row) {
    final tone = '${row['status_tone'] ?? ''}';
    final pid = '${row['payload_id'] ?? ''}';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${row['event'] ?? ''}', style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text(
                  pid.isEmpty
                      ? '${row['at_label'] ?? ''}'
                      : '${row['at_label'] ?? ''} · $pid',
                  style: Ds.t.caption,
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration:
                BoxDecoration(color: toneBg(tone), borderRadius: Ds.r.rChip),
            child: Text('${row['status_label'] ?? ''}',
                style: Ds.t.caption.copyWith(color: toneFg(tone))),
          ),
        ],
      ),
    );
  }
}
