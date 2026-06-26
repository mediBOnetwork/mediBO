import 'package:flutter/material.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import '../data/wa_repository.dart';
import '../models/wa_conversation.dart';
import '../models/wa_message.dart';
import 'wa_message_bubble.dart';

class WaChatScreen extends StatefulWidget {
  final WaConversation conversation;

  const WaChatScreen({super.key, required this.conversation});

  @override
  State<WaChatScreen> createState() => _WaChatScreenState();
}

class _WaChatScreenState extends State<WaChatScreen> {
  final _repo = WaRepository();
  final _textController = TextEditingController();
  final _scroll = ScrollController();
  late Future<List<WaMessage>> _future;
  List<WaMessage> _messages = [];
  bool _sending = false;
  bool _loggedOpen = false;

  @override
  void initState() {
    super.initState();
    _loadThread();
  }

  @override
  void dispose() {
    _textController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _loadThread() {
    _future = _repo.getThread(widget.conversation.senderPhone).then((msgs) {
      if (mounted) {
        setState(() => _messages = msgs);
        if (!_loggedOpen) {
          _loggedOpen = true;
          RenderLog.write('c204_wa_thread_opened', msgs.length);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
      return msgs;
    });
    if (mounted) setState(() {});
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
  }

  Future<void> _sendReply() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final result = await _repo.sendReply(
        to: widget.conversation.senderPhone,
        text: text,
      );
      _textController.clear();
      final waId = result['wa_message_id']?.toString() ?? '';
      final optimistic = WaMessage(
        id: waId.isNotEmpty ? waId : 'opt_${DateTime.now().millisecondsSinceEpoch}',
        direction: 'out',
        msgType: 'text',
        text: text,
        receivedAt: DateTime.now(),
      );
      if (mounted) {
        setState(() {
          // De-dupe by id: remove if already present (from a refresh), then append
          _messages.removeWhere((m) => waId.isNotEmpty && m.id == waId);
          _messages.add(optimistic);
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
    } on WaSendException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.humanMessage),
            backgroundColor: const Color(0xFF991B1B),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not send. Please try again.'),
            backgroundColor: Color(0xFF991B1B),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _senderTypeLabel(String type) {
    switch (type) {
      case 'customer':
        return 'Customer';
      case 'supplier':
        return 'Supplier';
      default:
        return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;
    return Scaffold(
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              conv.displayName,
              style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF111827)),
              overflow: TextOverflow.ellipsis,
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _senderTypeLabel(conv.senderType),
                    style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF065F46),
                        fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF374151)),
            tooltip: 'Refresh thread',
            onPressed: _loadThread,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<List<WaMessage>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    _messages.isEmpty) {
                  return const Center(
                    child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
                  );
                }
                if (snap.hasError && _messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline,
                            size: 40, color: Color(0xFF6B7280)),
                        const SizedBox(height: 12),
                        const Text(
                          'Could not load messages.',
                          style: TextStyle(
                              fontSize: 14, color: Color(0xFF6B7280)),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: _loadThread,
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
                final msgs = _messages;
                if (msgs.isEmpty) {
                  return const Center(
                    child: Text(
                      'No messages yet.',
                      style:
                          TextStyle(fontSize: 15, color: Color(0xFF6B7280)),
                    ),
                  );
                }
                return RefreshIndicator(
                  color: const Color(0xFF1B7A43),
                  onRefresh: () async => _loadThread(),
                  child: ListView.builder(
                    controller: _scroll,
                    padding:
                        const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                    itemCount: msgs.length,
                    itemBuilder: (ctx, i) => WaMessageBubble(
                      message: msgs[i],
                      repo: _repo,
                    ),
                  ),
                );
              },
            ),
          ),
          _ReplyBar(
            controller: _textController,
            sending: _sending,
            onSend: _sendReply,
          ),
        ],
      ),
    );
  }
}

class _ReplyBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  const _ReplyBar({
    required this.controller,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: 'Type a reply…',
                    hintStyle: const TextStyle(
                        color: Color(0xFF9CA3AF), fontSize: 14),
                    filled: true,
                    fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: const TextStyle(
                      fontSize: 14, color: Color(0xFF111827)),
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => onSend(),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 44,
                height: 44,
                child: sending
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF1B7A43)),
                      )
                    : Material(
                        color: const Color(0xFF1B7A43),
                        borderRadius: BorderRadius.circular(22),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: onSend,
                          child: const Icon(Icons.send,
                              color: Colors.white, size: 20),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
