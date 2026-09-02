// CHANGE #690 — the exceptions console (register row feature_gaps #74).
//
// Delhivery works NDRs as ONE queue: every stuck object carries a reason code,
// an age, an owner, a next action and, when it ends, a recorded outcome. mediBO
// had the objects and none of the queue — a dispute sat in supplier_disputes, an
// item nobody could source in order_items.unfulfillable, a shop/warehouse
// disagreement in count_diff, a refused WhatsApp send in wa_send_attempts, an
// unanswered stock follow-up in stock_update_queue, an unverified payment claim
// in payment_claims, and everything past its deadline on the ops board. Seven
// tables, nothing owned, nothing aged, no outcome anywhere.
//
// THIS FILE COMPUTES NOTHING. It is `exceptions_queue()` printed in payload
// order:
//
//   • The ORDER is the backend's: `sort_score` is age × severity, so a
//     30-hour dispute outranks a 40-day count mismatch. Re-sorting here would
//     replace that judgement with "newest first", which is not a queue.
//   • Every string — title, subtitle, reason, age, SLA, owner, status, the
//     action label, the outcome names, the empty state — arrives written.
//     There is no pluralisation, no age arithmetic and no ₹ formatting here.
//   • The next action is the BACKEND's dispatch. `next_action.kind == 'rpc'`
//     sends the exception id to `exceptions_action` and prints whatever comes
//     back; adding a new one-tap action is an UPDATE, never a deploy.
//   • `tone` is a token mapped to a colour and nothing else. An unknown tone
//     renders neutral rather than blanking the card, and a reason_code this
//     build has never heard of still renders, because its label came with it.
//
// REACHABILITY. The console is Fulfill stage 10 (feature_registry
// 'fulfill.exceptions'), and /admin/go/exceptions opens it directly so a digest
// line or a notification has somewhere to point — the shell switches to the
// fulfilment screen and asks it for the stage by the BACKEND's own key, which
// is ignored in silence if fulfill_tabs() never sent that stage to this login.
// The fulfilment page is wrapped in a QuickLinkNavigator for the same reason
// the dashboard is: a next action here can point OUT of the pipeline (Money,
// Bill pipeline, WhatsApp Ops, Add medicine), and those buttons must resolve.
//
// Styling is 100% `Ds` tokens (DESIGN.md / CHANGE #66): zero style literals.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Injectable RPC seams — production leaves them null and gets the Supabase
/// calls; tests hand in stubs and never touch the network.
typedef ExceptionsQueueRpc = Future<Map<String, dynamic>> Function(
    {String? reason, String status});
typedef ExceptionsActionRpc = Future<Map<String, dynamic>> Function(String id);
typedef ExceptionsCloseRpc = Future<Map<String, dynamic>> Function(
    String id, String outcomeCode, String? note);

Map<String, dynamic> asMap(dynamic res) =>
    res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

Future<Map<String, dynamic>> exceptionsQueue(
        {String? reason, String status = 'open'}) async =>
    asMap(await Supabase.instance.client.rpc('exceptions_queue', params: {
      'p_reason': reason,
      'p_status': status,
    }));

Future<Map<String, dynamic>> exceptionsAction(String id) async =>
    asMap(await Supabase.instance.client
        .rpc('exceptions_action', params: {'p_id': id}));

Future<Map<String, dynamic>> exceptionsClose(
        String id, String outcomeCode, String? note) async =>
    asMap(await Supabase.instance.client.rpc('exceptions_close', params: {
      'p_id': id,
      'p_outcome_code': outcomeCode,
      'p_note': note,
    }));

/// Backend tone token -> (wash, ink). Token to token: nothing is interpreted
/// here and an unrecognised tone stays readable.
(Color, Color) toneColors(String? t) => switch (t) {
      'good' => (Ds.c.successSoft, Ds.c.success),
      'warn' => (Ds.c.warningSoft, Ds.c.warning),
      'bad' => (Ds.c.dangerSoft, Ds.c.danger),
      _ => (Ds.c.infoSoft, Ds.c.info),
    };

