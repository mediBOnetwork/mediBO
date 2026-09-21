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

/// CMD #2124 — what the card's action says after a tap, before the next read.
///
/// `card.action` carries every word the card can move to — the pill template
/// ("{qty} strip"), the in-cart foot template, Notify / Notified and their two
/// foot lines — and `card.foot_idle` is the foot once the pack leaves the
/// cart. This class only picks between those backend strings and fills the
/// `{qty}` slot with the cart's own number. A payload without `action` (built
/// before #2124) gets null and the card keeps its older controls.
class CardAction {
  final String pickerRpc;
  final String packType;
  final String qtyTpl;
  final String qtyFootTpl;
  final String notifyLabel;
  final String notifiedLabel;
  final String notifyLine;
  final String notifiedLine;
  final bool notified;
  final int payloadQty;
  final String idleFoot;
  final String idleFootTone;

  const CardAction({
    required this.pickerRpc,
    required this.packType,
    required this.qtyTpl,
    required this.qtyFootTpl,
    required this.notifyLabel,
    required this.notifiedLabel,
    required this.notifyLine,
    required this.notifiedLine,
    required this.notified,
    required this.payloadQty,
    required this.idleFoot,
    required this.idleFootTone,
  });

  static String _s(Object? v) => (v ?? '').toString();

  static CardAction? of(Map<String, dynamic>? card) {
    final a = card?['action'];
    if (a is! Map) return null;
    final picker = a['picker'] is Map ? a['picker'] as Map : const {};
    final notify = a['notify'] is Map ? a['notify'] as Map : const {};
    final idle = card?['foot_idle'] is Map ? card!['foot_idle'] as Map : const {};
    final idleTone = idle['tone'] is Map ? idle['tone'] as Map : const {};
    return CardAction(
      pickerRpc: _s(picker['rpc']),
      packType: _s(picker['pack_type']),
      qtyTpl: _s(a['qty_tpl']),
      qtyFootTpl: _s(a['qty_foot_tpl']),
      notifyLabel: _s(notify['label']),
      notifiedLabel: _s(notify['done_label']),
      notifyLine: _s(notify['idle_line']),
      notifiedLine: _s(notify['done_line']),
      notified: notify['notified'] == true || card?['notified'] == true,
      payloadQty: (card?['qty_in_cart'] as num?)?.toInt() ?? 0,
      idleFoot: _s(idle['label']),
      idleFootTone: _s(idleTone['name']),
    );
  }

  /// "5 strip" — the pill, the backend's template with the cart's number.
  String pillLabel(int qty) => qtyTpl.replaceAll('{qty}', '$qty');

  /// The ONE line under the price for the state the card is in right now.
  /// Returns (label, tone name); an empty label means print nothing.
  (String, String) foot({
    required ProductCardView view,
    required bool soldOut,
    required bool notifiedNow,
    required int qty,
  }) {
    if (soldOut) {
      return (notifiedNow || notified)
          ? (notifiedLine, 'muted')
          : (notifyLine, 'danger');
    }
    if (qty > 0) return (qtyFootTpl.replaceAll('{qty}', '$qty'), 'brand');
    if (payloadQty > 0) return (idleFoot, idleFootTone);
    return (view.hasFoot ? view.footLabel : '', view.footTone);
  }
}
