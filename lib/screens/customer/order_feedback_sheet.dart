import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CHANGE #697 — the whole-order feedback card.
///
/// Until now a customer could rate the RIDER (delivery_ratings) or a PRODUCT
/// (product reviews). Nothing asked what the mediBO ORDER was like. This is
/// that card, and it is deliberately ONE widget: the in-app sheet and the
/// public `/feedback/<token>` page a WhatsApp link opens both render this file,
/// so the two surfaces cannot drift apart.
///
/// It decides nothing. The dimension list, every label, every low-score chip,
/// the NPS question and its two scale ends, the hint, both button captions and
/// the star ceiling all arrive in the payload (`order_feedback_prompt` /
/// `order_feedback_form`). The only state this file owns is the user's own
/// input: which star is lit, where the NPS slider sits, which chips are on and
/// what is typed in the reason box.

/// The backend names a tone; this is the only place that turns one into a
/// colour, and it never guesses one from a score.
Color _tone(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'brand':
      return Ds.c.brand;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

List<Map<String, dynamic>> _rows(Object? v) => (v as List? ?? const [])
    .whereType<Map>()
    .map((e) => e.cast<String, dynamic>())
    .toList(growable: false);

/// What the card hands back when the customer taps Send.
class OrderFeedbackAnswer {
  /// dim_key -> 1..5
  final Map<String, int> scores;
  final int nps;
  final String? reason;
  final List<String> chips;
  const OrderFeedbackAnswer(this.scores, this.nps, this.reason, this.chips);
}

/// The card itself — pure, testable, and shared by both surfaces.
class OrderFeedbackCard extends StatefulWidget {
  final Map<String, dynamic> payload;
  final bool busy;
  final Future<void> Function(OrderFeedbackAnswer answer) onSubmit;

  /// Null on the public link page: there is nothing to come back to, so there
  /// is no "Not now".
  final Future<void> Function()? onSkip;

  const OrderFeedbackCard({
    super.key,
    required this.payload,
    required this.onSubmit,
    this.onSkip,
    this.busy = false,
  });

  @override
  State<OrderFeedbackCard> createState() => _OrderFeedbackCardState();
}

class _OrderFeedbackCardState extends State<OrderFeedbackCard> {
  final Map<String, int> _scores = {};
  final Set<String> _chips = {};
  final TextEditingController _reason = TextEditingController();
  double? _nps;

  @override
  void initState() {
    super.initState();
    // A dimension the backend pre-filled (today: the delivery star the rider
    // already got) arrives SELECTED and stays editable. Absence is unselected —
    // never a default star.
    for (final d in _rows(widget.payload['dimensions'])) {
      final pre = d['prefill'];
      if (pre is int && pre >= 1 && pre <= 5) _scores[_s(d, 'key')] = pre;
    }
    RenderLog.write('c697_feedback_card', _rows(widget.payload['dimensions']).length);
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  int get _npsMin => (widget.payload['nps_min'] as num?)?.toInt() ?? 0;
  int get _npsMax => (widget.payload['nps_max'] as num?)?.toInt() ?? 10;
  int get _starsMax => (widget.payload['stars_max'] as num?)?.toInt() ?? 5;
  int get _lowAt => (widget.payload['low_score_at'] as num?)?.toInt() ?? 2;

  bool get _complete =>
      _nps != null &&
      _rows(widget.payload['dimensions'])
          .every((d) => (_scores[_s(d, 'key')] ?? 0) >= 1);

  Future<void> _send() async {
    if (!_complete || widget.busy) return;
    final text = _reason.text.trim();
    await widget.onSubmit(OrderFeedbackAnswer(
      Map<String, int>.from(_scores),
      _nps!.round(),
      text.isEmpty ? null : text,
      _chips.toList(growable: false),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.payload;
    final dims = _rows(p['dimensions']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_s(p, 'title'), style: Ds.t.title),
        if (_s(p, 'subtitle').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(p, 'subtitle'), style: Ds.t.caption),
        ],
        if (_s(p, 'intro').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(p, 'intro'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x24),
        for (final d in dims) _dimensionRow(d),
        SizedBox(height: Ds.space.x24),
        _npsBlock(p),
        SizedBox(height: Ds.space.x24),
        TextField(
          controller: _reason,
          maxLines: 2,
          minLines: 1,
          style: Ds.t.body,
          decoration: InputDecoration(hintText: _s(p, 'reason_hint')),
        ),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: (_complete && !widget.busy) ? _send : null,
            child: Text(_s(p, 'submit_label')),
          ),
        ),
        if (widget.onSkip != null) ...[
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: widget.busy ? null : () => widget.onSkip!(),
              child: Text(_s(p, 'skip_label')),
            ),
          ),
        ],
      ],
    );
  }

  Widget _dimensionRow(Map<String, dynamic> d) {
    final key = _s(d, 'key');
    final score = _scores[key] ?? 0;
    final chips = _rows(d['chips']);
    // The chip strip appears only once this dimension is actually low, and the
    // threshold is the BACKEND's number, not a 2 written here.
    final showChips = score >= 1 && score <= _lowAt && chips.isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(d, 'label'), style: Ds.t.body)),
              for (var i = 1; i <= _starsMax; i++)
                _StarTap(
                  filled: i <= score,
                  onTap: () => setState(() {
                    _scores[key] = i;
                    if (i > _lowAt) {
                      _chips.removeAll(chips.map((c) => _s(c, 'key')));
                    }
                  }),
                ),
            ],
          ),
          if (showChips) ...[
            SizedBox(height: Ds.space.x8),
            Text(_s(widget.payload, 'chips_hint'), style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final c in chips)
                  _ChipTap(
                    label: _s(c, 'label'),
                    selected: _chips.contains(_s(c, 'key')),
                    onTap: () => setState(() {
                      final k = _s(c, 'key');
                      _chips.contains(k) ? _chips.remove(k) : _chips.add(k);
                    }),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _npsBlock(Map<String, dynamic> p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(p, 'nps_question'), style: Ds.t.body),
        SizedBox(height: Ds.space.x8),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _nps ?? _npsMin.toDouble(),
                min: _npsMin.toDouble(),
                max: _npsMax.toDouble(),
                divisions: _npsMax - _npsMin,
                label: (_nps ?? _npsMin).round().toString(),
                onChanged: (v) => setState(() => _nps = v),
              ),
            ),
            SizedBox(
              width: Ds.space.x32,
              child: Text(
                _nps == null ? '' : _nps!.round().toString(),
                style: Ds.t.bodyStrong,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_s(p, 'nps_low'), style: Ds.t.caption),
            Text(_s(p, 'nps_high'), style: Ds.t.caption),
          ],
        ),
      ],
    );
  }
}

