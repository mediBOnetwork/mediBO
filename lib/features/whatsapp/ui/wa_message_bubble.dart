import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/utils/wa_markdown.dart';
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
    _initSignedUrl();
    // CHANGE #208: log first render of a non-text INCOMING bubble.
    if (!widget.message.isOut && widget.message.isNonText) {
      RenderLog.write('c208_incoming_media_render', 1);
    }
  }

  @override
  void didUpdateWidget(WaMessageBubble old) {
    super.didUpdateWidget(old);
    // Re-fetch signed URL when the message's media path changes (e.g. realtime
    // delivers a new message into the same list position before the key fix
    // takes effect, or the path is updated).
    if (widget.message.filePath != old.message.filePath) {
      _initSignedUrl();
    }
  }

  void _initSignedUrl() {
    if (widget.message.hasMedia) {
      _signedUrlFuture = widget.repo.signedUrl(
        widget.message.effectiveBucket,
        widget.message.filePath!,
      );
    } else {
      _signedUrlFuture = null;
    }
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    // CHANGE #374: dt is already IST wall-clock (WaMessage.receivedAt is
    // converted at parse time) — do not re-offset here.
    final t = DateFormat('h:mm a').format(dt).toLowerCase();
    RenderLog.write('c248_bubble_time_12h', t);
    return t;
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
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
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
                    child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
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
        return _DocumentCard(
          fileName: widget.message.displayFileName,
          onOpen: () => _openUrl(signedUrl),
        );
      case 'audio':
        return _OpenButton(
          label: 'Open audio',
          icon: Icons.headphones_outlined,
          onTap: () => _openUrl(signedUrl),
        );
      case 'video':
        return _VideoCard(onOpen: () => _openUrl(signedUrl));
      default:
        return _DocumentCard(
          fileName: widget.message.displayFileName,
          onOpen: () => _openUrl(signedUrl),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isOut = msg.isOut;
    final maxWidth = MediaQuery.of(context).size.width * 0.78;

    // CHANGE #208: WhatsApp colours — outbound green, inbound white.
    final bubbleColor = isOut ? const Color(0xFFDCF8C6) : Colors.white;
    const textColor = Color(0xFF111827);
    const timeColor = Color(0xFF667781);

    final type = msg.msgType.toLowerCase();
    final isLocation = type == 'location';
    final isContact = type == 'contacts' || type == 'contact';

    // CHANGE #280: log every rendered bubble type for observability.
    RenderLog.write('c277_wa_all_types', type);

    Widget? body;
    try {
      if (isLocation) {
        body = _LocationCard(
          lat: msg.latitude,
          lng: msg.longitude,
          name: msg.locationName,
          address: msg.locationAddress,
          onOpen: () {
            if (msg.latitude != null && msg.longitude != null) {
              _openUrl(
                  'https://maps.google.com/?q=${msg.latitude},${msg.longitude}');
            }
          },
        );
      } else if (isContact) {
        body = _ContactCard(
          name: msg.contactName ?? 'Contact',
          phone: msg.contactPhone ?? '',
          onCall: () {
            final p = msg.contactPhone;
            if (p != null && p.isNotEmpty) _openUrl('tel:$p');
          },
          onCopy: () {
            final p = msg.contactPhone;
            if (p != null && p.isNotEmpty) {
              Clipboard.setData(ClipboardData(text: p));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Phone number copied'),
                  behavior: SnackBarBehavior.floating,
                  duration: Duration(seconds: 2),
                ),
              );
            }
          },
        );
      } else if (msg.hasMedia && _signedUrlFuture != null) {
        body = FutureBuilder<String>(
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
                  Icon(Icons.error_outline, size: 16, color: Color(0xFF9CA3AF)),
                  SizedBox(width: 4),
                  Text('Media unavailable',
                      style:
                          TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ]),
              );
            }
            return _buildMediaContent(msg.mediaKind, snap.data!);
          },
        );
      } else if ((msg.text == null || msg.text!.isEmpty) &&
          type != 'text' &&
          !msg.hasMedia) {
        // CHANGE #280: document/file types with no media path — show a static
        // DocumentCard (no download URL) so the bubble is recognisable.
        const _docTypes = {
          'document', 'file', 'pdf', 'audio', 'voice', 'video', 'sticker',
        };
        if (_docTypes.contains(type)) {
          RenderLog.write('c277_wa_doc_bubble', type);
          final label = msg.fileName?.isNotEmpty == true
              ? msg.fileName!
              : (type == 'audio' || type == 'voice')
                  ? 'Audio message'
                  : type == 'video'
                      ? 'Video'
                      : 'Document';
          body = _DocumentCard(
            fileName: label,
            onOpen: () {},
          );
        } else {
          // Truly unknown type.
          body = Text(
            '[${msg.msgType}] message',
            style: const TextStyle(
                fontSize: 14, color: Color(0xFF6B7280), height: 1.4),
          );
        }
      }
    } catch (_) {
      body = Text(
        '[${msg.msgType}] message',
        style: const TextStyle(
            fontSize: 14, color: Color(0xFF6B7280), height: 1.4),
      );
    }

    // ── CHANGE #247: WA markdown rendering ───────────────────────────────────
    const bodyStyle = TextStyle(fontSize: 14, color: textColor, height: 1.4);
    const captionStyle = TextStyle(fontSize: 13, color: Color(0xFF374151), height: 1.4);

    final bodyText = msg.text ?? '';
    final captionText = msg.caption ?? '';
    final hasBodyText = bodyText.isNotEmpty;
    final hasCaptionText = captionText.isNotEmpty;

    final bodySpans = hasBodyText ? WaMarkdown.spans(bodyText, bodyStyle) : <TextSpan>[];
    final captionSpans = hasCaptionText ? WaMarkdown.spans(captionText, captionStyle) : <TextSpan>[];

    // Determine if any markdown was actually parsed (span count > 1 means markdown present).
    final hasMarkdown = bodySpans.length > 1 || captionSpans.length > 1;

    // Image-above-text logging.
    final isImage = type == 'image' || (msg.hasMedia && msg.mediaKind == 'image');
    if (isImage && body != null) {
      if (hasBodyText || hasCaptionText) {
        RenderLog.write('c247_img_above_text', 'img+text');
      } else {
        RenderLog.write('c247_img_only', 'img_only');
      }
    }
    if (hasMarkdown) {
      final cnt = bodySpans.length + captionSpans.length;
      RenderLog.write('c247_md_render', 'spans=$cnt');
    } else if (!isImage && body == null) {
      RenderLog.write('c247_plain', '1');
    }

    Widget _richText(List<TextSpan> spans) => RichText(
          text: TextSpan(children: spans),
        );

    final bubbleContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (body != null) body,
        if (hasBodyText) ...[
          if (body != null) const SizedBox(height: 6),
          _richText(bodySpans),
        ],
        if (hasCaptionText)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _richText(captionSpans),
          ),
        const SizedBox(height: 4),
        Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              _formatTime(msg.receivedAt),
              style: const TextStyle(fontSize: 11, color: timeColor),
            ),
            if (isOut) ...[
              const SizedBox(width: 4),
              // CHANGE #508 B4: real Meta delivery status — this used to be a
              // hardcoded blue double-tick on every outbound message, which
              // read as "delivered and read" even for messages Meta never
              // confirmed delivery of (or that failed outright).
              _WaStatusTick(status: msg.waStatus, failReason: msg.waFailReason),
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(isOut ? 12 : 2),
            topRight: Radius.circular(isOut ? 2 : 12),
            bottomLeft: const Radius.circular(12),
            bottomRight: const Radius.circular(12),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.08),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: bubbleContent,
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  final String fileName;
  final VoidCallback onOpen;
  const _DocumentCard({required this.fileName, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.insert_drive_file,
              size: 28, color: Color(0xFF1B7A43)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              fileName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFF111827)),
            ),
          ),
          const SizedBox(width: 8),
          _MiniButton(label: 'Open', onTap: onOpen),
        ],
      ),
    );
  }
}

