import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../data/wa_repository.dart';
import '../models/wa_message.dart';

class WaMessageBubble extends StatefulWidget {
  final WaMessage message;
  final WaRepository repo;

  const WaMessageBubble({
    super.key,
    required this.message,
    required this.repo,
  });

  @override
  State<WaMessageBubble> createState() => _WaMessageBubbleState();
}

class _WaMessageBubbleState extends State<WaMessageBubble> {
  Future<String>? _signedUrlFuture;

  @override
  void initState() {
    super.initState();
    if (widget.message.hasMedia) {
      _signedUrlFuture = widget.repo.signedUrl(
        widget.message.effectiveBucket,
        widget.message.filePath!,
      );
    }
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    if (msgDay == today) return DateFormat('HH:mm').format(dt);
    return DateFormat('d MMM HH:mm').format(dt);
  }

  void _showFullscreen(BuildContext ctx, String url) {
    showDialog<void>(
      context: ctx,
      builder: (_) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: EdgeInsets.zero,
        child: Stack(children: [
          SizedBox.expand(
            child: InteractiveViewer(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (ctx2, err, st) => const Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: Colors.white, size: 48),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(ctx).pop(),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Widget _buildMediaContent(String kind, String signedUrl) {
    switch (kind) {
      case 'image':
        return GestureDetector(
          onTap: () => _showFullscreen(context, signedUrl),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              signedUrl,
              width: double.infinity,
              height: 220,
              fit: BoxFit.cover,
              loadingBuilder: (ctx, child, progress) {
                if (progress == null) return child;
                return const SizedBox(
                  height: 220,
                  child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1B7A43)),
                  ),
                );
              },
              errorBuilder: (ctx2, err, st) => const SizedBox(
                height: 80,
                child: Center(
                  child: Icon(Icons.broken_image_outlined,
                      size: 36, color: Color(0xFF9CA3AF)),
                ),
              ),
            ),
          ),
        );
      case 'pdf':
        return _OpenButton(
          label: 'Open document',
          icon: Icons.picture_as_pdf_outlined,
          onTap: () => _openUrl(signedUrl),
        );
      case 'audio':
        return _OpenButton(
          label: 'Open audio',
          icon: Icons.headphones_outlined,
          onTap: () => _openUrl(signedUrl),
        );
      case 'video':
        return _OpenButton(
          label: 'Open video',
          icon: Icons.play_circle_outline,
          onTap: () => _openUrl(signedUrl),
        );
      default:
        return _OpenButton(
          label: 'Open file',
          icon: Icons.attach_file_outlined,
          onTap: () => _openUrl(signedUrl),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isOut = msg.isOut;
    final maxWidth = MediaQuery.of(context).size.width * 0.75;

    final bubbleColor =
        isOut ? const Color(0xFF1B7A43) : const Color(0xFFECFDF5);
    final textColor = isOut ? Colors.white : const Color(0xFF111827);
    final timeColor =
        isOut ? Colors.white70 : const Color(0xFF9CA3AF);

    final isLocation = msg.msgType == 'location';
    final isContact = msg.msgType == 'contact';

    Widget bubbleContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isLocation)
          _TypeHeader(
            icon: Icons.location_on_outlined,
            label: 'Location',
            isOut: isOut,
          ),
        if (isContact)
          _TypeHeader(
            icon: Icons.person_outline,
            label: 'Contact',
            isOut: isOut,
          ),
        if (msg.hasMedia && _signedUrlFuture != null)
          FutureBuilder<String>(
            future: _signedUrlFuture,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFF1B7A43)),
                    ),
                  ),
                );
              }
              if (snap.hasError || snap.data == null) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    Icon(Icons.error_outline,
                        size: 16, color: Color(0xFF9CA3AF)),
                    SizedBox(width: 4),
                    Text('Media unavailable',
                        style: TextStyle(
                            fontSize: 13, color: Color(0xFF9CA3AF))),
                  ]),
                );
              }
              return _buildMediaContent(msg.mediaKind, snap.data!);
            },
          ),
        if (msg.text != null && msg.text!.isNotEmpty)
          SelectableText(
            msg.text!,
            style: TextStyle(fontSize: 14, color: textColor, height: 1.4),
          ),
        if (msg.caption != null && msg.caption!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              msg.caption!,
              style: TextStyle(
                  fontSize: 13,
                  color: isOut ? Colors.white70 : const Color(0xFF6B7280),
                  fontStyle: FontStyle.italic),
            ),
          ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              _formatTime(msg.receivedAt),
              style: TextStyle(fontSize: 11, color: timeColor),
            ),
            if (isOut) ...[
              const SizedBox(width: 4),
              Icon(Icons.done, size: 12, color: timeColor),
            ],
          ],
        ),
      ],
    );

    return Align(
      alignment: isOut ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        margin: EdgeInsets.only(
          left: isOut ? 60 : 8,
          right: isOut ? 8 : 60,
          bottom: 4,
          top: 2,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOut ? 16 : 4),
            bottomRight: Radius.circular(isOut ? 4 : 16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: bubbleContent,
      ),
    );
  }
}

class _TypeHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isOut;

  const _TypeHeader({
    required this.icon,
    required this.label,
    required this.isOut,
  });

  @override
  Widget build(BuildContext context) {
    final color = isOut ? Colors.white : const Color(0xFF1B7A43);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _OpenButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF1B7A43),
        side: const BorderSide(color: Color(0xFF1B7A43)),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    );
  }
}
