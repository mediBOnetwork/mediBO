/// CMD #410 — the `product_reviews(p_product_id, p_offset)` payload.
///
/// Parsed and nothing more. Every visible word below — the headings, the empty
/// states, the button captions, the reason a composer is closed, the badge on
/// an approved review, the note on a pending one — is a string the backend
/// sent. Nothing here is written in Dart, and nothing here is decided in Dart:
/// [ProductReviews.canWrite] is the BACKEND's verdict on whether this account
/// has a delivered order containing the product, never "is somebody signed
/// in", because a gate implemented twice is a gate enforced once.
///
/// Absence is explicit in the same style the PDP already uses: a rating below
/// the review floor arrives as `summary.has == false` with no number at all,
/// so the page shows nothing rather than a 5.0 that one customer wrote.
class ProductReviews {
  final bool ok;
  final String productId;
  final RatingSummary summary;

  final String title;
  final String qnaTitle;
  final String empty;
  final String qnaEmpty;

  /// The backend's answer to "may this account write here". The composer is
  /// shown on this and nothing else.
  final bool canWrite;

  /// Why it is closed, in the backend's words. Empty when [canWrite] is true.
  final String gateNote;

  final Map<String, String> labels;
  final int bodyMax;
  final int questionMax;

  final List<ReviewItem> items;
  final List<QuestionItem> questions;
  final bool hasMore;
  final int nextOffset;

  const ProductReviews({
    required this.ok,
    required this.productId,
    required this.summary,
    required this.title,
    required this.qnaTitle,
    required this.empty,
    required this.qnaEmpty,
    required this.canWrite,
    required this.gateNote,
    required this.labels,
    required this.bodyMax,
    required this.questionMax,
    required this.items,
    required this.questions,
    required this.hasMore,
    required this.nextOffset,
  });

  static const ProductReviews empty_ = ProductReviews(
    ok: false,
    productId: '',
    summary: RatingSummary.absent,
    title: '',
    qnaTitle: '',
    empty: '',
    qnaEmpty: '',
    canWrite: false,
    gateNote: '',
    labels: {},
    bodyMax: 0,
    questionMax: 0,
    items: [],
    questions: [],
    hasMore: false,
    nextOffset: 0,
  );

  /// One backend label, e.g. `write_cta`. Missing reads as '' — never a
  /// Dart-side default, which would be the app writing user-facing copy.
  String label(String key) => labels[key] ?? '';

  static String s(Object? v) => v?.toString() ?? '';
  static int _i(Object? v) => v is int ? v : int.tryParse(s(v)) ?? 0;

