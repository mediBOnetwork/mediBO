// CMD #2126 — the pieces of the 3-step registration flow that are not fields.
//
// Both render `customer_registration_payload().wizard` verbatim: the step
// labels, which steps are complete, the Done screen's title, line, checklist
// and button. Nothing here composes a word or decides a state — a step is
// "done" because the backend said `complete`, or because the person has
// already been past it on this device.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const {};

List<Map<String, dynamic>> wizardSteps(Map<String, dynamic> wizard) =>
    ((wizard['steps'] as List?) ?? const []).map(_m).toList();

/// Which steps may be tapped to jump back: every step before the current one,
/// and any the backend already calls complete.
bool wizardStepReachable(List<Map<String, dynamic>> steps, int i, int current) =>
    i < current || (i != current && steps[i]['complete'] == true);

/// The approved design (Registration v3): three bars, and under each its own
/// label, centred. The current step is bold brand; a finished step reads
/// "✓ General" (the backend's done_label), tappable; a step not reached yet is
/// grey. No numbers — the words are the backend's.
class RegistrationProgressBar extends StatelessWidget {
  const RegistrationProgressBar({
    super.key,
    required this.steps,
    required this.current,
    required this.onJump,
    this.currentComplete,
  });

  final List<Map<String, dynamic>> steps;
  final int current;
  final ValueChanged<int> onJump;

  /// CMD #2141 — the current step's own "done" as its surface knows it live
  /// (the Documents block's `required_complete`). Null → the backend's flag.
  final bool? currentComplete;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++) ...[
          if (i > 0) SizedBox(width: Ds.space.x8),
          Expanded(child: _segment(i)),
        ],
      ],
    );
  }

  /// CMD #2141 — v4: a bar is green ONLY when its step is complete — the
  /// backend's `complete` (the host marks a step the backend just accepted
  /// with Continue); the current step is grey until it is done. Being BEHIND
  /// the current step is not "complete": a resumed draft parked past an
  /// unfinished step keeps that step grey (QA round). Labels never carry a
  /// ✓ — the current one is bold, a done one green, the rest grey.
  Widget _segment(int i) {
    final active = i == current;
    final done = active
        ? (currentComplete ?? false)
        : steps[i]['complete'] == true;
    final reachable = wizardStepReachable(steps, i, current);
    final label = ((done && !active ? steps[i]['done_label'] : null) ??
            steps[i]['label'] ??
            '')
        .toString();
    // CMD #2135 — every label sits centred under its own bar.
    const align = TextAlign.center;
    final style = active
        ? Ds.t.caption.copyWith(color: Ds.c.text, fontWeight: FontWeight.w700)
        : done
            ? Ds.t.caption.copyWith(color: Ds.c.brand)
            : Ds.t.caption;
    return Semantics(
      identifier: 'reg_step_$i',
      button: reachable,
      selected: active,
      child: InkWell(
        onTap: reachable ? () => onJump(i) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: Ds.space.x4,
                decoration: BoxDecoration(
                  color: done ? Ds.c.brand : Ds.c.divider,
                  borderRadius: Ds.r.rChip,
                ),
              ),
              SizedBox(height: Ds.space.x8),
              Text(label,
                  textAlign: align,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen after Submit (Image A · Done): a tick in a soft-green circle,
/// the backend's title and line, one card listing each part with a coloured
/// Done / Add later, and "Start browsing" pinned to the bottom.
class RegistrationDoneView extends StatelessWidget {
  const RegistrationDoneView({
    super.key,
    required this.done,
    required this.onBrowse,
    this.horizontalPadding,
  });

  final Map<String, dynamic> done;
  final VoidCallback onBrowse;
  final double? horizontalPadding;

  String _s(String k) => (done[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final items = ((done['checklist'] as List?) ?? const []).map(_m).toList();
    final pad = horizontalPadding ?? Ds.space.x16;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x32, pad, Ds.space.x24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: Ds.space.x48 + Ds.space.x32,
                    height: Ds.space.x48 + Ds.space.x32,
                    decoration: BoxDecoration(
                      color: Ds.c.brandSoft,
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Icon(Icons.check_rounded,
                        size: Ds.space.x48, color: Ds.c.brand),
                  ),
                ),
                SizedBox(height: Ds.space.x24),
                Text(_s('title'), style: Ds.t.title, textAlign: TextAlign.center),
                SizedBox(height: Ds.space.x8),
                Text(_s('line'),
                    style: Ds.t.bodySecondary, textAlign: TextAlign.center),
                SizedBox(height: Ds.space.x24),
                Container(
                  decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rCard,
                    border: Border.all(color: Ds.c.divider),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < items.length; i++) ...[
                        if (i > 0) Divider(height: Ds.space.hairline, color: Ds.c.divider),
                        _row(items[i]),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, Ds.space.x12, pad, Ds.space.x16),
          child: Semantics(
            identifier: 'reg_primary',
            button: true,
            child: SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: onBrowse,
                child: Text(_s('cta_label')),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> it) {
    final ok = it['done'] == true;
    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x12),
      child: Row(children: [
        Expanded(child: Text((it['label'] ?? '').toString(), style: Ds.t.body)),
        SizedBox(width: Ds.space.x8),
        Text(
          ok ? _s('done_label') : _s('later_label'),
          style: Ds.t.bodyStrong.copyWith(color: ok ? Ds.c.brand : Ds.c.warning),
        ),
      ]),
    );
  }
}
