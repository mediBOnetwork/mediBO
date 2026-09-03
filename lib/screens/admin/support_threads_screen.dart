// lib/screens/admin/support_threads_screen.dart — CHANGE #713
//
// The other end of the conversation: every customer message waiting on an
// answer, and every call somebody owes a customer. ONE screen for the zone
// partner and for the mediBO office — thread_inbox() answers a partner with
// their own zone and the office with all of them, so this file contains no
// zone filter, no role branch and no "am I an admin" question.
//
// Two tabs because they are two questions with two answers ("who is waiting on
// a reply" / "who is waiting on a phone call"), not one list with a mode
// switch. Both are rendered verbatim: the filter chips carry their own counts,
// the tag chips their own tones, the SLA sentence and its colour arrive
// finished, and the call button is the platform's masked-call descriptor.

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/masked_call_service.dart';
import '../../services/order_thread_api.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/masked_call_button.dart';
import '../order_thread_screen.dart';
import '../partner/partner_ui.dart';

class SupportThreadsScreen extends StatefulWidget {
  const SupportThreadsScreen({super.key});

  @override
  State<SupportThreadsScreen> createState() => _SupportThreadsScreenState();
}

class _SupportThreadsScreenState extends State<SupportThreadsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  Map<String, dynamic>? _inbox;
  Map<String, dynamic>? _tasks;
  bool _loading = true;
  String _filter = 'waiting';
  String _tag = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final inbox = await OrderThreadApi.inbox(filter: _filter, tag: _tag);
      final tasks = await OrderThreadApi.callTasks();
      RenderLog.write(
          'c713_inbox',
          'ok=${inbox['ok']} view=${inbox['view']} '
              'rows=${threadRows(inbox['rows']).length} '
              'tasks=${threadRows(tasks['rows']).length}');
      if (!mounted) return;
      setState(() {
        _inbox = inbox;
        _tasks = tasks;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final inbox = _inbox;
    // This screen is PUSHED as a bare route by shellExtraRouteScreen(), so it
    // owns its own Scaffold — the same as PartnerTasksScreen next to it. A
    // TabBar with no Material ancestor throws, which is exactly how the first
    // deploy of this change rendered an empty page.
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(threadStr(inbox ?? const {}, 'title')),
        bottom: (inbox == null || inbox['ok'] != true)
            ? null
            : TabBar(
                controller: _tabs,
                tabs: [
                  Tab(text: threadStr(inbox, 'title')),
                  Tab(text: threadStr(_tasks ?? const {}, 'title')),
                ],
              ),
      ),
      body: _body(inbox),
    );
  }

  Widget _body(Map<String, dynamic>? inbox) {
    if (_loading) return const PartnerSkeleton(rows: 6);
    if (inbox == null || inbox['ok'] != true) {
      return PartnerNotice(
        text: threadStr(inbox ?? const {}, 'message'),
        onRetry: _load,
        retryLabel: threadStr(inbox ?? const {}, 'title'),
      );
    }
    return Column(
      children: [
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              _InboxTab(
                d: inbox,
                filter: _filter,
                tag: _tag,
                onFilter: (k) {
                  setState(() => _filter = k);
                  _load();
                },
                onTag: (k) {
                  setState(() => _tag = _tag == k ? '' : k);
                  _load();
                },
                onOpen: (threadId) async {
                  await showOrderThread(context, threadId: threadId);
                  await _load();
                },
              ),
              _TasksTab(
                d: _tasks ?? const {},
                onLogged: _load,
                onOpen: (threadId) async {
                  await showOrderThread(context, threadId: threadId);
                  await _load();
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _InboxTab extends StatelessWidget {
  const _InboxTab({
    required this.d,
    required this.filter,
    required this.tag,
    required this.onFilter,
    required this.onTag,
    required this.onOpen,
  });

  final Map<String, dynamic> d;
  final String filter;
  final String tag;
  final ValueChanged<String> onFilter;
  final ValueChanged<String> onTag;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final rows = threadRows(d['rows']);
    final zone = threadStr(d, 'zone_label');
    return Column(
      // stretch, so the two horizontal chip rows start on the same left edge
      // as the zone line and the cards below them. Without it a Column centres
      // a child that does not fill the width, and on a desktop viewport the
      // chips floated to the middle of an otherwise left-aligned screen.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x4),
          child: Row(
            children: [
              // The zone this list is clamped to, in the BACKEND's words —
              // "All zones" for the office, the zone's own name for a partner.
              Expanded(child: Text(zone, style: Ds.t.caption)),
            ],
          ),
        ),
        _ChipRow(
          items: threadRows(d['filters']),
          selected: filter,
          onTap: onFilter,
          showCount: true,
        ),
        _ChipRow(
          items: threadRows(d['tags']),
          selected: tag,
          onTap: onTag,
          showCount: false,
        ),
        Expanded(
          child: rows.isEmpty
              ? PartnerNotice(
                  title: threadStr(d, 'empty_title'),
                  text: threadStr(d, 'empty_note'),
                )
              : ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: [
                    for (final r in rows)
                      PartnerCard(
                        onTap: () => onOpen(threadStr(r, 'thread_id')),
                        child: _InboxRow(r: r),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

/// One chip row, for both the filters (which carry counts) and the tags (which
/// do not). The keys and the labels are the payload's; a key this build has
/// never heard of is still tappable, because nothing here switches on it.
class _ChipRow extends StatelessWidget {
  const _ChipRow({
    required this.items,
    required this.selected,
    required this.onTap,
    required this.showCount,
  });

  final List<Map<String, dynamic>> items;
  final String selected;
  final ValueChanged<String> onTap;
  final bool showCount;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.start,
        children: [
          for (final it in items) ...[
            ChoiceChip(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x8),
              selected: selected == threadStr(it, 'key'),
              label: Text(showCount && threadInt(it, 'count') > 0
                  ? '${threadStr(it, 'label')} ${threadInt(it, 'count')}'
                  : threadStr(it, 'label')),
              onSelected: (_) => onTap(threadStr(it, 'key')),
            ),
            SizedBox(width: Ds.space.x8),
          ],
        ],
      ),
    );
  }
}

class _InboxRow extends StatelessWidget {
  const _InboxRow({required this.r});

  final Map<String, dynamic> r;

  @override
  Widget build(BuildContext context) {
    final unread = threadInt(r, 'unread');
    final ref = threadStr(r, 'ticket_ref');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(threadStr(r, 'title'), style: Ds.t.subtitle)),
            if (unread > 0)
              PartnerChip(text: '$unread', tone: 'danger'),
          ],
        ),
        SizedBox(height: Ds.space.x4),
        Text(threadStr(r, 'customer_label'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            if (threadStr(r, 'tag_label').isNotEmpty)
              PartnerChip(
                  text: threadStr(r, 'tag_label'), tone: threadStr(r, 'tag_tone')),
            if (threadStr(r, 'status_label').isNotEmpty)
              PartnerChip(
                  text: threadStr(r, 'status_label'),
                  tone: threadStr(r, 'status_tone')),
            if (threadStr(r, 'sla_label').isNotEmpty)
              PartnerChip(
                  text: threadStr(r, 'sla_label'), tone: threadStr(r, 'sla_tone')),
            if (ref.isNotEmpty) PartnerChip(text: ref, tone: 'info'),
          ],
        ),
        if (threadStr(r, 'last_line').isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(threadStr(r, 'last_line'),
              style: Ds.t.body, maxLines: 2, overflow: TextOverflow.ellipsis),
        ],
        SizedBox(height: Ds.space.x8),
        Row(
          children: [
            Expanded(child: Text(threadStr(r, 'owner_label'), style: Ds.t.caption)),
            if (threadStr(r, 'last_by').isNotEmpty)
              Text(threadStr(r, 'last_by'), style: Ds.t.caption),
            SizedBox(width: Ds.space.x8),
            Text(threadStr(r, 'at_label'), style: Ds.t.caption),
          ],
        ),
      ],
    );
  }
}