  factory ProductReviews.fromMap(Map<String, dynamic> m) {
    if (m['ok'] != true) return ProductReviews.empty_;
    final rawLabels = m['labels'];
    return ProductReviews(
      ok: true,
      productId: s(m['product_id']),
      summary: RatingSummary.fromMap(m['summary']),
      title: s(m['title']),
      qnaTitle: s(m['qna_title']),
      empty: s(m['empty']),
      qnaEmpty: s(m['qna_empty']),
      canWrite: m['can_write'] == true,
      gateNote: s(m['gate_note']),
      labels: rawLabels is Map
          ? rawLabels.map((k, v) => MapEntry(k.toString(), s(v)))
          : const {},
      bodyMax: _i(m['body_max']),
      questionMax: _i(m['question_max']),
      items: ((m['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => ReviewItem.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
      questions: ((m['questions'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => QuestionItem.fromMap(r.cast<String, dynamic>()))
          .toList(growable: false),
      hasMore: m['has_more'] == true,
      nextOffset: _i(m['next_offset']),
    );
  }
}

/// The aggregate. `has` is the backend's verdict on whether there is enough
/// evidence to show a rating at all — the app never re-derives it from
/// `count > 0`, which is exactly how a one-review 5.0 ends up on a buying
/// screen. Below the floor the only thing to print is [empty].
class RatingSummary {
  final bool has;
  final int count;
  final String starsLabel;
  final String countLabel;
  final String empty;

  /// Only ever used to paint the star row. The TEXT beside it is
  /// [starsLabel], which the backend formatted.
  final double stars;

  const RatingSummary({
    required this.has,
    required this.count,
    required this.stars,
    required this.starsLabel,
    required this.countLabel,
    required this.empty,
  });

  static const RatingSummary absent = RatingSummary(
    has: false, count: 0, stars: 0, starsLabel: '', countLabel: '', empty: '');

  factory RatingSummary.fromMap(Object? raw) {
    if (raw is! Map) return RatingSummary.absent;
    final m = raw.cast<String, dynamic>();
    final st = m['stars'];
    return RatingSummary(
      has: m['has'] == true,
      count: ProductReviews._i(m['count']),
      stars: st is num ? st.toDouble() : double.tryParse('${st ?? ''}') ?? 0,
      starsLabel: ProductReviews.s(m['stars_label']),
      countLabel: ProductReviews.s(m['count_label']),
      empty: ProductReviews.s(m['empty']),
    );
  }
}

class ReviewItem {
  final String id;
  final int stars;
  final String body;
  final String author;
  final String when;
  final bool isMine;

  /// 'Verified buyer' — or '' when the backend did not send one. The app never
  /// decides that a review is verified; it prints the badge it was given.
  final String badge;
  final String status;
  final bool hasNote;
  final String note;
  final bool canFlag;

  const ReviewItem({
    required this.id,
    required this.stars,
    required this.body,
    required this.author,
    required this.when,
    required this.isMine,
    required this.badge,
    required this.status,
    required this.hasNote,
    required this.note,
    required this.canFlag,
  });

  factory ReviewItem.fromMap(Map<String, dynamic> m) => ReviewItem(
        id: ProductReviews.s(m['id']),
        stars: ProductReviews._i(m['stars']),
        body: ProductReviews.s(m['body']),
        author: ProductReviews.s(m['author']),
        when: ProductReviews.s(m['when']),
        isMine: m['is_mine'] == true,
        badge: ProductReviews.s(m['badge']),
        status: ProductReviews.s(m['status']),
        hasNote: m['has_note'] == true,
        note: ProductReviews.s(m['note']),
        canFlag: m['can_flag'] == true,
      );
}

class QuestionItem {
  final String id;
  final String body;
  final String author;
  final String when;
  final bool isMine;
  final String status;
  final bool hasNote;
  final String note;
  final bool canAnswer;
  final bool canFlag;
  final List<AnswerItem> answers;

  const QuestionItem({
    required this.id,
    required this.body,
    required this.author,
    required this.when,
    required this.isMine,
    required this.status,
    required this.hasNote,
    required this.note,
    required this.canAnswer,
    required this.canFlag,
    required this.answers,
  });

  factory QuestionItem.fromMap(Map<String, dynamic> m) => QuestionItem(
        id: ProductReviews.s(m['id']),
        body: ProductReviews.s(m['body']),
        author: ProductReviews.s(m['author']),
        when: ProductReviews.s(m['when']),
        isMine: m['is_mine'] == true,
        status: ProductReviews.s(m['status']),
        hasNote: m['has_note'] == true,
        note: ProductReviews.s(m['note']),
        canAnswer: m['can_answer'] == true,
        canFlag: m['can_flag'] == true,
        answers: ((m['answers'] as List?) ?? const [])
            .whereType<Map>()
            .map((a) => AnswerItem.fromMap(a.cast<String, dynamic>()))
            .toList(growable: false),
      );
}

class AnswerItem {
  final String id;
  final String body;
  final String badge;
  final String when;
  final bool canFlag;
  const AnswerItem({
    required this.id,
    required this.body,
    required this.badge,
    required this.when,
    required this.canFlag,
  });

  factory AnswerItem.fromMap(Map<String, dynamic> m) => AnswerItem(
        id: ProductReviews.s(m['id']),
        body: ProductReviews.s(m['body']),
        badge: ProductReviews.s(m['badge']),
        when: ProductReviews.s(m['when']),
        canFlag: m['can_flag'] == true,
      );
}

/// What a write RPC answers with. `ok:false` is a REFUSAL carrying the
/// backend's sentence, never an exception — same contract as CartOrderRefusal
/// and the wishlist toggle.
class ReviewWriteResult {
  final bool ok;
  final String error;
  final String message;
  const ReviewWriteResult({
    required this.ok,
    required this.error,
    required this.message,
  });

  static const ReviewWriteResult failed =
      ReviewWriteResult(ok: false, error: 'failed', message: '');

  factory ReviewWriteResult.fromMap(Map<String, dynamic> m) => ReviewWriteResult(
        ok: m['ok'] == true,
        error: ProductReviews.s(m['error']),
        message: ProductReviews.s(m['message']),
      );
}
