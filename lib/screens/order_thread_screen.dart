// lib/screens/order_thread_screen.dart — CHANGE #713
//
// ONE conversation screen, three audiences. The customer, the zone partner and
// the mediBO office all open this widget on the same payload; what differs is
// what order_thread_get() PUT in that payload, not a role branch drawn here.
//
// The two facts that make that work:
//   * `mine` is the backend's, not "did I write it". The customer's side owns
//     the customer's messages; our side owns partner AND admin messages,
//     because to a customer they are one counterparty called "mediBO".
//   * `who_label` is finished text. The customer never learns that a partner
//     answered rather than the office — that collapse is made in SQL, and
//     renaming the brand is an UPDATE to ui_copy, not a deploy.
//
// The owner line, the SLA sentence and its tone are absent from a customer's
// payload (empty strings), so the rows simply do not render. There is no
// `if (isCustomer)` anywhere in this file.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';
import '../services/order_thread_api.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';
import 'partner/partner_ui.dart';

/// Open the conversation for an order (the customer's and the order card's
/// door) or for a thread id (the inbox's).
///
/// It returns nothing: reading a thread already changed the unread counts the
/// caller drew its badge from, so the caller refetches unconditionally rather
/// than trusting a boolean this screen would have had to guess at.
Future<void> showOrderThread(BuildContext context,
    {String? orderId, String? threadId}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => OrderThreadScreen(orderId: orderId, threadId: threadId),
    ));

class OrderThreadScreen extends StatefulWidget {
  const OrderThreadScreen({super.key, this.orderId, this.threadId});

  final String? orderId;
  final String? threadId;

  @override
  State<OrderThreadScreen> createState() => _OrderThreadScreenState();
}

class _OrderThreadScreenState extends State<OrderThreadScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;
  bool _sending = false;
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final d = await OrderThreadApi.get(
          orderId: widget.orderId, threadId: widget.threadId);
      RenderLog.write(
          'c713_thread',
          'ok=${d['ok']} view=${d['view']} '
              'msgs=${threadRows(d['messages']).length} '
              'unread=${d['unread_from_customer']}');
      if (!mounted) return;
      setState(() {
        _d = d;
        _loading = false;
      });
      _toBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  void _toBottom() {
    // After a frame, so the list has its extent. A conversation opens where it
    // left off, which is the newest message.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final d = _d;
      final res = await OrderThreadApi.post(
        threadId: threadStr(d ?? const {}, 'thread_id').isEmpty
            ? null
            : threadStr(d!, 'thread_id'),
        orderId: widget.orderId,
        body: text,
      );
      if (!mounted) return;
      final msg = threadStr(res, 'toast').isNotEmpty
          ? threadStr(res, 'toast')
          : threadStr(res, 'message');
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      if (res['ok'] == true) {
        _input.clear();
        // post() answers with the whole thread, so the reload is free: the
        // screen re-renders the SERVER's new state rather than appending a
        // message it composed itself.
        setState(() {
          _d = res;
          _sending = false;
        });
        _toBottom();
        return;
      }
      setState(() => _sending = false);
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _close() async {
    final d = _d;
    if (d == null) return;
    final res = await OrderThreadApi.setStatus(threadStr(d, 'thread_id'), 'closed');
    if (!mounted) return;
    final msg = threadStr(res, 'message');
    if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
    if (res['ok'] == true) setState(() => _d = res);
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(threadStr(d ?? const {}, 'title')),
        actions: [
          if (d != null && d['ok'] == true && threadStr(d, 'view') != 'customer')
            IconButton(
              tooltip: threadStr(d, 'status_label'),
              onPressed: threadStr(d, 'status') == 'closed' ? null : _close,
              icon: const Icon(Icons.check_circle_outline),
            ),
        ],
      ),
      body: () {
        if (_loading) return const PartnerSkeleton(rows: 5);
        if (d == null || d['ok'] != true) {
          return PartnerNotice(
            text: threadStr(d ?? const {}, 'message'),
            onRetry: _load,
            retryLabel: threadStr(d ?? const {}, 'send_cta'),
          );
        }
        return Column(
          children: [
            _Header(d: d),
            Expanded(child: _Messages(d: d, scroll: _scroll)),
            _Composer(
              d: d,
              controller: _input,
              busy: _sending,
              onSend: _send,
            ),
          ],
        );
      }(),
    );
  }
}

/// The order, the tag, the status — and, for our side only, the owner and the
/// clock. Every one of those is an empty string in a customer's payload, so
/// this widget renders nothing extra for them without asking who is looking.
class _Header extends StatelessWidget {
  const _Header({required this.d});

  final Map<String, dynamic> d;

