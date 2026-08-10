import 'package:flutter/material.dart';
import '../services/ui_copy.dart';

/// Calls `request_account_deletion(scope, reason)` and returns the RPC payload
/// (`{ok, title?, message, already_open?}`) verbatim.
typedef DeletionRequestRpc =
    Future<Map<String, dynamic>> Function(String scope, String? reason);

/// The customer's "Delete my account" / "Delete my data only" actions.
///
/// The two buttons and the confirm prompt are ordinary app chrome; the WORDING
/// that matters — the 30-day / legal-retention notice and the "already with our
/// team" case — is never written here. It is whatever
/// `request_account_deletion` returns, rendered verbatim in the result dialog.
///
/// The RPC is injected so this widget carries no Supabase import and can be
/// pumped on the VM. The real call site (profile_screen) supplies the live RPC.
class DeleteAccountSection extends StatelessWidget {
  final DeletionRequestRpc rpc;

  const DeleteAccountSection({super.key, required this.rpc});

  static const _danger = Color(0xFFDC2626);

  Future<void> _request(BuildContext context, String scope) async {
    final reasonCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          scope == 'data' ? 'Delete my data only?' : 'Delete my account?',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c('delete_account_section.confirm_body'),
              style: const TextStyle(fontSize: 14, color: Color(0xFF374151)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reasonCtrl,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                hintText: c('delete_account_section.reason_hint'),
                filled: true,
                fillColor: const Color(0xFFF5F6F8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(c('delete_account_section.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: _danger),
            child: Text(c('delete_account_section.continue')),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final reason = reasonCtrl.text.trim();
    // Blocking spinner while the request is in flight.
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
      ),
    );
    Map<String, dynamic>? result;
    try {
      result = await rpc(scope, reason.isEmpty ? null : reason);
    } catch (_) {
      result = null;
    }
    if (!context.mounted) return;
    Navigator.of(context).pop(); // dismiss spinner
    if (!context.mounted) return;

    if (result == null) {
      // No payload = we could not reach the backend; retry affordance only, no
      // invented deletion copy.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(c('delete_account_section.please_try_again'))),
      );
      return;
    }
    _showResult(context, result);
  }

  void _showResult(BuildContext context, Map<String, dynamic> d) {
    final title = (d['title'] as String?) ?? '';
    final message = (d['message'] as String?) ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: title.isEmpty
            ? null
            : Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(message,
            style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43)),
            child: Text(c('delete_account_section.ok')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The destructive actions are collapsed behind a muted "danger zone" row —
    // no red button sitting next to Logout — so a tap meant for logout cannot
    // land on Delete. Opening it is a deliberate extra step, and each option
    // still passes through the confirm dialog below.
    // Border + rounded corners come from the tile's own shape (not a colored
    // Container wrapping the ListTile, which trips a Material ink-visibility
    // assertion).
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: const BorderSide(color: Color(0xFFE5E7EB)),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
            backgroundColor: Colors.white,
            collapsedBackgroundColor: Colors.white,
            shape: shape,
            collapsedShape: shape,
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            leading: const Icon(Icons.warning_amber_rounded,
                size: 20, color: Color(0xFF9CA3AF)),
            title: Text(
              c('delete_account_section.section_header'),
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280)),
            ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                c('delete_account_section.section_note'),
                style: const TextStyle(
                    fontSize: 12.5, color: Color(0xFF6B7280), height: 1.4),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => _request(context, 'account'),
                icon:
                    const Icon(Icons.delete_outline, size: 18, color: _danger),
                label: Text(c('delete_account_section.delete_my_account')),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _danger,
                  side: const BorderSide(color: _danger, width: 1.5),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  textStyle: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => _request(context, 'data'),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF6B7280)),
                child: Text(c('delete_account_section.delete_my_data_only')),
              ),
            ],
          ),
        ),
    );
  }
}
