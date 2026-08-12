import 'package:flutter/material.dart';

import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import '../../../widgets/image_pick.dart';
import '../../../widgets/payment_proof_image.dart';
import 'dev_queue_common.dart';
import 'dev_queue_service.dart';

/// The ONE image-attach control the Dev Queue reuses everywhere an admin can
/// add a picture to a command: the paste sheet, and the live chat/reply
/// composer. It owns nothing but the pick→upload→path round-trip; the paths it
/// reports are what the backend stores and renders back. No decisions here.
class DevQueueImageTray extends StatefulWidget {
  final DevQueueService service;
  final List<String> paths;
  final ValueChanged<List<String>> onChanged;

  const DevQueueImageTray({
    super.key,
    required this.service,
    required this.paths,
    required this.onChanged,
  });

  @override
  State<DevQueueImageTray> createState() => _DevQueueImageTrayState();
}

class _DevQueueImageTrayState extends State<DevQueueImageTray> {
  bool _busy = false;

  Future<void> _pick() async {
    if (_busy) return;
    final picked = await pickImageBytes();
    if (picked == null) return;
    setState(() => _busy = true);
    try {
      final path = await widget.service.uploadImage(picked.bytes, picked.name);
      widget.onChanged([...widget.paths, path]);
    } catch (_) {
      if (mounted) showToast(context, c('dev_queue.attach_failed'), isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _remove(String path) =>
      widget.onChanged(widget.paths.where((p) => p != path).toList());

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.paths.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in widget.paths)
                Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 72,
                      height: 72,
                      child: PaymentProofImage(
                        bucket: DevQueueService.uploadsBucket,
                        path: p,
                        fixedHeight: 72,
                        tapToEnlarge: false,
                      ),
                    ),
                  ),
                  Positioned(
                    top: -6,
                    right: -6,
                    child: IconButton(
                      icon: const Icon(Icons.cancel, size: 20, color: Color(0xFF991B1B)),
                      onPressed: () => _remove(p),
                      splashRadius: 16,
                    ),
                  ),
                ]),
            ],
          ),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _busy ? null : _pick,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kBrand))
              : const Icon(Icons.image_outlined, size: 18, color: kBrand),
          label: Text(_busy ? c('dev_queue.uploading') : c('dev_queue.btn_attach'),
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: kBrand)),
        ),
      ),
    ]);
  }
}
