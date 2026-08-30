// CHANGE #293 — "Pay & Place Order": the payment sheet a customer sees the
// instant their own order is created, in Payment Gateway mode.
// CHANGE #304 — that sheet was QR-only, and a QR is a scan-from-ANOTHER-device
// product. On this Razorpay account qr_string comes back NULL, so the sheet
// could only ever draw a picture and could never launch PhonePe/GPay on the
// phone holding it: five QRs minted, zero payments, and a customer stuck on
// "Preparing your QR…".
//
// The sheet now renders whichever branch the BACKEND chose. `pay_mode` comes
// from `rzp_pay_mode()` — sdk for a real customer paying their own order, qr
// when the payer is on a different phone (an admin acting-as, a WhatsApp
// order), manual when the gateway is off. Flutter never picks: it prints what
// it is given.
//
// It words nothing. Title, subtitle, amount, note, button labels, the waiting
// line and the paid line all arrive finished in the payload. No dart:html here
// — the sheet is pumpable on the Dart VM.
import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'razorpay_qr_card.dart';
import 'rzp_checkout_card.dart';

/// How often to ask the backend whether the webhook has landed.
///
/// This poll is not a nicety. The SDK/checkout return is a UI hint and nothing
/// more — the order is marked paid ONLY by the verified webhook, so the sheet
/// has to ask the backend rather than believe the customer's own return.
const Duration kCheckoutPayPollInterval = Duration(seconds: 4);

class CheckoutPaySheet extends StatefulWidget {
  final String orderId;

  /// `checkout_action()` — pay_title, paid_toast, and the button words.
  final Map<String, dynamic> checkout;

  /// `payment.upi.razorpay` — loading / error / retry / expired copy, plus the
  /// #304 checkout copy (sdk_opening_label, sdk_waiting_label, …).
  final Map<String, dynamic> razorpayCopy;

  /// The order-placed strings the caller already has (`place_order_v2()`),
  /// shown above the payment block so the buyer sees what they are paying for.
  final String orderCode;
  final String amountDisplay;

  /// Injected in tests. Production hits `razorpay-checkout-create` and
  /// `rzp_checkout_state()`.
  final Future<Map<String, dynamic>> Function(String orderId)? createPayment;
  final Future<Map<String, dynamic>> Function(String orderId)? checkPaid;

  /// Opens the backend's pay_url. Injected so this widget never reaches for a
  /// platform channel. Returns false when the launch was refused.
  final Future<bool> Function(String url)? openUrl;

  /// Closes the sheet. The caller decides what "done" means for its screen.
  final VoidCallback? onDone;

  const CheckoutPaySheet({
    super.key,
    required this.orderId,
    this.checkout = const <String, dynamic>{},
    this.razorpayCopy = const <String, dynamic>{},
    this.orderCode = '',
    this.amountDisplay = '',
    this.createPayment,
    this.checkPaid,
    this.openUrl,
    this.onDone,
  });

  @override
  State<CheckoutPaySheet> createState() => CheckoutPaySheetState();
}

class CheckoutPaySheetState extends State<CheckoutPaySheet> {
  /// Which branch the BACKEND chose for this session and this order.
  String _payMode = '';

  RzpQrView? _qrView;
  RzpCheckoutView? _payView;

  bool _loading = true;
  bool _opening = false;
  bool _handedOff = false;
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
    final create = widget.createPayment;
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

    // The mode is whatever the backend said. An absent pay_mode is the old
    // QR contract, so an older payload keeps working unchanged.
    final mode = (raw['pay_mode'] ?? '').toString();
    setState(() {
      _loading = false;
      _payMode = mode;
      _qrView = null;
      _payView = null;
      _error = '';

      // 'link' is the same payable object minted for a chat send; both are
      // the checkout branch. Anything else is the QR contract.
      if (mode == 'sdk' || mode == 'link') {
        final v = RzpCheckoutView.fromPayload(raw);
        if (v.ok && v.hasPayUrl) {
          _payView = v;
          _paid = v.paid;
        } else {
          _error = v.error.isNotEmpty ? v.error : _copy('error_label');
        }
      } else {
        final v = RzpQrView.fromPayload(raw);
        if (v.ok && v.hasQr) {
          _qrView = v;
          _paid = v.paid;
        } else {
          // The backend's own message outranks the machine slug; only when it
          // sent neither does the generic error copy stand in.
          _error = v.error.isNotEmpty ? v.error : _copy('error_label');
        }
      }
    });
    if ((_payView != null || _qrView != null) && !_paid) _startPolling();
  }

  /// Hand the customer to Razorpay Checkout. This NEVER marks anything paid:
  /// the return from the UPI app is speed, the webhook is truth.
  Future<void> _pay() async {
    final view = _payView;
    final open = widget.openUrl;
    if (view == null || !view.hasPayUrl || open == null) return;
    setState(() => _opening = true);
    bool launched = false;
    try {
      launched = await open(view.payUrl);
    } catch (_) {
      launched = false;
    }
    if (!mounted) return;
    setState(() {
      _opening = false;
      _handedOff = launched;
      if (!launched) _error = _copy('sdk_open_failed_label');
    });
    if (launched) _startPolling();
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
      // Only the backend's own paid flag flips this sheet.
      if (res['paid'] == true) {
        _poll?.cancel();
        final v = res['view'];
        setState(() {
          _paid = true;
          if (v is Map) {
            final m = v.cast<String, dynamic>();
            if (_payMode == 'sdk') {
              _payView = RzpCheckoutView.fromPayload(m);
            } else {
              _qrView = RzpQrView.fromPayload(m);
            }
          }
        });
      }
    });
  }

  Widget _body() {
    final pay = _payView;
    if (pay != null) {
      return RzpCheckoutCard(
        view: pay,
        onPay: _pay,
        opening: _opening,
        openingLabel: _copy('sdk_opening_label'),
        waiting: _handedOff && !_paid,
        waitingLabel: _copy('sdk_waiting_label'),
        waitingHint: _copy('sdk_waiting_hint'),
      );
    }
    final qr = _qrView;
    if (qr != null) return RazorpayQrCard(view: qr, qrSize: kRzpQrSide);
    return RazorpayQrStatus(
      loading: _loading,
      message: _loading ? _copy('loading_label') : _error,
      retryLabel: _loading ? '' : _copy('retry_label'),
      onRetry: _loading ? null : _mint,
    );
  }

  @override
  Widget build(BuildContext context) {
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
          _body(),
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
