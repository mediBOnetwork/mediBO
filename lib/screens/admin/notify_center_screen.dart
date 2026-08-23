// CHANGE — #297 (part 1 of 3): the Notification Centre.
//
// /admin/notify-center — the screen for the ONE dispatcher every outbound
// message now goes through. `notify_center()` is a single read and this file
// prints it: the heading, the range, the summary sentence, the pending/dead
// counts, the alert bodies, and one row per event route with its own state
// label, count sentence and action captions.
//
// Nothing here is computed. In particular:
//   • "3 sent · 1 failed · 0 waiting" is a backend sentence, not three ints
//     glued together in Dart. So is every count_label on a row.
//   • The state of a route ("Live" / "On — no template" / "Off") is
//     `state_label` + `state_tone`; this file never looks at `enabled` and
//     `template_id` and decides which word applies.
//   • The alert text, the threshold sentence and both empty states are copy
//     the backend owns, so rewording them is an UPDATE to ui_copy, not a
//     deploy.
//   • Preview and test-send print `body_preview` / `message` verbatim,
//     including the refusals — "That number belongs to a supplier" is the
//     backend's sentence, and the block itself lives in the backend too. There
//     is deliberately no recipient field on the test action: notify_test_send()
//     takes no recipient at all and resolves the caller's own number, so this
//     screen has no way to aim a test at anyone else.
//
// The tone -> palette lookup is the same token->token adapter every other
// WhatsApp screen uses: an unrecognised tone renders grey with its label
// intact rather than blanking the row.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// The ONE place a backend tone becomes pixels on this screen.
(Color, Color) notifyTone(String? tone) => switch (tone) {
      'good' || 'success' => (Ds.c.successSoft, Ds.c.success),
      'warn' || 'warning' => (Ds.c.warningSoft, Ds.c.warning),
      'bad' || 'danger' => (Ds.c.dangerSoft, Ds.c.danger),
      'info' => (Ds.c.infoSoft, Ds.c.info),
      _ => (Ds.c.bg, Ds.c.textSecondary),
    };

/// Rows for one audience, in the order the backend sent them.
///
/// Pure, so the grouping is testable without a widget tree. The backend
/// already sorted by `audience|title`; this only slices that order into
/// sections and never re-sorts, because a client-side sort is a second opinion
/// about an order the payload already stated.
List<MapEntry<String, List<Map<String, dynamic>>>> notifyGroupByAudience(
    List<Map<String, dynamic>> rows) {
  final out = <MapEntry<String, List<Map<String, dynamic>>>>[];
  for (final r in rows) {
    final a = r['audience']?.toString() ?? '';
    if (out.isNotEmpty && out.last.key == a) {
      out.last.value.add(r);
    } else {
      out.add(MapEntry(a, <Map<String, dynamic>>[r]));
    }
  }
  return out;
}

typedef NotifyCenterRpc = Future<Map<String, dynamic>> Function(int hours);
typedef NotifyPreviewRpc = Future<Map<String, dynamic>> Function(String eventKey);
typedef NotifyTestSendRpc = Future<Map<String, dynamic>> Function(String eventKey);
typedef NotifyRetryNowRpc = Future<Map<String, dynamic>> Function();

Map<String, dynamic> _asMap(dynamic res) =>
    res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

SupabaseClient get _db => Supabase.instance.client;

Future<Map<String, dynamic>> notifyCenterRpc(int hours) async =>
    _asMap(await _db.rpc('notify_center', params: {'p_hours': hours}));

Future<Map<String, dynamic>> notifyPreviewRpc(String eventKey) async =>
    _asMap(await _db.rpc('notify_preview', params: {'p_event_key': eventKey}));

Future<Map<String, dynamic>> notifyTestSendRpc(String eventKey) async =>
    _asMap(await _db.rpc('notify_test_send', params: {'p_event_key': eventKey}));

Future<Map<String, dynamic>> notifyRetryNowRpc() async =>
    _asMap(await _db.rpc('notify_retry_now'));

class NotifyCenterScreen extends StatefulWidget {
  final NotifyCenterRpc? centerRpc;
  final NotifyPreviewRpc? previewRpc;
  final NotifyTestSendRpc? testSendRpc;
  final NotifyRetryNowRpc? retryNowRpc;

  const NotifyCenterScreen({
    super.key,
    this.centerRpc,
    this.previewRpc,
    this.testSendRpc,
    this.retryNowRpc,
  });

  @override
  State<NotifyCenterScreen> createState() => _NotifyCenterScreenState();
}

