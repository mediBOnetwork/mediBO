// CHANGE #280 — Play Store: the one screen that ships the app.
//
// Om taps Publish to Play; `play_publish_request` queues a release; the
// medibo-play timer on the builder drains it (build → sign → upload → notes →
// full rollout → commit) and writes every stage back. This screen shows what is
// live, what is in flight, and what Google Play said — nothing more.
//
// THE APP RENDERS. IT NEVER DECIDES. Every visible word here — title, headings,
// button captions, status labels, the release notes, the error — arrives inside
// the `play_state()` payload. There is no display string in this file, no
// status→label switch, no date formatting, and no "is it publishable" rule: the
// backend sends `can_publish`. Even the tone of a status chip is the backend's
// word, resolved to the fixed design palette by [toneByName].

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
  bool _sending = false;
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

  Future<void> _publish() async {
    setState(() => _sending = true);
    try {
      final res = await widget.service.playPublishRequest(notes: _notes.text);
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
      if (mounted) setState(() => _sending = false);
    }
  }

  String _s2(String key) => (_s[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final active = (_s['active'] as Map?) ?? const {};
    final live = (_s['live'] as Map?) ?? const {};
    final history = (_s['history'] as List?) ?? const [];
    final busy = active['has'] == true;
    final canPublish = _s['can_publish'] == true && !_sending;

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
                    _card(child: Text(_error!, style: Ds.t.body)),
                    SizedBox(height: Ds.space.x16),
                  ],
                  Text(_s2('subtitle'), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x24),
                  if (live['has'] == true) ...[
                    _live(live),
                    SizedBox(height: Ds.space.x24),
                  ],
                  if (busy) ...[
                    _active(active),
                    SizedBox(height: Ds.space.x24),
                  ],
                  _next(canPublish),
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

  Widget _live(Map live) => _card(
        accent: Ds.c.success,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s2('live_heading'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            Text((live['version_label'] ?? '').toString(), style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Text((live['when_label'] ?? '').toString(), style: Ds.t.caption),
            if ((live['notes'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(live['notes'].toString(), style: Ds.t.bodySecondary),
            ],
          ],
        ),
      );

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
              Text((active['track_label'] ?? '').toString(), style: Ds.t.caption),
            ]),
            if ((active['release_notes'] ?? '').toString().isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(active['release_notes'].toString(), style: Ds.t.bodySecondary),
            ],
          ],
        ),
      );

  Widget _next(bool canPublish) => _card(
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
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: canPublish ? _publish : null,
                child: Text(
                  canPublish ? _s2('publish_button') : _s2('publishing_button'),
                  style: Ds.t.body.copyWith(color: Ds.c.surface),
                ),
              ),
            ),
          ],
        ),
      );

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
          Text(
            '${(r['track_label'] ?? '')} · ${(r['when_label'] ?? '')}',
            style: Ds.t.caption,
          ),
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
