// CMD #1989 — the new-order popup, as a bottom sheet.
//
// #1988 took the centre dialog away because it fought the lock-screen alert.
// What replaced it was a slim strip, and Om's note on 14 Sep is about what the
// interrupt LOOKS like when it does come: "a grey centre dialog with flat chips
// — it looks unfinished next to the rest of the app."
//
// So this is the popup, rebuilt: a bottom sheet with a coloured status rail, a
// real hierarchy, one filled status pill and exactly ONE action. It decides
// nothing. Every string on it — shop name, order code, amount, item count, the
// three-item preview, the age, the pill's word, the button's word — arrives
// rendered from order_alert_sheet(). The only thing Dart reads off the payload
// is which design token a NAMED TONE maps to, which is the same latitude the
// strip has had since #1988.
//
// Accept and Reject are not here either: a decision is taken on the order
// screen, next to the items and the amount. That rule is #1988's and it stands.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Opens the popup. Returns once it is dismissed — by the button, by a swipe
/// down, or by a tap outside.
///
/// The spring entry and the haptic tick are here rather than in the widget so
/// the sheet itself stays a pure render of the payload (and a test can pump it
/// without a navigator).
Future<void> showOrderAlertSheet(
  BuildContext context, {
  required Map<String, dynamic> sheet,
  required VoidCallback onOpen,
  AnimationController? controller,
}) {
  // A single tick, not a buzz: the phone says "look" without taking over.
  HapticFeedback.selectionClick();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // Swipe-down to dismiss, and a tap outside is a dismiss too — the popup
    // can always be ignored, which is what stopped #1988's dialog being a trap.
    enableDrag: true,
    isDismissible: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    barrierColor: Ds.c.text.withValues(alpha: 0.45),
    transitionAnimationController: controller,
    builder: (_) => OrderAlertSheet(sheet: sheet, onOpen: onOpen),
  );
}

/// The animation controller that gives the sheet its spring: it overshoots a
/// little on the way in and settles. Owned by the caller so it can be disposed.
AnimationController orderAlertSheetController(TickerProvider vsync) =>
    AnimationController(
      vsync: vsync,
      duration: Ds.motion.sheet,
      reverseDuration: Ds.motion.standard,
    );

/// The spring curve for [orderAlertSheetController]. `easeOutBack` is the
/// overshoot; the reverse is a plain ease so a dismissal never bounces.
const Curve kOrderAlertSheetCurve = Curves.easeOutBack;

class OrderAlertSheet extends StatelessWidget {
  final Map<String, dynamic> sheet;
  final VoidCallback onOpen;

  const OrderAlertSheet({super.key, required this.sheet, required this.onOpen});

  String _s(String key) => (sheet[key] as String?) ?? '';

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
    final railTone = _tone(_s('rail_tone'));
    final statusTone = _tone(_s('status_tone'));
    final statusSoft = _toneSoft(_s('status_tone'));

    final shopName = _s('shop_name');
    final orderCode = _s('order_code');
    final amount = _s('amount_display');
    final itemsLabel = _s('items_label');
    final preview = _s('items_preview');
    final age = _s('age_label');
    final status = _s('status_label');
    final primary = _s('primary_label');
    final more = _s('more_label');

    RenderLog.write('c1989_alert_sheet', '1');

    return Padding(
      // The sheet rides above the keyboard/nav inset rather than under it.
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Material(
        color: Ds.c.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
        ),
        child: SafeArea(
          top: false,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Item 2 — the status rail. Amber unpaid, green paid, and the
                // colour is the backend's word, not a re-reading of `paid`.
                Container(width: Ds.space.x4, color: railTone),
                Expanded(child: _body(context,
                    shopName: shopName,
                    orderCode: orderCode,
                    amount: amount,
                    itemsLabel: itemsLabel,
                    preview: preview,
                    age: age,
                    status: status,
                    statusTone: statusTone,
                    statusSoft: statusSoft,
                    primary: primary,
                    more: more)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context, {
    required String shopName,
    required String orderCode,
    required String amount,
    required String itemsLabel,
    required String preview,
    required String age,
    required String status,
    required Color statusTone,
    required Color statusSoft,
    required String primary,
    required String more,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The drag handle: the affordance for "swipe me away".
        Center(
          child: Padding(
            padding: EdgeInsets.only(top: Ds.space.x12, bottom: Ds.space.x4),
            child: Container(
              width: Ds.space.x32 + Ds.space.x8,
              height: Ds.space.x4,
              decoration: BoxDecoration(
                color: Ds.c.divider,
                borderRadius: BorderRadius.circular(Ds.r.chip),
              ),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Item 3 — the hierarchy. Shop name leads, the money answers it
              // on the right, and everything else is metadata beneath.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (shopName.isNotEmpty)
                          Text(shopName,
                              style: Ds.t.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis),
                        if (orderCode.isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(orderCode,
                              style: Ds.t.caption.copyWith(
                                  fontFamily: 'monospace',
                                  fontFamilyFallback: const [
                                    'Courier New',
                                    'monospace'
                                  ]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ],
                    ),
                  ),
                  SizedBox(width: Ds.space.x12),
                  // Money right-aligned, with its own count under it.
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (amount.isNotEmpty)
                        Text(amount,
                            style: Ds.t.display,
                            textAlign: TextAlign.right,
                            maxLines: 1),
                      if (itemsLabel.isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(itemsLabel,
                            style: Ds.t.caption,
                            textAlign: TextAlign.right,
                            maxLines: 1),
                      ],
                    ],
                  ),
                ],
              ),

              // The faint one-line preview of what is actually on the order.
              if (preview.isNotEmpty) ...[
                SizedBox(height: Ds.space.x12),
                Text(preview,
                    style: Ds.t.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ],

              SizedBox(height: Ds.space.x16),

              // Item 4 — a filled pill, never a grey chip. The age sits beside
              // it as muted text, which is the one thing it is not: a chip.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (status.isNotEmpty)
                    Container(
                      padding: EdgeInsets.symmetric(
                          horizontal: Ds.space.x12, vertical: Ds.space.x4),
                      decoration: BoxDecoration(
                        color: statusSoft,
                        borderRadius: BorderRadius.circular(Ds.r.chip),
                        border: Border.all(
                            color: statusTone, width: Ds.space.hairline),
                      ),
                      child: Text(status,
                          style: Ds.t.caption.copyWith(
                              color: statusTone,
                              fontWeight: FontWeight.w600),
                          maxLines: 1),
                    ),
                  if (age.isNotEmpty) ...[
                    SizedBox(width: Ds.space.x12),
                    Flexible(
                      child: Text(age,
                          style: Ds.t.caption,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                  if (more.isNotEmpty) ...[
                    SizedBox(width: Ds.space.x8),
                    Flexible(
                      child: Text(more,
                          style: Ds.t.caption,
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ],
              ),

              SizedBox(height: Ds.space.x24),

              // Item 5 — exactly one action, full width, and its word is the
              // backend's. Nothing competes with it: no Dismiss, no Snooze, no
              // Accept, no Reject.
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: onOpen,
                  style: FilledButton.styleFrom(
                    backgroundColor: Ds.c.brand,
                    foregroundColor: Ds.c.surface,
                    shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(Ds.r.button)),
                  ),
                  child: Text(primary,
                      style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