class _NotifyCenterScreenState extends State<NotifyCenterScreen> {
  Map<String, dynamic>? _p;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  NotifyCenterRpc get _center => widget.centerRpc ?? notifyCenterRpc;
  NotifyPreviewRpc get _preview => widget.previewRpc ?? notifyPreviewRpc;
  NotifyTestSendRpc get _test => widget.testSendRpc ?? notifyTestSendRpc;
  NotifyRetryNowRpc get _retry => widget.retryNowRpc ?? notifyRetryNowRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final map = await _center(24);
      if (!mounted) return;
      setState(() {
        _p = map;
        _loading = false;
        _error = (map['ok'] == true) ? null : (map['message']?.toString() ?? '');
      });
      final events = (map['events'] as List?) ?? const [];
      RenderLog.write('notify_center_events', events.length);
      RenderLog.write('notify_center_alerts',
          ((map['alerts'] as List?) ?? const []).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Every action follows the same rule as the WhatsApp Ops screen: the RPC
  /// answers first, its own sentence is what the admin reads, and the screen
  /// re-reads rather than painting an outcome it merely hopes for.
  Future<void> _run(Future<Map<String, dynamic>> Function() call,
      {bool reload = true}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await call();
      if (!mounted) return;
      final msg = res['message']?.toString() ?? '';
      if (msg.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(msg)));
      }
      if (reload) await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openPreview(String eventKey) async {
    late Map<String, dynamic> res;
    try {
      res = await _preview(eventKey);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => NotifyPreviewSheet(
        payload: res,
        onTestSend: () {
          Navigator.of(context).pop();
          _run(() => _test(eventKey));
        },
      ),
    );
  }

  List<Map<String, dynamic>> _list(String key) =>
      ((_p?[key] as List?) ?? const [])
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final pending = (p?['pending_count'] as num?)?.toInt() ?? 0;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p?['heading']?.toString() ?? ''),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const _NotifySkeleton()
          : (_error != null && _error!.isNotEmpty)
              ? _NotifyError(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.fromLTRB(Ds.space.x16, Ds.space.x16,
                        Ds.space.x16, Ds.space.x48),
                    children: [
                      if ((p?['subheading']?.toString() ?? '').isNotEmpty)
                        Text(p!['subheading'].toString(), style: Ds.t.caption),
                      SizedBox(height: Ds.space.x16),
                      NotifySummaryCard(
                        payload: p ?? const <String, dynamic>{},
                        busy: _busy,
                        onRetryQueue:
                            pending > 0 ? () => _run(() => _retry()) : null,
                      ),
                      SizedBox(height: Ds.space.x24),
                      Text(p?['alerts_heading']?.toString() ?? '',
                          style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x12),
                      if (_list('alerts').isEmpty)
                        _NotifyEmpty(text: p?['alerts_empty']?.toString() ?? ''),
                      for (final a in _list('alerts')) ...[
                        NotifyAlertCard(alert: a),
                        SizedBox(height: Ds.space.x12),
                      ],
                      SizedBox(height: Ds.space.x24),
                      Text(p?['events_heading']?.toString() ?? '',
                          style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x12),
                      if (_list('events').isEmpty)
                        _NotifyEmpty(text: p?['events_empty']?.toString() ?? ''),
                      for (final g in notifyGroupByAudience(_list('events'))) ...[
                        Padding(
                          padding: EdgeInsets.only(
                              top: Ds.space.x12, bottom: Ds.space.x8),
                          child: Text(g.key, style: Ds.t.caption),
                        ),
                        for (final r in g.value) ...[
                          NotifyEventCard(
                            row: r,
                            busy: _busy,
                            onPreview: () =>
                                _openPreview(r['event_key']?.toString() ?? ''),
                            onTest: () => _run(
                                () => _test(r['event_key']?.toString() ?? '')),
                          ),
                          SizedBox(height: Ds.space.x12),
                        ],
                      ],
                    ],
                  ),
                ),
    );
  }
}

