import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../customer/order_feedback_sheet.dart';

/// CHANGE #697 — the public feedback page, reached from the WhatsApp link
/// `/feedback/<token>`. No auth: the token in the URL is the authorisation,
/// exactly the way `/stock-update/<token>` already works. A pharmacy that
/// never opens the app still gets asked, and a low score still opens a ticket.
///
/// Every string is `order_feedback_form()`'s — the card, the thank-you, and
/// all three refusals (unknown link / already used / expired). This file owns
/// only which star is lit, and that lives one layer down in [OrderFeedbackCard].
class OrderFeedbackFormScreen extends StatefulWidget {
  final String token;
  const OrderFeedbackFormScreen({super.key, required this.token});

  /// Test seam, same shape as StockUpdateFormScreen.rpcTransport.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<OrderFeedbackFormScreen> createState() =>
      _OrderFeedbackFormScreenState();
}

class _OrderFeedbackFormScreenState extends State<OrderFeedbackFormScreen> {
  bool _loading = true;
  bool _busy = false;

  Map<String, dynamic> _payload = const {};
  String _error = '';
  String _done = '';

  @override
  void initState() {
    super.initState();
    RenderLog.write(
        'c697_feedback_page_init',
        widget.token.length >= 8
            ? widget.token.substring(0, 8)
            : widget.token);
    _load();
  }

  Map<String, dynamic>? _asMap(dynamic raw) {
    final data = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return data is Map ? data.cast<String, dynamic>() : null;
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final map = _asMap(await OrderFeedbackFormScreen.rpc(
          'order_feedback_form', {'p_token': widget.token}));
      if (!mounted) return;
      if (map == null) {
        setState(() {
          _error = 'invalid';
          _loading = false;
        });
        return;
      }
      setState(() {
        _payload = map;
        // ok:false is a page the backend wrote, not an exception. The message
        // it carries is printed verbatim — there is no Dart wording here.
        _error = map['ok'] == true ? '' : (map['error'] ?? 'invalid').toString();
        _loading = false;
      });
      RenderLog.write('c697_feedback_page', _error.isEmpty ? 1 : 0);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'invalid';
          _loading = false;
        });
      }
    }
  }

  Future<void> _submit(OrderFeedbackAnswer a) async {
    setState(() => _busy = true);
    try {
      final res =
          _asMap(await OrderFeedbackFormScreen.rpc('order_feedback_submit_token', {
        'p_token': widget.token,
        'p_scores': a.scores,
        'p_nps': a.nps,
        'p_reason': a.reason,
        'p_chips': a.chips,
      }));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _done = (res?['message'] ?? '').toString();
        if (res?['ok'] != true) _error = (res?['error'] ?? '').toString();
      });
      RenderLog.write('c697_feedback_page_submit', a.nps);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Container(
                padding: EdgeInsets.all(Ds.space.x16),
                decoration: BoxDecoration(
                  color: Ds.c.surface,
                  borderRadius: Ds.r.rCard,
                  boxShadow: Ds.elevation.e1,
                ),
                child: _body(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 4; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: Container(
                height: Ds.space.x24,
                decoration: BoxDecoration(
                    color: Ds.c.bg, borderRadius: Ds.r.rChip),
              ),
            ),
        ],
      );
    }
    if (_done.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: Ds.c.success),
          SizedBox(height: Ds.space.x12),
          Text(_done, style: Ds.t.body),
        ],
      );
    }
    if (_error.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text((_payload['title'] ?? '').toString(), style: Ds.t.title),
          SizedBox(height: Ds.space.x8),
          Text((_payload['message'] ?? '').toString(), style: Ds.t.bodySecondary),
        ],
      );
    }
    return OrderFeedbackCard(
      payload: _payload,
      busy: _busy,
      onSubmit: _submit,
    );
  }
}
