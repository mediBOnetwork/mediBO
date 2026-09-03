import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// CHANGE #706 — the automatic checks, printed.
///
/// One widget for the applicant's panel and the review console, because both
/// are looking at the same answer: what did the machine make of this document?
/// Nothing here is computed. The tier, the verdict sentence, every check label,
/// every "OK / Check / Failed" word, every explanation ("The map pin is 106.2 km
/// from the address on the document — further than 500 m") and the conflicting
/// account's name all arrive inside `verify` from `kyc_verify_panel()`.
///
/// A payload with `has:false` is a state, not an absence: it carries the note
/// the backend wants shown while the document is still being read. A `verify`
/// that is null or empty draws nothing at all, so an old payload from a build
/// that predates this change still renders.
class KycVerifyBlock extends StatelessWidget {
  const KycVerifyBlock({super.key, required this.verify, this.dense = false});

  /// The `verify` object out of `kyc_my_panel().items[]` or a
  /// `kyc_review_queue().rows[]` row. May be null.
  final Map<String, dynamic>? verify;

  /// The review console packs more on screen than the applicant's panel does.
  final bool dense;

  static Map<String, dynamic>? of(Map<String, dynamic> row) {
    final v = row['verify'];
    return v is Map ? Map<String, dynamic>.from(v) : null;
  }

  static List<Map<String, dynamic>> checksOf(Map<String, dynamic>? verify) =>
      ((verify?['checks'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  static Color tone(String t) {
    switch (t) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  static Color toneSoft(String t) {
    switch (t) {
      case 'success':
        return Ds.c.successSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.warningSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = verify;
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    String s(String k) => (v[k] ?? '').toString();

    // Still being read, or never run: the backend supplies the sentence.
    if (v['has'] != true) {
      final note = s('empty_note');
      if (note.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(top: Ds.space.x12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: Ds.space.x16,
              height: Ds.space.x16,
              child: CircularProgressIndicator(
                strokeWidth: 2, color: Ds.c.textSecondary),
            ),
            SizedBox(width: Ds.space.x8),
            Expanded(child: Text(note, style: Ds.t.caption)),
          ],
        ),
      );
    }

    final checks = checksOf(v);
    final t = s('tone');
    final mismatch = s('mismatch_label');
    final conflict = v['conflict'] is Map
        ? Map<String, dynamic>.from(v['conflict'] as Map)
        : null;

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(dense ? Ds.space.x12 : Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(s('title'), style: Ds.t.subtitle)),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration: BoxDecoration(
                    color: toneSoft(t), borderRadius: Ds.r.rChip),
                child: Text(s('tier_label'),
                    style: Ds.t.caption.copyWith(color: tone(t))),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(s('verdict_label'), style: Ds.t.caption),
          if (s('approved_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(s('approved_label'),
                style: Ds.t.caption.copyWith(color: Ds.c.success)),
          ],
          if (mismatch.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text('${s('mismatch_heading')} · $mismatch',
                style: Ds.t.caption.copyWith(color: Ds.c.warning)),
          ],
          SizedBox(height: Ds.space.x12),
          for (final c in checks) _check(c),
          if (conflict != null) ...[
            SizedBox(height: Ds.space.x12),
            Text(s('conflict_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            Text(
              [
                (conflict['owner_name'] ?? '').toString(),
                (conflict['owner_label'] ?? '').toString(),
                (conflict['owner_city'] ?? '').toString(),
              ].where((e) => e.isNotEmpty).join(' · '),
              style: Ds.t.body,
            ),
          ],
          if (s('reason').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(s('reason'), style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          if (s('note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(s('note'), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Text(
            [s('decided_label'), s('actor_label')]
                .where((e) => e.isNotEmpty)
                .join(' · '),
            style: Ds.t.caption,
          ),
        ],
      ),
    );
  }

  Widget _check(Map<String, dynamic> c) {
    String s(String k) => (c[k] ?? '').toString();
    final t = s('tone');
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: EdgeInsets.only(top: Ds.space.x4),
            width: Ds.space.x8,
            height: Ds.space.x8,
            decoration:
                BoxDecoration(color: tone(t), shape: BoxShape.circle),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(s('label'), style: Ds.t.body)),
                    Text(s('status_label'),
                        style: Ds.t.caption.copyWith(color: tone(t))),
                  ],
                ),
                if (s('detail').isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(s('detail'), style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