class _TasksTab extends StatelessWidget {
  const _TasksTab({
    required this.d,
    required this.onLogged,
    required this.onOpen,
  });

  final Map<String, dynamic> d;
  final Future<void> Function() onLogged;
  final ValueChanged<String> onOpen;

  Future<void> _log(BuildContext context, Map<String, dynamic> row) async {
    final outcomes = threadRows(d['outcomes']);
    final note = TextEditingController();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(threadStr(d, 'log_cta'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: note,
              decoration:
                  InputDecoration(hintText: threadStr(d, 'note_hint')),
            ),
            SizedBox(height: Ds.space.x16),
            // The options are the payload's. An outcome the backend did not
            // send simply cannot be picked.
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final o in outcomes)
                  ActionChip(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x12, vertical: Ds.space.x8),
                    label: Text(threadStr(o, 'label')),
                    onPressed: () => Navigator.of(ctx).pop(threadStr(o, 'code')),
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
          ],
        ),
      ),
    );
    if (picked == null || picked.isEmpty) return;
    final res = await OrderThreadApi.logCallOutcome(
        threadStr(row, 'task_id'), picked, note.text.trim());
    if (!context.mounted) return;
    final msg = threadStr(res, 'toast').isNotEmpty
        ? threadStr(res, 'toast')
        : threadStr(res, 'message');
    if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
    await onLogged();
  }

  @override
  Widget build(BuildContext context) {
    final rows = threadRows(d['rows']);
    if (rows.isEmpty) {
      return PartnerNotice(
        title: threadStr(d, 'empty_title'),
        text: threadStr(d, 'empty_note'),
      );
    }
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (final r in rows)
          PartnerCard(
            onTap: () => onOpen(threadStr(r, 'thread_id')),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(threadStr(r, 'title'), style: Ds.t.subtitle),
                SizedBox(height: Ds.space.x4),
                Text(threadStr(r, 'customer_label'), style: Ds.t.caption),
                if (threadStr(r, 'order_label').isNotEmpty)
                  Text(threadStr(r, 'order_label'), style: Ds.t.caption),
                SizedBox(height: Ds.space.x8),
                PartnerChip(
                    text: threadStr(r, 'due_label'),
                    tone: threadStr(r, 'due_tone')),
                SizedBox(height: Ds.space.x12),
                Row(
                  children: [
                    // The call descriptor carries no phone number: has:false,
                    // a missing label or a missing role each render nothing.
                    Expanded(
                      child: () {
                        final t = MaskedCallTarget.from(
                            threadStr(r, 'order_id'), r['call']);
                        if (t == null) return const SizedBox.shrink();
                        return MaskedCallButton(target: t, dense: true);
                      }(),
                    ),
                    SizedBox(width: Ds.space.x8),
                    SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton(
                        onPressed: () => _log(context, r),
                        child: Text(threadStr(d, 'log_cta')),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
