import 'package:flutter/material.dart';

/// `admin_deletion_request_list(p_status)` → `{rows, count, has_rows, title}`.
typedef DeletionListRpc = Future<Map<String, dynamic>> Function(String status);

/// `admin_review_deletion_request(id, decision, note)` → `{ok, status, message}`.
typedef DeletionReviewRpc =
    Future<Map<String, dynamic>> Function(String id, String decision, String? note);

/// The admin "Deletion requests" queue — the sibling of registration approvals.
///
/// Every row is rendered exactly as `admin_deletion_request_list` returns it;
/// the screen sorts and filters nothing (the RPC's `p_status` does the
/// filtering, server-side, ordered by submitted_at). Approve/Reject call
/// `admin_review_deletion_request`, whose returned message is shown verbatim.
///
/// Both RPCs are injected so the screen carries no Supabase import and pumps on
/// the VM; home_shell supplies the live calls.
class AdminDeletionRequestScreen extends StatefulWidget {
  final DeletionListRpc listRpc;
  final DeletionReviewRpc reviewRpc;

  /// Fired after a successful review so the shell can refresh its badge count.
  final VoidCallback? onChanged;

  const AdminDeletionRequestScreen({
    super.key,
    required this.listRpc,
    required this.reviewRpc,
    this.onChanged,
  });

  @override
  State<AdminDeletionRequestScreen> createState() =>
      _AdminDeletionRequestScreenState();
}

class _AdminDeletionRequestScreenState
    extends State<AdminDeletionRequestScreen> {
  static const _filters = ['pending', 'approved', 'rejected', 'all'];
  String _status = 'pending';
  bool _loading = true;
  String _title = 'Account deletion requests';
  List<Map<String, dynamic>> _rows = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final payload = await widget.listRpc(_status);
      final rows = ((payload['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _title = (payload['title'] as String?) ?? _title;
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _review(Map<String, dynamic> row, String decision) async {
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          decision == 'approve' ? 'Approve request?' : 'Reject request?',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: noteCtrl,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Note (optional)',
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: decision == 'approve'
                  ? const Color(0xFF1B5E20)
                  : const Color(0xFF991B1B),
            ),
            child: Text(decision == 'approve' ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final note = noteCtrl.text.trim();
    Map<String, dynamic>? result;
    try {
      result = await widget.reviewRpc(
          '${row['id']}', decision, note.isEmpty ? null : note);
    } catch (_) {
      result = null;
    }
    if (!mounted) return;

    final message = (result?['message'] as String?) ?? 'Please try again.';
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
    if (result?['ok'] == true) {
      widget.onChanged?.call();
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_title,
            style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827))),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFF374151)),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 8,
              children: [
                for (final f in _filters)
                  ChoiceChip(
                    label: Text(f[0].toUpperCase() + f.substring(1)),
                    selected: _status == f,
                    onSelected: (_) {
                      if (_status == f) return;
                      setState(() => _status = f);
                      _load();
                    },
                    selectedColor: const Color(0xFFD1FAE5),
                    labelStyle: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: _status == f
                          ? const Color(0xFF065F46)
                          : const Color(0xFF6B7280),
                    ),
                    backgroundColor: const Color(0xFFF5F6F8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF1B5E20)))
          : _rows.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.person_remove_outlined,
                          size: 48, color: Color(0xFFD1D5DB)),
                      SizedBox(height: 12),
                      Text('No requests here',
                          style: TextStyle(
                              fontSize: 15, color: Color(0xFF6B7280))),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _DeletionCard(
                    row: _rows[i],
                    onApprove: () => _review(_rows[i], 'approve'),
                    onReject: () => _review(_rows[i], 'reject'),
                  ),
                ),
    );
  }
}

class _DeletionCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  const _DeletionCard(
      {required this.row, required this.onApprove, required this.onReject});

  @override
  Widget build(BuildContext context) {
    final status = '${row['status'] ?? 'pending'}';
    final isPending = status == 'pending';
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: const [
          BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2))
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text('${row['pharmacy_name'] ?? '—'}',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827))),
            ),
            _Chip('${row['scope'] ?? 'account'}',
                bg: const Color(0xFFEFF6FF), fg: const Color(0xFF1E40AF)),
            const SizedBox(width: 6),
            _StatusChip(status),
          ]),
          const SizedBox(height: 8),
          _InfoRow(Icons.person_outline, '${row['owner_name'] ?? '—'}'),
          _InfoRow(Icons.phone_outlined, '${row['phone'] ?? '—'}'),
          if ('${row['email'] ?? ''}'.isNotEmpty)
            _InfoRow(Icons.email_outlined, '${row['email']}'),
          if ('${row['customer_code'] ?? ''}'.isNotEmpty)
            _InfoRow(Icons.tag_outlined, 'Code: ${row['customer_code']}'),
          if ('${row['reason'] ?? ''}'.isNotEmpty)
            _InfoRow(Icons.notes_outlined, '${row['reason']}'),
          _InfoRow(Icons.schedule_outlined, '${row['submitted_at'] ?? ''}',
              subtle: true),
          if (isPending) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Reject'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF991B1B),
                    side: const BorderSide(color: Color(0xFF991B1B)),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Approve'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B5E20),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool subtle;
  const _InfoRow(this.icon, this.text, {this.subtle = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(children: [
        Icon(icon,
            size: 14,
            color: subtle ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280)),
        const SizedBox(width: 7),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 13,
                  color: subtle
                      ? const Color(0xFF9CA3AF)
                      : const Color(0xFF374151))),
        ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String text;
  final Color bg;
  final Color fg;
  const _Chip(this.text, {required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(text,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (status) {
      case 'approved':
        bg = const Color(0xFFD1FAE5);
        fg = const Color(0xFF065F46);
        break;
      case 'rejected':
        bg = const Color(0xFFFEE2E2);
        fg = const Color(0xFF991B1B);
        break;
      default:
        bg = const Color(0xFFFEF3C7);
        fg = const Color(0xFF92400E);
    }
    final label = status.isEmpty
        ? '—'
        : status[0].toUpperCase() + status.substring(1);
    return _Chip(label, bg: bg, fg: fg);
  }
}
