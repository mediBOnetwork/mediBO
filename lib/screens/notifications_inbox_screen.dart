// CHANGE #298 — the in-app inbox (spec item 6). Every event that was sent on
// ANY channel is readable here, so nothing is ever missed because a push was
// declined or a WhatsApp never arrived.
//
// The screen prints notif_inbox_list() verbatim: the page title, the empty
// state, the "Mark all read" and "Load more" captions, each row's title, body,
// timestamp label and channel label are all backend strings. The only thing
// Dart decides is layout.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../models/notification_inbox.dart';
import '../services/ui_copy.dart';
import '../utils/render_log.dart';

class NotificationsInboxScreen extends StatefulWidget {
  const NotificationsInboxScreen({super.key});

  @override
  State<NotificationsInboxScreen> createState() =>
      _NotificationsInboxScreenState();
}

class _NotificationsInboxScreenState extends State<NotificationsInboxScreen> {
  static const _pageSize = 30;

  InboxPage? _page;
  List<InboxItem> _items = const [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final res = await Supabase.instance.client.rpc('notif_inbox_list',
          params: {'p_limit': _pageSize, 'p_offset': reset ? 0 : _items.length});
      if (!mounted) return;
      final page = InboxPage.fromJson(Map<String, dynamic>.from(res as Map));
      setState(() {
        _page = page;
        // InboxPage.append dedupes by id: a shifting sort near an offset
        // boundary must never paint the same notification twice.
        _items = reset ? page.items : InboxPage.append(_items, page.items);
        _loading = false;
        _loadingMore = false;
      });
      RenderLog.write('c298_inbox_rows', _items.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _markAllRead() async {
    try {
      await Supabase.instance.client
          .rpc('notif_inbox_mark_read', params: {'p_all': true});
      await _load(reset: true);
    } catch (_) {/* the list still stands; the next open re-reads */}
  }

  Future<void> _openRow(InboxItem row) async {
    try {
      await Supabase.instance.client.rpc('notif_inbox_mark_read',
          params: {'p_ids': [row.id], 'p_all': false});
    } catch (_) {/* opening matters more than the read receipt */}

    if (!mounted) return;
    final route = row.route;
    if (route == null) {
      // The backend gave this event nowhere to go — stay put and just clear
      // the unread dot. Never fall back to the app home (spec item 5).
      await _load(reset: true);
      return;
    }
    Navigator.of(context).pushNamed(route);
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p?.title ?? ''),
        actions: [
          if (p?.showMarkAll ?? false)
            TextButton(onPressed: _markAllRead, child: Text(p!.markAllLabel)),
        ],
      ),
      body: _buildBody(p),
    );
  }

  Widget _buildBody(InboxPage? p) {
    if (_loading) return const _InboxSkeleton();

    if (_error != null) {
      // Backend copy, not the raw exception: UiCopy.t returns '' for a key the
      // backend has not written, never a Dart literal.
      return _Centered(
        title: UiCopy.t('notif_inbox.error'),
        hint: '',
        action: TextButton(
          onPressed: () => _load(reset: true),
          child: Text(UiCopy.t('notif_inbox.retry')),
        ),
      );
    }

    if (_items.isEmpty) {
      return _Centered(
        title: p?.emptyTitle ?? '',
        hint: p?.emptyHint ?? '',
      );
    }

    final hasMore = p?.hasMore ?? false;
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        itemCount: _items.length + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x8),
        itemBuilder: (context, i) {
          if (i >= _items.length) {
            return Padding(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
              child: Center(
                child: _loadingMore
                    ? const CircularProgressIndicator()
                    : TextButton(
                        onPressed: () => _load(),
                        child: Text(p?.loadMoreLabel ?? ''),
                      ),
              ),
            );
          }
          return _InboxCard(row: _items[i], onTap: () => _openRow(_items[i]));
        },
      ),
    );
  }
}

class _InboxCard extends StatelessWidget {
  const _InboxCard({required this.row, required this.onTap});

  final InboxItem row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = row.unread;
    final title = row.title;
    final body = row.body;
    final when = row.whenLabel;
    final channel = row.channelLabel;

    return Material(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: Ds.space.x8,
                height: Ds.space.x8,
                margin: EdgeInsets.only(top: Ds.space.x4, right: Ds.space.x12),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: unread ? Ds.c.brand : Colors.transparent,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Ds.t.body.copyWith(
                        fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
                      ),
                    ),
                    if (row.hasBody) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(body, style: Ds.t.caption),
                    ],
                    SizedBox(height: Ds.space.x8),
                    Row(
                      children: [
                        if (row.hasChannel) ...[
                          Container(
                            padding: EdgeInsets.symmetric(
                                horizontal: Ds.space.x8),
                            decoration: BoxDecoration(
                              color: Ds.c.brandSoft,
                              borderRadius: Ds.r.rChip,
                            ),
                            child: Text(channel, style: Ds.t.caption),
                          ),
                          SizedBox(width: Ds.space.x8),
                        ],
                        Expanded(
                          child: Text(when,
                              style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.title, required this.hint, this.action});

  final String title;
  final String hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.all(Ds.space.x32),
      children: [
        SizedBox(height: Ds.space.x48),
        Text(title, textAlign: TextAlign.center, style: Ds.t.title),
        if (hint.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(hint, textAlign: TextAlign.center, style: Ds.t.caption),
        ],
        if (action != null) ...[
          SizedBox(height: Ds.space.x24),
          Center(child: action!),
        ],
      ],
    );
  }
}

class _InboxSkeleton extends StatelessWidget {
  const _InboxSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x12),
      itemCount: 6,
      separatorBuilder: (_, _) => SizedBox(height: Ds.space.x8),
      itemBuilder: (_, _) => Container(
        height: Ds.touch.listRowMinHeight,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
      ),
    );
  }
}
