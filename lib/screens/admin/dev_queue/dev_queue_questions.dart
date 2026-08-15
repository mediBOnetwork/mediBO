import 'dart:async';

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// Generate-Command — the "ask my doubts before building" screen.
///
/// THE APP RENDERS. IT NEVER DECIDES. — every question, its recommended answer,
/// the source it came from and the receipt are written by the runner and read
/// here verbatim. This screen only polls [draftGet], collects Om's picks, and
/// posts them back to [draftSubmit], which deterministically composes the final
/// command(s) server-side. The live preview is a read-only mirror, never an
/// authority.
class DevQueueQuestions extends StatefulWidget {
  final DevQueueService service;
  final int draftId;

  // Kept only so a failed generation can be retried (re-create the draft).
  final String spec;
  final String mode;
  final int? count;
  final Map<String, dynamic> opts;

  const DevQueueQuestions({
    super.key,
    required this.service,
    required this.draftId,
    required this.spec,
    required this.mode,
    required this.count,
    required this.opts,
  });

  @override
  State<DevQueueQuestions> createState() => _DevQueueQuestionsState();
}

class _DevQueueQuestionsState extends State<DevQueueQuestions> {
  late int _id;
  Timer? _poll;
  Map<String, dynamic>? _draft;
  bool _loading = true;
  bool _submitting = false;
  bool _acceptSplit = true;

  // Per-question pick: 'rec' | 'alt' | 'own'. Recommended is pre-selected so a
  // single Submit accepts every default. 'own' also carries a free-text answer.
  final Map<int, String> _sel = {};
  final Map<int, TextEditingController> _own = {};

  @override
  void initState() {
    super.initState();
    _id = widget.draftId;
    _load();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted && _isGenerating) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _own.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _isGenerating {
    final s = (_draft?['status'] ?? 'generating').toString();
    return s == 'generating';
  }

