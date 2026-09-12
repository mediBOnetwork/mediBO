// CHANGE #1922 — "what is the in-app update prompt offering right now?"
//
// On 08 Sep 1.3.25 was uploaded at 22:22 and sat In review in Play Console,
// while every phone already showed "A new version of mediBO is ready · Version
// 1.3.25 · Update on Google Play" — and Play still served 1.3.24. Nobody could
// SEE that mismatch: the release row said one thing, Play said another, and the
// only surface for either was a log file. This panel is that surface.
//
// Two facts, side by side, both the backend's words: the version Play has
// PUBLISHED (the one the prompt may offer) and the latest version SUBMITTED
// (silent until review clears and the rollout reaches everyone), plus the log
// of every status change the poller has seen.
//
// WHERE THE DATA COMES FROM, AND WHY IT IS NOT DevQueueService: app_releases,
// app_update_check() and app_update_state() all live on PRODUCTION — the dev
// queue's own control plane (#1761) has no app_releases at all, and routing
// this read there is exactly the #1802 bug (a row written where nothing reads
// it). Lesson 290 says dev-queue reads go through DevQueueService; this is not
// a dev-queue read, it is a production read that happens to be rendered on a
// dev-queue screen, so it uses the app's own (production) client.
//
// THE APP RENDERS. IT NEVER DECIDES. Every word here — headings, status
// labels, the rollout sentence, the "Play read 3m ago" line, chip tones —
// arrives inside app_update_state(). No status→label switch, no percentage
// formatting, no date maths.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';

/// The panel as it appears on the Play Store screen: loads once, renders what
/// came back, and says nothing at all when the backend refuses.
class AppUpdateGatePanel extends StatefulWidget {
  const AppUpdateGatePanel({super.key, this.loader});

  /// Injectable seam for the widget test — no network, no Supabase.
  final Future<Map<String, dynamic>?> Function()? loader;

  @override
  State<AppUpdateGatePanel> createState() => _AppUpdateGatePanelState();
}

class _AppUpdateGatePanelState extends State<AppUpdateGatePanel> {
  Map<String, dynamic>? _state;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic>? s;
    try {
      s = widget.loader != null ? await widget.loader!() : await _defaultLoad();
    } catch (_) {
      s = null; // a failed read draws nothing rather than a wrong sentence
    }
    if (!mounted) return;
    setState(() {
      _state = s;
      _loading = false;
    });
  }

  static Future<Map<String, dynamic>?> _defaultLoad() async {
    final res = await Supabase.instance.client.rpc('app_update_state');
    if (res is Map) return Map<String, dynamic>.from(res);
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return DqCard(
        child: SizedBox(
          height: Ds.space.x48,
          child: Center(
            child: SizedBox(
              width: Ds.space.x16,
              height: Ds.space.x16,
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }
    final s = _state;
    if (s == null || s['ok'] != true) return const SizedBox.shrink();
    return AppUpdateGateView(state: s);
  }
}

/// The pure renderer. Public so the widget test pumps it with a fixture
/// payload and asserts that every string on screen came from that payload.
class AppUpdateGateView extends StatelessWidget {
  const AppUpdateGateView({super.key, required this.state});

  final Map<String, dynamic> state;

  static String _s(Map<String, dynamic> m, String k) {
    final v = m[k];
    return v is String ? v : '';
  }

  Map<String, dynamic> _block(String key) {
    final v = state[key];
    return v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _block('prompt');
    final published = _block('published');
    final submitted = _block('submitted');
    final log = (state['log'] as List?) ?? const [];

    try {
      RenderLog.write(
        'c1922_update_gate',
        'prompt_on=${prompt['is_on'] == true};published=${published['has'] == true};'
            'submitted=${submitted['has'] == true};log=${log.length}',
      );
    } catch (_) {}

    return DqCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(_s(state, 'title'), style: Ds.t.subtitle)),
              ToneChip(
                label: _s(prompt, 'label'),
                tone: toneByName(_s(prompt, 'tone')),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(_s(state, 'subtitle'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x12),
          Text(_s(prompt, 'detail'), style: Ds.t.body),
          SizedBox(height: Ds.space.x24),
          _release(published),
          SizedBox(height: Ds.space.x16),
          _release(submitted),
          SizedBox(height: Ds.space.x16),
          Text(_s(state, 'checked_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          Text(_s(state, 'log_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x8),
          if (log.isEmpty)
            Text(_s(state, 'log_empty'), style: Ds.t.caption)
          else
            ...log.map((e) => _logRow(Map<String, dynamic>.from(e as Map))),
        ],
      ),
    );
  }

  /// One release block: heading, the version line (or the backend's own empty
  /// sentence), the status chip and whatever metadata the payload carried.
  Widget _release(Map<String, dynamic> r) {
    final has = r['has'] == true;
    final rollout = _s(r, 'rollout_label');
    final track = _s(r, 'track_label');
    final meta = _s(r, 'meta_label');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(r, 'heading'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              Text(
                has ? _s(r, 'version_label') : _s(r, 'empty_label'),
                style: has ? Ds.t.body : Ds.t.bodySecondary,
              ),
              if (has && rollout.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(rollout, style: Ds.t.caption),
              ],
              if (has && track.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(track, style: Ds.t.caption),
              ],
              if (has && meta.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(meta, style: Ds.t.caption),
              ],
            ],
          ),
        ),
        if (has)
          ToneChip(
            label: _s(r, 'status_label'),
            tone: toneByName(_s(r, 'status_tone')),
          ),
      ],
    );
  }

  Widget _logRow(Map<String, dynamic> l) {
    final detail = _s(l, 'detail');
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(l, 'title'), style: Ds.t.body),
                if (detail.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(detail, style: Ds.t.caption),
                ],
              ],
            ),
          ),
          Text(_s(l, 'at_label'), style: Ds.t.caption),
        ],
      ),
    );
  }
}
