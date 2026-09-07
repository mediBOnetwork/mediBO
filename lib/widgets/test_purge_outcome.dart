import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// CMD #1852 — THE PURGE REPORTS WHAT IT DID, AND SAYS SO IN THE BACKEND'S
/// WORDS.
///
/// End & purge used to answer with a single sentence in a snackbar. That is
/// not a report: it never said what was REVERSED, and it never said whether
/// the before and after fingerprints agreed — which is the only thing that
/// makes a purge provable rather than hopeful.
///
/// `test_session_outcome()` returns the whole verdict — title, tone, a list of
/// {label, value, tone} rows, the fingerprint sentence and its tone, and the
/// word on the close button. This widget PRINTS it. It computes no number,
/// pluralises no label, and picks no colour: `tone` is one lookup, and a tone
/// this build has never heard of stays neutral rather than guessing.
///
/// A payload with `has:false` (or an absent one) draws nothing at all — the
/// absence of a verdict is not a verdict.
class TestPurgeOutcomeSheet extends StatelessWidget {
  const TestPurgeOutcomeSheet({super.key, required this.outcome, this.onClose});

  /// `outcome` from `test_session_end_purge()`, verbatim.
  final Map<String, dynamic> outcome;

  /// Tapped when the close button is pressed. Absent → the button pops.
  final VoidCallback? onClose;

  static bool has(Map<String, dynamic>? o) => o != null && o['has'] == true;

  /// Shows the sheet for [outcome]; a payload with nothing in it shows
  /// nothing, because the decision to report is the backend's too.
  static Future<void> show(
      BuildContext context, Map<String, dynamic>? outcome) async {
    if (!has(outcome)) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => TestPurgeOutcomeSheet(outcome: outcome!),
    );
  }

  static Color toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'warning':
        return Ds.c.warning;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  static Color toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }

  String _s(String key) {
    final v = outcome[key];
    return v is String ? v : '';
  }

  List<Map<String, dynamic>> get _lines {
    final raw = outcome['lines'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    if (outcome['has'] != true) return const SizedBox.shrink();
    final verdict = _s('verdict');
    final close = _s('close');
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _s('title'),
              style: Ds.t.title.copyWith(color: toneColor(_s('tone'))),
            ),
            SizedBox(height: Ds.space.x16),
            // Payload order, always. The backend decides what leads.
            for (final line in _lines) ...[
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        (line['label'] ?? '').toString(),
                        style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Text(
                      (line['value'] ?? '').toString(),
                      style: Ds.t.body.copyWith(
                        color: toneColor((line['tone'] ?? '').toString()),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (verdict.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(Ds.space.x12),
                decoration: BoxDecoration(
                  color: toneSoft(_s('verdict_tone')),
                  borderRadius: Ds.r.rCard,
                ),
                child: Text(
                  verdict,
                  key: const ValueKey('test_purge_verdict'),
                  style: Ds.t.body
                      .copyWith(color: toneColor(_s('verdict_tone'))),
                ),
              ),
            ],
            if (close.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  key: const ValueKey('test_purge_close'),
                  onPressed:
                      onClose ?? () => Navigator.of(context).maybePop(),
                  child: Text(close),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
