// CHANGE #293 — "Pay & Place Order": the QR a customer sees the instant their
// own order is created, in Payment Gateway mode.
//
// #291 built the QR but never reached checkout, so a customer could only pay
// after hunting the order down in My Orders. This sheet closes that gap and
// nothing else: it mints the SAME QR `razorpay-qr-create` hands the My Orders
// panel (that RPC reuses an open QR, so an order never gets a second one), then
// asks the backend whether the webhook has confirmed it yet and flips itself
// when the backend says paid.
//
// It words nothing. Title, subtitle, amount, note, the paid line and every
// button label arrive finished in the payload. No dart:html here — the sheet is
// pumpable on the Dart VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'razorpay_qr_card.dart';

/// How often to ask the backend whether the webhook has landed. The QR is
/// scanned on another device, so there is nothing local to listen to.
const Duration kCheckoutPayPollInterval = Duration(seconds: 4);

class CheckoutPaySheet extends StatefulWidget {
  final String orderId;

  /// `checkout_action()` — pay_title, paid_toast, and the button words.
  final Map<String, dynamic> checkout;

  /// `payment.upi.razorpay` — loading / error / retry / expired copy.
  final Map<String, dynamic> razorpayCopy;

  /// The order-placed strings the caller already has (`place_order_v2()`),
  /// shown above the QR so the buyer sees what they are paying for.
  final String orderCode;
  final String amountDisplay;

  /// Injected in tests. Production hits `razorpay-qr-create` and
  /// `rzp_order_paid()`.
  final Future<Map<String, dynamic>> Function(String orderId)? createQr;
  final Future<Map<String, dynamic>> Function(String orderId)? checkPaid;

  /// Closes the sheet. The caller decides what "done" means for its screen.
  final VoidCallback? onDone;

  const CheckoutPaySheet({
    super.key,
    required this.orderId,
    this.checkout = const <String, dynamic>{},
    this.razorpayCopy = const <String, dynamic>{},
    this.orderCode = '',
    this.amountDisplay = '',
    this.createQr,
    this.checkPaid,
    this.onDone,
  });

  @override
  State<CheckoutPaySheet> createState() => CheckoutPaySheetState();
}

class CheckoutPaySheetState extends State<CheckoutPaySheet> {
  RzpQrView? _view;
  bool _loading = true;
  String _error = '';
  bool _paid = false;
  Timer? _poll;

  String _copy(String key) => (widget.razorpayCopy[key] ?? '').toString();
  String _act(String key) => (widget.checkout[key] ?? '').toString();

  @override
  void initState() {
    super.initState();
    _mint();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _mint() async {
    final create = widget.createQr;
    if (create == null) {
      setState(() {
        _loading = false;
        _error = _copy('error_label');
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    Map<String, dynamic> raw;
    try {
      raw = await create(widget.orderId);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _copy('error_label');
      });
      return;
    }
    if (!mounted) return;
    final view = RzpQrView.fromPayload(raw);
    setState(() {
      _loading = false;
      if (view.ok && view.hasQr) {
        _view = view;
        _paid = view.paid;
        _error = '';
      } else {
        // The backend's own message outranks the machine slug; only when it
        // sent neither does the generic error copy stand in.
        _error = view.error.isNotEmpty ? view.error : _copy('error_label');
      }
    });
    if (_view != null && !_paid) _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    final check = widget.checkPaid;
    if (check == null) return;
    _poll = Timer.periodic(kCheckoutPayPollInterval, (_) async {
      Map<String, dynamic> res;
      try {
        res = await check(widget.orderId);
      } catch (_) {
        return;
      }
      if (!mounted) return;
      if (res['paid'] == true) {
        _poll?.cancel();
        final v = res['view'];
        setState(() {
          _paid = true;
          if (v is Map) _view = RzpQrView.fromPayload(v.cast<String, dynamic>());
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final view = _view;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_act('pay_title').isNotEmpty)
            Text(_act('pay_title'),
                textAlign: TextAlign.center, style: Ds.t.subtitle),
          if (widget.orderCode.isNotEmpty || widget.amountDisplay.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              [widget.orderCode, widget.amountDisplay]
                  .where((s) => s.isNotEmpty)
                  .join('  ·  '),
              textAlign: TextAlign.center,
              style: Ds.t.caption,
            ),
          ],
          SizedBox(height: Ds.space.x16),
          if (view != null)
            RazorpayQrCard(view: view, qrSize: kRzpQrSide)
          else
            RazorpayQrStatus(
              loading: _loading,
              message: _loading ? _copy('loading_label') : _error,
              retryLabel: _loading ? '' : _copy('retry_label'),
              onRetry: _loading ? null : _mint,
            ),
          if (_paid && _act('paid_toast').isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.successSoft,
                borderRadius: Ds.r.rCard,
              ),
              child: Text(_act('paid_toast'),
                  textAlign: TextAlign.center, style: Ds.t.bodyStrong),
            ),
          ],
          if (_act('done_label').isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: widget.onDone,
                child: Text(_act('done_label')),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
