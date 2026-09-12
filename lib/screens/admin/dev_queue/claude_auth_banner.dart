import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';

/// CHANGE #1369 — the Claude login, on the Runner card.
///
/// 5 Sep the VM's Claude Code login expired. `claude --version` still answered
/// 2.1.261, so every check the fleet ran was green while every session died at
/// birth: runners claimed, posted "started", registered a NULL pid, spent zero
/// tokens, and the liveness sweep handed each row straight back — 28 claims in
/// 40 minutes, with nothing anywhere in the app able to say why.
///
/// This banner is that missing sentence. Like [BreakerBanner] beside it, it is
/// rendered OUTSIDE the control card's expand gate on purpose: "no worker can
/// start a session" is not a state Om should have to open a panel to discover.
///
/// It decides NOTHING. `claude_auth_status()` builds the title, the sub-line,
/// the "checked 4m ago on …" line, the CLI chip, the tone name, whether a
/// re-login may be offered at all, that button's label, and every word of the
/// handshake — including the link and the code the VM scrapes off its own login
/// pane. The widget asks the payload one question (`has`) and prints the rest in
/// the order it arrives. A `success` tone draws nothing: a healthy login is not
/// news, and a permanent green badge is how a real red stops being read.
class ClaudeAuthBanner extends StatelessWidget {
  /// `dev_ctl_get().claude_auth`, verbatim.
  final Map<String, dynamic> auth;

  /// Called when Om taps the backend's own re-login button. The parent runs
  /// `claude_auth_relogin_request()` and re-renders from what it returns —
  /// this widget never talks to the network and never guesses the next state.
  final Future<void> Function()? onRelogin;

  /// True while that request is in flight, so the button can say so without
  /// this widget owning any state of its own.
  final bool busy;

  const ClaudeAuthBanner(
      {super.key, required this.auth, this.onRelogin, this.busy = false});

  /// The one question the widget asks. A payload that is absent, that says
  /// `has:false`, or that reports a healthy login draws nothing at all.
  static bool shows(Map<String, dynamic>? a) =>
      (a?['has'] ?? false) == true &&
      (a?['tone'] ?? 'success').toString() != 'success' &&
      (a?['title'] ?? '').toString().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    if (!shows(auth)) return const SizedBox.shrink();

    final tone = toneByName((auth['tone'] ?? 'error').toString());
    final title = (auth['title'] ?? '').toString();
    final sub = (auth['sub'] ?? '').toString();
    final checked = (auth['checked'] ?? '').toString();
    final version = (auth['version'] ?? '').toString();
    final relogin =
        (auth['relogin'] as Map?)?.cast<String, dynamic>() ?? const {};

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x8),
      width: double.infinity,
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x12),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.key_off_outlined, size: Ds.t.subtitleSize, color: tone.fg),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
            // Absence is absence: an empty string from the backend is a line
            // that is not drawn, never a dash or a placeholder.
            if (sub.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(sub, style: Ds.t.caption.copyWith(color: tone.fg)),
            ],
            if (checked.isNotEmpty || version.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(
                [checked, version].where((s) => s.isNotEmpty).join(' · '),
                style: Ds.t.caption.copyWith(color: tone.fg),
              ),
            ],
            _relogin(relogin, tone),
          ]),
        ),
      ]),
    );
  }

  /// The handshake, printed. `can` is the backend's decision about whether a
  /// login would help AND whether one is already running — a second tap must
  /// never restart the VM's login mid-flow, and that judgement is not the
  /// widget's to make.
  Widget _relogin(Map<String, dynamic> r, Tone tone) {
    if (r.isEmpty) return const SizedBox.shrink();
    final can = (r['can'] ?? false) == true;
    final label = (r['label'] ?? '').toString();
    final stateLabel = (r['state_label'] ?? '').toString();
    final url = (r['url'] ?? '').toString();
    final code = (r['code'] ?? '').toString();
    final hint = (r['hint'] ?? '').toString();

    final rows = <Widget>[];

    if (stateLabel.isNotEmpty) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: Ds.space.x8),
        child: Text(stateLabel, style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
      ));
    }
    // The link and the code are the payload's, scraped off the VM's own login
    // pane and published by claude_auth_relogin_post — they are shown exactly
    // as they arrived, selectable so Om can copy them on the phone he is
    // holding.
    if (url.isNotEmpty) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: Ds.space.x4),
        child: SelectableText(url, style: Ds.t.caption.copyWith(color: tone.fg)),
      ));
    }
    if (code.isNotEmpty) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: Ds.space.x4),
        child: SelectableText(code,
            style: Ds.t.bodyStrong.copyWith(color: tone.fg)),
      ));
    }
    if (can && label.isNotEmpty && onRelogin != null) {
      rows.add(Padding(
        padding: EdgeInsets.only(top: Ds.space.x8),
        child: SizedBox(
          height: Ds.space.x48,
          child: OutlinedButton(
            onPressed: busy ? null : () => onRelogin!.call(),
            style: OutlinedButton.styleFrom(
              foregroundColor: tone.fg,
              side: BorderSide(color: tone.fg),
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: busy
                ? SizedBox(
                    width: Ds.space.x16,
                    height: Ds.space.x16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: tone.fg))
                : Text(label),
          ),
        ),
      ));
      if (hint.isNotEmpty) {
        rows.add(Padding(
          padding: EdgeInsets.only(top: Ds.space.x4),
          child: Text(hint, style: Ds.t.caption.copyWith(color: tone.fg)),
        ));
      }
    }

    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}