class _VideoCard extends StatelessWidget {
  final VoidCallback onOpen;
  const _VideoCard({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        height: 120,
        width: 200,
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Center(
          child: Icon(Icons.play_circle_fill, size: 48, color: Colors.white),
        ),
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final double? lat;
  final double? lng;
  final String? name;
  final String? address;
  final VoidCallback onOpen;
  const _LocationCard({
    required this.lat,
    required this.lng,
    required this.name,
    required this.address,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final coords = (lat != null && lng != null)
        ? '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}'
        : '';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.location_on, size: 22, color: Color(0xFF1B7A43)),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  (name != null && name!.isNotEmpty) ? name! : 'Location',
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF111827)),
                ),
              ),
            ],
          ),
          if (address != null && address!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(address!,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ),
          if (coords.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(coords,
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF9CA3AF))),
            ),
          const SizedBox(height: 6),
          _MiniButton(label: 'Open in Maps', onTap: onOpen),
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  final String name;
  final String phone;
  final VoidCallback onCall;
  final VoidCallback onCopy;
  const _ContactCard({
    required this.name,
    required this.phone,
    required this.onCall,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6F8),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF1B7A43),
                child: Text(initial,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827))),
                    if (phone.isNotEmpty)
                      Text(phone,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280))),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MiniButton(label: 'Call', icon: Icons.call, onTap: onCall),
              const SizedBox(width: 6),
              _MiniButton(label: 'Copy', icon: Icons.copy, onTap: onCopy),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback onTap;
  const _MiniButton({required this.label, this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: icon != null
          ? Icon(icon, size: 16)
          : const SizedBox.shrink(),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFF1B7A43),
        side: const BorderSide(color: Color(0xFF1B7A43)),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// CHANGE #508 B4: renders Meta's REAL per-message delivery status, sourced
// from whatsapp_messages.wa_status via the webhook's status-callback handler.
// A message must never look sent/delivered unless Meta actually confirmed it.
class _WaStatusTick extends StatelessWidget {
  final String? status;
  final String? failReason;
  const _WaStatusTick({this.status, this.failReason});

  @override
  Widget build(BuildContext context) {
    final s = (status ?? '').toLowerCase();
    if (s == 'failed') {
      try { RenderLog.write('c508_status_failed', failReason ?? 'unknown'); } catch (_) {}
      return Tooltip(
        message: (failReason != null && failReason!.isNotEmpty)
            ? failReason!
            : 'Message was not delivered',
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.error_outline, size: 13, color: Color(0xFFDC2626)),
          SizedBox(width: 2),
          Text('Not delivered',
              style: TextStyle(
                  fontSize: 10, color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
        ]),
      );
    }
    if (s == 'read') {
      try { RenderLog.write('c508_status_delivered', 'read'); } catch (_) {}
      return const Icon(Icons.done_all, size: 14, color: Color(0xFF53BDEB));
    }
    if (s == 'delivered') {
      try { RenderLog.write('c508_status_delivered', 'delivered'); } catch (_) {}
      return const Icon(Icons.done_all, size: 14, color: Color(0xFF667781));
    }
    // 'accepted' / 'sent' / unknown — Meta took the message, but that is NOT
    // proof of delivery. Single grey tick only.
    return const Icon(Icons.done, size: 14, color: Color(0xFF667781));
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
