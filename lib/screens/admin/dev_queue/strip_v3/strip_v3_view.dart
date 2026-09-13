import 'package:flutter/material.dart';

import '../../../../design_tokens.dart';
import '../../../../utils/render_log.dart';
import '../dev_queue_common.dart';

/// CHANGE #1367 — the Runner control strip, v3. The PURE renderer.
///
/// v1 and v2 drew what Om had ASKED for. That is not a status, and three
/// capabilities proved it by dying quietly behind a green toggle: usage sync,
/// Remote Control, and the build branch — which reported `enabled: true`,
/// `want: true` and 22 pending commands while its status had been `off` since
/// the day it shipped, because a token read parsed a JSON string as an object
/// and concluded the vault was empty. The card said everything was on. It was
/// on in the only sense the card measured: somebody had switched it on.
///
/// So every toggle here carries TWO booleans — `desired` and `actual` — and the
/// strip's headline is the backend's sentence for the gap between them, or its
/// all-clear. The widget compares nothing and words nothing: `strip_v3_card()`
/// decides what counts as blocked, in what order, and how to say it.
///
/// The one rule worth stating twice, because #1369 broke it and stopped the
/// fleet: a capability that cannot be OBSERVED is never reported as broken.
/// `rc_sessions: null` means "the supervisor has not reported recently" and
/// draws nothing at all — it is not zero.
class StripV3View extends StatelessWidget {
  /// `strip_v3_card()`, verbatim.
  final Map<String, dynamic> data;

  /// Tapping a toggle. The parent calls the backend and re-renders from what it
  /// returns — this widget never assumes a tap succeeded.
  final void Function(String key, bool on)? onToggle;

  /// Tapping a live command chip.
  final void Function(int id)? onOpenCommand;

  /// Tapping Stop / Restart on a worker row. `(agent, actionKey)`.
  final void Function(String agent, String action)? onWorkerAction;

  /// CHANGE #1570 — what used to be the SECOND runner card, rendered INSIDE
  /// this one. #1367 left v2 in place beside v3 deliberately, and the result
  /// was two cards stacked at the top of Dev Queue saying overlapping things.
  /// v2 still owns surfaces v3 does not (the breaker, the usage meter, health,
  /// context economy); so it moves in here as a footer instead of being
  /// deleted, and the screen renders exactly one card.
  final Widget? footer;

  final bool busy;

  const StripV3View({
    super.key,
    required this.data,
    this.onToggle,
    this.onOpenCommand,
    this.onWorkerAction,
    this.footer,
    this.busy = false,
  });

  static bool shows(Map<String, dynamic>? d) => (d?['has'] ?? false) == true;

  @override
  Widget build(BuildContext context) {
    // has:false must not take the footer down with it — the strip having
    // nothing to say is not a reason to hide the controls it now hosts.
    if (!shows(data)) {
      return footer == null ? const SizedBox.shrink() : DqCard(child: footer!);
    }

    final toggles = (data['toggles'] as List?) ?? const [];
    final blocked = (data['blocked'] as List?) ?? const [];
    final tone = toneByName((data['tone'] ?? 'neutral').toString());
    final drain = (data['drain_label'] ?? '').toString();
    final gauges = (data['gauges'] as List?) ?? const [];
    final workers = (data['workers'] as List?) ?? const [];
    final branch = (data['branch'] as Map?) ?? const {};
    // The branch block is the richer form (it carries the builds counter and
    // the refusal line). A payload that only sends the flat `branch_label` —
    // any build older than #1570, and the shape the protected suite has held
    // since #1367 — still prints its sentence.
    final branchLabel = (branch['label'] ?? data['branch_label'] ?? '').toString();

    // Reachability proof (CLAUDE.md): the live render-log is what says this
    // card PAINTED, not that it compiled. `c1570_strip` carries the two numbers
    // that make the difference this change is about — how many gauges and how
    // many worker rows actually reached the screen — and `c1570_cards` is 1
    // because there is ONE runner card now, which is the claim a screenshot
    // alone can always be argued with.
    RenderLog.write('c1570_strip',
        'gauges=${gauges.length} workers=${workers.length} builds=${branch['builds_label'] ?? ''}');
    RenderLog.write('c1570_cards', 1);
    // CMD #1862 — how many of the three switches actually reached the screen.
    // It read 0 (the key was absent entirely) for as long as this card was
    // asking production for a control-plane RPC, which is the only evidence
    // that separates "the toggles are back" from "the code that draws them
    // compiled".
    RenderLog.write('c1862_toggles', toggles.length);

    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text((data['title'] ?? '').toString(),
            style:
                Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700, color: kTextHi)),

