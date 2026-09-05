import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import 'dev_queue_common.dart';

/// The Claude usage block on the Dev Queue runner strip — bars for the 5h
/// session and the weekly caps, plus the sync chip above them.
///
/// It is a PRINTER (CHANGE #1365). Every string, percent and tone in here is
/// `dev_cmd_session_usage()`'s: the bar label, `pct_display`, the reset
/// sentence, `updated_display` and `updated_tone`. Nothing is computed, and
/// nothing is inferred from the numbers — in particular the widget never
/// decides for itself whether the reading is fresh, because the failure it was
/// built for looks exactly like freshness from here: on 5 Sep the fetcher had
/// been dead since boot while the card read "synced 15h ago". The backend now
/// says `sync failing: <reason>` and this draws that sentence, in the tone it
/// was handed, however long it is.
class UsageMeter extends StatelessWidget {
  /// The `dev_cmd_session_usage()` payload, verbatim.
  final Map<String, dynamic> usage;

  /// Opens the token-rate sheet. Null hides the chip entirely.
  final VoidCallback? onRates;

  const UsageMeter({super.key, required this.usage, this.onRates});

  List<Map<String, dynamic>> get _limits =>
      ((usage['limits'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Widget build(BuildContext context) {
    final spend = '${usage['spend_display'] ?? ''}';
    final today = '${usage['today_display'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.data_usage,
              size: Ds.t.bodySize,
              color: Ds.c.textSecondary,
            ),
            SizedBox(width: Ds.space.x8),
            Text(c('dev_queue.usage_label'), style: Ds.t.subtitle),
            SizedBox(width: Ds.space.x8),
            // Flexible, not Spacer: the sync line can be a whole failure sentence
            // ("sync failing: Claude login not usable — accessToken absent"), and a
            // fixed-width chip would clip exactly the message that matters most.
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: _syncChip(),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x12),
        for (final l in _limits) _limitBar(l),
        if (spend.isNotEmpty) Text(spend, style: Ds.t.caption),
        if (today.isNotEmpty) Text(today, style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Row(
          children: [
            Expanded(
              child: Text(
                c('dev_queue.plan_note'),
                style: Ds.t.caption.copyWith(
                  color: Ds.c.brand,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onRates != null)
              InkWell(
                onTap: onRates,
                borderRadius: Ds.r.rChip,
                // The chip stays visually small in a dense admin strip, but its tap
                // target is a full Ds.touch.minTarget box around it.
                child: Container(
                  constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12,
                      vertical: Ds.space.x4,
                    ),
                    decoration: BoxDecoration(
                      color: Ds.c.infoSoft,
                      borderRadius: Ds.r.rChip,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.info_outline,
                          size: Ds.t.captionSize,
                          color: Ds.c.info,
                        ),
                        SizedBox(width: Ds.space.x4),
                        Text(
                          c('dev_queue.rates_open'),
                          style: Ds.t.caption.copyWith(
                            color: Ds.c.info,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  /// Freshness / failure indicator. The sentence AND the tone are the
  /// backend's (`updated_display` / `updated_tone`) — a minutes-old number can
  /// never look current, and a dead fetcher can never look like a live one.
  Widget _syncChip() {
    final txt = '${usage['updated_display'] ?? ''}';
    if (txt.isEmpty) return const SizedBox.shrink();
    final tone = statusTone((usage['updated_tone'] ?? 'completed').toString());
    final fresh = (usage['stale'] ?? false) != true;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x8,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rChip),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            fresh ? Icons.check_circle : Icons.sync_problem,
            size: Ds.t.captionSize,
            color: tone.fg,
          ),
          SizedBox(width: Ds.space.x4),
          Flexible(
            child: Text(
              txt,
              style: Ds.t.caption.copyWith(
                color: tone.fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _limitBar(Map<String, dynamic> l) {
    final tone = statusTone((l['tone'] ?? 'completed').toString());
    // The width of the bar is the ONE number this widget reads as a number —
    // and it is still the backend's effective percent, so an expired window
    // draws empty because the server counted it as 0, not because Dart did.
    final pct = ((l['percent'] as num?)?.toDouble() ?? 0).clamp(0, 100) / 100.0;
    final resets = '${l['resets_display'] ?? ''}';
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('${l['label'] ?? ''}', style: Ds.t.body)),
              SizedBox(width: Ds.space.x8),
              Text(
                '${l['pct_display'] ?? ''}',
                style: Ds.t.body.copyWith(
                  color: tone.fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          ClipRRect(
            borderRadius: Ds.r.rChip,
            child: LinearProgressIndicator(
              value: pct.toDouble(),
              minHeight: Ds.space.x8,
              backgroundColor: Ds.c.divider,
              valueColor: AlwaysStoppedAnimation<Color>(tone.fg),
            ),
          ),
          if (resets.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(resets, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}
