// CMD #452 — the other side of feature_gaps #132. A ticket nobody can answer
// is a suggestion box, so the buyer's help request lands here with its order,
// its reference and the same thread the customer is reading.
//
// The filter chips, the status words, their tones, both timestamps and the
// customer's name are all `support_inbox()`'s strings; this screen renders them
// in payload order and decides nothing. `support_inbox()` refuses a non-admin
// itself — the screen is not the gate.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/customer_care_service.dart';
import '../../utils/render_log.dart';
import '../customer/order_help_sheet.dart'
    show showSupportThread, SupportStatusChip;

class AdminSupportInboxScreen extends StatefulWidget {
  const AdminSupportInboxScreen({super.key});

  @override
  State<AdminSupportInboxScreen> createState() =>
      _AdminSupportInboxScreenState();
}

class _AdminSupportInboxScreenState extends State<AdminSupportInboxScreen> {
  Map<String, dynamic>? _p;
  String _filter = 'open';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await CustomerCare.inbox(_filter);
    if (!mounted) return;
    setState(() => _p = p);
    RenderLog.write('c452_support_inbox', careRows(p['tickets']).length);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    final tickets = careRows(p?['tickets']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(careStr(p, 'title'))),
      body: p == null
          // A skeleton, not a bare spinner: the row shape is already known.
          ? ListView.builder(
              padding: EdgeInsets.all(Ds.space.x16),
              itemCount: 4,
              itemBuilder: (_, _) => Container(
                height: Ds.space.x48 + Ds.space.x32,
                margin: EdgeInsets.only(bottom: Ds.space.x12),
                decoration: BoxDecoration(
                    color: Ds.c.surface, borderRadius: Ds.r.rCard),
              ),
            )
          : p['ok'] != true
              ? Center(
                  child: Padding(
                    padding: EdgeInsets.all(Ds.space.x24),
                    child: Text(careStr(p, 'message'), style: Ds.t.body),
                  ),
                )
              : Column(children: [
                  Padding(
                    padding: EdgeInsets.all(Ds.space.x16),
                    child: Row(children: [
                      for (final f in careRows(p['filters'])) ...[
                        _FilterChip(
                          label: careStr(f, 'label'),
                          selected: _filter == careStr(f, 'key'),
                          onTap: () {
                            setState(() => _filter = careStr(f, 'key'));
                            _load();
                          },
                        ),
                        SizedBox(width: Ds.space.x8),
                      ],
                    ]),
                  ),
                  Expanded(
                    child: tickets.isEmpty
                        ? Center(
                            child: Padding(
                              padding: EdgeInsets.all(Ds.space.x32),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(careStr(p, 'empty_title'),
                                        style: Ds.t.subtitle,
                                        textAlign: TextAlign.center),
                                    SizedBox(height: Ds.space.x8),
                                    Text(careStr(p, 'empty_note'),
                                        style: Ds.t.caption,
                                        textAlign: TextAlign.center),
                                  ]),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _load,
                            child: ListView.builder(
                              padding: EdgeInsets.fromLTRB(Ds.space.x16, 0,
                                  Ds.space.x16, Ds.space.x24),
                              itemCount: tickets.length,
                              itemBuilder: (_, i) => _InboxRow(
                                ticket: tickets[i],
                                onTap: () async {
                                  await showSupportThread(
                                      context, careStr(tickets[i], 'id'));
                                  await _load();
                                },
                              ),
                            ),
                          ),
                  ),
                ]),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brandSoft : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(label,
            style: Ds.t.body
                .copyWith(color: selected ? Ds.c.brand : Ds.c.textSecondary)),
      ),
    );
  }
}

class _InboxRow extends StatelessWidget {
  final Map<String, dynamic> ticket;
  final VoidCallback onTap;
  const _InboxRow({required this.ticket, required this.onTap});

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
                    child: Text(careStr(ticket, 'customer_label'),
                        style: Ds.t.bodyStrong)),
                SupportStatusChip(ticket: ticket),
              ]),
              SizedBox(height: Ds.space.x4),
              Text(
                  [
                    careStr(ticket, 'topic_label'),
                    careStr(ticket, 'ref_label'),
                    careStr(ticket, 'order_label'),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: Ds.t.caption),
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
