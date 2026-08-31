import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/product_reviews.dart';

/// CMD #410 — the ratings, reviews and Q&A block on the product page.
///
/// It renders `product_reviews()` and writes through `review_submit`,
/// `question_submit`, `answer_submit` and `content_flag_raise`. Every visible
/// string on this screen comes out of the payload: the two headings, the two
/// empty states, every button caption, the placeholder in each field, the
/// badge on a review, the note under a pending one, and the sentence
/// explaining why the composer is closed.
///
/// The one thing it decides is which composer is OPEN, which is UI state.
/// Whether a composer may exist at all is [ProductReviews.canWrite] — the
/// backend's verdict that this account has a delivered order containing the
/// product. The widget never checks "is somebody signed in" as a stand-in.
typedef ReviewSubmit = Future<ReviewWriteResult> Function(int stars, String body);
typedef QuestionSubmit = Future<ReviewWriteResult> Function(String body);
typedef AnswerSubmit = Future<ReviewWriteResult> Function(String questionId, String body);
typedef FlagRaise = Future<ReviewWriteResult> Function(String kind, String targetId);

class ProductReviewsBlock extends StatefulWidget {
  final ProductReviews data;

  /// Called after any successful write so the page can reload the block. The
  /// widget never patches its own list optimistically: a submitted review is
  /// PENDING and only the backend knows what the list looks like now.
  final Future<void> Function() onChanged;

  final ReviewSubmit onReview;
  final QuestionSubmit onQuestion;
  final AnswerSubmit onAnswer;
  final FlagRaise onFlag;

  /// Test seam. Production shows a SnackBar; a test records the string and
  /// asserts it is the backend's, character for character.
  final void Function(String message)? onToast;

  const ProductReviewsBlock({
    super.key,
    required this.data,
    required this.onChanged,
    required this.onReview,
    required this.onQuestion,
    required this.onAnswer,
    required this.onFlag,
    this.onToast,
  });

  @override
  State<ProductReviewsBlock> createState() => _ProductReviewsBlockState();
}

class _ProductReviewsBlockState extends State<ProductReviewsBlock> {
  bool _reviewOpen = false;
  bool _askOpen = false;
  String? _answeringId;
  int _stars = 0;
  bool _busy = false;

  final _reviewCtl = TextEditingController();
  final _askCtl = TextEditingController();
  final _answerCtl = TextEditingController();

