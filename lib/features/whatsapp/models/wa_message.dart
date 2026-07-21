import '../../../utils/ist_date.dart';

class WaMessage {
  final String id;
  final String direction;
  final String msgType;
  final String? text;
  final String? caption;
  final String? filePath;
  final String? mimeType;
  final String? routedTo;
  final DateTime? receivedAt;
  // CHANGE #208: rich message fields.
  final String? fileName;
  final double? latitude;
  final double? longitude;
  final String? locationName;
  final String? locationAddress;
  final String? contactName;
  final String? contactPhone;
  // CHANGE #508 B4: real Meta delivery status — never inferred from routedTo.
  // null/'accepted' = single grey tick (Meta took it, not proof of delivery),
  // 'delivered' = double grey, 'read' = double blue, 'failed' = red + reason.
  final String? waStatus;
  final String? waFailReason;

  const WaMessage({
    required this.id,
    required this.direction,
    required this.msgType,
    this.text,
    this.caption,
    this.filePath,
    this.mimeType,
    this.routedTo,
    this.receivedAt,
    this.fileName,
    this.latitude,
    this.longitude,
    this.locationName,
    this.locationAddress,
    this.contactName,
    this.contactPhone,
    this.waStatus,
    this.waFailReason,
  });

  factory WaMessage.fromJson(Map<String, dynamic> j) {
    return WaMessage(
      id: (j['id'] ?? '').toString(),
      direction: (j['direction'] ?? 'in').toString(),
      msgType: (j['msg_type'] ?? 'other').toString(),
      text: j['text']?.toString(),
      caption: j['caption']?.toString(),
      filePath: j['file_path']?.toString(),
      mimeType: j['mime_type']?.toString(),
      routedTo: j['routed_to']?.toString(),
      receivedAt: _asDate(j['received_at']),
      fileName: j['file_name']?.toString(),
      latitude: _asDouble(j['latitude']),
      longitude: _asDouble(j['longitude']),
      locationName: j['location_name']?.toString(),
      locationAddress: j['location_address']?.toString(),
      contactName: j['contact_name']?.toString(),
      contactPhone: j['contact_phone']?.toString(),
      waStatus: j['wa_status']?.toString(),
      waFailReason: j['wa_fail_reason']?.toString(),
    );
  }

  static double? _asDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  /// Best display filename for a document bubble.
  String get displayFileName {
    if (fileName != null && fileName!.trim().isNotEmpty) return fileName!.trim();
    if (filePath != null && filePath!.trim().isNotEmpty) {
      final p = filePath!.trim();
      final i = p.lastIndexOf('/');
      return i >= 0 ? p.substring(i + 1) : p;
    }
    return 'Document';
  }

  /// True when this is a non-text message (media/location/contact) — used to
  /// trigger the c208_incoming_media_render render-log key for incoming msgs.
  bool get isNonText {
    final t = msgType.toLowerCase();
    return t != 'text' && (hasMedia || t == 'location' || t == 'contacts' ||
        t == 'contact' || t == 'media' || t == 'image' || t == 'document' ||
        t == 'audio' || t == 'voice' || t == 'video' || t == 'sticker');
  }

  static DateTime? _asDate(dynamic v) {
    if (v == null) return null;
    return tryIstFromDb(v.toString());
  }

  bool get isOut => direction == 'out';

  bool get hasMedia =>
      filePath != null && filePath!.trim().isNotEmpty;

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
