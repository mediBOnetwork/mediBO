// CMD #452 — feature_gaps #132: support was one "Contact Us" link in the
// storefront footer and a fire-and-forget form. A customer with a problem on a
// specific order had nowhere to raise it and nothing to come back to.
//
// This is the buyer's side of a ticket: raise one against an order, read the
// thread, reply, mark it sorted, reopen it. The reference, the status word, its
// tone, both timestamps and every button caption come from the RPC. The only
// thing decided here is which topic was tapped and what was typed.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/customer_care_service.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'order_cancel_sheet.dart'
    show CareSheetShell, CareSheetSkeleton, CareRefusal, CareReasonRow;

/// "Need help with this order?" — the sheet the order card opens.
/// Returns true when a ticket was raised, so the card can refresh its badge.
Future<bool> showOrderHelpSheet(BuildContext context, String? orderId) async {
  final raised = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _OrderHelpSheet(orderId: orderId),
  );
  return raised == true;
}

class _OrderHelpSheet extends StatefulWidget {
  final String? orderId;
  const _OrderHelpSheet({this.orderId});

  @override
  State<_OrderHelpSheet> createState() => _OrderHelpSheetState();
}

class _OrderHelpSheetState extends State<_OrderHelpSheet> {
  Map<String, dynamic>? _p;
  final _msg = TextEditingController();
  String _topic = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _msg.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await CustomerCare.supportTopics(widget.orderId);
    if (!mounted) return;
    setState(() => _p = p);
    RenderLog.write('c452_help_sheet', careRows(p['topics']).length);
  }

  Future<void> _submit() async {
    if (_topic.isEmpty || _msg.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final res = await CustomerCare.openTicket(
        topicCode: _topic, message: _msg.text, orderId: widget.orderId);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res['ok'] != true) {
      showToast(context, careStr(res, 'message'), isError: true);
      return;
    }
    showToast(context, careStr(res, 'toast'));
    final ticket = careMap(res['ticket']);
    Navigator.of(context).pop(true);
    await showSupportThread(context, careStr(ticket, 'id'));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return CareSheetShell(
      child: p == null
          ? const CareSheetSkeleton()
          : p['ok'] != true
              ? CareRefusal(message: careStr(p, 'message'))
              : _form(p),
    );
  }

  Widget _form(Map<String, dynamic> p) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(careStr(p, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x24),
        Text(careStr(p, 'topic_label'), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x8),
        for (final t in careRows(p['topics']))
          CareReasonRow(
            label: careStr(t, 'label'),
            selected: _topic == careStr(t, 'code'),
            onTap: () => setState(() => _topic = careStr(t, 'code')),
          ),
        SizedBox(height: Ds.space.x16),
        Text(careStr(p, 'message_label'), style: Ds.t.bodyStrong),
        SizedBox(height: Ds.space.x8),
        TextField(
          controller: _msg,
          minLines: 3,
          maxLines: 6,
          style: Ds.t.body,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: careStr(p, 'message_hint'),
            hintStyle: Ds.t.caption,
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
                borderRadius: Ds.r.rButton, borderSide: BorderSide.none),
          ),
        ),
        SizedBox(height: Ds.space.x24),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed:
                (_topic.isEmpty || _msg.text.trim().isEmpty || _busy)
                    ? null
                    : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: Ds.c.brand,
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: Text(careStr(p, 'cta')),
          ),
        ),
      ],
    );
  }
}

// ── the thread ───────────────────────────────────────────────────────────────

/// One ticket, both sides of it. Opened from the help sheet after raising, and
/// from the Help requests list.
Future<void> showSupportThread(BuildContext context, String ticketId) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SupportThreadSheet(ticketId: ticketId),
    );

class _SupportThreadSheet extends StatefulWidget {
  final String ticketId;
  const _SupportThreadSheet({required this.ticketId});

  @override
  State<_SupportThreadSheet> createState() => _SupportThreadSheetState();
}

