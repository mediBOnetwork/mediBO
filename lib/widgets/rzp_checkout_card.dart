// lib/widgets/rzp_checkout_card.dart — CHANGE #304
//
// The SDK/checkout branch of the payment sheet: the one a customer paying for
// their OWN order on the phone in their hand actually sees.
//
// #291 could only ever draw a picture. Razorpay returns image_url with a NULL
// qr_string on this account, and even with one, a QR on the paying phone is
// unscannable — five QRs were minted and not one was ever paid. This card
// replaces the picture with a BUTTON that opens Razorpay Checkout, which fires
// the UPI intent and hands the customer straight to PhonePe / Google Pay /
// Paytm.
//
// Every string here arrives finished from `razorpay-checkout-create`, which
// prints `_rzp_attempt_view()`. This file composes nothing: no amount is
// formatted, no button word is chosen, no status sentence is assembled. The
// button says "Pay now" or "Resume payment" because the BACKEND said so — the
// state machine on `rzp_payment_attempt`, not a flag counted here.
//
// Like `razorpay_qr_card.dart` this file imports no dart:html (direct or
// transitive), so it is pumpable on the Dart VM in test/protected/.
import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// One payment attempt, exactly as the backend described it.
class RzpCheckoutView {
  /// True only when the backend said so. Everything below is meaningless
  /// otherwise.
  final bool ok;

  /// 'sdk' | 'qr' | 'manual' — decided by `rzp_pay_mode()`, never here.
  final String payMode;

  final String attemptId;

  /// pending | attempted | paid | failed | expired.
  final String status;
  final String statusLabel;

  /// The Razorpay Checkout URL. Opening it is the whole point of this card.
  final String payUrl;

  final String title;
  final String subtitle;
  final String amountLabel;
  final String amountRowLabel;
  final String linkRowLabel;

  /// "Pay now" / "Resume payment" — the backend's word for what this tap does.
  final String buttonLabel;

  /// Set only for a failed or expired attempt; carries the backend's sentence.
  final String failureLabel;

  /// The backend's own paid flag — never inferred from a status string parsed
  /// here, and never from the client's return from Razorpay.
  final bool paid;
  final String paidAtLabel;

  /// The backend's judgement on whether this attempt can be reopened. A tap
  /// on a resumable attempt reopens the SAME Razorpay link.
  final bool resumable;

  /// Set only when the backend refused; carries its message verbatim.
  final String error;

  const RzpCheckoutView({
    this.ok = false,
    this.payMode = '',
    this.attemptId = '',
    this.status = '',
    this.statusLabel = '',
    this.payUrl = '',
    this.title = '',
    this.subtitle = '',
    this.amountLabel = '',
    this.amountRowLabel = '',
    this.linkRowLabel = '',
    this.buttonLabel = '',
    this.failureLabel = '',
    this.paid = false,
    this.paidAtLabel = '',
    this.resumable = false,
    this.error = '',
  });

  /// There is something to open only when the backend handed over a URL.
  bool get hasPayUrl => payUrl.isNotEmpty;

  static String _s(Map<String, dynamic>? j, String k) =>
      (j?[k] ?? '').toString();

  factory RzpCheckoutView.fromPayload(Map<String, dynamic>? j) {
    if (j == null) return const RzpCheckoutView();
    // The backend's own message outranks the machine slug, exactly as the QR
    // card does — 'nothing_due' has a sentence, 'store_failed' does not.
    final msg = _s(j, 'message');
    return RzpCheckoutView(
      ok: j['ok'] == true,
      payMode: _s(j, 'pay_mode'),
      attemptId: _s(j, 'attempt_id'),
      status: _s(j, 'status'),
      statusLabel: _s(j, 'status_label'),
      payUrl: _s(j, 'pay_url'),
      title: _s(j, 'title'),
      subtitle: _s(j, 'subtitle'),
      amountLabel: _s(j, 'amount_label'),
      amountRowLabel: _s(j, 'amount_row_label'),
      linkRowLabel: _s(j, 'link_row_label'),
      buttonLabel: _s(j, 'button_label'),
      failureLabel: _s(j, 'failure_label'),
      paid: j['paid'] == true,
      paidAtLabel: _s(j, 'paid_at_label'),
      resumable: j['resumable'] == true,
      error: msg.isNotEmpty ? msg : _s(j, 'error'),
    );
  }
}

/// The checkout card: the backend's words, one primary action, nothing else.
class RzpCheckoutCard extends StatelessWidget {
  final RzpCheckoutView view;

  /// Opens [RzpCheckoutView.payUrl]. Injected so the card itself never reaches
  /// for a platform channel and stays pumpable on the Dart VM.
  final VoidCallback? onPay;

  /// Shown instead of the button while the launch is in flight — its words come
  /// from the payload too.
  final bool opening;
  final String openingLabel;

  /// The waiting-for-the-webhook block. The order is paid by the webhook, never
  /// by the customer coming back, so this is what an honest sheet shows after
  /// the hand-off.
  final bool waiting;
  final String waitingLabel;
  final String waitingHint;

  /// A launch the device refused (a pop-up blocker, no browser). Its words are
  /// the payload's too. Shown beside the link, which is the way out.
  final String openFailedLabel;

  const RzpCheckoutCard({
    super.key,
    required this.view,
    this.onPay,
    this.opening = false,
    this.openingLabel = '',
    this.waiting = false,
    this.waitingLabel = '',
    this.waitingHint = '',
    this.openFailedLabel = '',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.all(Ds.space.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (view.subtitle.isNotEmpty) ...[
          Text(view.subtitle, textAlign: TextAlign.center, style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
        ],
        if (view.amountRowLabel.isNotEmpty && view.amountLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(view.amountRowLabel, style: Ds.t.caption),
                Text(view.amountLabel, style: Ds.t.bodyStrong),
              ],
            ),
          ),
        if (openFailedLabel.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.warningSoft,
              borderRadius: Ds.r.rCard,
            ),
            child: Text(openFailedLabel, style: Ds.t.caption),
          ),
          SizedBox(height: Ds.space.x12),
        ],
        if (view.failureLabel.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.dangerSoft,
              borderRadius: Ds.r.rCard,
            ),
            child: Text(view.failureLabel, style: Ds.t.caption),
          ),
          SizedBox(height: Ds.space.x12),
        ],
        // The primary action. Absent once the backend says paid — there is
        // nothing left to pay — and absent when it handed over no URL to open.
        if (!view.paid && view.hasPayUrl && view.buttonLabel.isNotEmpty)
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              onPressed: opening ? null : onPay,
              child: opening && openingLabel.isNotEmpty
                  ? Text(openingLabel)
                  : Text(view.buttonLabel),
            ),
          ),
        if (waiting && waitingLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Row(children: [
            SizedBox(
              width: Ds.space.x16,
              height: Ds.space.x16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Ds.c.brand),
            ),
            SizedBox(width: Ds.space.x12),
            Expanded(child: Text(waitingLabel, style: Ds.t.caption)),
          ]),
          if (waitingHint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(waitingHint, style: Ds.t.caption),
          ],
        ],
        // The URL in plain sight: if the launch is blocked (a pop-up blocker on
        // web, no browser on the device) the customer still has the link.
        if (!view.paid && view.hasPayUrl && view.linkRowLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Text(view.linkRowLabel, style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          SelectableText(view.payUrl, style: Ds.t.caption),
        ],
        if (view.paid && view.paidAtLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(view.paidAtLabel, style: Ds.t.caption),
        ],
      ]),
    );
  }
}
