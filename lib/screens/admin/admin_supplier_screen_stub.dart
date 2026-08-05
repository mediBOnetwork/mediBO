import 'package:flutter/material.dart';
import '../platform_unavailable.dart';
import '../../widgets/backend_chip.dart' show backendHex;

/// Android stub for the supplier console. The full screen is web-only (CSV
/// file pickers, window.open links). The small backend-driven send widgets
/// below are pure Flutter — kept as the real implementations so their unit
/// tests (inquiry/order_manual_send) compile and run off-web too.
class AdminSupplierScreen extends StatelessWidget {
  AdminSupplierScreen({super.key});
  static void triggerFocus() {}
  @override
  Widget build(BuildContext context) => const PlatformUnavailableScreen();
}

// ── InquirySendButton (verbatim from the web screen — no web APIs) ────────────
class InquirySendButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onOpenPopupOnly;
  final Widget child;

  const InquirySendButton({
    super.key,
    required this.enabled,
    required this.onOpenPopupOnly,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: !enabled ? null : onOpenPopupOnly,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }
}

// ── SendButtonView (verbatim — backend-owned label/tone, no web APIs) ─────────
class SendButtonView extends StatelessWidget {
  final Map<String, dynamic>? sendButton;

  const SendButtonView({super.key, required this.sendButton});

  @override
  Widget build(BuildContext context) {
    final sb = sendButton;
    final label = sb?['label'] as String? ?? '';
    if (label.isEmpty) return const SizedBox.shrink();
    final enabled =
        sb == null || !sb.containsKey('enabled') || sb['enabled'] == true;
    final cBg = backendHex(sb?['bg'] as String?, const Color(0xFFEDEFF2));
    final cFg = backendHex(sb?['fg'] as String?, const Color(0xFF5A6472));
    final cBorder = backendHex(sb?['border'] as String?, cBg);
    return Opacity(
      opacity: enabled ? 1.0 : 0.5,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: cBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.send_outlined, size: 13, color: cFg),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: cFg)),
        ]),
      ),
    );
  }
}

// ── ContactPickerPopover ──────────────────────────────────────────────────────
// The real popover uses dart:html (mailto window.open) and is web-only. This
// signature-compatible stub keeps callers and the analyzer happy off-web; the
// live WhatsApp-send flow it drives has no native implementation in this build.
class ContactPickerPopover extends StatefulWidget {
  final Rect btnRect;
  final String supplierName;
  final String message;
  final Map<String, dynamic> contactData;
  final VoidCallback onDismiss;
  final Future<void> Function()? onManualSendSuccess;
  final Future<Map<String, dynamic>> Function(
      {required String supplier, required String phone})? sendInquiryRpc;
  final Map<String, dynamic>? sendOptions;
  final String sentLabel;

  const ContactPickerPopover({
    super.key,
    required this.btnRect,
    required this.supplierName,
    required this.message,
    required this.contactData,
    required this.onDismiss,
    this.onManualSendSuccess,
    this.sendInquiryRpc,
    this.sendOptions,
    this.sentLabel = 'Inquiry',
  });

  @override
  State<ContactPickerPopover> createState() => _ContactPickerPopoverStub();
}

class _ContactPickerPopoverStub extends State<ContactPickerPopover> {
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
