import 'package:flutter/material.dart';
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
    with AutomaticKeepAliveClientMixin {
  final _repo = WaRepository();
  late Future<List<WaConversation>> _future;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _future = _repo.listConversations(widget.type);
  }

  void _refresh() {
    setState(() {
      _future = _repo.listConversations(widget.type);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<WaConversation>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
          );
        }
        if (snap.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline,
                    size: 40, color: Color(0xFF6B7280)),
                const SizedBox(height: 12),
                Text(
                  'Could not load ${widget.type} conversations.',
                  style: const TextStyle(
                      fontSize: 14, color: Color(0xFF6B7280)),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  onPressed: _refresh,
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
        final conversations = snap.data ?? [];
        if (conversations.isEmpty) {
          return Center(
            child: Text(
              'No ${widget.type} conversations yet.',
              style:
                  const TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
              textAlign: TextAlign.center,
            ),
          );
        }
        return RefreshIndicator(
          color: const Color(0xFF1B7A43),
          onRefresh: () async => _refresh(),
          child: ListView.separated(
            itemCount: conversations.length,
            separatorBuilder: (context, idx) => const Divider(
              height: 1,
              color: Color(0xFFE5E7EB),
              indent: 72,
            ),
            itemBuilder: (context, i) {
              final c = conversations[i];
              return WaConversationTile(
                conversation: c,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => WaChatScreen(conversation: c),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}
