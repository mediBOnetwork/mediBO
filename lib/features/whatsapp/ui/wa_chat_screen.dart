import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
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
  late Future<WaThreadResult> _future;
  List<WaMessage> _messages = [];
  bool _sending = false;
  bool _loggedOpen = false;

  // CHANGE #207: resolved identity from wa_thread (falls back to conversation).
  String? _threadName;
  String? _threadLabel;

  @override
  void initState() {
    super.initState();
    _loadThread();
    _markRead();
  }

  // CHANGE #207: mark this conversation read on open (await, tolerate errors).
  Future<void> _markRead() async {
    RenderLog.write('c208_mark_read', widget.conversation.senderPhone);
    await _repo.markRead(widget.conversation.senderPhone);
  }

  @override
  void dispose() {
    _textController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _loadThread() {
    _future = _repo.getThread(widget.conversation.senderPhone).then((res) {
      if (mounted) {
        setState(() {
          _messages = res.messages;
          _threadName = res.name;
          _threadLabel = res.label;
        });
        if (!_loggedOpen) {
          _loggedOpen = true;
          RenderLog.write('c204_wa_thread_opened', res.messages.length);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      }
      return res;
    });
    if (mounted) setState(() {});
  }

  // CHANGE #207: resolved display name for header. Priority: thread name >
  // thread label > conversation name/label > prettified phone.
  String get _headerName {
    final n = _threadName;
    if (n != null && n.trim().isNotEmpty) return n.trim();
    final l = _threadLabel;
    if (l != null && l.trim().isNotEmpty) return l.trim();
    return widget.conversation.displayName;
  }

  bool get _headerHasName {
    final n = _threadName;
    final l = _threadLabel;
    return (n != null && n.trim().isNotEmpty) ||
        (l != null && l.trim().isNotEmpty) ||
        widget.conversation.hasName;
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

  void _appendOptimistic(WaMessage msg) {
    if (!mounted) return;
    setState(() => _messages.add(msg));
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFF991B1B),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  void _handleSendError(Object e) {
    if (e is WaSendException) {
      _showError(e.humanMessage);
    } else {
      _showError('Could not send. Please try again.');
    }
  }

  Future<void> _openAttachMenu() async {
    if (_sending) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        // CHANGE #208: attachment sheet built.
        RenderLog.write('c208_attach_menu_shown', 1);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              _attachTile(ctx, Icons.photo_outlined, 'Gallery', 'gallery'),
              _attachTile(ctx, Icons.camera_alt_outlined, 'Camera', 'camera'),
              _attachTile(
                  ctx, Icons.insert_drive_file_outlined, 'Document', 'document'),
              _attachTile(ctx, Icons.audiotrack_outlined, 'Audio', 'audio'),
              _attachTile(ctx, Icons.videocam_outlined, 'Video', 'video'),
              _attachTile(
                  ctx, Icons.location_on_outlined, 'Location', 'location'),
              _attachTile(ctx, Icons.person_outline, 'Contact', 'contact'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
    if (choice == null) return;
    switch (choice) {
      case 'gallery':
        await _pickImage(ImageSource.gallery);
        break;
      case 'camera':
        await _pickImage(ImageSource.camera);
        break;
      case 'audio':
        await _pickAndSendMedia(FileType.audio, null);
        break;
      case 'video':
        await _pickAndSendMedia(FileType.video, null);
        break;
      case 'document':
        await _pickAndSendMedia(
          FileType.custom,
          ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv'],
        );
        break;
      case 'location':
        await _showLocationDialog();
        break;
      case 'contact':
        await _showContactDialog();
        break;
    }
  }

  Widget _attachTile(
      BuildContext ctx, IconData icon, String label, String value) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF1B7A43)),
      title: Text(
        label,
        style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w500,
            color: Color(0xFF111827)),
      ),
      onTap: () => Navigator.of(ctx).pop(value),
    );
  }

  Future<void> _pickAndSendMedia(
      FileType type, List<String>? allowedExtensions) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        type: type,
        allowedExtensions: allowedExtensions,
        withData: true,
      );
    } catch (e) {
      _showError('Could not open file picker.');
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _showError('Could not read the selected file.');
      return;
    }
    final ext = (file.extension ?? '').toLowerCase();
    final mime = _mimeFor(ext);
    await _sendBytes(bytes, file.name, mime);
  }

  // CHANGE #208: Gallery/Camera via image_picker.
  Future<void> _pickImage(ImageSource source) async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(source: source, imageQuality: 85);
    } catch (e) {
      _showError('Could not open the camera/gallery.');
      return;
    }
    if (picked == null) return;
    final bytes = await picked.readAsBytes();
    var name = picked.name;
    if (!name.contains('.')) name = '$name.jpg';
    final ext = name.split('.').last.toLowerCase();
    final mime = picked.mimeType ?? _mimeFor(ext);
    await _sendBytes(bytes, name, mime);
  }

  /// Shared upload+send for any picked bytes (validates size, asks caption,
  /// appends an optimistic outbound bubble).
  Future<void> _sendBytes(
      Uint8List bytes, String fileName, String mime) async {
    final ext = fileName.contains('.') ? fileName.split('.').last : 'bin';
    final cat = WaRepository.categorize(mime, ext);
    if (bytes.length > WaRepository.maxBytesFor(cat)) {
      final mb = (WaRepository.maxBytesFor(cat) / (1024 * 1024)).round();
      _showError('File is too large. Limit is $mb MB for this type.');
      return;
    }

    final caption = await _askCaption();
    if (caption == null) return; // cancelled

    setState(() => _sending = true);
    try {
      final res = await _repo.sendMedia(
        to: widget.conversation.senderPhone,
        bytes: bytes,
        fileName: fileName,
        mime: mime,
        caption: caption,
      );
      final waId = res['wa_message_id']?.toString() ?? '';
      _appendOptimistic(WaMessage(
        id: waId.isNotEmpty
            ? waId
            : 'opt_${DateTime.now().millisecondsSinceEpoch}',
        direction: 'out',
        msgType: 'media',
        caption: caption.isNotEmpty ? caption : null,
        filePath: res['media_path']?.toString(),
        mediaBucket: res['media_bucket']?.toString() ?? 'whatsapp-media',
        mimeType: mime,
        fileName: fileName,
        receivedAt: DateTime.now(),
      ));
    } catch (e) {
      _handleSendError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<String?> _askCaption() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Add a caption',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'Optional caption…',
            filled: true,
            fillColor: Color(0xFFF5F6F8),
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF6B7280))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
  }

  Future<void> _showLocationDialog() async {
    final latC = TextEditingController();
    final lngC = TextEditingController();
    final nameC = TextEditingController();
    final addrC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Send location',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _dialogField(latC, 'Latitude *',
                  keyboard: const TextInputType.numberWithOptions(
                      decimal: true, signed: true)),
              const SizedBox(height: 8),
              _dialogField(lngC, 'Longitude *',
                  keyboard: const TextInputType.numberWithOptions(
                      decimal: true, signed: true)),
              const SizedBox(height: 8),
              _dialogField(nameC, 'Name (optional)'),
              const SizedBox(height: 8),
              _dialogField(addrC, 'Address (optional)'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF6B7280))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final lat = double.tryParse(latC.text.trim());
    final lng = double.tryParse(lngC.text.trim());
    if (lat == null || lng == null || lat.abs() > 90 || lng.abs() > 180) {
      _showError('Please enter a valid latitude and longitude.');
      return;
    }
    setState(() => _sending = true);
    try {
      final res = await _repo.sendLocation(
        to: widget.conversation.senderPhone,
        latitude: lat,
        longitude: lng,
        name: nameC.text,
        address: addrC.text,
      );
      final waId = res['wa_message_id']?.toString() ?? '';
      _appendOptimistic(WaMessage(
        id: waId.isNotEmpty
            ? waId
            : 'opt_${DateTime.now().millisecondsSinceEpoch}',
        direction: 'out',
        msgType: 'location',
        latitude: lat,
        longitude: lng,
        locationName: nameC.text.trim().isNotEmpty ? nameC.text.trim() : null,
        locationAddress:
            addrC.text.trim().isNotEmpty ? addrC.text.trim() : null,
        receivedAt: DateTime.now(),
      ));
    } catch (e) {
      _handleSendError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _showContactDialog() async {
    final nameC = TextEditingController();
    final phoneC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text('Send contact',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _dialogField(nameC, 'Contact name *'),
            const SizedBox(height: 8),
            _dialogField(phoneC, 'Contact phone *',
                keyboard: TextInputType.phone),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: Color(0xFF6B7280))),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43)),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final name = nameC.text.trim();
    final digits = phoneC.text.replaceAll(RegExp(r'\D'), '');
    if (name.isEmpty || digits.isEmpty) {
      _showError('Please enter a contact name and phone number.');
      return;
    }
    setState(() => _sending = true);
    try {
      final res = await _repo.sendContact(
        to: widget.conversation.senderPhone,
        contactName: name,
        contactPhone: digits,
      );
      final waId = res['wa_message_id']?.toString() ?? '';
      _appendOptimistic(WaMessage(
        id: waId.isNotEmpty
            ? waId
            : 'opt_${DateTime.now().millisecondsSinceEpoch}',
        direction: 'out',
        msgType: 'contacts',
        contactName: name,
        contactPhone: digits,
        receivedAt: DateTime.now(),
      ));
    } catch (e) {
      _handleSendError(e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Widget _dialogField(TextEditingController c, String hint,
      {TextInputType? keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      decoration: InputDecoration(
        hintText: hint,
        filled: true,
        fillColor: const Color(0xFFF5F6F8),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  static String _mimeFor(String ext) {
    switch (ext.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'bmp':
        return 'image/bmp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case '3gp':
        return 'video/3gpp';
      case 'webm':
        return 'video/webm';
      case 'mkv':
        return 'video/x-matroska';
      case 'avi':
        return 'video/x-msvideo';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'wav':
        return 'audio/wav';
      case 'amr':
        return 'audio/amr';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      case 'xls':
        return 'application/vnd.ms-excel';
      case 'xlsx':
        return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      case 'ppt':
        return 'application/vnd.ms-powerpoint';
      case 'pptx':
        return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      case 'txt':
        return 'text/plain';
      case 'csv':
        return 'text/csv';
      default:
        return 'application/octet-stream';
    }
  }

  // CHANGE #208: WhatsApp-style day separators.
  bool _isNewDay(DateTime? prev, DateTime? cur) {
    if (cur == null) return false;
    if (prev == null) return true;
    return prev.year != cur.year ||
        prev.month != cur.month ||
        prev.day != cur.day;
  }

  String _dayLabel(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return DateFormat('d MMM yyyy').format(dt);
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
            Builder(builder: (_) {
              if (_headerHasName) {
                RenderLog.write('c207_name_resolved', 1);
                RenderLog.write('c208_name_resolved', 1);
              }
              return Text(
                _headerName,
                style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis,
              );
            }),
            if (_headerHasName)
              Text(
                conv.phonePretty,
                style: const TextStyle(
                    fontSize: 11, color: Color(0xFF9CA3AF)),
                overflow: TextOverflow.ellipsis,
              ),
            const SizedBox(height: 2),
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
            child: Container(
              // CHANGE #208: WhatsApp-style warm wallpaper behind messages.
              color: const Color(0xFFECE5DD),
              child: Builder(builder: (_) {
                RenderLog.write('c208_chat_whatsapp_ui', 1);
                return FutureBuilder<WaThreadResult>(
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
                    itemBuilder: (ctx, i) {
                      final m = msgs[i];
                      final prev = i > 0 ? msgs[i - 1] : null;
                      final showSep = _isNewDay(prev?.receivedAt, m.receivedAt);
                      final bubble = WaMessageBubble(
                        message: m,
                        repo: _repo,
                      );
                      if (!showSep) return bubble;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _DaySeparator(label: _dayLabel(m.receivedAt)),
                          bubble,
                        ],
                      );
                    },
                  ),
                );
                });
              },
            ),
            ),
          ),
          _ReplyBar(
            controller: _textController,
            sending: _sending,
            onSend: _sendReply,
            onAttach: _openAttachMenu,
          ),
        ],
      ),
    );
  }
}

class _DaySeparator extends StatelessWidget {
  final String label;
  const _DaySeparator({required this.label});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFFE1F2FB),
          borderRadius: BorderRadius.circular(8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 2,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF5A6B73)),
        ),
      ),
    );
  }
}

class _ReplyBar extends StatelessWidget {
  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;
  final VoidCallback onAttach;

  const _ReplyBar({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.onAttach,
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
              IconButton(
                icon: const Icon(Icons.add_circle_outline,
                    color: Color(0xFF1B7A43)),
                tooltip: 'Attach',
                onPressed: sending ? null : onAttach,
              ),
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
