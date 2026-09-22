import 'package:flutter/material.dart';

import 'package:pharma_b2b/design_tokens.dart';

/// CMD #2154 — the ONE card every staff sign-up alert draws.
///
/// Pharmacy, supplier, MR, company and delivery-partner registrations used to
/// get three different cards carrying Approve / Reject / Skip / Dismiss. A
/// decision is never taken from an alert, so the card now has exactly one
/// button — View — and a mute icon that silences without leaving.
///
/// Every string is the backend's: `card` {title, name, subtitle, detail} and
/// `view` {label} arrive on each admin_alert_new_since() row. [heading] is the
/// title (or its queued form) the host already rendered from ui_copy.
class AdminAlertCard extends StatelessWidget {
  final String heading;
  final Map<String, dynamic> card;
  final Map<String, dynamic> view;
  final bool muted;
  final Animation<double>? flash;
  final VoidCallback onView;
  final VoidCallback onMute;

  const AdminAlertCard({
    super.key,
    required this.heading,
    required this.card,
    required this.view,
    required this.muted,
    required this.onView,
    required this.onMute,
    this.flash,
  });

  String _s(Map<String, dynamic> m, String k) => (m[k] as String?) ?? '';

  @override
  Widget build(BuildContext context) {
    final name = _s(card, 'name');
    final subtitle = _s(card, 'subtitle');
    final detail = _s(card, 'detail');
    final label = _s(view, 'label');

    final banner = Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x4),
      color: Ds.c.brand,
      child: Row(children: [
        Expanded(
          child: Text(heading,
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        ),
        // Mute: silences the ring, stays on the alert.
        Semantics(
          identifier: 'admin_alert_mute',
          button: true,
          child: IconButton(
            onPressed: onMute,
            constraints: BoxConstraints(
                minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
            icon: Icon(
                muted ? Icons.volume_off_outlined : Icons.volume_up_outlined,
                color: Ds.c.surface,
                size: Ds.space.x24),
          ),
        ),
      ]),
    );

    return Container(
      margin: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x24),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e2,
      ),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            flash == null
                ? banner
                : FadeTransition(opacity: flash!, child: banner),
            Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, style: Ds.t.title, maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  if (subtitle.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(subtitle, style: Ds.t.bodySecondary, maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  if (detail.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x8),
                    Text(detail, style: Ds.t.caption, maxLines: 2,
                        overflow: TextOverflow.ellipsis),
                  ],
                  SizedBox(height: Ds.space.x24),
                  if (label.isNotEmpty)
                    Semantics(
                      identifier: 'admin_alert_view',
                      button: true,
                      child: SizedBox(
                        width: double.infinity,
                        height: Ds.touch.minTarget,
                        child: FilledButton(
                          onPressed: onView,
                          style: FilledButton.styleFrom(
                            backgroundColor: Ds.c.brand,
                            foregroundColor: Ds.c.surface,
                            shape: RoundedRectangleBorder(
                                borderRadius: Ds.r.rButton),
                          ),
                          child: Text(label,
                              style: Ds.t.bodyStrong
                                  .copyWith(color: Ds.c.surface),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
