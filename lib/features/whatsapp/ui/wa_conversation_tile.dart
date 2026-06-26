import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/wa_conversation.dart';

class WaConversationTile extends StatelessWidget {
  final WaConversation conversation;
  final VoidCallback onTap;

  const WaConversationTile({
    super.key,
    required this.conversation,
    required this.onTap,
  });

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    if (msgDay == today) return DateFormat('HH:mm').format(dt);
    if (dt.year == now.year) return DateFormat('d MMM').format(dt);
    return DateFormat('d MMM yy').format(dt);
  }

  Color _avatarColor(String senderType) {
    switch (senderType) {
      case 'customer':
        return const Color(0xFF1B7A43);
      case 'supplier':
        return const Color(0xFF1E40AF);
      default:
        return const Color(0xFF6B7280);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = conversation;
    final initial = c.displayName.isNotEmpty
        ? c.displayName[0].toUpperCase()
        : '?';
    final preview = c.lastText.isNotEmpty ? c.lastText : '[no preview]';
    final previewStyle = c.lastText.isNotEmpty
        ? const TextStyle(fontSize: 13, color: Color(0xFF6B7280))
        : const TextStyle(
            fontSize: 13,
            color: Color(0xFF9CA3AF),
            fontStyle: FontStyle.italic);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: _avatarColor(c.senderType),
              child: Text(
                initial,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.displayName,
                    style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827)),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    preview,
                    style: previewStyle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(c.lastAt),
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 4),
                if (c.hasUnread)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1B7A43),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${c.unread}',
                      style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                          fontWeight: FontWeight.w600),
                    ),
                  )
                else
                  const SizedBox(height: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