class ExceptionsScreen extends StatefulWidget {
  /// Inside the Fulfill shell there is already a bar and a title above us.
  final bool embedded;

  /// A row's `next_action.route`. The shell decides whether that is one of its
  /// own stages or an admin destination — this screen never routes.
  final ValueChanged<String>? onNavigate;

  /// Something moved (an action ran, an exception closed), so the shell's
  /// badges are stale. The backend still owns the numbers.
  final VoidCallback? onChanged;

  final ExceptionsQueueRpc? queueRpc;
  final ExceptionsActionRpc? actionRpc;
  final ExceptionsCloseRpc? closeRpc;

  const ExceptionsScreen({
    super.key,
    this.embedded = true,
    this.onNavigate,
    this.onChanged,
    this.queueRpc,
    this.actionRpc,
    this.closeRpc,
  });

  @override
  State<ExceptionsScreen> createState() => ExceptionsScreenState();
}

class ExceptionsScreenState extends State<ExceptionsScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;
  String? _reason;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    reload();
  }

  /// The shell calls this when the stage is re-opened.
  Future<void> reload() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.queueRpc ?? exceptionsQueue)(
          reason: _reason, status: 'open');
      if (!mounted) return;
      if (res['ok'] != true) {
        // A refusal is the backend's sentence, printed as given.
        setState(() {
          _loading = false;
          _payload = null;
          _error = (res['message'] ?? res['error'] ?? '').toString();
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write('c690_exceptions', (res['count'] ?? 0).toString());
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _pickReason(String key) {
    setState(() => _reason = key == 'all' ? null : key);
    reload();
  }

  void _say(String message) {
    if (!mounted || message.isEmpty) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _runAction(Map<String, dynamic> row) async {
    final act = asMap(row['next_action']);
    if (act['has'] != true) return;
    final kind = (act['kind'] ?? '').toString();

    if (kind == 'route') {
      final route = (act['route'] ?? '').toString();
      if (route.isNotEmpty) widget.onNavigate?.call(route);
      return;
    }
    if (kind != 'rpc' || _busy) return;

    setState(() => _busy = true);
    try {
      final res = await (widget.actionRpc ?? exceptionsAction)(
          (row['id'] ?? '').toString());
      // Success or refusal, the message on the reply is the one shown.
      _say((res['message'] ?? '').toString());
      if (res['ok'] == true) widget.onChanged?.call();
    } catch (e) {
      _say(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await reload();
    }
  }

  Future<void> _close(Map<String, dynamic> row) async {
    final p = _payload ?? const <String, dynamic>{};
    final copy = asMap(p['close']);
    final outcomes = (p['outcomes'] as List?) ?? const [];
    if (outcomes.isEmpty) return;

    final picked = await showModalBottomSheet<_CloseResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _CloseSheet(copy: copy, outcomes: outcomes, row: row),
    );
    if (picked == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final res = await (widget.closeRpc ?? exceptionsClose)(
          (row['id'] ?? '').toString(), picked.outcomeCode, picked.note);
      _say((res['message'] ?? '').toString());
      if (res['ok'] == true) {
        try {
          RenderLog.write('c690_exception_closed',
              (res['outcome_code'] ?? '').toString());
        } catch (_) {}
        widget.onChanged?.call();
      }
    } catch (e) {
      _say(e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
      await reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    final body = RefreshIndicator(onRefresh: reload, child: _body(p));
    if (widget.embedded) return body;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((p['title'] ?? '').toString()),
        actions: [
          IconButton(
            key: const Key('exc_refresh'),
            onPressed: _loading ? null : reload,
            icon: const Icon(Icons.refresh),
            tooltip: (p['refresh_label'] ?? '').toString(),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _body(Map<String, dynamic> p) {
    if (_loading) return const _QueueSkeleton();
    if (_error != null) {
      return _ErrorState(
        message: _error!,
        retryLabel: (p['retry_label'] ?? '').toString(),
        onRetry: reload,
      );
    }

    final rows = (p['rows'] as List?) ?? const [];
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        _Headline(payload: p),
        SizedBox(height: Ds.space.x16),
        _ReasonFilters(payload: p, onPick: _pickReason),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          _EmptyState(label: (p['empty_label'] ?? '').toString())
        else
          // Payload order IS the ranking: age × severity, worst first.
          ...rows.map((raw) => _ExceptionCard(
                data: asMap(raw),
                busy: _busy,
                onAction: _runAction,
                onClose: _close,
              )),
      ],
    );
  }
}

// ── The headline: how much is stuck, in which zone ───────────────────────────

class _Headline extends StatelessWidget {
  final Map<String, dynamic> payload;
  const _Headline({required this.payload});

  @override
  Widget build(BuildContext context) {
    String s(String k) => (payload[k] ?? '').toString();
    final (wash, ink) = toneColors(s('tone'));

    return Container(
      key: const Key('exc_headline'),
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: ink.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s('count_label'), style: Ds.t.display.copyWith(color: ink)),
          SizedBox(height: Ds.space.x4),
          Text(s('subtitle'), style: Ds.t.body),
          if (s('zone_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(s('zone_label'),
                key: const Key('exc_zone'), style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

// ── Reason chips. Counts are the backend's, and they do not renumber ─────────

class _ReasonFilters extends StatelessWidget {
  final Map<String, dynamic> payload;
  final ValueChanged<String> onPick;
  const _ReasonFilters({required this.payload, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final filters = (payload['filters'] as List?) ?? const [];
    if (filters.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text((payload['filter_label'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: filters.map((raw) {
            final f = asMap(raw);
            final key = (f['key'] ?? '').toString();
            final on = f['selected'] == true;
            return SizedBox(
              height: Ds.touch.minTarget,
              child: InkWell(
                key: Key('exc_filter_$key'),
                borderRadius: Ds.r.rChip,
                onTap: () => onPick(key),
                child: Container(
                  alignment: Alignment.center,
                  padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                  decoration: BoxDecoration(
                    color: on ? Ds.c.brandSoft : Ds.c.surface,
                    borderRadius: Ds.r.rChip,
                    border: Border.all(
                        color: on ? Ds.c.brand : Ds.c.divider),
                  ),
                  child: Text(
                    '${f['label'] ?? ''} · ${f['count'] ?? 0}',
                    style: Ds.t.caption.copyWith(
                      color: on ? Ds.c.brand : Ds.c.textSecondary,
                      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

// ── One stuck object: reason, age, owner, ONE action, and a close ────────────

class _ExceptionCard extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool busy;
  final Future<void> Function(Map<String, dynamic>) onAction;
  final Future<void> Function(Map<String, dynamic>) onClose;

  const _ExceptionCard({
    required this.data,
    required this.busy,
    required this.onAction,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    String s(String k) => (data[k] ?? '').toString();
    final (wash, ink) = toneColors(s('tone'));
    final act = asMap(data['next_action']);
    final canClose = data['can_close'] == true;

    return Container(
      key: Key('exc_row_${s('id')}'),
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(s('title'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.subtitle),
            ),
            SizedBox(width: Ds.space.x8),
            _Chip(label: s('reason_label'), wash: wash, ink: ink),
          ]),
          if (s('subtitle').isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(s('subtitle'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x12,
            runSpacing: Ds.space.x4,
            children: [
              Text(s('age_label'),
                  style: Ds.t.caption.copyWith(
                      color: ink, fontWeight: FontWeight.w600)),
              Text(s('sla_label'), style: Ds.t.caption.copyWith(color: ink)),
              Text(s('owner_label'), style: Ds.t.caption),
              Text(s('status_label'), style: Ds.t.caption),
            ],
          ),
          if (s('outcome_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(s('outcome_label'),
                key: Key('exc_outcome_${s('id')}'), style: Ds.t.caption),
          ],
          if (act['has'] == true || canClose) ...[
            SizedBox(height: Ds.space.x12),
            Row(children: [
              if (act['has'] == true)
                Expanded(
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      key: Key('exc_action_${s('id')}'),
                      onPressed: busy ? null : () => onAction(data),
                      child: Text((act['label'] ?? '').toString(),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              if (act['has'] == true && canClose)
                SizedBox(width: Ds.space.x12),
              // One filled primary per surface, and it lives in the close
              // sheet: a list of cards each shouting a green button is a wall,
              // not a hierarchy. Here the action leads and Close follows it.
              if (canClose)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    key: Key('exc_close_${s('id')}'),
                    onPressed: busy ? null : () => onClose(data),
                    child: Text(s('close_label'),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
            ]),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color wash, ink;
  const _Chip({required this.label, required this.wash, required this.ink});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: wash, borderRadius: Ds.r.rChip),
      child: Text(label,
          style:
              Ds.t.caption.copyWith(color: ink, fontWeight: FontWeight.w600)),
    );
  }
}

// ── Closing: the outcome enum is the backend's list, in its order ────────────

class _CloseResult {
  final String outcomeCode;
  final String? note;
  const _CloseResult(this.outcomeCode, this.note);
}

class _CloseSheet extends StatefulWidget {
  final Map<String, dynamic> copy;
  final List<dynamic> outcomes;
  final Map<String, dynamic> row;
  const _CloseSheet(
      {required this.copy, required this.outcomes, required this.row});

  @override
  State<_CloseSheet> createState() => _CloseSheetState();
}

class _CloseSheetState extends State<_CloseSheet> {
  String? _code;
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String s(String k) => (widget.copy[k] ?? '').toString();
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s('title'), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(s('hint'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          // The outcome list is the backend's enum, in the backend's order.
          ...widget.outcomes.map((raw) {
            final o = asMap(raw);
            final code = (o['code'] ?? '').toString();
            final on = _code == code;
            return InkWell(
              key: Key('exc_outcome_opt_$code'),
              borderRadius: Ds.r.rButton,
              onTap: () => setState(() => _code = code),
              child: Container(
                constraints:
                    BoxConstraints(minHeight: Ds.touch.minTarget),
                padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                child: Row(children: [
                  Icon(
                    on ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: on ? Ds.c.brand : Ds.c.textSecondary,
                  ),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Text((o['label'] ?? '').toString(),
                        style: on
                            ? Ds.t.body.copyWith(fontWeight: FontWeight.w600)
                            : Ds.t.body),
                  ),
                ]),
              ),
            );
          }),
          SizedBox(height: Ds.space.x12),
          TextField(
            key: const Key('exc_close_note'),
            controller: _note,
            maxLines: 2,
            decoration: InputDecoration(labelText: s('note_hint')),
          ),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              key: const Key('exc_close_submit'),
              onPressed: _code == null
                  ? null
                  : () => Navigator.of(context).pop(_CloseResult(
                      _code!,
                      _note.text.trim().isEmpty ? null : _note.text.trim())),
              child: Text(s('submit')),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              key: const Key('exc_close_cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(s('cancel')),
            ),
          ),
        ],
      ),
    );
  }
}

// ── States ───────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final String label;
  const _EmptyState({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('exc_empty'),
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x24),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: Text(label, style: Ds.t.body, textAlign: TextAlign.center),
      );
}

/// A skeleton, not a bare spinner — the queue's shape is known before its rows.
class _QueueSkeleton extends StatelessWidget {
  const _QueueSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List.generate(
          4,
          (i) => Container(
            key: Key('exc_skeleton_$i'),
            height: Ds.space.x48 + Ds.space.x32,
            margin: EdgeInsets.only(bottom: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              boxShadow: Ds.elevation.e1,
            ),
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final String retryLabel;
  final VoidCallback onRetry;
  const _ErrorState(
      {required this.message, required this.retryLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          Container(
            key: const Key('exc_error'),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: BoxDecoration(
              color: Ds.c.dangerSoft,
              borderRadius: Ds.r.rCard,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: Ds.t.body.copyWith(color: Ds.c.danger)),
                SizedBox(height: Ds.space.x12),
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    key: const Key('exc_retry'),
                    onPressed: onRetry,
                    child: Text(retryLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
}
