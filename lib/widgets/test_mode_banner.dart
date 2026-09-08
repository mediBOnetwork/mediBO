import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../services/test_session.dart';

/// CHANGE #573 — the unmissable TEST MODE strip.
///
/// It is mounted once, in `MaterialApp.builder`, above every route of every
/// role, exactly like the update bar. That placement is the point: Om walks
/// the flow from an admin, a customer, a supplier, a partner and a rider
/// login, and none of those screens has to know test mode exists.
///
/// The host reflows the page (SafeArea + Column) rather than floating over it,
/// because a banner that can be scrolled behind is a banner he can forget.
///
/// CMD #1848 — the session is bound to THIS INSTALL now. `test_session_banner()`
/// answers `on:true` only to the device carrying the session's token (whoever
/// is signed in there); every other device shows nothing, because nothing of
/// its is being stamped. The strip names WHOSE session it is
/// (`owner_label`), when it auto-ends (`ends_label`), and carries the one
/// action — End & purge — whose every word, confirm sentence and result
/// message are the backend's.
class TestModeBannerHost extends StatelessWidget {
  const TestModeBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: TestSessionState.instance.banner,
      builder: (context, payload, _) {
        if (payload['on'] != true) return child;
        return ValueListenableBuilder<Map<String, dynamic>>(
          valueListenable: TestSessionState.instance.clock,
          builder: (context, clock, _) => Column(
            children: [
              TestModeBanner(
                payload: payload,
                clock: clock,
                onEndPurge: TestSessionState.instance.endAndPurge,
                onPin: TestSessionState.instance.pinClock,
                onStep: TestSessionState.instance.stepClock,
                onRelease: TestSessionState.instance.releaseClock,
              ),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

/// The strip itself — pure presentation, so a widget test mounts it with a
/// fixture payload and no network, no timer and no service singleton. The
/// End & purge tap calls [onEndPurge]; absent, the button is inert.
class TestModeBanner extends StatelessWidget {
  const TestModeBanner({
    super.key,
    required this.payload,
    this.clock = const {},
    this.onEndPurge,
    this.onPin,
    this.onStep,
    this.onRelease,
  });

  final Map<String, dynamic> payload;

  /// CMD #1850 — `test_clock_state()`, verbatim. `has:false` (or an empty
  /// map, before the first read lands) draws no time control at all.
  final Map<String, dynamic> clock;

  /// The three clock verbs. Each returns the backend's reply; its `message`
  /// is shown verbatim and nothing is decided here.
  final Future<Map<String, dynamic>> Function(String at)? onPin;
  final Future<Map<String, dynamic>> Function(int minutes)? onStep;
  final Future<Map<String, dynamic>> Function()? onRelease;

  bool get _showClock =>
      clock['has'] == true && _cs('open_action').isNotEmpty;

  String _cs(String key) {
    final v = clock[key];
    return v is String ? v : '';
  }

  /// Runs the backend's end-and-purge and returns its payload; the banner
  /// shows that payload's `message` verbatim.
  final Future<Map<String, dynamic>> Function()? onEndPurge;

  String _s(String key) {
    final v = payload[key];
    return v is String ? v : '';
  }

  /// The action is drawn only when the BACKEND says this person may end the
  /// session (`can_end`) and has a word for the button. No Dart rule.
  bool get _showEnd => payload['can_end'] == true && _s('end_action').isNotEmpty;

  Future<void> _confirmAndEnd(BuildContext context) async {
    final confirm = _s('end_confirm');
    final action = _s('end_action');
    final cancel = _s('end_cancel');
    var ok = true;
    if (confirm.isNotEmpty) {
      ok = await showModalBottomSheet<bool>(
            context: context,
            backgroundColor: Ds.c.surface,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
            builder: (ctx) => SafeArea(
              child: Padding(
                padding: EdgeInsets.all(Ds.space.x24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(confirm, style: Ds.t.body),
                    SizedBox(height: Ds.space.x24),
                    SizedBox(
                      width: double.infinity,
                      height: Ds.touch.minTarget,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Ds.c.danger,
                          shape: RoundedRectangleBorder(
                              borderRadius: Ds.r.rButton),
                        ),
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(action,
                            style:
                                Ds.t.body.copyWith(color: Ds.c.surface)),
                      ),
                    ),
                    if (cancel.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x8),
                      SizedBox(
                        width: double.infinity,
                        height: Ds.touch.minTarget,
                        child: TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: Text(cancel,
                              style: Ds.t.body
                                  .copyWith(color: Ds.c.textSecondary)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ) ==
          true;
    }
    if (!ok) return;
    final run = onEndPurge;
    if (run == null) return;
    final res = await run();
    if (!context.mounted) return;
    final msg = (res['message'] ?? res['error'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _openClock(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => TestClockSheet(
        clock: clock,
        onPin: onPin,
        onStep: onStep,
        onRelease: onRelease,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _s('label');
    final owner = _s('owner_label');
    final ends = _s('ends_label');
    // The pinned time is the ONE thing that outranks the session's own
    // metadata here: a person who has bent the clock must see, on every
    // screen, what time this session believes it is.
    final pinned = clock['pinned'] == true ? _cs('now_label') : '';
    final caption = [if (pinned.isNotEmpty) pinned, label, owner, ends]
        .where((s) => s.isNotEmpty)
        .join('  ·  ');
    return Material(
      color: Ds.c.danger,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16,
            vertical: Ds.space.x8,
          ),
          child: Row(
            children: [
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  _s('badge'),
                  style: Ds.t.caption.copyWith(
                    color: Ds.c.danger,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _s('text'),
                      style: Ds.t.body.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (caption.isNotEmpty)
                      Text(
                        caption,
                        style: Ds.t.caption.copyWith(color: Ds.c.surface),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (_showClock) ...[
                SizedBox(width: Ds.space.x8),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    key: const ValueKey('test_clock_open'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.surface,
                      side: BorderSide(color: Ds.c.surface),
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      padding:
                          EdgeInsets.symmetric(horizontal: Ds.space.x12),
                    ),
                    onPressed: () => _openClock(context),
                    child: Text(
                      _cs('open_action'),
                      style: Ds.t.caption.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
              if (_showEnd) ...[
                SizedBox(width: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    key: const ValueKey('test_session_end_purge'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.surface,
                      side: BorderSide(color: Ds.c.surface),
                      shape: RoundedRectangleBorder(
                          borderRadius: Ds.r.rButton),
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x12),
                    ),
                    onPressed: () => _confirmAndEnd(context),
                    child: Text(
                      _s('end_action'),
                      style: Ds.t.caption.copyWith(
                        color: Ds.c.surface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// CMD #1850 — THE TIME CONTROL.
///
/// A test session can pin an effective time, and this is where it is set:
/// jump to a moment the backend named (one minute before this zone's cut-off,
/// just past it, one minute before close), step by the sizes it offered, type
/// a time, or go back to the real clock.
///
/// It computes NOTHING. The rendered time, the sub-line under it, the label on
/// every chip, the size of every step, the hint under the field and the
/// message after a tap are all `test_clock_state()`'s. It draws the presets in
/// payload order, and a payload with no presets simply has no preset row —
/// there is no Dart fallback list of times.
class TestClockSheet extends StatefulWidget {
  const TestClockSheet({
    super.key,
    required this.clock,
    this.onPin,
    this.onStep,
    this.onRelease,
  });

  final Map<String, dynamic> clock;
  final Future<Map<String, dynamic>> Function(String at)? onPin;
  final Future<Map<String, dynamic>> Function(int minutes)? onStep;
  final Future<Map<String, dynamic>> Function()? onRelease;

  @override
  State<TestClockSheet> createState() => _TestClockSheetState();
}

class _TestClockSheetState extends State<TestClockSheet> {
  late final TextEditingController _at = TextEditingController();
  Map<String, dynamic> _clock = const {};
  String _message = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _clock = widget.clock;
  }

  /// The banner keeps polling while this sheet is open, so a fresher state
  /// from the BACKEND replaces the one this sheet is holding. The server is
  /// the authority on what time this session is at — never this widget.
  @override
  void didUpdateWidget(TestClockSheet old) {
    super.didUpdateWidget(old);
    if (!identical(widget.clock, old.clock) && widget.clock['has'] == true) {
      _clock = widget.clock;
    }
  }

  @override
  void dispose() {
    _at.dispose();
    super.dispose();
  }

  String _s(String key) {
    final v = _clock[key];
    return v is String ? v : '';
  }

  List<Map<String, dynamic>> _list(String key) {
    final v = _clock[key];
    if (v is! List) return const [];
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Every action lands the same way: run it, adopt the state that came back,
  /// print the message that came with it.
  Future<void> _run(Future<Map<String, dynamic>> Function()? action) async {
    if (action == null || _busy) return;
    setState(() => _busy = true);
    final res = await action();
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['has'] == true) _clock = res;
      final msg = res['message'] ?? res['error'];
      _message = msg == null ? '' : msg.toString();
    });
  }

  @override
  Widget build(BuildContext context) {
    final presets = _list('presets');
    final steps = _list('steps');
    final pinned = _clock['pinned'] == true;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x24,
          Ds.space.x24,
          Ds.space.x24,
          Ds.space.x24 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s('title'), style: Ds.t.title),
            SizedBox(height: Ds.space.x16),
            Text(
              _s('now_label'),
              key: const ValueKey('test_clock_now'),
              style: Ds.t.display.copyWith(
                color: pinned ? Ds.c.danger : Ds.c.text,
              ),
            ),
            SizedBox(height: Ds.space.x4),
            Text(_s('now_sub'), style: Ds.t.caption),
            if (presets.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s('presets_label'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final p in presets)
                    _ClockChip(
                      label: (p['label'] ?? '').toString(),
                      onTap: _busy || widget.onPin == null
                          ? null
                          : () => _run(
                              () => widget.onPin!((p['at'] ?? '').toString())),
                    ),
                ],
              ),
            ],
            if (steps.isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              Text(_s('step_label'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x8,
                children: [
                  for (final st in steps)
                    _ClockChip(
                      label: (st['label'] ?? '').toString(),
                      onTap: _busy || widget.onStep == null
                          ? null
                          : () => _run(() => widget.onStep!(
                              (st['minutes'] as num?)?.toInt() ?? 0)),
                    ),
                ],
              ),
            ],
            SizedBox(height: Ds.space.x24),
            Text(_s('jump_label'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('test_clock_at'),
                    controller: _at,
                    style: Ds.t.body,
                    decoration: InputDecoration(hintText: _s('jump_hint')),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    key: const ValueKey('test_clock_pin'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    onPressed: _busy || widget.onPin == null
                        ? null
                        : () => _run(() => widget.onPin!(_at.text)),
                    child: Text(
                      _s('jump_action'),
                      style: Ds.t.body.copyWith(color: Ds.c.surface),
                    ),
                  ),
                ),
              ],
            ),
            if (_message.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Text(
                _message,
                key: const ValueKey('test_clock_message'),
                style: Ds.t.caption,
              ),
            ],
            // Going back to the real clock is offered only while there is
            // something to go back from — `can_release` is the backend's call.
            if (_clock['can_release'] == true) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  key: const ValueKey('test_clock_release'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.text,
                    side: BorderSide(color: Ds.c.divider),
                    shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                  ),
                  onPressed:
                      _busy ? null : () => _run(() => widget.onRelease!()),
                  child: Text(_s('release_action'), style: Ds.t.body),
                ),
              ),
            ],
            SizedBox(height: Ds.space.x8),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(
                  _s('close_action'),
                  style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One tappable word, sized for a thumb. The label is always the backend's.
class _ClockChip extends StatelessWidget {
  const _ClockChip({required this.label, this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: Ds.c.text,
          side: BorderSide(color: Ds.c.divider),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        ),
        onPressed: onTap,
        child: Text(label, style: Ds.t.caption),
      ),
    );
  }
}
