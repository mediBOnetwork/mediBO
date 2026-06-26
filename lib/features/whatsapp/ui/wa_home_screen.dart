import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import '../data/wa_repository.dart';
import '../models/wa_conversation.dart';
import 'wa_conversation_tile.dart';
import 'wa_chat_screen.dart';

class WaHomeScreen extends StatelessWidget {
  const WaHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF5F6F8),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          centerTitle: false,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new,
                size: 20, color: Color(0xFF1B7A43)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: const Text(
            'WhatsApp',
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Color(0xFF111827)),
          ),
          bottom: const TabBar(
            labelColor: Color(0xFF1B7A43),
            unselectedLabelColor: Color(0xFF6B7280),
            indicatorColor: Color(0xFF1B7A43),
            indicatorWeight: 2,
            tabs: [
              Tab(text: 'Customers'),
              Tab(text: 'Suppliers'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ConversationListView(type: 'customer'),
            _ConversationListView(type: 'supplier'),
          ],
        ),
      ),
    );
  }
}

class _ConversationListView extends StatefulWidget {
  final String type;
  const _ConversationListView({required this.type});

  @override
  State<_ConversationListView> createState() => _ConversationListViewState();
}

class _ConversationListViewState extends State<_ConversationListView>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  final _repo = WaRepository();

  // CHANGE #209: mutable in-memory list so Realtime can patch it live.
  List<WaConversation> _conversations = [];
  bool _loading = true;
  Object? _error;

  // CHANGE #207: phones whose badge was optimistically cleared on chat open.
  final Set<String> _locallyRead = {};

  // CHANGE #209: Supabase Realtime channel for live inbox updates.
  RealtimeChannel? _waListChannel;
  bool _listFirstSubscribed = false;
  bool _listHadError = false;
  // Phone of the conversation currently open from this list (skip unread bump).
  String? _openPhone;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _subscribeList();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final ch = _waListChannel;
    _waListChannel = null;
    if (ch != null) {
      Supabase.instance.client.removeChannel(ch);
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.listConversations(widget.type);
      if (!mounted) return;
      setState(() {
        _conversations = list;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  // CHANGE #209: subscribe to all INSERTs on whatsapp_messages (admin sees all).
  void _subscribeList() {
    if (_waListChannel != null) return;
    _waListChannel = Supabase.instance.client
        .channel('wa_inbox_list_${widget.type}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'whatsapp_messages',
          callback: (payload) => _onListInsert(payload.newRecord),
        )
        .subscribe((status, [err]) => _onListChannelStatus(status, err));
  }

  void _onListChannelStatus(dynamic status, Object? err) {
    final s = status.toString().toLowerCase();
    if (s.contains('subscribed') || s.contains('joined')) {
      if (!_listFirstSubscribed) {
        _listFirstSubscribed = true;
        RenderLog.write('c209_wa_realtime_list_subscribed', 1);
      }
      if (_listHadError) {
        _listHadError = false;
        _silentResync();
      }
    } else if (s.contains('error') ||
        s.contains('closed') ||
        s.contains('timed')) {
      _listHadError = true;
    }
  }

  void _onListInsert(Map<String, dynamic> row) {
    if (!mounted) return;
    final phone = (row['sender_phone'] ?? '').toString();
    if (phone.isEmpty) return;
    final text = (row['text'] ?? row['caption'] ?? '').toString();
    final direction = (row['direction'] ?? 'in').toString();
    final at = _parseAt(row['received_at']);

    final idx = _conversations.indexWhere((c) => c.senderPhone == phone);
    if (idx >= 0) {
      final existing = _conversations[idx];
      final bumpUnread = direction == 'in' &&
          _openPhone != phone &&
          !_locallyRead.contains(phone);
      final updated = WaConversation(
        senderPhone: existing.senderPhone,
        senderType: existing.senderType,
        name: existing.name,
        label: existing.label,
        linkedSupplier: existing.linkedSupplier,
        total: existing.total + 1,
        lastAt: at ?? existing.lastAt,
        lastText: text.isNotEmpty ? text : existing.lastText,
        unread: bumpUnread ? existing.unread + 1 : existing.unread,
      );
      setState(() {
        _conversations.removeAt(idx);
        _conversations.insert(0, updated);
      });
      RenderLog.write('c209_wa_realtime_list_insert', _conversations.length);
    } else {
      // New contact not yet in this tab's list. We can't be sure of the
      // sender_type from a raw message row, so re-sync from the RPC (which
      // applies the correct type filter) instead of guessing the tab.
      RenderLog.write('c209_wa_realtime_list_insert', _conversations.length);
      _silentResync();
    }
  }

  static DateTime? _parseAt(dynamic v) {
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  // CHANGE #209: silent re-sync on reconnect/resume — refetch list, no spinner.
  Future<void> _silentResync() async {
    try {
      final list = await _repo.listConversations(widget.type);
      if (!mounted) return;
      setState(() {
        _conversations = list;
        _error = null;
        _loading = false;
      });
      RenderLog.write('c209_wa_realtime_resync', list.length);
    } catch (_) {
      // tolerate — backstop only.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _silentResync();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    // CHANGE #209: no manual refresh button — inbox auto-refreshes via Realtime.
    RenderLog.write('c209_refresh_button_removed', 1);
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40, color: Color(0xFF6B7280)),
            const SizedBox(height: 12),
            Text(
              'Could not load ${widget.type} conversations.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF1B7A43)),
                foregroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final conversations = _conversations;
    if (conversations.isEmpty) {
      return Center(
        child: Text(
          'No ${widget.type} conversations yet.',
          style: const TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
          textAlign: TextAlign.center,
        ),
      );
    }
    return RefreshIndicator(
      // CHANGE #209: pull-to-refresh kept as a silent backstop; no refresh button.
      color: const Color(0xFF1B7A43),
      onRefresh: () async => _silentResync(),
      child: ListView.separated(
        itemCount: conversations.length,
        separatorBuilder: (context, idx) => const Divider(
          height: 1,
          color: Color(0xFFE5E7EB),
          indent: 72,
        ),
        itemBuilder: (context, i) {
          final raw = conversations[i];
          // CHANGE #207: optimistic badge clear for opened chats.
          final c = _locallyRead.contains(raw.senderPhone)
              ? raw.copyWith(unread: 0)
              : raw;
          return WaConversationTile(
            conversation: c,
            onTap: () async {
              // Optimistically clear the badge immediately.
              setState(() {
                _locallyRead.add(c.senderPhone);
                _openPhone = c.senderPhone;
              });
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => WaChatScreen(conversation: c),
                ),
              );
              _openPhone = null;
              // Re-sync so badges reflect the real backend state.
              if (mounted) _silentResync();
            },
          );
        },
      ),
    );
  }
}
