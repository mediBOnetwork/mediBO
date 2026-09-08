// CHANGE #404 — the one masked-call button every surface uses.
//
// Rider, partner and admin all draw THIS widget, so "call the pharmacy" behaves
// identically in three places and there is exactly one code path that could ever
// leak a number. It cannot leak one: the only number it ever holds is the DID
// the backend reserved, which both sides are supposed to see.
//
// Everything printed here arrives in the payload — the button's label, the
// privacy line, the connecting sentence, the refusal. There is no Dart fallback
// string anywhere in this file, deliberately: a screen that invents its own
// wording for a refused call is a screen that disagrees with the server.
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';
import '../services/masked_call_service.dart';
import '../utils/render_log.dart';

class MaskedCallButton extends StatefulWidget {
  const MaskedCallButton({
    super.key,
    required this.target,
    this.dense = false,
    this.launch,
  });

  final MaskedCallTarget target;

  /// Compact form for a dense list row; the tap target stays >= the touch token.
  final bool dense;

  /// Injectable dialer seam — the protected test asserts on what would have
  /// been dialled without opening anything.
  final Future<void> Function(String url)? launch;

  @override
  State<MaskedCallButton> createState() => _MaskedCallButtonState();
}

class _MaskedCallButtonState extends State<MaskedCallButton> {
  bool _busy = false;

  Future<void> _open(String url) async {
    if (widget.launch != null) return widget.launch!(url);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _tap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await MaskedCallService.place(
          widget.target.orderId, widget.target.targetRole);
      try {
        RenderLog.write('c404_masked_call', res.ok ? res.mode : 'refused');
      } catch (_) {}

      if (res.shouldDial) {
        // tel: the MASKING number. The counterparty's real number is not in
        // this process, so there is nothing here to dial by mistake.
        await _open('tel:${res.did}');
      }

      if (!mounted) return;
      final line = [res.message, res.stubNotice]
          .where((s) => s.isNotEmpty)
          .join(' ');
      if (line.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(line)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.target.label;
    return Tooltip(
      message: widget.target.privacyNote,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: Ds.touch.minTarget,
          minWidth: Ds.touch.minTarget,
        ),
        child: OutlinedButton.icon(
          onPressed: _busy ? null : _tap,
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.divider),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            padding: EdgeInsets.symmetric(
              horizontal: widget.dense ? Ds.space.x12 : Ds.space.x16,
              vertical: Ds.space.x8,
            ),
          ),
          icon: _busy
              ? SizedBox(
                  width: Ds.space.x16,
                  height: Ds.space.x16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Ds.c.brand),
                )
              : Icon(Icons.call_outlined, size: Ds.space.x16 + Ds.space.x4),
          label: Text(label, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
        ),
      ),
    );
  }
}

/// The row of masked-call buttons for one order. An order with no permitted
/// counterparty renders NOTHING — absence is the backend's answer, not a
/// disabled button this widget decided to grey out.
class MaskedCallRow extends StatelessWidget {
  const MaskedCallRow({
    super.key,
    required this.targets,
    this.dense = false,
    this.launch,
  });

  final List<MaskedCallTarget> targets;
  final bool dense;
  final Future<void> Function(String url)? launch;

  @override
  Widget build(BuildContext context) {
    if (targets.isEmpty) return const SizedBox.shrink();
    try {
      RenderLog.write('c404_masked_call_buttons', targets.length);
    } catch (_) {}
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final t in targets)
          MaskedCallButton(target: t, dense: dense, launch: launch),
      ],
    );
  }
}
