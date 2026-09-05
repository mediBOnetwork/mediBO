import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../design_tokens.dart';
import 'claude_auth_banner.dart';
import 'dev_queue_common.dart';

/// CHANGE #1369 — Claude login, on the Cron health screen.
///
/// It sits with the lanes because it answers the same shape of question they
/// do: is this part of the fleet healthy right now, and if not, what is holding
/// it. On 5 Sep the answer was "the box cannot start a Claude session at all"
/// and there was nowhere in the app it could be said — so the queue churned 28
/// claims in 40 minutes while every surface stayed green.
///
/// Unlike the lanes beside it this panel is also a CONTROL: one tap starts
/// `claude auth login` on the VM, and the link and code the VM scrapes off its
/// own login pane are published back onto this card. That is the whole point —
/// the one failure Om cannot fix from his phone is the one that stops every
/// runner, so the fix has to live where the diagnosis does.
///
/// The panel decides nothing. `claude_auth_status()` builds every string, tone
/// and flag, including whether the button may be offered at all; the shared
/// [ClaudeAuthBanner] prints them. A healthy login draws only the calm
/// one-liner, because a green badge that is always there is how a real red
/// stops being read.
class ClaudeAuthSection extends StatefulWidget {
  /// Injectable so the panel can be driven from a fixture.
  final SupabaseClient? client;
  const ClaudeAuthSection({super.key, this.client});

  @override
  State<ClaudeAuthSection> createState() => _ClaudeAuthSectionState();
}

class _ClaudeAuthSectionState extends State<ClaudeAuthSection> {
  SupabaseClient get _c => widget.client ?? Supabase.instance.client;
  Map<String, dynamic> _auth = const {};
  bool _busy = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Map<String, dynamic> _asMap(dynamic raw) {
    final v = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  Future<void> _load() async {
    try {
      final r = _asMap(await _c.rpc('claude_auth_status'));
      if (!mounted) return;
      setState(() {
        _auth = r;
        _loading = false;
      });
    } catch (_) {
      // Same contract as every lane on this screen: a panel, never the page.
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The one tap. The backend starts the login on the VM, publishes the link
  /// and the code onto this same card, and flips the state itself once the
  /// login lands — so all this does is ask, then re-read what comes back.
  Future<void> _relogin() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final r = _asMap(await _c.rpc('claude_auth_relogin_request'));
      if (!mounted) return;
      if (r.isNotEmpty) setState(() => _auth = r);
    } catch (_) {
      // Swallowed for the same reason: the panel degrades, the screen does not.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    // The VM answers within a tick. Re-read rather than guess at the states
    // between "requested" and the link appearing.
    for (final s in const [5, 15, 30]) {
      Future.delayed(Duration(seconds: s), () {
        if (mounted) _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || (_auth['has'] ?? false) != true) {
      return const SizedBox.shrink();
    }
    final tone = toneByName((_auth['tone'] ?? 'neutral').toString());
    return DqCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(
              (_auth['title'] as String?) ?? '',
              style: Ds.t.subtitle
                  .copyWith(fontWeight: FontWeight.w700, color: kTextHi),
            ),
          ),
          if (((_auth['version'] as String?) ?? '').isNotEmpty)
            ToneChip(label: _auth['version'] as String, tone: tone),
        ]),
        if (((_auth['checked'] as String?) ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_auth['checked'] as String, style: Ds.t.caption),
        ],
        if (((_auth['detail'] as String?) ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(_auth['detail'] as String, style: Ds.t.caption),
        ],
        // The banner draws itself only when there is something wrong — the
        // shared widget the Runner card uses, so the two surfaces can never
        // disagree about what red looks like.
        ClaudeAuthBanner(auth: _auth, busy: _busy, onRelogin: _relogin),
      ]),
    );
  }
}
