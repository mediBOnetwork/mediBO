import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../widgets/image_pick.dart';
import '../../../widgets/payment_proof_image.dart';
import 'dev_queue_service.dart';

/// CHANGE #72 — the media attach control for a NEW command (paste sheet).
///
/// Three sources — Camera, Gallery (multi image), File (any type). Every pick
/// uploads IMMEDIATELY to the private uploads bucket, so a chip only ever
/// reaches `done` once its bytes are safely stored — media cannot be lost on
/// "Add to queue". A failed upload keeps its bytes, turns the chip red
/// ("failed — tap to retry"), and reports `pending=true` so the sheet blocks
/// submit until it succeeds or is removed. Nothing here decides anything: the
/// paths it reports are what the backend stores and renders straight back.
///
/// Styled entirely from the `Ds` token layer; every string comes from ui_copy.
class DevMediaItem {
  final String id;
  final String name;
  final String kind; // 'image' | 'file'
  final Uint8List bytes;
  final int size;
  String state; // 'uploading' | 'done' | 'failed'
  String? path; // set when an image upload lands
  Map<String, dynamic>? attachment; // {path,kind,name} when a file upload lands
  DevMediaItem({
    required this.id,
    required this.name,
    required this.kind,
    required this.bytes,
    required this.size,
    this.state = 'uploading',
  });
}

class DevQueueMediaTray extends StatefulWidget {
  final DevQueueService service;

  /// Reports the current media: the uploaded image paths, the uploaded file
  /// attachments ({path,kind,name}), and whether any item is still uploading
  /// or failed (so the parent can block submit).
  final void Function(
    List<String> images,
    List<Map<String, dynamic>> attachments,
    bool pending,
  ) onChanged;

  const DevQueueMediaTray({
    super.key,
    required this.service,
    required this.onChanged,
  });

  @override
  State<DevQueueMediaTray> createState() => _DevQueueMediaTrayState();
}

class _DevQueueMediaTrayState extends State<DevQueueMediaTray> {
  final List<DevMediaItem> _items = [];
  int _seq = 0;