  @override
  void dispose() {
    _reviewCtl.dispose();
    _askCtl.dispose();
    _answerCtl.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (message.isEmpty) return;
    final cb = widget.onToast;
    if (cb != null) {
      cb(message);
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// One place for every write: run it, print the backend's own message
  /// whether it succeeded or refused, and reload on success. A refusal is a
  /// payload, never an exception, so there is no error branch that invents
  /// copy of its own.
  Future<void> _run(Future<ReviewWriteResult> Function() call,
      VoidCallback onOk) async {
    if (_busy) return;
    setState(() => _busy = true);
    final res = await call();
    if (!mounted) return;
    setState(() => _busy = false);
    _toast(res.message);
    if (!res.ok) return;
    onOk();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.data;
    if (!d.ok) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: Ds.space.x24),
        _SectionHeading(text: d.title),
        SizedBox(height: Ds.space.x8),

        // The aggregate, or the backend's "not rated yet" line. `has` is the
        // backend's verdict — never count > 0 re-derived here.
        if (d.summary.has)
          _AggregateRow(summary: d.summary)
        else
          Text(d.summary.empty, style: Ds.t.caption),

        SizedBox(height: Ds.space.x12),

        if (d.canWrite && !_reviewOpen)
          _SecondaryButton(
            label: d.label('write_cta'),
            icon: Icons.rate_review_outlined,
            onTap: () => setState(() => _reviewOpen = true),
          ),
        if (!d.canWrite && d.gateNote.isNotEmpty)
          _GateNote(text: d.gateNote),

        if (_reviewOpen) ...[
          SizedBox(height: Ds.space.x12),
          _Composer(
            starsHint: d.label('stars_hint'),
            stars: _stars,
            onStars: (n) => setState(() => _stars = n),
            controller: _reviewCtl,
            hint: d.label('body_hint'),
            maxLength: d.bodyMax,
            submitLabel: d.label('submit'),
            cancelLabel: d.label('cancel'),
            busy: _busy,
            onCancel: () => setState(() {
              _reviewOpen = false;
              _stars = 0;
              _reviewCtl.clear();
            }),
            onSubmit: () => _run(
              () => widget.onReview(_stars, _reviewCtl.text),
              () => setState(() {
                _reviewOpen = false;
                _stars = 0;
                _reviewCtl.clear();
              }),
            ),
          ),
        ],

        SizedBox(height: Ds.space.x12),
        if (d.items.isEmpty)
          Text(d.empty, style: Ds.t.caption)
        else
          for (final r in d.items) ...[
            _ReviewCard(
              item: r,
              flagLabel: d.label('flag_cta'),
              onFlag: () => _run(() => widget.onFlag('review', r.id), () {}),
            ),
            SizedBox(height: Ds.space.x8),
          ],

        // ── Q&A ───────────────────────────────────────────────────────────
        SizedBox(height: Ds.space.x24),
        _SectionHeading(text: d.qnaTitle),
        SizedBox(height: Ds.space.x8),

        if (d.canWrite && !_askOpen)
          _SecondaryButton(
            label: d.label('ask_cta'),
            icon: Icons.help_outline,
            onTap: () => setState(() => _askOpen = true),
          ),

        if (_askOpen) ...[
          SizedBox(height: Ds.space.x12),
          _Composer(
            starsHint: '',
            stars: 0,
            onStars: null,
            controller: _askCtl,
            hint: d.label('question_hint'),
            maxLength: d.questionMax,
            submitLabel: d.label('submit'),
            cancelLabel: d.label('cancel'),
            busy: _busy,
            onCancel: () => setState(() {
              _askOpen = false;
              _askCtl.clear();
            }),
            onSubmit: () => _run(
              () => widget.onQuestion(_askCtl.text),
              () => setState(() {
                _askOpen = false;
                _askCtl.clear();
              }),
            ),
          ),
        ],

        SizedBox(height: Ds.space.x12),
        if (d.questions.isEmpty)
          Text(d.qnaEmpty, style: Ds.t.caption)
        else
          for (final q in d.questions) ...[
            _QuestionCard(
              question: q,
              answerLabel: d.label('answer_cta'),
              flagLabel: d.label('flag_cta'),
              submitLabel: d.label('submit'),
              cancelLabel: d.label('cancel'),
              hint: d.label('question_hint'),
              answering: _answeringId == q.id,
              busy: _busy,
              controller: _answerCtl,
              onOpenAnswer: () => setState(() {
                _answeringId = q.id;
                _answerCtl.clear();
              }),
              onCancelAnswer: () => setState(() => _answeringId = null),
              onSubmitAnswer: () => _run(
                () => widget.onAnswer(q.id, _answerCtl.text),
                () => setState(() => _answeringId = null),
              ),
              onFlag: () => _run(() => widget.onFlag('question', q.id), () {}),
              onFlagAnswer: (id) =>
                  _run(() => widget.onFlag('answer', id), () {}),
            ),
            SizedBox(height: Ds.space.x8),
          ],
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final String text;
  const _SectionHeading({required this.text});
  @override
  Widget build(BuildContext context) => Text(text, style: Ds.t.subtitle);
}

/// The stars are painted from [RatingSummary.stars]; the sentence beside them
/// is [RatingSummary.starsLabel], which the backend already formatted. The
/// widget never builds "4.2 out of 5" itself.
class _AggregateRow extends StatelessWidget {
  final RatingSummary summary;
  const _AggregateRow({required this.summary});

  @override
  Widget build(BuildContext context) => Row(
        children: [
          _Stars(value: summary.stars),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(
              summary.starsLabel,
              style: Ds.t.bodyStrong,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Flexible(
            child: Text(
              summary.countLabel,
              style: Ds.t.caption,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
}

class _Stars extends StatelessWidget {
  final double value;
  final double size;
  const _Stars({required this.value, this.size = 16});
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 1; i <= 5; i++)
            Icon(
              value >= i
                  ? Icons.star_rounded
                  : (value >= i - 0.5
                      ? Icons.star_half_rounded
                      : Icons.star_border_rounded),
              size: size,
              color: Ds.c.warning,
            ),
        ],
      );
}

class _GateNote extends StatelessWidget {
  final String text;
  const _GateNote({required this.text});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.infoSoft,
          borderRadius: Ds.r.rButton,
        ),
        child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.text)),
      );
}

