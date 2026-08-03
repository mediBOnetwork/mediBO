import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// CHANGE #642 — the payment QR sheet's visible copy, rendered verbatim.
///
/// The bug this file exists to kill: the sheet composed its own headings out of
/// three parts —
///
///   title    : '${payLabel} — mediBO'
///   subtitle : 'mediBO — ${payLabel} ${_amountLabel}'
///
/// `pay_label` ALREADY contains a formatted amount ("Pay advance ₹10,770.73"),
/// and `_amountLabel` was a second amount formatted in Dart from a raw double
/// (`₹10770.73`, no separators). So the customer saw the amount twice, in two
/// different formats, next to a payee name glued on by the app.
///
/// The backend now returns the finished strings on
/// `payment.upi.qr_sheet.{advance,balance}`, so this widget prints them and
/// composes nothing.
///
/// This file deliberately imports NO dart:html (directly or transitively).
/// `cust_pay_panel.dart` pulls in `download_bytes.dart` → `dart:html`, which
/// makes every test that imports it fail to LOAD on the VM test platform —
/// that is why test/pay_popup_test.dart, test/download_qr_test.dart and
/// test/send_qr_popup_test.dart cannot run. Keeping the payload-rendering part
/// of the sheet here is what makes it testable at all, and matches the repo's
/// DEFENSIVE IMPORT RULE.
class PayQrSheetCopy {
  /// The heading, e.g. "Pay advance ₹10,770.73" — or, for a balance that is not
  /// yet confirmed, "Balance not confirmed yet". Printed exactly as received.
  final String title;

  /// The line under the heading, e.g. "Scan the QR or use the UPI ID below".
  final String subtitle;

  /// The amount on its own, e.g. "₹10,770.73". May legitimately be absent (a
  /// balance that is not confirmed has no amount yet).
  ///
  /// NOTE: this is deliberately NOT rendered as its own row. `title` already
  /// carries the amount for every kind that has one, so printing it a second
  /// time would re-create the exact duplication this change removes. It is
  /// parsed and exposed so a future layout can use it, and so the absence case
  /// is explicit rather than inferred.
  final String amountLabel;

  /// Row labels — "UPI ID" and "Banking Name" — which used to be Dart literals.
  final String vpaLabel;
  final String payeeLabel;

  const PayQrSheetCopy({
    this.title = '',
    this.subtitle = '',
    this.amountLabel = '',
    this.vpaLabel = '',
    this.payeeLabel = '',
  });

  /// Reads one branch of `qr_sheet`. A null/absent value reads as `''` — an
  /// absence, which every widget below renders as "omit the line". Nothing here
  /// substitutes a word of its own.
  factory PayQrSheetCopy.fromPayload(Map<String, dynamic>? j) {
    final m = j ?? const <String, dynamic>{};
    return PayQrSheetCopy(
      title: (m['title'] ?? '').toString(),
      subtitle: (m['subtitle'] ?? '').toString(),
      amountLabel: (m['amount_label'] ?? '').toString(),
      vpaLabel: (m['vpa_label'] ?? '').toString(),
      payeeLabel: (m['payee_label'] ?? '').toString(),
    );
  }

  /// `kind` is the button that was tapped ('advance' | 'remaining'); the payload
  /// calls the second one 'balance'. This is a lookup key, not a user-facing
  /// string — no displayed text is chosen here.
  static PayQrSheetCopy forKind(Map<String, dynamic>? qrSheet, String kind) {
    final root = qrSheet ?? const <String, dynamic>{};
    final key = kind == 'advance' ? 'advance' : 'balance';
    final branch = root[key];
    return PayQrSheetCopy.fromPayload(
        branch is Map ? branch.cast<String, dynamic>() : null);
  }
}

/// The sheet's heading. `title` VERBATIM — no payee, no order code, no amount
/// appended.
class PayQrSheetTitle extends StatelessWidget {
  final String title;
  const PayQrSheetTitle({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    if (title.isEmpty) return const SizedBox.shrink();
    return Text(title,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        maxLines: 2,
        overflow: TextOverflow.ellipsis);
  }
}

/// The captured card: subtitle, QR, and the two copy rows. This whole widget is
/// what "Download QR" rasterises, so anything added here also lands in the
/// downloaded PNG.
class PayQrCard extends StatelessWidget {
  final PayQrSheetCopy copy;
  final String qrData;
  final String vpa;
  final String payee;

  const PayQrCard({
    super.key,
    required this.copy,
    required this.qrData,
    required this.vpa,
    required this.payee,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The subtitle, verbatim. This replaced
        // 'mediBO — ${payLabel} ${_amountLabel}' — the duplicated-amount line.
        if (copy.subtitle.isNotEmpty)
          Text(copy.subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13, color: Color(0xFF6B7280))),
        if (copy.subtitle.isNotEmpty) const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: QrImageView(
              data: qrData,
              version: QrVersions.auto,
              size: 220,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 20),
        // Row labels come from the payload too — they used to be the Dart
        // literals 'UPI ID' and 'Banking Name'.
        C330CopyRow(label: copy.vpaLabel, value: vpa),
        C330CopyRow(label: copy.payeeLabel, value: payee),
      ]),
    );
  }
}

/// Label + value + copy button. Moved here from `sup_pay_panel.dart` (CHANGE
/// #642) so the QR card can use it without dragging in that file's transitive
/// `dart:html` import, which would make this widget untestable on the VM.
///
/// Renders nothing when the value is blank — an absent value is an absence, not
/// an empty row.
class C330CopyRow extends StatelessWidget {
  final String label;
  final String? value;

  const C330CopyRow({super.key, required this.label, this.value});

  @override
  Widget build(BuildContext context) {
    final v = (value ?? '').trim();
    if (v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9CA3AF))),
            const SizedBox(height: 2),
            Text(v,
                style: const TextStyle(
                    fontSize: 14, color: Color(0xFF111827))),
          ]),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          icon: const Icon(Icons.copy, size: 18, color: Color(0xFF2E7D32)),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: v));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
              content: Text('Copied: $v',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              duration: const Duration(seconds: 1),
            ));
          },
        ),
      ]),
    );
  }
}
