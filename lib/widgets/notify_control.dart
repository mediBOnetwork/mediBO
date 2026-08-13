import 'package:flutter/material.dart';

import '../data/medicine_repository.dart';
import '../data/storefront_labels.dart';
import '../models/storefront_p3.dart';
import '../utils/toast.dart';

typedef NotifyRequest = Future<NotifyResult> Function(String productId);

/// CHANGE #638 — the "Notify me" control for an out-of-stock product.
///
/// Shared by the compact card and the product page so both can never drift.
/// Every string here comes from the backend: the idle label and the subscribed
/// label from `storefront_ui_label`, and the confirmation toast from
/// `stock_notify_request`'s own response, printed verbatim.
///
/// There is no polling. Subscribed state changes only when an RPC says so —
/// either the request that just succeeded, or `stock_notify_status` read once
/// when the product page loads.
class NotifyControl extends StatefulWidget {
  final String productId;

  /// Whether the viewer is already subscribed, as the backend reported it.
  final bool initiallySubscribed;

  /// Card-sized when true, product-page-sized when false.
  final bool compact;

  /// Idle label. Defaults to the cached backend label.
  final String? notifyLabel;

  /// Subscribed label. Defaults to the cached backend label.
  final String? subscribedLabel;

  /// Test seam — production calls the repository.
  final NotifyRequest? request;

  const NotifyControl({
    super.key,
    required this.productId,
    this.initiallySubscribed = false,
    this.compact = true,
    this.notifyLabel,
    this.subscribedLabel,
    this.request,
  });

  @override
  State<NotifyControl> createState() => _NotifyControlState();
}

class _NotifyControlState extends State<NotifyControl> {
  late bool _subscribed = widget.initiallySubscribed;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant NotifyControl old) {
    super.didUpdateWidget(old);
    // The product page learns the real state after stock_notify_status
    // resolves; adopt it unless the user has already subscribed here.
    if (old.initiallySubscribed != widget.initiallySubscribed &&
        widget.initiallySubscribed) {
      _subscribed = true;
    }
  }

  String get _idleLabel =>
      widget.notifyLabel ?? StorefrontLabels.get(StorefrontLabels.kNotify);

  String get _doneLabel =>
      widget.subscribedLabel ??
      StorefrontLabels.get(StorefrontLabels.kNotifySubscribed);

  Future<void> _tap() async {
    if (_busy || _subscribed) return;
    setState(() => _busy = true);

    final req = widget.request ??
        (id) => MedicineRepository().stockNotifyRequest(id);

    // The await MUST be able to throw without leaving the button dead. Before
    // this guard, a single network hiccup on the RPC left `_busy` stuck true
    // forever, so the Notify button "worked sometimes and not others" until a
    // full page reload. Reset in `finally`, always.
    NotifyResult? res;
    try {
      res = await req(widget.productId);
    } catch (_) {
      // The backend owns all wording — a thrown RPC just re-enables the tap.
    } finally {
      if (mounted) setState(() => _busy = false);
    }

    if (!mounted || res == null) return;
    final r = res;

    // The one error the app acts on: send them to log in, then let them try
    // again. Everything else surfaces the backend's own wording.
    if (r.loginRequired) {
      Navigator.of(context).pushNamed('/login');
      return;
    }

    if (r.ok) {
      if (r.toast.isNotEmpty) showToast(context, r.toast);
      setState(() => _subscribed = r.subscribed);
      return;
    }

    if (r.toast.isNotEmpty) showToast(context, r.toast, isError: true);
  }

  @override
  Widget build(BuildContext context) {
    final label = _subscribed ? _doneLabel : _idleLabel;

    // A label the backend never sent is not a label this app may invent, so
    // an empty one renders nothing rather than a hardcoded "Notify me".
    if (label.isEmpty) return const SizedBox.shrink();

    final icon = _subscribed
        ? Icons.notifications_active
        : Icons.notifications_none_outlined;
    final fg = _subscribed ? Colors.white : const Color(0xFF8A5A11);
    final bg = _subscribed ? const Color(0xFF8A5A11) : const Color(0xFFFFF7ED);

    if (widget.compact) {
      return SizedBox(
        height: 28,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: _tap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE0B978)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: fg),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return FilledButton.icon(
      onPressed: _subscribed ? null : _tap,
      icon: Icon(icon, size: 18),
      label: Text(
        label,
        style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700),
      ),
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        disabledBackgroundColor: bg,
        disabledForegroundColor: fg,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