  static const _imageExts = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'heic'};

  String _kindOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return _imageExts.contains(ext) ? 'image' : 'file';
  }

  void _notify() {
    final images = <String>[];
    final attachments = <Map<String, dynamic>>[];
    var pending = false;
    for (final it in _items) {
      if (it.state != 'done') {
        pending = true;
        continue;
      }
      if (it.kind == 'image' && it.path != null) {
        images.add(it.path!);
      } else if (it.attachment != null) {
        attachments.add(it.attachment!);
      }
    }
    widget.onChanged(images, attachments, pending);
  }

  Future<void> _upload(DevMediaItem it) async {
    setState(() => it.state = 'uploading');
    _notify();
    try {
      if (it.kind == 'image') {
        it.path = await widget.service.uploadImage(it.bytes, it.name);
      } else {
        it.attachment = await widget.service.uploadAttachment(it.bytes, it.name);
      }
      it.state = 'done';
    } catch (_) {
      it.state = 'failed';
    }
    if (mounted) setState(() {});
    _notify();
  }

  void _add(String name, Uint8List bytes) {
    final it = DevMediaItem(
      id: 'm${_seq++}',
      name: name,
      kind: _kindOf(name),
      bytes: bytes,
      size: bytes.length,
    );
    setState(() => _items.add(it));
    _upload(it);
  }

  void _remove(DevMediaItem it) {
    setState(() => _items.remove(it));
    _notify();
  }

  Future<void> _camera() async {
    final picked = await pickImageBytes(camera: true);
    if (picked != null) _add(picked.name, picked.bytes);
  }

  Future<void> _gallery() async {
    final res = await FilePicker.pickFiles(
        type: FileType.image, allowMultiple: true, withData: true);
    if (res == null) return;
    for (final f in res.files) {
      final b = f.bytes;
      if (b != null) _add(f.name, b);
    }
  }

  Future<void> _file() async {
    final res = await FilePicker.pickFiles(allowMultiple: true, withData: true);
    if (res == null) return;
    for (final f in res.files) {
      final b = f.bytes;
      if (b != null) _add(f.name, b);
    }
  }

  String _sizeLabel(int size) {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  void _openImage(DevMediaItem it) {
    if (it.path == null) return;
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (_) => GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: InteractiveViewer(
          child: Center(
            child: PaymentProofImage(
              bucket: DevQueueService.uploadsBucket,
              path: it.path!,
              tapToEnlarge: false,
            ),
          ),
        ),
      ),
    );
  }

  void _openFile(DevMediaItem it) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.insert_drive_file_outlined, size: 22, color: Ds.c.brand),
            SizedBox(width: Ds.space.x8),
            Expanded(child: Text(it.name, style: Ds.t.subtitle.copyWith(fontWeight: FontWeight.w600))),
          ]),
          SizedBox(height: Ds.space.x8),
          Text(_sizeLabel(it.size), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(c('dev_queue.media_preview_close')),
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_items.isNotEmpty)
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [for (final it in _items) _chip(it)],
          ),
        ),
      Row(children: [
        _action(Icons.photo_camera_outlined, c('dev_queue.attach_camera'), _camera),
        SizedBox(width: Ds.space.x8),
        _action(Icons.photo_library_outlined, c('dev_queue.attach_gallery'), _gallery),
        SizedBox(width: Ds.space.x8),
        _action(Icons.attach_file, c('dev_queue.attach_file'), _file),
      ]),
    ]);
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18, color: Ds.c.brand),
      label: Text(label,
          style: Ds.t.caption.copyWith(fontWeight: FontWeight.w600, color: Ds.c.brand)),
    );
  }

  Widget _chip(DevMediaItem it) {
    const box = 72.0;
    Widget inner;
    VoidCallback? onTap;

    if (it.state == 'uploading') {
      inner = Center(
        child: SizedBox(
          width: 20, height: 20,
          child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand),
        ),
      );
    } else if (it.state == 'failed') {
      onTap = () => _upload(it); // tap to retry
      inner = Padding(
        padding: EdgeInsets.all(Ds.space.x4),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.refresh, size: 20, color: Ds.c.danger),
          SizedBox(height: Ds.space.x4),
          Text(c('dev_queue.media_retry'),
              textAlign: TextAlign.center, maxLines: 3,
              style: Ds.t.caption.copyWith(color: Ds.c.danger, fontSize: 9)),
        ]),
      );
    } else if (it.kind == 'image' && it.path != null) {
      onTap = () => _openImage(it);
      inner = PaymentProofImage(
        bucket: DevQueueService.uploadsBucket,
        path: it.path!,
        fixedHeight: box,
        tapToEnlarge: false,
      );
    } else {
      onTap = () => _openFile(it);
      inner = Padding(
        padding: EdgeInsets.all(Ds.space.x4),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.insert_drive_file_outlined, size: 22, color: Ds.c.textSecondary),
          SizedBox(height: Ds.space.x4),
          Text(it.name, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: Ds.t.caption.copyWith(fontSize: 9)),
        ]),
      );
    }

    final border = it.state == 'failed' ? Ds.c.danger : Ds.c.divider;
    return Stack(clipBehavior: Clip.none, children: [
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: box, height: box,
          decoration: BoxDecoration(
            color: it.state == 'failed' ? Ds.c.dangerSoft : Ds.c.bg,
            borderRadius: BorderRadius.circular(Ds.r.button),
            border: Border.all(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: inner,
        ),
      ),
      Positioned(
        top: -8, right: -8,
        child: IconButton(
          icon: Icon(Icons.cancel, size: 20, color: Ds.c.danger),
          onPressed: () => _remove(it),
          splashRadius: 16,
        ),
      ),
    ]);
  }
}