class _SupportThreadSheetState extends State<_SupportThreadSheet> {
  Map<String, dynamic>? _p;
  final _reply = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final p = await CustomerCare.thread(widget.ticketId);
    if (!mounted) return;
    setState(() => _p = p);
    RenderLog.write('c452_help_thread', careRows(p['messages']).length);
  }

  Future<void> _send() async {
    if (_reply.text.trim().isEmpty || _busy) return;
    setState(() => _busy = true);
    final res = await CustomerCare.reply(widget.ticketId, _reply.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['ok'] == true) {
        _reply.clear();
        _p = res;
      }
    });
    if (res['ok'] != true) {
      showToast(context, careStr(res, 'message'), isError: true);
    }
  }

  Future<void> _setStatus(String status) async {
    setState(() => _busy = true);
    final res = await CustomerCare.setStatus(widget.ticketId, status);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (res['ok'] == true) _p = res;
    });
    if (res['ok'] == true) showToast(context, careStr(res, 'toast'));
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return CareSheetShell(
      child: p == null
          ? const CareSheetSkeleton()
          : p['ok'] != true
              ? CareRefusal(message: careStr(p, 'message'))
              : _thread(p),
    );
  }

  Widget _thread(Map<String, dynamic> p) {
    final t = careMap(p['ticket']);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Expanded(child: Text(careStr(t, 'topic_label'), style: Ds.t.title)),
          SupportStatusChip(ticket: t),
        ]),
        SizedBox(height: Ds.space.x4),
        Text(careStr(t, 'ref_label'), style: Ds.t.caption),
        if (careStr(t, 'order_label').isNotEmpty)
          Text(careStr(t, 'order_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x24),
        for (final m in careRows(p['messages'])) _Bubble(message: m),
        SizedBox(height: Ds.space.x16),
        TextField(
          controller: _reply,
          minLines: 2,
          maxLines: 5,
          style: Ds.t.body,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: careStr(p, 'reply_hint'),
            hintStyle: Ds.t.caption,
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(
                borderRadius: Ds.r.rButton, borderSide: BorderSide.none),
          ),
        ),
        SizedBox(height: Ds.space.x12),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed:
                (_reply.text.trim().isEmpty || _busy) ? null : _send,
            style: FilledButton.styleFrom(
              backgroundColor: Ds.c.brand,
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            child: Text(careStr(p, 'reply_cta')),
          ),
        ),
        if (p['can_close'] == true) ...[
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: TextButton(
              onPressed: _busy ? null : () => _setStatus('closed'),
              child: Text(careStr(p, 'close_cta'),
                  style: Ds.t.body.copyWith(color: Ds.c.textSecondary)),
            ),
          ),
        ],
        if (p['can_reopen'] == true) ...[
          SizedBox(height: Ds.space.x8),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _setStatus('open'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton)),
              child: Text(careStr(p, 'reopen_cta')),
            ),
          ),
        ],
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final Map<String, dynamic> message;
  const _Bubble({required this.message});

  @override
  Widget build(BuildContext context) {
    // `role` is the backend's word for who spoke; the side it sits on is the
    // only thing derived from it.
    final mine = careStr(message, 'role') == 'customer';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x12),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: mine ? Ds.c.brandSoft : Ds.c.bg,
          borderRadius: Ds.r.rCard,
        ),
        child: Column(
          crossAxisAlignment:
              mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(careStr(message, 'body'), style: Ds.t.body),
            SizedBox(height: Ds.space.x4),
            Text(
                '${careStr(message, 'who_label')} · ${careStr(message, 'at_label')}',
                style: Ds.t.caption),
          ],
        ),
      ),
    );
  }
}

/// The status word and its tone, both from the payload.
class SupportStatusChip extends StatelessWidget {
  final Map<String, dynamic> ticket;
  const SupportStatusChip({super.key, required this.ticket});

  @override
  Widget build(BuildContext context) {
    final label = careStr(ticket, 'status_label');
    if (label.isEmpty) return const SizedBox.shrink();
    final tone = careStr(ticket, 'status_tone');
    final fg = switch (tone) {
      'success' => Ds.c.success,
      'warning' => Ds.c.warning,
      'danger' => Ds.c.danger,
      _ => Ds.c.info,
    };
    final bg = switch (tone) {
      'success' => Ds.c.successSoft,
      'warning' => Ds.c.warningSoft,
      'danger' => Ds.c.dangerSoft,
      _ => Ds.c.infoSoft,
    };
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption.copyWith(color: fg)),
    );
  }
}

// ── the customer's list of tickets ───────────────────────────────────────────

class MySupportRequestsScreen extends StatefulWidget {
  const MySupportRequestsScreen({super.key});

  @override
  State<MySupportRequestsScreen> createState() =>
      _MySupportRequestsScreenState();
}

class _MySupportRequestsScreenState extends State<MySupportRequestsScreen> {
  Map<String, dynamic>? _p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await CustomerCare.myTickets();
    if (!mounted) return;
    setState(() => _p = p);
    RenderLog.write('c452_help_list', careRows(p['tickets']).length);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final tickets = careRows(p?['tickets']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(careStr(p, 'title'))),
      body: p == null
          ? Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: const CareSheetSkeleton())
          : tickets.isEmpty
              ? _Empty(
                  title: careStr(p, 'empty_title'),
                  note: careStr(p, 'empty_note'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: EdgeInsets.all(Ds.space.x16),
                    itemCount: tickets.length,
                    itemBuilder: (_, i) => _TicketRow(
                      ticket: tickets[i],
                      onTap: () async {
                        await showSupportThread(
                            context, careStr(tickets[i], 'id'));
                        await _load();
                      },
                    ),
                  ),
                ),
    );
  }
}

class _TicketRow extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final VoidCallback onTap;
  const _TicketRow({required this.ticket, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rCard,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                    child: Text(careStr(ticket, 'topic_label'),
                        style: Ds.t.bodyStrong)),
                SupportStatusChip(ticket: ticket),
              ]),
              SizedBox(height: Ds.space.x4),
              Text(careStr(ticket, 'ref_label'), style: Ds.t.caption),
              if (careStr(ticket, 'order_label').isNotEmpty)
                Text(careStr(ticket, 'order_label'), style: Ds.t.caption),
              if (careStr(ticket, 'last_line').isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(careStr(ticket, 'last_line'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Ds.t.body),
              ],
              SizedBox(height: Ds.space.x4),
              Text(careStr(ticket, 'updated_label'), style: Ds.t.caption),
            ],
          ),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  final String title;
  final String note;
  const _Empty({required this.title, required this.note});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
          SizedBox(height: Ds.space.x8),
          Text(note, style: Ds.t.caption, textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
