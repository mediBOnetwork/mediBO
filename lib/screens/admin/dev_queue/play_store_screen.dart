// CHANGE #280/#281 — Play Store: the screen that ships the app.
//
// #280 gave this screen ONE button that built and shipped straight to
// production. #281 splits that into the three moves a real release has, and
// adds the panel that says what Google Play actually believes right now:
//
//   Test now       build the current code onto Play's INTERNAL TESTING track.
//                  No Google review; Om installs it FROM Play within minutes,
//                  so it is Play-signed and behaves exactly like production.
//   Publish update PROMOTE that same uploaded bundle to production, full
//                  rollout, submitted for review. Nothing is rebuilt — what
//                  ships is the artifact he approved.
//   Auto-publish   a config flag. ON: a successful build goes to internal AND
//                  is submitted to production automatically. OFF: it stops at
//                  internal and waits for the second button.
//
// THE APP RENDERS. IT NEVER DECIDES. Every visible word — title, headings,
// button captions, status labels, the "as of" line, the rollout percentage,
// the reason a button is greyed out — arrives inside `play_state()`. There is
// no display string in this file, no status→label switch, no date formatting,
// and no "may I publish" rule: the backend sends `can_test` / `can_promote`
// and the sentence explaining them. Even a chip's tone is the backend's word,
// resolved to the fixed design palette by [toneByName].

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

class PlayStoreScreen extends StatefulWidget {
  const PlayStoreScreen({super.key, required this.service});

  final DevQueueService service;

  @override
  State<PlayStoreScreen> createState() => _PlayStoreScreenState();
}

class _PlayStoreScreenState extends State<PlayStoreScreen> {
  Map<String, dynamic> _s = const {};
  bool _loading = true;
  bool _testing = false;
  bool _promoting = false;
  bool _togglingAuto = false;
  String? _error;
  final _notes = TextEditingController();
  bool _notesTouched = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final s = await widget.service.playState();
      if (!mounted) return;
      // The draft body is the backend's; an edit Om has already made wins until
      // the screen is left, so a background refresh never eats his typing.
      if (!_notesTouched) _notes.text = (s['draft_notes'] ?? '').toString();
      setState(() {
        _s = s;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Every button is the same three moves: call the one RPC, show whatever
  /// sentence came back (success, refusal or Play's own error) and reload.
  Future<void> _run(
      Future<Map<String, dynamic>> Function() call, void Function(bool) busy) async {
    setState(() => busy(true));
    try {
      final res = await call();
      if (!mounted) return;
      final msg = (res['message'] ?? res['error'] ?? '').toString();
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
      _notesTouched = false;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => busy(false));
    }
  }

  String _s2(String key) => (_s[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final active = (_s['active'] as Map?) ?? const {};
    final history = (_s['history'] as List?) ?? const [];
    final tracks = (_s['tracks'] as List?) ?? const [];
    final busy = active['has'] == true;
    final anySending = _testing || _promoting || _togglingAuto;

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        iconTheme: IconThemeData(color: Ds.c.brand),
        title: Text(_s2('title'), style: Ds.t.subtitle),
        actions: [
          IconButton(
            icon: Icon(Icons.refresh, color: Ds.c.brand),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? _skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_error != null) ...[
                    _errorCard(_error!),
                    SizedBox(height: Ds.space.x24),
                  ],
                  Text(_s2('subtitle'), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x24),
                  _tracksPanel(tracks),
                  SizedBox(height: Ds.space.x24),
                  if (busy) ...[
                    _active(active),
                    SizedBox(height: Ds.space.x24),
                  ],
                  _release(anySending),
                  SizedBox(height: Ds.space.x24),
                  _autoPublish(),
                  SizedBox(height: Ds.space.x32),
                  Text(_s2('history_heading'), style: Ds.t.subtitle),
                  SizedBox(height: Ds.space.x12),
                  if (history.isEmpty)
                    _card(child: Text(_s2('empty_history'), style: Ds.t.caption))
                  else
                    ...history.map((r) => Padding(
                          padding: EdgeInsets.only(bottom: Ds.space.x12),
                          child: _historyRow(Map<String, dynamic>.from(r as Map)),
                        )),
                  SizedBox(height: Ds.space.x48),
                ],
              ),
            ),
    );
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  Widget _card({required Widget child, Color? accent}) =>
      DqCard(padding: EdgeInsets.all(Ds.space.x16), accent: accent, child: child);

