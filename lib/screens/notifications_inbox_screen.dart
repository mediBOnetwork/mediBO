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

  Map<String, dynamic>? _page;
  final List<Map<String, dynamic>> _items = [];
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
      final map = Map<String, dynamic>.from(res as Map);
      final rows = (map['items'] as List? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      setState(() {
        _page = map;
        if (reset) _items.clear();
        _items.addAll(rows);
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

  Future<void> _openRow(Map<String, dynamic> row) async {
    final id = row['id'];
    try {
      await Supabase.instance.client.rpc('notif_inbox_mark_read',
          params: {'p_ids': [id], 'p_all': false});
    } catch (_) {/* opening matters more than the read receipt */}

    final link = (row['deep_link'] as String? ?? '').trim();
    if (!mounted) return;
    if (link.isEmpty || link == '/') {
      await _load(reset: true);
      return;
    }
    if (link.startsWith('http')) {
      // An absolute backend link (a supplier form) — hand it to the router as
      // its path; the app never rewrites a link the backend produced.
      final uri = Uri.tryParse(link);
      if (uri != null) {
        Navigator.of(context).pushNamed(uri.path);
        return;
      }
    }
    Navigator.of(context).pushNamed(link);
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(p?['title'] as String? ?? ''),
        actions: [
          if ((p?['mark_all'] as String? ?? '').isNotEmpty && _items.isNotEmpty)
            TextButton(
              onPressed: _markAllRead,
              child: Text(p!['mark_all'] as String),
            ),
        ],
      ),
      body: _buildBody(p),
    );
  }

  Widget _buildBody(Map<String, dynamic>? p) {
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
        title: p?['empty_title'] as String? ?? '',
        hint: p?['empty_hint'] as String? ?? '',
      );
    }

    final hasMore = (p?['has_more'] as bool?) ?? false;
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
                        child: Text(p?['load_more'] as String? ?? ''),
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

  final Map<String, dynamic> row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final unread = (row['unread'] as bool?) ?? false;
    final title = row['title'] as String? ?? '';
    final body = row['body'] as String? ?? '';
    final when = row['when_label'] as String? ?? '';
    final channel = row['channel_label'] as String? ?? '';

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
                    if (body.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(body, style: Ds.t.caption),
                    ],
                    SizedBox(height: Ds.space.x8),
                    Row(
                      children: [
                        if (channel.isNotEmpty) ...[
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