        // The headline is a SENTENCE the backend wrote, and its length is the
        // backend's business — "Blocked: 1 build(s) running on production while
        // the branch is on" does not fit beside a title on any phone. It sat on
        // the title row and overflowed by 38 px, which clips the very words the
        // card exists to deliver. Its own row, free to wrap.
        if ((data['headline'] ?? '').toString().isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Flexible(
              child: ToneChip(
                  label: (data['headline']).toString(), tone: tone),
            ),
          ]),
        ],

        // Every gap, in the order the backend ranked them. One line each.
        if (blocked.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          for (final b in blocked)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.error_outline,
                    size: Ds.t.bodySize, color: toneByName('warning').fg),
                SizedBox(width: Ds.space.x8),
                Expanded(
                    child: Text(b.toString(),
                        style: Ds.t.caption
                            .copyWith(color: toneByName('warning').fg))),
              ]),
            ),
        ],

        SizedBox(height: Ds.space.x16),
        for (final t in toggles) _toggle(t as Map),

        SizedBox(height: Ds.space.x12),
        Text((data['building_label'] ?? '').toString(), style: Ds.t.body),

        // The build branch, and the one number that says whether it is being
        // USED. A branch that is up and carrying zero builds is the #1570
        // failure; the counter is the only thing that can tell them apart, so
        // it is on the card rather than in a log.
        if (branchLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Row(children: [
            Flexible(
              child: Text(branchLabel, style: Ds.t.caption),
            ),
            if ((branch['builds_label'] ?? '').toString().isNotEmpty) ...[
              SizedBox(width: Ds.space.x8),
              ToneChip(
                  label: (branch['builds_label']).toString(),
                  tone: toneByName((branch['builds_tone'] ?? 'neutral').toString())),
            ],
          ]),
          if ((branch['refusal_label'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text((branch['refusal_label']).toString(),
                style: Ds.t.caption.copyWith(color: toneByName('warning').fg)),
          ],
        ],

        if (gauges.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [for (final g in gauges) _gauge(g as Map)],
          ),
        ],

        if (workers.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          Text((data['workers_title'] ?? '').toString(),
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          for (final w in workers) _worker(w as Map),
        ],

        if (drain.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          ToneChip(label: drain, tone: toneByName('info')),
        ],

        if (footer != null) ...[
          SizedBox(height: Ds.space.x16),
          footer!,
        ],
      ]),
    );
  }

  /// One gauge. Every word and the tone are the payload's; this decides only
  /// how wide the tile is.
  Widget _gauge(Map g) {
    final tone = toneByName((g['tone'] ?? 'neutral').toString());
    final sub = (g['sub'] ?? '').toString();
    return Container(
      constraints: BoxConstraints(minWidth: Ds.space.x48 * 2),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: Ds.r.rChip,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text((g['label'] ?? '').toString(),
            style: Ds.t.caption.copyWith(color: tone.fg)),
        SizedBox(height: Ds.space.x4),
        Text((g['value'] ?? '').toString(),
            style: Ds.t.body
                .copyWith(fontWeight: FontWeight.w700, color: tone.fg)),
        if (sub.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(sub, style: Ds.t.caption.copyWith(color: tone.fg)),
        ],
      ]),
    );
  }

  /// One worker, with its own two taps. The buttons, their words, their tone
  /// and their confirmation sentence all arrive in `actions[]` — a build that
  /// has never heard of a third action would render it correctly, and one that
  /// receives none draws no buttons at all.
  Widget _worker(Map w) {
    final actions = (w['actions'] as List?) ?? const [];
    final sub = (w['sub'] ?? '').toString();
    final title = (w['title'] ?? '').toString();
    final agent = (w['agent'] ?? '').toString();
    final pending = (w['busy'] ?? false) == true;

    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Flexible(
          child: Text((w['label'] ?? '').toString(),
              overflow: TextOverflow.ellipsis,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        ),
        SizedBox(width: Ds.space.x8),
        ToneChip(
            label: (w['status'] ?? '').toString(),
            tone: toneByName((w['tone'] ?? 'neutral').toString())),
      ]),
      if (sub.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: Ds.t.caption),
      ],
      if (title.isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: Ds.t.caption),
      ],
    ]);

    final buttons = Wrap(
      spacing: Ds.space.x8,
      children: [
        for (final a in actions) _actionButton(agent, a as Map, pending),
      ],
    );

    // A worker row carries a command TITLE and up to two buttons. The text
    // takes whatever the buttons leave and ellipsises inside that — never a
    // hard-coded width, and never an overflow. (A LayoutBuilder cannot be used
    // here: DqCard measures its children with IntrinsicHeight, which refuses to
    // run a layout callback speculatively.)
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: text),
        SizedBox(width: Ds.space.x8),
        buttons,
      ]),
    );
  }

  Widget _actionButton(String agent, Map a, bool pending) {
    final tone = toneByName((a['tone'] ?? 'neutral').toString());
    final key = (a['key'] ?? '').toString();
    final enabled = !busy && !pending && onWorkerAction != null && agent.isNotEmpty;
    return SizedBox(
      height: Ds.space.x48,
      child: TextButton(
        style: TextButton.styleFrom(
          foregroundColor: tone.fg,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          minimumSize: Size(Ds.space.x48, Ds.space.x48),
        ),
        onPressed: enabled ? () => onWorkerAction!.call(agent, key) : null,
        child: Text((a['label'] ?? '').toString(), style: Ds.t.caption),
      ),
    );
  }

  /// One row, two truths. `desired` drives the switch; `actual` is stated
  /// beside it, and the two disagreeing is the whole information content of
  /// this card — so the disagreement is never smoothed over by showing one of
  /// them twice.
  Widget _toggle(Map t) {
    final key = (t['key'] ?? '').toString();
    final desired = (t['desired'] ?? false) == true;
    final actual = (t['actual'] ?? false) == true;
    final sub = (t['sub'] ?? '').toString();
    final mismatch = desired != actual;
    final actualLabel =
        (actual ? t['actual_label'] : t['not_actual_label'] ?? '')?.toString() ??
            '';
    // CMD #1864 — WHETHER the state word is shown, and in what tone, are the
    // backend's calls now. Drawing it only on a mismatch made the chip a
    // restatement of the switch: with the VM row it meant a box that had gone
    // down while the switch was still on showed the disagreement, but a box
    // whose real state simply could not be read showed nothing at all. The VM
    // row sends its word always; the other two still send it only on a gap.
    // An older payload without these keys keeps the previous behaviour exactly.
    final actualChip =
        (t['actual_chip'] ?? (mismatch ? actualLabel : '')).toString();
    final actualTone = (t['actual_tone'] ?? 'warning').toString();

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text((t['label'] ?? '').toString(),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
              // CHANGE #1570 — these two words were Dart literals ('running'
              // / 'not running'), which is a display string written in the
              // frontend on the one card whose entire purpose is to print the
              // backend's account of itself. They arrive in the payload now,
              // and a toggle that sends neither shows no chip.
              if (actualChip.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                ToneChip(label: actualChip, tone: toneByName(actualTone)),
              ],
            ]),
            if (sub.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(sub, style: Ds.t.caption),
            ],
          ]),
        ),
        Switch(
          value: desired,
          activeThumbColor: kBrand,
          onChanged: busy || onToggle == null
              ? null
              : (v) => onToggle!.call(key, v),
        ),
      ]),
    );
  }
}