/// The summary block: the range, the one-sentence verdict, the two queue
/// counts and the threshold sentence — every one of them a backend string.
class NotifySummaryCard extends StatelessWidget {
  final Map<String, dynamic> payload;
  final bool busy;
  final VoidCallback? onRetryQueue;
  const NotifySummaryCard(
      {super.key, required this.payload, this.busy = false, this.onRetryQueue});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = notifyTone(payload['summary_tone']?.toString());
    final dead = (payload['dead_count'] as num?)?.toInt() ?? 0;
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(payload['range_label']?.toString() ?? '',
                    style: Ds.t.caption),
              ),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration:
                    BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
                child: Text(payload['channels_label']?.toString() ?? 'WhatsApp',
                    style: Ds.t.caption.copyWith(color: fg)),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(payload['summary_label']?.toString() ?? '',
              style: Ds.t.subtitle.copyWith(color: fg)),
          SizedBox(height: Ds.space.x12),
          Text(payload['pending_label']?.toString() ?? '', style: Ds.t.body),
          if (dead > 0) ...[
            SizedBox(height: Ds.space.x4),
            Text(payload['dead_label']?.toString() ?? '',
                style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x8),
          Text(payload['threshold_label']?.toString() ?? '',
              style: Ds.t.caption),
          if (onRetryQueue != null) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: busy ? null : onRetryQueue,
                child: Text(payload['retry_label']?.toString() ?? ''),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One open health alert. Red is reserved for exactly this: an event that is
/// failing right now.
class NotifyAlertCard extends StatelessWidget {
  final Map<String, dynamic> alert;
  const NotifyAlertCard({super.key, required this.alert});

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = notifyTone(alert['tone']?.toString());
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(alert['title']?.toString() ?? '',
              style: Ds.t.subtitle.copyWith(color: fg)),
          SizedBox(height: Ds.space.x4),
          Text(alert['body']?.toString() ?? '',
              style: Ds.t.body.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// One event route. Two actions, both captioned by the backend.
class NotifyEventCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onPreview;
  final VoidCallback onTest;
  const NotifyEventCard({
    super.key,
    required this.row,
    required this.onPreview,
    required this.onTest,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = notifyTone(row['state_tone']?.toString());
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row['title']?.toString() ?? '', style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(row['subtitle']?.toString() ?? '',
                        style: Ds.t.caption),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x12, vertical: Ds.space.x4),
                decoration:
                    BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
                child: Text(row['state_label']?.toString() ?? '',
                    style: Ds.t.caption.copyWith(color: fg)),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Text(row['count_label']?.toString() ?? '', style: Ds.t.body),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy ? null : onPreview,
                    child: Text(row['preview_label']?.toString() ?? ''),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed: busy ? null : onTest,
                    child: Text(row['test_label']?.toString() ?? ''),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The preview sheet. `body_preview` is the backend's already-substituted
/// text — this file never fills a placeholder itself, because the whole point
/// of the preview is to show what the SERVER would actually send.
class NotifyPreviewSheet extends StatelessWidget {
  final Map<String, dynamic> payload;
  final VoidCallback onTestSend;
  const NotifyPreviewSheet(
      {super.key, required this.payload, required this.onTestSend});

  @override
  Widget build(BuildContext context) {
    final ok = payload['ok'] == true;
    if (!ok) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Text(payload['message']?.toString() ?? '',
            style: Ds.t.bodySecondary),
      );
    }
    final (bg, fg) = notifyTone(payload['status_tone']?.toString());
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(payload['title']?.toString() ?? '', style: Ds.t.title),
            SizedBox(height: Ds.space.x4),
            Row(
              children: [
                Text(payload['channel_label']?.toString() ?? '',
                    style: Ds.t.caption),
                SizedBox(width: Ds.space.x8),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x4),
                  decoration:
                      BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
                  child: Text(payload['status_label']?.toString() ?? '',
                      style: Ds.t.caption.copyWith(color: fg)),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rCard,
              ),
              child: Text(payload['body_preview']?.toString() ?? '',
                  style: Ds.t.body),
            ),
            SizedBox(height: Ds.space.x8),
            Text(payload['sample_note']?.toString() ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: onTestSend,
                child: Text(c('notify.test_action')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NotifyEmpty extends StatelessWidget {
  final String text;
  const _NotifyEmpty({required this.text});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1),
        child: Text(text, style: Ds.t.bodySecondary),
      );
}

class _NotifyError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _NotifyError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message,
                  textAlign: TextAlign.center, style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                    onPressed: onRetry, child: Text(c('wa_diagnosis.retry'))),
              ),
            ],
          ),
        ),
      );
}

class _NotifySkeleton extends StatelessWidget {
  const _NotifySkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 6; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x48 * 3,
                decoration: BoxDecoration(
                    color: Ds.c.surface,
                    borderRadius: Ds.r.rCard,
                    boxShadow: Ds.elevation.e1),
              ),
            ),
        ],
      );
}