  List<Map<String, dynamic>> get _questions =>
      ((_draft?['questions'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _emitMulti =>
      ((_draft?['emit_multi'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  int _qIdx(Map q) => (q['idx'] as num?)?.toInt() ?? 0;

  Future<void> _load({bool silent = false}) async {
    try {
      final d = await widget.service.draftGet(_id);
      if (!mounted) return;
      setState(() {
        _draft = d;
        _loading = false;
      });
      if (!_isGenerating) _poll?.cancel();
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _retry() async {
    setState(() {
      _loading = true;
      _draft = null;
    });
    try {
      final res = await widget.service
          .draftCreate(widget.spec, widget.mode, widget.count, widget.opts);
      final id = (res['id'] as num?)?.toInt() ?? 0;
      if (id > 0) {
        _id = id;
        _poll?.cancel();
        _poll = Timer.periodic(const Duration(seconds: 2), (_) {
          if (mounted && _isGenerating) _load(silent: true);
        });
        await _load();
      } else if (mounted) {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _answerForMe() {
    setState(() {
      for (final q in _questions) {
        _sel[_qIdx(q)] = 'rec';
      }
    });
  }

  // The answer that will be sent for one question, honouring the pick and
  // falling back to the recommendation (exactly what the backend does).
  String _answerFor(Map q) {
    final idx = _qIdx(q);
    final pick = _sel[idx] ?? 'rec';
    if (pick == 'alt') return (q['alt'] ?? q['recommended'] ?? '').toString();
    if (pick == 'own') {
      final t = _own[idx]?.text.trim() ?? '';
      return t.isNotEmpty ? t : (q['recommended'] ?? '').toString();
    }
    return (q['recommended'] ?? '').toString();
  }

  Future<void> _submit() async {
    final answers = [
      for (final q in _questions) {'idx': _qIdx(q), 'answer': _answerFor(q)}
    ];
    setState(() => _submitting = true);
    try {
      final res = await widget.service.draftSubmit(_id, answers,
          acceptSplit: _acceptSplit, savePrefs: true);
      if (!mounted) return;
      final added =
          (((res['result'] as Map?)?['added'] as List?) ?? const []).length;
      final msg = added == 1
          ? c('dev_queue.q_queued_one')
          : c('dev_queue.q_queued_many').replaceFirst('{n}', '$added');
      showToast(context, msg);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        showToast(context, e.toString(), isError: true);
      }
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.service.draftCancel(_id);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final status = (_draft?['status'] ?? 'generating').toString();
    return Scaffold(
      backgroundColor: kPageBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: kTextHi,
        elevation: 0,
        title: Text(c('dev_queue.q_title'), style: Ds.t.subtitle),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _submitting ? null : _cancel,
        ),
      ),
      body: _body(status),
    );
  }

  Widget _body(String status) {
    if (_loading || status == 'generating') return _generatingView();
    if (status == 'failed') return _failedView();
    return _readyView();
  }

  Widget _generatingView() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: kBrand),
            SizedBox(height: Ds.space.x24),
            Text(c('dev_queue.q_generating'),
                textAlign: TextAlign.center, style: Ds.t.body),
            SizedBox(height: Ds.space.x8),
            Text(c('dev_queue.q_generating_sub'),
                textAlign: TextAlign.center, style: Ds.t.caption),
          ]),
        ),
      );

  Widget _failedView() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline, color: Ds.c.danger, size: Ds.space.x48),
            SizedBox(height: Ds.space.x16),
            Text(c('dev_queue.q_failed'),
                textAlign: TextAlign.center, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text((_draft?['error'] ?? '').toString(),
                textAlign: TextAlign.center, style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            Row(mainAxisSize: MainAxisSize.min, children: [
              OutlinedButton(
                onPressed: _cancel,
                style: OutlinedButton.styleFrom(
                    foregroundColor: kTextLo, side: const BorderSide(color: kBorder)),
                child: Text(c('dev_queue.q_close')),
              ),
              SizedBox(width: Ds.space.x12),
              FilledButton(
                onPressed: _retry,
                style: FilledButton.styleFrom(backgroundColor: kBrand),
                child: Text(c('dev_queue.q_retry')),
              ),
            ]),
          ]),
        ),
      );

  Widget _readyView() {
    final qs = _questions;
    if (qs.isEmpty) return _emptyView();
    return Column(children: [
      Expanded(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x16),
          children: [
            _answerForMeBar(),
            SizedBox(height: Ds.space.x12),
            ..._questionSections(qs),
            if (_emitMulti.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _splitCard(),
            ],
            SizedBox(height: Ds.space.x16),
            _previewCard(qs),
            if ((_draft?['receipt'] ?? '').toString().trim().isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              _receiptCard(),
            ],
          ],
        ),
      ),
      _submitBar(),
    ]);
  }

  Widget _emptyView() => Column(children: [
        Expanded(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(Ds.space.x24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.check_circle_outline,
                    color: Ds.c.success, size: Ds.space.x48),
                SizedBox(height: Ds.space.x16),
                Text(c('dev_queue.q_empty'),
                    textAlign: TextAlign.center, style: Ds.t.body),
              ]),
            ),
          ),
        ),
        _submitBar(emptyLabel: true),
      ]);

  Widget _answerForMeBar() => Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          onPressed: _answerForMe,
          icon: const Icon(Icons.auto_fix_high, size: 16),
          label: Text(c('dev_queue.q_answer_for_me'), style: Ds.t.caption),
          style: OutlinedButton.styleFrom(
              foregroundColor: kBrand, side: const BorderSide(color: kBrand)),
        ),
      );

  // Flat when auto/command; grouped by point (point_text header) when 'point'.
  List<Widget> _questionSections(List<Map<String, dynamic>> qs) {
    if (widget.mode != 'point') {
      return [
        for (final q in qs) ...[_questionCard(q), SizedBox(height: Ds.space.x12)]
      ];
    }
    final groups = <int, List<Map<String, dynamic>>>{};
    final headers = <int, String>{};
    for (final q in qs) {
      final pi = (q['point_idx'] as num?)?.toInt() ?? 0;
      groups.putIfAbsent(pi, () => []).add(q);
      headers[pi] = (q['point_text'] ?? '').toString();
    }
    final keys = groups.keys.toList()..sort();
    final out = <Widget>[];
    for (final k in keys) {
      final head = headers[k] ?? '';
      if (head.isNotEmpty) {
        out.add(Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8, top: Ds.space.x4),
          child: Text(head, style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
        ));
      }
      for (final q in groups[k]!) {
        out.add(_questionCard(q));
        out.add(SizedBox(height: Ds.space.x12));
      }
    }
    return out;
  }

  Tone _kindTone(String kind) {
    switch (kind) {
      case 'contradiction':
        return toneByName('error');
      case 'prereq':
        return toneByName('warning');
      case 'hidden':
        return toneByName('info');
      default: // gap | scope
        return toneByName('neutral');
    }
  }

  Color _confColor(String conf) {
    switch (conf) {
      case 'high':
        return Ds.c.success;
      case 'med':
        return Ds.c.warning;
      default:
        return Ds.c.textSecondary;
    }
  }

  Widget _questionCard(Map<String, dynamic> q) {
    final idx = _qIdx(q);
    final kind = (q['kind'] ?? 'gap').toString();
    final conf = (q['confidence'] ?? '').toString();
    final reason = (q['reason'] ?? '').toString();
    final costHint = (q['cost_hint'] ?? '').toString();
    final source = (q['recommended_source'] ?? '').toString();
    final rec = (q['recommended'] ?? '').toString();
    final alt = (q['alt'] ?? '').toString();
    final urls = ((q['example_urls'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toList();
    final pick = _sel[idx] ?? 'rec';
    final flagged = kind == 'contradiction' || kind == 'prereq';

    return DqCard(
      accent: flagged ? _kindTone(kind).fg : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          ToneChip(label: c('dev_queue.q_kind_$kind'), tone: _kindTone(kind)),
          const Spacer(),
          if (conf.isNotEmpty) ...[
            Container(
              width: Ds.space.x8,
              height: Ds.space.x8,
              decoration:
                  BoxDecoration(color: _confColor(conf), shape: BoxShape.circle),
            ),
            SizedBox(width: Ds.space.x4 + Ds.space.x4),
          ],
          if (conf.isNotEmpty)
            Text(c('dev_queue.q_conf_$conf'), style: Ds.t.caption),
        ]),
        SizedBox(height: Ds.space.x12),
        Text((q['q'] ?? '').toString(),
            style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
        if (reason.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(reason, style: Ds.t.caption),
        ],
        if (costHint.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          ToneChip(
              label: costHint, tone: toneByName('neutral'), icon: Icons.schedule),
        ],
        if (urls.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
            for (final u in urls) _thumb(u),
          ]),
        ],
        SizedBox(height: Ds.space.x12),
        _optRow(idx, 'rec', c('dev_queue.q_opt_recommended'), rec, pick,
            subtitle: source),
        if (alt.isNotEmpty)
          _optRow(idx, 'alt', c('dev_queue.q_opt_alt'), alt, pick),
        _optRow(idx, 'own', c('dev_queue.q_opt_own'), '', pick),
        if (pick == 'own') ...[
          SizedBox(height: Ds.space.x8),
          _ownField(idx),
        ],
      ]),
    );
  }

  Widget _optRow(int idx, String key, String title, String value, String pick,
      {String subtitle = ''}) {
    final selected = pick == key;
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () => setState(() => _sel[idx] = key),
      child: Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? kBrand : kTextLo),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: Ds.t.caption.copyWith(
                      color: selected ? kBrand : kTextLo,
                      fontWeight: FontWeight.w600)),
              if (value.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(value, style: Ds.t.body),
              ],
              if (subtitle.isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(subtitle, style: Ds.t.caption),
              ],
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _ownField(int idx) {
    final ctl = _own.putIfAbsent(idx, () => TextEditingController());
    return Row(children: [
      Expanded(
        child: TextField(
          controller: ctl,
          minLines: 1,
          maxLines: 4,
          onChanged: (_) => setState(() {}),
          style: Ds.t.body,
          decoration: InputDecoration(
            hintText: c('dev_queue.q_own_hint'),
            filled: true,
            fillColor: Colors.white,
            isDense: true,
            contentPadding: EdgeInsets.all(Ds.space.x12),
            enabledBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: const BorderSide(color: kBorder)),
            focusedBorder: OutlineInputBorder(
                borderRadius: Ds.r.rButton,
                borderSide: const BorderSide(color: kBrand)),
          ),
        ),
      ),
      IconButton(
        tooltip: c('dev_queue.mic_tooltip'),
        onPressed: _mic,
        icon: const Icon(Icons.mic_none, color: kBrand),
      ),
    ]);
  }

  void _mic() {
    // Dictation runs on the native app; the shared VoiceLiveController is wired
    // there. On web the backend copy explains where to use it.
    showToast(context, c('dev_queue.mic_unsupported'));
  }

  Widget _thumb(String url) => GestureDetector(
        onTap: () => _openImage(url),
        child: ClipRRect(
          borderRadius: Ds.r.rChip,
          child: Image.network(url,
              width: Ds.space.x48 + Ds.space.x16,
              height: Ds.space.x48 + Ds.space.x16,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
                    width: Ds.space.x48 + Ds.space.x16,
                    height: Ds.space.x48 + Ds.space.x16,
                    color: kPageBg,
                    child: const Icon(Icons.broken_image_outlined, color: kTextLo),
                  )),
        ),
      );

  void _openImage(String url) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: InteractiveViewer(child: Image.network(url)),
      ),
    );
  }

  Widget _splitCard() => DqCard(
        accent: toneByName('info').fg,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
              c('dev_queue.q_split_note')
                  .replaceAll('{n}', '${_emitMulti.length + 1}'),
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
          SizedBox(height: Ds.space.x8),
          Row(children: [
            Expanded(
                child: Text(c('dev_queue.q_split_accept'), style: Ds.t.caption)),
            Switch(
              value: _acceptSplit,
              activeColor: kBrand,
              onChanged: (v) => setState(() => _acceptSplit = v),
            ),
          ]),
        ]),
      );

  Widget _previewCard(List<Map<String, dynamic>> qs) => DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.visibility_outlined, size: 18, color: kBrand),
            SizedBox(width: Ds.space.x8),
            Text(c('dev_queue.q_preview_title'),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
          ]),
          SizedBox(height: Ds.space.x8),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration:
                BoxDecoration(color: kPageBg, borderRadius: Ds.r.rButton),
            child: Text(widget.spec, style: Ds.t.caption),
          ),
          SizedBox(height: Ds.space.x12),
          Text(c('dev_queue.q_preview_decisions'),
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
          SizedBox(height: Ds.space.x4),
          for (var i = 0; i < qs.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x4),
              child: Text('${i + 1}. ${(qs[i]['q'] ?? '')} → ${_answerFor(qs[i])}',
                  style: Ds.t.caption),
            ),
        ]),
      );

  Widget _receiptCard() => DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(c('dev_queue.q_receipt_title'),
              style: Ds.t.caption.copyWith(fontWeight: FontWeight.w700)),
          SizedBox(height: Ds.space.x4),
          Text((_draft?['receipt'] ?? '').toString(), style: Ds.t.caption),
        ]),
      );

  Widget _submitBar({bool emptyLabel = false}) => Container(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x16),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: kBorder)),
        ),
        child: SizedBox(
          height: Ds.touch.minTarget,
          width: double.infinity,
          child: FilledButton(
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
                backgroundColor: kBrand,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
            child: _submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Text(
                    emptyLabel
                        ? c('dev_queue.q_empty_build')
                        : c('dev_queue.q_submit'),
                    style: Ds.t.body.copyWith(
                        color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ),
      );
}