  /// An error state Om can act on: the backend's own heading, the failure text,
  /// and a Retry — never a dead end that only a page reload escapes.
  Widget _errorCard(String message) => _card(
        accent: Ds.c.danger,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s2('error_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            Text(message, style: Ds.t.body),
            SizedBox(height: Ds.space.x12),
            _secondary(label: _s2('retry'), onPressed: _load),
          ],
        ),
      );

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          3,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 + Ds.space.x32,
              decoration: BoxDecoration(
                color: Ds.c.divider,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
        ),
      );

  /// The one outlined action shape, so the screen keeps exactly one filled
  /// brand button (design contract: one primary per screen).
  Widget _secondary({required String label, VoidCallback? onPressed}) => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: onPressed == null ? Ds.c.divider : Ds.c.brand),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          onPressed: onPressed,
          child: Text(label, style: Ds.t.body.copyWith(
              color: onPressed == null ? Ds.c.textSecondary : Ds.c.brand)),
        ),
      );

  /// What Google Play believes about every track, right now. Read from the Play
  /// Developer API by the builder and stored with the moment it was read — this
  /// screen never infers a version from our own publish queue.
  Widget _tracksPanel(List tracks) {
    final asOf = _s2('tracks_asof');
    final err = _s2('tracks_error');
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s2('tracks_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(asOf.isEmpty ? _s2('tracks_hint') : asOf, style: Ds.t.caption),
          if (err.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s2('error_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            // Google Play's own words, verbatim.
            Text(err, style: Ds.t.bodySecondary.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          if (tracks.isEmpty)
            Text(_s2('tracks_never'), style: Ds.t.caption)
          else
            ...tracks.map((t) => _trackRow(Map<String, dynamic>.from(t as Map))),
          SizedBox(height: Ds.space.x16),
          _secondary(
            label: _s2('refresh_button'),
            onPressed: () => _run(widget.service.playRefreshRequest, (v) {}),
          ),
        ],
      ),
    );
  }

  Widget _trackRow(Map<String, dynamic> t) {
    final has = t['has'] == true;
    final rollout = (t['rollout_label'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((t['track_label'] ?? '').toString(), style: Ds.t.caption),
                SizedBox(height: Ds.space.x4),
                Text(
                  has
                      ? (t['version_label'] ?? '').toString()
                      : (t['empty_label'] ?? '').toString(),
                  style: has ? Ds.t.body : Ds.t.bodySecondary,
                ),
                if (has && rollout.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(rollout, style: Ds.t.caption),
                ],
              ],
            ),
          ),
          if (has)
            ToneChip(
              label: (t['status_label'] ?? '').toString(),
              tone: toneByName((t['status_tone'] ?? '').toString()),
            ),
        ],
      ),
    );
  }

  Widget _active(Map active) => _card(
        accent: Ds.c.info,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              ToneChip(
                label: (active['status_label'] ?? '').toString(),
                tone: toneByName((active['status_tone'] ?? '').toString()),
                spinning: true,
              ),
              SizedBox(width: Ds.space.x8),
              Expanded(
                child: Text((active['track_label'] ?? '').toString(),
                    style: Ds.t.caption),
              ),
            ]),
            if ((active['release_notes'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(active['release_notes'].toString(), style: Ds.t.bodySecondary),
            ],
          ],
        ),
      );

  /// Buttons 1 and 2, over the notes body they both submit. The notes are shown
  /// BEFORE anything is sent and stay editable — nothing reaches a Play listing
  /// that Om has not had the chance to read first.
  Widget _release(bool anySending) {
    final canTest = _s['can_test'] == true && !anySending;
    final canPromote = _s['can_promote'] == true && !anySending;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s2('next_heading'), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s2('notes_hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Text(_s2('notes_heading'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          TextField(
            controller: _notes,
            maxLines: 6,
            minLines: 3,
            onChanged: (_) => _notesTouched = true,
            style: Ds.t.body,
            decoration: InputDecoration(
              filled: true,
              fillColor: Ds.c.bg,
              border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              contentPadding: EdgeInsets.all(Ds.space.x12),
            ),
          ),
          SizedBox(height: Ds.space.x24),

          // 1 — Test now. The screen's single filled brand action.
          Text(_s2('test_hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                disabledBackgroundColor: Ds.c.divider,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: canTest
                  ? () => _run(() => widget.service.playTestRequest(notes: _notes.text),
                      (v) => _testing = v)
                  : null,
              child: Text(
                _testing ? _s2('test_running') : _s2('test_button'),
                style: Ds.t.body.copyWith(
                    color: canTest ? Ds.c.surface : Ds.c.textSecondary),
              ),
            ),
          ),
          SizedBox(height: Ds.space.x24),

          // 2 — Publish update. Promotes the tested bundle; never a rebuild.
          Text(_s2('promote_hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          _secondary(
            label: _promoting ? _s2('promote_running') : _s2('promote_button'),
            onPressed: canPromote
                ? () => _run(() => widget.service.playPromoteRequest(notes: _notes.text),
                    (v) => _promoting = v)
                : null,
          ),
          if (_s2('promote_note').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            // Why the button is available, or why it is not — the backend's
            // sentence, naming the exact build that would ship.
            Text(_s2('promote_note'), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }

  /// 3 — the auto-publish flag. It lives in config, so flipping it is an
  /// UPDATE the builder reads on its next tick, never a deploy.
  Widget _autoPublish() {
    final on = _s['auto_publish'] == true;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s2('auto_title'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(_s2('auto_state_label'), style: Ds.t.caption),
                  ],
                ),
              ),
              Switch(
                value: on,
                activeThumbColor: Ds.c.surface,
                activeTrackColor: Ds.c.brand,
                onChanged: _togglingAuto
                    ? null
                    : (v) => _run(() => widget.service.playAutoPublishSet(v),
                        (b) => _togglingAuto = b),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s2('auto_hint'), style: Ds.t.caption),
        ],
      ),
    );
  }

  Widget _historyRow(Map<String, dynamic> r) {
    final err = (r['play_error'] ?? '').toString();
    final review = (r['review_status'] ?? '').toString();
    return _card(
      accent: toneByName((r['status_tone'] ?? '').toString()).fg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text((r['version_label'] ?? '').toString(), style: Ds.t.body),
            ),
            ToneChip(
              label: (r['status_label'] ?? '').toString(),
              tone: toneByName((r['status_tone'] ?? '').toString()),
            ),
          ]),
          SizedBox(height: Ds.space.x4),
          Row(children: [
            Text((r['track_label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(width: Ds.space.x8),
            Text((r['kind_label'] ?? '').toString(), style: Ds.t.caption),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text((r['when_label'] ?? '').toString(), style: Ds.t.caption),
            ),
          ]),
          if (review.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(review, style: Ds.t.bodySecondary),
          ],
          if ((r['release_notes'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(r['release_notes'].toString(), style: Ds.t.caption),
          ],
          if (err.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(_s2('error_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x4),
            // Google Play's own words, verbatim — never re-worded in Dart.
            Text(err, style: Ds.t.bodySecondary.copyWith(color: Ds.c.danger)),
          ],
        ],
      ),
    );
  }
}
