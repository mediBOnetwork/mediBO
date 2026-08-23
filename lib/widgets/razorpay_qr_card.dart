// lib/widgets/razorpay_qr_card.dart — CHANGE #291
//
// The Razorpay dynamic-QR branch of the payment sheet.
//
// Every string here arrives finished from `razorpay-qr-create`, which itself
// prints `rzp_qr_view()`. This file composes nothing: no amount is formatted,
// no heading is assembled, no status word is chosen. If a label is missing from
// the payload the widget renders NOTHING in its place — an absence is an
// absence, never a Dart default.
//
// Like `pay_qr_card.dart`, this file deliberately imports no dart:html (direct
// or transitive) so it can be pumped on the Dart VM in test/protected/.
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design_tokens.dart';

/// The QR box side, matched to [PayQrCard] so both providers render the same
/// size. Not a style token — it is the scannable area of a QR, which has to
/// stay big enough for a phone camera regardless of theme.
const double kRzpQrSide = 220;

/// One Razorpay QR, exactly as the backend described it.
class RzpQrView {
  /// True only when the backend said so. Everything below is meaningless
  /// otherwise.
  final bool ok;

  /// 'razorpay_qr' when the auto-verified path is live; 'upi_manual' means the
  /// caller must fall back to the shared-VPA sheet.
  final String provider;

  final String qrId;
  final String rzpQrId;

  /// The Razorpay-hosted PNG. Used by WhatsApp, and by this card when the
  /// payload carried no `qr_string` to draw locally.
  final String imageUrl;

  /// The raw UPI string behind the QR, when Razorpay returned one. Drawing it
  /// locally keeps the sheet working on a slow connection.
  final String qrString;

  final String title;
  final String subtitle;
  final String amountLabel;
  final String amountRowLabel;
  final String noteLabel;

  /// The backend's own paid flag — never inferred from an amount or a status
  /// string parsed here.
  final bool paid;
  final String paidAtLabel;

  /// Set only when the backend refused; carries its message verbatim.
  final String error;

  const RzpQrView({
    this.ok = false,
    this.provider = '',
    this.qrId = '',
    this.rzpQrId = '',
    this.imageUrl = '',
    this.qrString = '',
    this.title = '',
    this.subtitle = '',
    this.amountLabel = '',
    this.amountRowLabel = '',
    this.noteLabel = '',
    this.paid = false,
    this.paidAtLabel = '',
    this.error = '',
  });

  static String _s(Object? v) => (v ?? '').toString();

  factory RzpQrView.fromPayload(Map<String, dynamic>? j) {
    final m = j ?? const <String, dynamic>{};
    return RzpQrView(
      ok: m['ok'] == true,
      provider: _s(m['provider']),
      qrId: _s(m['qr_id']),
      rzpQrId: _s(m['rzp_qr_id']),
      imageUrl: _s(m['image_url']),
      qrString: _s(m['qr_string']),
      title: _s(m['title']),
      subtitle: _s(m['subtitle']),
      amountLabel: _s(m['amount_label']),
      amountRowLabel: _s(m['amount_row_label']),
      noteLabel: _s(m['note_label']),
      paid: m['paid'] == true,
      paidAtLabel: _s(m['paid_at_label']),
      // The backend sends a human message when it has one (nothing_due); the
      // machine-readable `error` is the fallback so a failure is never silent.
      error: _s(m['message']).isNotEmpty ? _s(m['message']) : _s(m['error']),
    );
  }

  /// Can this card actually draw a QR? Neither source present means the sheet
  /// must show the error state instead of an empty box.
  bool get hasQr => qrString.isNotEmpty || imageUrl.isNotEmpty;

  /// Which source the QR is drawn from. `qr_string` always wins: drawing it
  /// locally means a slow connection cannot leave the customer staring at a
  /// blank square. The Razorpay-hosted image is the fallback, not the default.
  /// (`QrImageView` keeps its data private, so this is what the test asserts
  /// on — it is the decision, and the widget below is its only reader.)
  String get qrSource => qrString.isNotEmpty
      ? 'local'
      : imageUrl.isNotEmpty
          ? 'network'
          : 'none';
}

/// The Razorpay QR itself: `qr_string` drawn locally when present, otherwise
/// the Razorpay-hosted image.
class RazorpayQrImage extends StatelessWidget {
  final RzpQrView view;
  final double size;
  const RazorpayQrImage({super.key, required this.view, required this.size});

  @override
  Widget build(BuildContext context) {
    if (view.qrSource == 'local') {
      return QrImageView(
        data: view.qrString,
        version: QrVersions.auto,
        size: size,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        backgroundColor: Ds.c.surface,
      );
    }
    if (view.qrSource == 'network') {
      return Image.network(
        view.imageUrl,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => SizedBox(width: size, height: size),
      );
    }
    return SizedBox(width: size, height: size);
  }
}

/// The whole Razorpay branch of the sheet, below the heading.
///
/// Layout mirrors [PayQrCard] so the two providers look like one product:
/// subtitle, framed QR, then the detail rows.
class RazorpayQrCard extends StatelessWidget {
  final RzpQrView view;

  /// Side of the QR box. Passed in so the sheet, not this card, owns the sizing
  /// decision for the viewport it is being shown in.
  final double qrSize;

  const RazorpayQrCard({super.key, required this.view, required this.qrSize});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.all(Ds.space.x4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (view.subtitle.isNotEmpty) ...[
          Text(view.subtitle,
              textAlign: TextAlign.center, style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
        ],
        if (view.hasQr)
          Center(
            child: Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
              child: RazorpayQrImage(view: view, size: qrSize),
            ),
          ),
        SizedBox(height: Ds.space.x24),
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
        if (view.noteLabel.isNotEmpty)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: Ds.c.successSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(view.noteLabel, style: Ds.t.caption),
            ),
          ),
        if (view.paid && view.paidAtLabel.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(view.paidAtLabel, style: Ds.t.caption),
        ],
      ]),
    );
  }
}

/// The non-QR states, drawn from the payload's own words: a spinner while the
/// QR is being minted, otherwise the backend's message plus its Retry button.
/// This widget supplies no copy of its own.
class RazorpayQrStatus extends StatelessWidget {
  final bool loading;
  final String message;
  final String retryLabel;
  final VoidCallback? onRetry;

  const RazorpayQrStatus({
    super.key,
    required this.loading,
    required this.message,
    this.retryLabel = '',
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    if (loading) children.add(CircularProgressIndicator(color: Ds.c.brand));
    if (loading && message.isNotEmpty) children.add(SizedBox(height: Ds.space.x16));

    if (message.isNotEmpty) {
      children.add(Text(message,
          textAlign: TextAlign.center,
          style: loading ? Ds.t.caption : Ds.t.body));
    }

    if (!loading && retryLabel.isNotEmpty && onRetry != null) {
      children.add(SizedBox(height: Ds.space.x16));
      children.add(SizedBox(
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          onPressed: onRetry,
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.brand),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(retryLabel),
        ),
      ));
    }

    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}