  @override
  Widget build(BuildContext context) {
    final order = threadStr(d, 'order_label');
    final customer = threadStr(d, 'customer_label');
    final tag = threadStr(d, 'tag_label');
    final status = threadStr(d, 'status_label');
    final owner = threadStr(d, 'owner_label');
    final sla = threadStr(d, 'sla_label');
    final brand = threadStr(d, 'brand_note');

    return Container(
      width: double.infinity,
      color: Ds.c.surface,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (order.isNotEmpty) Text(order, style: Ds.t.subtitle),
          if (customer.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(customer, style: Ds.t.caption),
          ],
          if (tag.isNotEmpty || status.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                if (tag.isNotEmpty)
                  PartnerChip(text: tag, tone: threadStr(d, 'tag_tone')),
                if (status.isNotEmpty)
                  PartnerChip(text: status, tone: threadStr(d, 'status_tone')),
                if (sla.isNotEmpty)
                  PartnerChip(text: sla, tone: threadStr(d, 'sla_tone')),
              ],
            ),
          ],
          if (owner.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(owner, style: Ds.t.caption),
          ],
          if (brand.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(brand, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

class _Messages extends StatelessWidget {
  const _Messages({required this.d, required this.scroll});

  final Map<String, dynamic> d;
  final ScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final rows = threadRows(d['messages']);
    if (rows.isEmpty) {
      return PartnerNotice(
        title: threadStr(d, 'empty_title'),
        text: threadStr(d, 'empty_note'),
      );
    }
    return ListView.builder(
      controller: scroll,
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: rows.length,
      itemBuilder: (_, i) => _Bubble(m: rows[i]),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.m});

  final Map<String, dynamic> m;

  @override
  Widget build(BuildContext context) {
    // `mine` is the payload's. A partner reading the thread sees the office's
    // messages on their OWN side, because to the customer both are mediBO.
    final mine = m['mine'] == true;
    final body = threadStr(m, 'body');
    final atts = threadRows(m['attachments']);
    final source = threadStr(m, 'source_label');
    final read = threadStr(m, 'read_label');
    final system = threadStr(m, 'role') == 'system';

    if (system) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
        child: Center(
          child: Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            decoration: BoxDecoration(
                color: Ds.c.infoSoft, borderRadius: Ds.r.rChip),
            child: Text(body,
                style: Ds.t.caption.copyWith(color: Ds.c.info),
                textAlign: TextAlign.center),
          ),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Column(
        crossAxisAlignment:
            mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Text(threadStr(m, 'who_label'), style: Ds.t.caption),
              if (source.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                Text(source, style: Ds.t.caption),
              ],
            ],
          ),
          SizedBox(height: Ds.space.x4),
          // Proportional, never a hard-coded width: the same bubble has to sit
          // on a 360 px phone and a 1280 px desktop.
          ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.78),
            child: Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: mine ? Ds.c.successSoft : Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (body.isNotEmpty) Text(body, style: Ds.t.body),
                  for (final a in atts) ...[
                    SizedBox(height: Ds.space.x8),
                    _Attachment(a: a),
                  ],
                ],
              ),
            ),
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Text(threadStr(m, 'at_label'), style: Ds.t.caption),
              if (read.isNotEmpty) ...[
                SizedBox(width: Ds.space.x8),
                Text(read, style: Ds.t.caption),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// An attachment is the backend's bucket + path. This widget never builds a
/// URL: it asks the platform for a signed one at tap time, which is the same
/// rule the supplier-records documents follow.
class _Attachment extends StatelessWidget {
  const _Attachment({required this.a});

  final Map<String, dynamic> a;

  /// Injectable opener, so the protected test asserts on the bucket and path
  /// that would have been opened without any network. Production signs the
  /// backend's own bucket + path under the signed-in session — this widget
  /// never builds a URL of its own, which is why a private bucket stays
  /// private.
  static Future<void> Function(String bucket, String path)? openFn;

  static Future<void> _open(String bucket, String path) async {
    if (openFn != null) return openFn!(bucket, path);
    if (bucket.isEmpty || path.isEmpty) return;
    final url = await Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, 3600);
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final name = threadStr(a, 'name');
    final label = threadStr(a, 'open_label');
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton.icon(
        onPressed: () => _open(threadStr(a, 'bucket'), threadStr(a, 'path')),
        icon: Icon(a['is_image'] == true
            ? Icons.image_outlined
            : Icons.description_outlined),
        label: Text(name.isEmpty ? label : name),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.d,
    required this.controller,
    required this.busy,
    required this.onSend,
  });

  final Map<String, dynamic> d;
  final TextEditingController controller;
  final bool busy;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    if (d['can_write'] != true) return const SizedBox.shrink();
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.all(Ds.space.x12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                decoration:
                    InputDecoration(hintText: threadStr(d, 'compose_hint')),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: busy ? null : onSend,
                child: Text(threadStr(d, 'send_cta')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
