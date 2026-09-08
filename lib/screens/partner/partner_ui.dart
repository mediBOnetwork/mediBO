// CHANGE #399 — the shared pieces of the partner surface.
//
// #326 built the partner home and its private tiles; the three self-service
// screens that hang off it need the same card, chip, skeleton and notice, and
// the same single meaning for a backend `tone` word. They live here rather than
// being copied three times, and deliberately hold no Scaffold: every partner
// destination is pushed inside PartnerFeaturePage, which owns the Scaffold and
// prints the BACKEND's label as the page title.

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

// ── shared partner-surface pieces ──────────────────────────────────────────
// Kept here so the three partner screens look like one screen, and so a tone
// string from the backend has exactly one meaning in the app.

Color partnerToneColor(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color partnerToneBg(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

class PartnerChip extends StatelessWidget {
  const PartnerChip({super.key, required this.text, this.tone});

  final String text;
  final String? tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: partnerToneBg(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(text,
          style: Ds.t.caption.copyWith(color: partnerToneColor(tone))),
    );
  }
}

class PartnerCard extends StatelessWidget {
  const PartnerCard({super.key, required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final body = Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      child: child,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: DecoratedBox(
        decoration: BoxDecoration(
            borderRadius: Ds.r.rCard, boxShadow: Ds.elevation.e1),
        child: Material(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          child: onTap == null
              ? body
              : InkWell(borderRadius: Ds.r.rCard, onTap: onTap, child: body),
        ),
      ),
    );
  }
}

/// Loading is a skeleton, never a bare spinner (DESIGN.md).
class PartnerSkeleton extends StatelessWidget {
  const PartnerSkeleton({super.key, this.rows = 4});

  final int rows;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < rows; i++)
          Container(
            height: Ds.touch.listRowMinHeight + Ds.space.x16,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
                color: Ds.c.surface, borderRadius: Ds.r.rCard),
          ),
      ],
    );
  }
}

/// Every empty / denied / failed state on the partner surface, printing the
/// BACKEND's own sentence. Nothing here composes English.
class PartnerNotice extends StatelessWidget {
  const PartnerNotice(
      {super.key, required this.text, this.title = '', this.onRetry, this.retryLabel = ''});

  final String text;
  final String title;
  final VoidCallback? onRetry;
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x8),
            ],
            Text(text, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            if (onRetry != null && retryLabel.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onRetry, child: Text(retryLabel)),
            ],
          ],
        ),
      ),
    );
  }
}
