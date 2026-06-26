class WaMessage {
  final String id;
  final String direction;
  final String msgType;
  final String? text;
  final String? caption;
  final String? filePath;
  final String? mediaBucket;
  final String? mimeType;
  final String? routedTo;
  final DateTime? receivedAt;

  const WaMessage({
    required this.id,
    required this.direction,
    required this.msgType,
    this.text,
    this.caption,
    this.filePath,
    this.mediaBucket,
    this.mimeType,
    this.routedTo,
    this.receivedAt,
  });

  factory WaMessage.fromJson(Map<String, dynamic> j) {
    return WaMessage(
      id: (j['id'] ?? '').toString(),
      direction: (j['direction'] ?? 'in').toString(),
      msgType: (j['msg_type'] ?? 'other').toString(),
      text: j['text']?.toString(),
      caption: j['caption']?.toString(),
      filePath: j['file_path']?.toString(),
      mediaBucket: j['media_bucket']?.toString(),
      mimeType: j['mime_type']?.toString(),
      routedTo: j['routed_to']?.toString(),
      receivedAt: _asDate(j['received_at']),
    );
  }

  static DateTime? _asDate(dynamic v) {
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString()).toLocal();
    } catch (_) {
      return null;
    }
  }

  bool get isOut => direction == 'out';

  bool get hasMedia =>
      filePath != null && filePath!.trim().isNotEmpty;

  String get effectiveBucket =>
      (mediaBucket != null && mediaBucket!.trim().isNotEmpty)
          ? mediaBucket!
          : 'whatsapp-media';

  String get mediaKind {
    final mime = (mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return 'image';
    if (mime == 'application/pdf') return 'pdf';
    if (mime.contains('word') ||
        mime.contains('excel') ||
        mime.contains('spreadsheet') ||
        mime.contains('presentation')) {
      return 'pdf';
    }
    if (mime.startsWith('audio/')) return 'audio';
    if (mime.startsWith('video/')) return 'video';
    // fallback to file extension
    if (hasMedia) {
      final ext = filePath!.split('.').last.toLowerCase();
      if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic'].contains(ext)) {
        return 'image';
      }
      if (['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx'].contains(ext)) {
        return 'pdf';
      }
      if (['mp3', 'ogg', 'opus', 'm4a', 'aac', 'wav'].contains(ext)) {
        return 'audio';
      }
      if (['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext)) {
        return 'video';
      }
    }
    return 'file';
  }
}
