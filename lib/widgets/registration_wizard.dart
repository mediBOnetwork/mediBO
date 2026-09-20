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

/// Three segments with their labels. A finished step shows a tick and is
/// tappable; the current step is brand-filled; the rest are hairline grey.
class RegistrationProgressBar extends StatelessWidget {
  const RegistrationProgressBar({
    super.key,
    required this.steps,
    required this.current,
    required this.onJump,
  });

  final List<Map<String, dynamic>> steps;
  final int current;
  final ValueChanged<int> onJump;

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

  Widget _segment(int i) {
    final done = i < current || (steps[i]['complete'] == true && i != current);
    final active = i == current;
    final reachable = wizardStepReachable(steps, i, current);
    final label = (steps[i]['label'] ?? '').toString();
    final color = (done || active) ? Ds.c.brand : Ds.c.divider;
    return Semantics(
      identifier: 'reg_step_$i',
      button: reachable,
      selected: active,
      child: InkWell(
        borderRadius: Ds.r.rChip,
        onTap: reachable ? () => onJump(i) : null,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: Ds.space.x4,
                decoration: BoxDecoration(
                    color: color, borderRadius: Ds.r.rChip),
              ),
              SizedBox(height: Ds.space.x8),
              Row(children: [
                if (done && !active) ...[
                  Icon(Icons.check_circle, size: Ds.space.x16, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x4),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: active
                        ? Ds.t.caption.copyWith(color: Ds.c.text)
                        : Ds.t.caption,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// The screen after Submit: a tick, the backend's sentence, what was sent
/// (Done / Add later per part) and one green button.
class RegistrationDoneView extends StatelessWidget {
  const RegistrationDoneView({
    super.key,
    required this.done,
    required this.onBrowse,
  });

  final Map<String, dynamic> done;
  final VoidCallback onBrowse;

  String _s(String k) => (done[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final items = ((done['checklist'] as List?) ?? const []).map(_m).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: Ds.space.x24),
        Icon(Icons.check_circle, size: Ds.space.x48, color: Ds.c.brand),
        SizedBox(height: Ds.space.x16),
        Text(_s('title'), style: Ds.t.title, textAlign: TextAlign.center),
        SizedBox(height: Ds.space.x8),
        Text(_s('line'), style: Ds.t.bodySecondary, textAlign: TextAlign.center),
        SizedBox(height: Ds.space.x24),
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_s('checklist_title').isNotEmpty) ...[
                Text(_s('checklist_title'), style: Ds.t.caption),
                SizedBox(height: Ds.space.x8),
              ],
              for (final it in items) _row(it),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x24),
        Semantics(
          identifier: 'reg_done_browse',
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
      ],
    );
  }

  Widget _row(Map<String, dynamic> it) {
    final ok = it['done'] == true;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Row(children: [
        Expanded(child: Text((it['label'] ?? '').toString(), style: Ds.t.body)),
        SizedBox(width: Ds.space.x8),
        Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: ok ? Ds.c.successSoft : Ds.c.warningSoft,
            borderRadius: Ds.r.rChip,
          ),
          child: Text(
            ok ? _s('done_label') : _s('later_label'),
            style: Ds.t.caption.copyWith(color: ok ? Ds.c.success : Ds.c.warning),
          ),
        ),
      ]),
    );
  }
}