class _StarTap extends StatelessWidget {
  final bool filled;
  final VoidCallback onTap;
  const _StarTap({required this.filled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: SizedBox(
        width: Ds.touch.minTarget,
        height: Ds.touch.minTarget,
        child: Icon(filled ? Icons.star_rounded : Icons.star_outline_rounded,
            color: filled ? Ds.c.brand : Ds.c.divider),
      ),
    );
  }
}

class _ChipTap extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChipTap(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.space.x32),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : Ds.c.bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(label,
            style: selected
                ? Ds.t.caption.copyWith(color: Ds.c.brand)
                : Ds.t.caption),
      ),
    );
  }
}

/// ─────────────────────── the in-app sheet ───────────────────────

class OrderFeedbackSheet {
  OrderFeedbackSheet._();

  /// Test seam, the same shape as StockUpdateFormScreen.rpcTransport.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }
}

Map<String, dynamic>? _asMap(dynamic raw) {
  final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
  return data is Map ? data.cast<String, dynamic>() : null;
}

/// Opens the card for one order. Returns true when an answer was submitted.
///
/// The prompt RPC is what decides whether the card appears at all — it says
/// show:false for an order that is not closed, is not this pharmacy's, or has
/// already been rated or skipped. Nothing here re-decides that.
Future<bool> showOrderFeedbackSheet(BuildContext context, String orderId) async {
  Map<String, dynamic>? payload;
  try {
    payload = _asMap(await OrderFeedbackSheet.rpc(
        'order_feedback_prompt', {'p_order_id': orderId}));
  } catch (_) {
    return false;
  }
  if (payload == null || payload['show'] != true) return false;
  if (!context.mounted) return false;
  return await showOrderFeedbackCardSheet(context, payload) ?? false;
}

/// Shows an already-loaded prompt payload. Split out so the Orders tab can ask
/// once with `order_feedback_pending()` and open the card with no second call.
Future<bool?> showOrderFeedbackCardSheet(
    BuildContext context, Map<String, dynamic> payload) {
  final orderId = _s(payload, 'order_id');
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
    builder: (ctx) => _FeedbackSheetBody(payload: payload, orderId: orderId),
  );
}

class _FeedbackSheetBody extends StatefulWidget {
  final Map<String, dynamic> payload;
  final String orderId;
  const _FeedbackSheetBody({required this.payload, required this.orderId});

  @override
  State<_FeedbackSheetBody> createState() => _FeedbackSheetBodyState();
}

class _FeedbackSheetBodyState extends State<_FeedbackSheetBody> {
  bool _busy = false;
  String _done = '';
  String _doneTone = 'success';

  Future<void> _submit(OrderFeedbackAnswer a) async {
    setState(() => _busy = true);
    try {
      final res = _asMap(await OrderFeedbackSheet.rpc('order_feedback_submit', {
        'p_order_id': widget.orderId,
        'p_scores': a.scores,
        'p_nps': a.nps,
        'p_reason': a.reason,
        'p_chips': a.chips,
      }));
      if (!mounted) return;
      // Both the thank-you and the refusal are the backend's own sentence.
      setState(() {
        _busy = false;
        _done = _s(res ?? const {}, 'message');
        _doneTone = (res?['ok'] == true) ? 'success' : 'danger';
      });
      RenderLog.write('c697_feedback_submit', a.nps);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    setState(() => _busy = true);
    try {
      await OrderFeedbackSheet.rpc(
          'order_feedback_skip', {'p_order_id': widget.orderId});
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x24 + inset),
      child: SingleChildScrollView(
        child: _done.isNotEmpty
            ? _DoneBlock(
                message: _done,
                tone: _doneTone,
                closeLabel: _s(widget.payload, 'close_label'),
                onClose: () => Navigator.of(context).pop(_doneTone == 'success'))
            : OrderFeedbackCard(
                payload: widget.payload,
                busy: _busy,
                onSubmit: _submit,
                onSkip: _skip,
              ),
      ),
    );
  }
}

/// The confirmation. The sentence is the backend's — including the one that
/// says a ticket was opened and the zone partner will call back.
class _DoneBlock extends StatelessWidget {
  final String message;
  final String tone;
  final String closeLabel;
  final VoidCallback onClose;
  const _DoneBlock({
    required this.message,
    required this.tone,
    required this.closeLabel,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.check_circle_outline, color: _tone(tone)),
        SizedBox(height: Ds.space.x12),
        Text(message, style: Ds.t.body),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(onPressed: onClose, child: Text(closeLabel)),
        ),
      ],
    );
  }
}
