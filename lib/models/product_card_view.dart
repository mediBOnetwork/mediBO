import 'product.dart';

/// CMD #2122 — what the ONE grid card prints, read out of the payload.
///
/// The card object `_product_card()` builds in Postgres (CMD #2121) is the
/// source: unit word, pack line, rx, offer, the price block and the single
/// foot line under the price (`card.foot`, CMD #2122). A payload built before
/// #2121 carries no `card`, so each field falls back to the older key that
/// held the SAME backend string — a mapping, never a computation. Nothing
/// here formats, counts, compares or chooses a word.
///
/// Pure on purpose: a protected test can build one from a fixture map and
/// assert on it without pumping a widget.
class ProductCardView {
  final String unitWord;
  final String packLine;
  final bool hasRx;
  final String rxLabel;
  final Object? rxBg;
  final Object? rxFg;
  final bool hasOffer;
  final String offerLabel;
  final Object? offerBg;
  final Object? offerFg;
  final CardPrice? price;
  final bool hasFoot;
  final String footLabel;

  /// The foot's tone NAME ('success', 'danger', 'brand', 'muted', …) when the
  /// payload sent one, and its colours when it sent those.
  final String footTone;
  final Object? footFg;

  /// A pre-#2121 payload's sold-out word, drawn on the plate as it always
  /// was. The card object says it in [footLabel] instead, so this is empty
  /// for a `card` payload.
  final String soldOutChip;

  const ProductCardView({
    required this.unitWord,
    required this.packLine,
    required this.hasRx,
    required this.rxLabel,
    this.rxBg,
    this.rxFg,
    required this.hasOffer,
    required this.offerLabel,
    this.offerBg,
    this.offerFg,
    required this.price,
    required this.hasFoot,
    required this.footLabel,
    required this.footTone,
    this.footFg,
    this.soldOutChip = '',
  });

  static Map<String, dynamic>? _map(Object? raw) =>
      raw is Map ? Map<String, dynamic>.from(raw) : null;

  static String _s(Object? v) => (v ?? '').toString();

  factory ProductCardView.of(Product p) {
    final c = p.card;
    if (c != null) return ProductCardView.fromCard(c);

    // ── pre-#2121 payload: the same strings under their older keys ─────────
    final pricing = p.pricing;
    final badge = pricing?.schemeBadge;
    final hasBadge = pricing?.hasSchemeBadge == true &&
        badge != null &&
        badge.label.isNotEmpty;
    final offerText = (!hasBadge && p.hasOffer) ? p.offerChip : '';
    final av = p.availability;
    final soldOut = av != null && !av.canAdd;
    return ProductCardView(
      // The older payload's rules stand for it (#2118: one pack label, the
      // sentence; #2040: no Rx class on a card). The unit chip and the Rx dot
      // arrive with the card object, which says so explicitly.
      unitWord: '',
      packLine: p.packQtyLabel,
      hasRx: false,
      rxLabel: '',
      hasOffer: hasBadge || offerText.isNotEmpty,
      offerLabel: hasBadge ? badge.label : offerText,
      offerBg: hasBadge ? badge.bg : null,
      offerFg: hasBadge ? badge.fg : null,
      price: pricing?.cardPrice,
      // Its zone availability sentence is the foot line; sold out, its own
      // out-of-stock word also rides on the plate, as it did before #2122.
      hasFoot: av?.availabilityLabel.isNotEmpty ?? false,
      footLabel: av?.availabilityLabel ?? '',
      footTone: av?.availabilityTone ?? '',
      soldOutChip: soldOut ? av.ctaLabel : '',
    );
  }

  factory ProductCardView.fromCard(Map<String, dynamic> c) {
    final rx = _map(c['rx']);
    final rxTone = _map(rx?['tone']);
    final offer = _map(c['offer']);
    final offerTone = _map(offer?['tone']);
    final foot = _map(c['foot']);
    final footTone = _map(foot?['tone']);
    return ProductCardView(
      unitWord: _s(c['unit_word']),
      packLine: _s(c['pack_line']),
      hasRx: rx?['has'] == true && rx?['is_rx'] == true,
      rxLabel: _s(rx?['label']),
      rxBg: rxTone?['bg'],
      rxFg: rxTone?['fg'],
      hasOffer: offer?['has'] == true && _s(offer?['label']).isNotEmpty,
      offerLabel: _s(offer?['label']),
      offerBg: offerTone?['bg'],
      offerFg: offerTone?['fg'],
      price: CardPrice.fromMap(c['price']),
      hasFoot: foot?['has'] == true && _s(foot?['label']).isNotEmpty,
      footLabel: _s(foot?['label']),
      footTone: _s(footTone?['name']),
      footFg: footTone?['fg'],
    );
  }
}
