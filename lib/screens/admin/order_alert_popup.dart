// CMD #2016 — the new-order alert in the app is a CENTRE POPUP, and nothing else.
//
// #1988 put a slim strip above the header. #1989 added a bottom sheet beside
// it. Om's call on 16 Sep: the strip goes, and what an admin sees while the app
// is open is ONE centre modal — customer, amount, item count, age, a paid /
// unpaid pill, and two buttons. "Open order" goes to the order. "Later" puts
// the popup away on THIS device; the order stays in Awaiting action and the
// nav badge keeps counting it, because Later writes to a dismissal table and
// never to the alert.
//
// This file decides nothing. Every string on it — the heading, the customer
// name, the money, the item count, the age, the pill's word, both button
// words, the "+N more" line — arrives rendered from order_alert_popup(). The
// only thing Dart reads off the payload is which design token a NAMED TONE
// maps to, which is the same latitude the strip had since #1988.
//
// Accept and Reject are not here: a decision is taken on the order screen,
// next to the items and the amount. That rule is #1988's and it stands.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// What the popup was closed with. The caller acts on it; the popup does not.
enum OrderAlertPopupResult { open, later, gone }

/// Opens the centre popup. Returns once it is dismissed — by either button, by
/// a tap outside, or because the host closed it when the server alert went away.
///
/// The haptic tick is here rather than in the widget so the widget stays a pure
/// render of the payload (and a test can pump it without a navigator).
Future<OrderAlertPopupResult?> showOrderAlertPopup(
  BuildContext context, {
  required Map<String, dynamic> popup,
  AnimationController? controller,
}) {
  // A single tick, not a buzz: the phone says "look" without taking over.
  HapticFeedback.selectionClick();
  return showDialog<OrderAlertPopupResult>(
    context: context,
    // A tap outside is "Later" — the popup can always be put aside, which is
    // what stopped #1988's dialog being a trap.
    barrierDismissible: true,
    barrierColor: Ds.c.text.withValues(alpha: 0.45),
    builder: (_) => OrderAlertPopup(
      popup: popup,
      onOpen: () => Navigator.of(context).pop(OrderAlertPopupResult.open),
      onLater: () => Navigator.of(context).pop(OrderAlertPopupResult.later),
    ),
  );
}

class OrderAlertPopup extends StatelessWidget {
  final Map<String, dynamic> popup;
  final VoidCallback onOpen;
  final VoidCallback onLater;

  const OrderAlertPopup({
    super.key,
    required this.popup,
    required this.onOpen,
    required this.onLater,
  });

  String _s(String key) => (popup[key] as String?) ?? '';

  /// A named tone → the token that paints it. The ONLY inference in this file.
  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.warning;
    }
  }

  Color _toneSoft(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.warningSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c2016_alert_popup', '1');

    final statusTone = _tone(_s('status_tone'));
    final statusSoft = _toneSoft(_s('status_tone'));

    // Mobile-first: the card fills a phone with one gutter step on each side
    // and simply stops growing on a desktop — no fixed width anywhere. The cap
    // is a multiple of the spacing token, so a retuned scale moves it too.
    final gutters = MediaQuery.of(context).size.width - Ds.space.x32;
    final cap = Ds.space.x48 * 10;

    return Dialog(
      backgroundColor: Ds.c.surface,
      insetPadding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x24),
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: gutters < cap ? gutters : cap,
        ),
        // A long customer name plus a long backend label must scroll rather
        // than overflow on a 320px phone in a landscape sliver.
        child: SingleChildScrollView(
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _content(context, statusTone, statusSoft),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _content(
      BuildContext context, Color statusTone, Color statusSoft) {
    final title = _s('title');
    final customer = _s('customer_name');
    final amount = _s('amount_display');
    final amountCaption = _s('amount_caption');
    final items = _s('items_label');
    final age = _s('age_label');
    final status = _s('status_label');
    final primary = _s('primary_label');
    final secondary = _s('secondary_label');
    final more = _s('more_label');

    return [
      // The heading is the backend's word, never "New order" written here.
      if (title.isNotEmpty)
        Text(title, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      if (title.isNotEmpty) SizedBox(height: Ds.space.x4),

      // One focal element: whose order it is.
      if (customer.isNotEmpty)
        Text(customer,
            style: Ds.t.title, maxLines: 2, overflow: TextOverflow.ellipsis),

      SizedBox(height: Ds.space.x16),

      // The money answers it, with its own caption and the item count beside.
      Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (amountCaption.isNotEmpty)
                  Text(amountCaption, style: Ds.t.caption, maxLines: 1),
                if (amount.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(amount,
                      style: Ds.t.display,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          if (items.isNotEmpty) ...[
            SizedBox(width: Ds.space.x12),
            Flexible(
              child: Text(items,
                  style: Ds.t.body,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ],
      ),

      SizedBox(height: Ds.space.x16),

      // A filled pill for paid / unpaid, the age as muted text beside it. Both
      // wrap rather than overflow when the words are long.
      Wrap(
        spacing: Ds.space.x12,
        runSpacing: Ds.space.x8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (status.isNotEmpty)
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: statusSoft,
                borderRadius: Ds.r.rChip,
                border:
                    Border.all(color: statusTone, width: Ds.space.hairline),
              ),
              child: Text(status,
                  style: Ds.t.caption
                      .copyWith(color: statusTone, fontWeight: FontWeight.w600),
                  maxLines: 1),
            ),
          if (age.isNotEmpty) Text(age, style: Ds.t.caption, maxLines: 1),
        ],
      ),

      // "+N more waiting" — written by the backend, counted by the backend.
      if (more.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        Text(more, style: Ds.t.caption, maxLines: 1),
      ],

      SizedBox(height: Ds.space.x24),

      // Two actions, both full width and stacked so neither is squeezed on a
      // 320px phone. One brand primary; Later is the quiet outline.
      SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: FilledButton(
          onPressed: onOpen,
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            foregroundColor: Ds.c.surface,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(primary,
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ),
      ),
      SizedBox(height: Ds.space.x8),
      SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          onPressed: onLater,
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.textSecondary,
            side: BorderSide(color: Ds.c.divider, width: Ds.space.hairline),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(secondary,
              style: Ds.t.body, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ),
    ];
  }
}