class _SecondaryButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _SecondaryButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: Icon(icon, size: Ds.space.x16),
          label: Text(label),
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.brand),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
        ),
      );
}

class _Composer extends StatelessWidget {
  final String starsHint;
  final int stars;
  final ValueChanged<int>? onStars;
  final TextEditingController controller;
  final String hint;
  final int maxLength;
  final String submitLabel;
  final String cancelLabel;
  final bool busy;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _Composer({
    required this.starsHint,
    required this.stars,
    required this.onStars,
    required this.controller,
    required this.hint,
    required this.maxLength,
    required this.submitLabel,
    required this.cancelLabel,
    required this.busy,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onStars != null) ...[
              Text(starsHint, style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              Row(
                children: [
                  for (var i = 1; i <= 5; i++)
                    IconButton(
                      onPressed: () => onStars!(i),
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                      icon: Icon(
                        stars >= i
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: Ds.c.warning,
                      ),
                    ),
                ],
              ),
              SizedBox(height: Ds.space.x8),
            ],
            TextField(
              controller: controller,
              maxLines: 3,
              maxLength: maxLength > 0 ? maxLength : null,
              decoration: InputDecoration(
                hintText: hint,
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(borderRadius: Ds.r.rButton),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                SizedBox(
                  height: 44,
                  child: TextButton(
                    onPressed: busy ? null : onCancel,
                    child: Text(cancelLabel),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
                SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: busy ? null : onSubmit,
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape:
                          RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                    child: Text(submitLabel),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class _ReviewCard extends StatelessWidget {
  final ReviewItem item;
  final String flagLabel;
  final VoidCallback onFlag;
  const _ReviewCard({
    required this.item,
    required this.flagLabel,
    required this.onFlag,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Stars(value: item.stars.toDouble()),
                SizedBox(width: Ds.space.x8),
                if (item.badge.isNotEmpty)
                  _Pill(text: item.badge, bg: Ds.c.successSoft, fg: Ds.c.success),
                const Spacer(),
                Text(item.when, style: Ds.t.caption),
              ],
            ),
            if (item.author.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(item.author, style: Ds.t.caption),
            ],
            if (item.body.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(item.body, style: Ds.t.body),
            ],
            // The note is the backend's — "sent for review", or the rejection
            // reason a moderator typed. The app never composes either.
            if (item.hasNote) ...[
              SizedBox(height: Ds.space.x8),
              Container(
                padding: EdgeInsets.all(Ds.space.x8),
                decoration: BoxDecoration(
                  color: Ds.c.warningSoft,
                  borderRadius: Ds.r.rButton,
                ),
                child: Text(item.note, style: Ds.t.caption.copyWith(color: Ds.c.text)),
              ),
            ],
            if (item.canFlag) ...[
              SizedBox(height: Ds.space.x4),
              Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  height: 44,
                  child: TextButton.icon(
                    onPressed: onFlag,
                    icon: Icon(Icons.flag_outlined, size: Ds.space.x16),
                    label: Text(flagLabel),
                    style: TextButton.styleFrom(
                        foregroundColor: Ds.c.textSecondary),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
}

class _QuestionCard extends StatelessWidget {
  final QuestionItem question;
  final String answerLabel;
  final String flagLabel;
  final String submitLabel;
  final String cancelLabel;
  final String hint;
  final bool answering;
  final bool busy;
  final TextEditingController controller;
  final VoidCallback onOpenAnswer;
  final VoidCallback onCancelAnswer;
  final VoidCallback onSubmitAnswer;
  final VoidCallback onFlag;
  final void Function(String answerId) onFlagAnswer;

  const _QuestionCard({
    required this.question,
    required this.answerLabel,
    required this.flagLabel,
    required this.submitLabel,
    required this.cancelLabel,
    required this.hint,
    required this.answering,
    required this.busy,
    required this.controller,
    required this.onOpenAnswer,
    required this.onCancelAnswer,
    required this.onSubmitAnswer,
    required this.onFlag,
    required this.onFlagAnswer,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
          boxShadow: Ds.elevation.e1,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(question.body, style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Row(
              children: [
                if (question.author.isNotEmpty)
                  Flexible(
                    child: Text(question.author,
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                  ),
                const Spacer(),
                Text(question.when, style: Ds.t.caption),
              ],
            ),
            if (question.hasNote) ...[
              SizedBox(height: Ds.space.x8),
              Container(
                padding: EdgeInsets.all(Ds.space.x8),
                decoration: BoxDecoration(
                  color: Ds.c.warningSoft,
                  borderRadius: Ds.r.rButton,
                ),
                child: Text(question.note,
                    style: Ds.t.caption.copyWith(color: Ds.c.text)),
              ),
            ],
            for (final a in question.answers) ...[
              SizedBox(height: Ds.space.x12),
              Container(
                padding: EdgeInsets.all(Ds.space.x12),
                decoration: BoxDecoration(
                  color: Ds.c.bg,
                  borderRadius: Ds.r.rButton,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (a.badge.isNotEmpty)
                          _Pill(text: a.badge, bg: Ds.c.brandSoft, fg: Ds.c.brand),
                        const Spacer(),
                        Text(a.when, style: Ds.t.caption),
                      ],
                    ),
                    SizedBox(height: Ds.space.x4),
                    Text(a.body, style: Ds.t.body),
                    if (a.canFlag)
                      Align(
                        alignment: Alignment.centerRight,
                        child: SizedBox(
                          height: 44,
                          child: TextButton(
                            onPressed: () => onFlagAnswer(a.id),
                            style: TextButton.styleFrom(
                                foregroundColor: Ds.c.textSecondary),
                            child: Text(flagLabel),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
            if (answering) ...[
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: controller,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: hint,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              SizedBox(height: Ds.space.x8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 44,
                    child: TextButton(
                      onPressed: busy ? null : onCancelAnswer,
                      child: Text(cancelLabel),
                    ),
                  ),
                  SizedBox(width: Ds.space.x8),
                  SizedBox(
                    height: 44,
                    child: FilledButton(
                      onPressed: busy ? null : onSubmitAnswer,
                      style: FilledButton.styleFrom(
                        backgroundColor: Ds.c.brand,
                        shape:
                            RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                      ),
                      child: Text(submitLabel),
                    ),
                  ),
                ],
              ),
            ] else
              Row(
                children: [
                  if (question.canAnswer)
                    SizedBox(
                      height: 44,
                      child: TextButton.icon(
                        onPressed: onOpenAnswer,
                        icon: Icon(Icons.reply_outlined, size: Ds.space.x16),
                        label: Text(answerLabel),
                        style: TextButton.styleFrom(foregroundColor: Ds.c.brand),
                      ),
                    ),
                  const Spacer(),
                  if (question.canFlag)
                    SizedBox(
                      height: 44,
                      child: TextButton(
                        onPressed: onFlag,
                        style: TextButton.styleFrom(
                            foregroundColor: Ds.c.textSecondary),
                        child: Text(flagLabel),
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
}

class _Pill extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Pill({required this.text, required this.bg, required this.fg});
  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
        child: Text(text,
            style: Ds.t.caption
                .copyWith(color: fg, fontWeight: FontWeight.w500)),
      );
}
