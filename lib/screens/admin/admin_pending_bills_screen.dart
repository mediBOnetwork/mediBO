import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import 'admin_add_medicine_screen.dart';

// ── Top-level helpers ─────────────────────────────────────────────────────────

/// Returns the trimmed supplier name, or null if absent/empty.
String? _effectiveName(Map<String, dynamic>? scanResult) {
  final raw = scanResult?['supplier_name'] as String?;
  final trimmed = raw?.trim();
  return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
}

/// Supplier name cell: shows name plainly for all row types.
Widget _supplierNameCell(String? name, bool isFake, {bool large = false}) {
  if (name != null) {
    return Text(
      name,
      style: TextStyle(
        fontSize: large ? 14 : 13,
        fontWeight: FontWeight.w600,
        color: const Color(0xFF111827),
      ),
      maxLines: large ? 2 : 1,
      overflow: TextOverflow.ellipsis,
    );
  }
  return Text(
    isFake ? 'Unknown supplier' : '—',
    style: TextStyle(
      fontSize: large ? 13 : 12,
      color: const Color(0xFFD1D5DB),
      fontStyle: isFake ? FontStyle.italic : null,
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

// ── Shared constants ──────────────────────────────────────────────────────────

const _kTh = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF),
  letterSpacing: 0.5,
);

// ── TYPE badge — compact pill, never stretches ────────────────────────────────

class _TypeBadge extends StatelessWidget {
  final String? verdict;
  final String? scanStatus;
  const _TypeBadge(this.verdict, {this.scanStatus});

  @override
  Widget build(BuildContext context) {
    final ss = scanStatus ?? 'pending';
    if (ss == 'pending' || ss == 'scanning') {
      return Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(
          width: 11,
          height: 11,
          child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF9CA3AF)),
        ),
        SizedBox(width: 5),
        Text(
          'scanning…',
          style: TextStyle(fontSize: 10, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500),
        ),
      ]);
    }
    if (ss == 'error') {
      return _pill('SCAN ERR', const Color(0xFFDC2626), const Color(0xFFFEE2E2));
    }
    switch (verdict) {
      case 'real':
        return _pill('REAL', const Color(0xFF15803D), const Color(0xFFDCFCE7));
      case 'needs_approval':
        return _pill('APPROVAL', const Color(0xFFB45309), const Color(0xFFFEF3C7));
      case 'fake':
        return _pill('FAKE', const Color(0xFFDC2626), const Color(0xFFFEE2E2));
      default:
        return _pill('—', const Color(0xFF9CA3AF), const Color(0xFFF3F4F6));
    }
  }

  // Align keeps the pill left-aligned and content-sized inside any SizedBox parent.
  Widget _pill(String label, Color fg, Color bg) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w700,
            color: fg,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

// ── Approval dropdown ─────────────────────────────────────────────────────────

class _ApprovalDropdown extends StatefulWidget {
  final bool loading;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  const _ApprovalDropdown({
    required this.loading,
    required this.onApprove,
    required this.onReject,
  });

  @override
  State<_ApprovalDropdown> createState() => _ApprovalDropdownState();
}

class _ApprovalDropdownState extends State<_ApprovalDropdown> {
  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFD97706)),
      );
    }
    return PopupMenuButton<String>(
      onSelected: (v) => v == 'approve' ? widget.onApprove() : widget.onReject(),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'approve',
          child: Row(children: [
            Icon(Icons.check_circle_outline, size: 16, color: Color(0xFF1B7A43)),
            SizedBox(width: 8),
            Text('Approve sender', style: TextStyle(fontSize: 13)),
          ]),
        ),
        const PopupMenuItem(
          value: 'reject',
          child: Row(children: [
            Icon(Icons.cancel_outlined, size: 16, color: Color(0xFFDC2626)),
            SizedBox(width: 8),
            Text('Reject bill', style: TextStyle(fontSize: 13)),
          ]),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.pending_outlined, size: 14, color: Color(0xFFD97706)),
          SizedBox(width: 4),
          Text(
            'Approval required',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFD97706)),
          ),
          SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFFD97706)),
        ]),
      ),
    );
  }
}

// ── View button — consistent height whether loading or idle ───────────────────

class _ViewBtn extends StatelessWidget {
  final bool loading;
  final VoidCallback? onTap;
  const _ViewBtn({required this.loading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Fixed container height so the VIEW column never collapses while loading.
    return SizedBox(
      height: 30,
      child: loading
          ? const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
              ),
            )
          : InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.open_in_new, size: 13, color: Color(0xFF2563EB)),
                  SizedBox(width: 4),
                  Text(
                    'View',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF2563EB),
                    ),
                  ),
                ]),
              ),
            ),
    );
  }
}

// ── Action button ─────────────────────────────────────────────────────────────

class _ActionBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool loading;
  final VoidCallback? onTap;
  final bool expanded;

  const _ActionBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.loading,
    required this.onTap,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    Widget inner = loading
        ? SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: active ? color : const Color(0xFFD1D5DB)),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: active ? color : const Color(0xFFD1D5DB),
              ),
            ),
          ]);

    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(
            color: active ? color.withValues(alpha: 0.4) : const Color(0xFFE5E7EB),
          ),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(child: inner),
      ),
    );
    return expanded ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}

// ── Desktop bill row ──────────────────────────────────────────────────────────
// Columns: SUPPLIER NAME | TYPE | RECEIVED AT | FROM | VIEW | ACTION

class _DesktopBillRow extends StatelessWidget {
  final Map<String, dynamic> bill;
  final bool isEven;
  final bool isLast;
  final String receivedStr;
  final bool isDownloading;
  final bool isDismissing;
  final bool isApproving;
  final bool isViewing;
  final VoidCallback onImport;
  final VoidCallback onDismiss;
  final VoidCallback onApprove;
  final VoidCallback onRetryScan;
  final VoidCallback onView;

  const _DesktopBillRow({
    required this.bill,
    required this.isEven,
    required this.isLast,
    required this.receivedStr,
    required this.isDownloading,
    required this.isDismissing,
    required this.isApproving,
    required this.isViewing,
    required this.onImport,
    required this.onDismiss,
    required this.onApprove,
    required this.onRetryScan,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final senderEmail = bill['sender_email'] as String? ?? '—';
    final verdict = bill['verdict'] as String?;
    final scanStatus = bill['scan_status'] as String? ?? 'pending';
    final scanResult = bill['scan_result'] as Map<String, dynamic>?;
    final name = _effectiveName(scanResult);
    final isFake = verdict == 'fake';

    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      decoration: BoxDecoration(
        color: isEven ? Colors.white : const Color(0xFFFAFAFA),
        border: isLast
            ? null
            : const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // SUPPLIER NAME
          Expanded(
            flex: 5,
            child: _supplierNameCell(name, isFake),
          ),
          const SizedBox(width: 12),
          // TYPE
          SizedBox(
            width: 88,
            child: _TypeBadge(verdict, scanStatus: scanStatus),
          ),
          const SizedBox(width: 12),
          // RECEIVED AT
          Expanded(
            flex: 3,
            child: Text(
              receivedStr,
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
          ),
          const SizedBox(width: 12),
          // FROM
          Expanded(
            flex: 4,
            child: Text(
              senderEmail,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 12),
          // VIEW — fixed width matches header SizedBox(68)
          SizedBox(width: 68, child: _ViewBtn(loading: isViewing, onTap: isViewing ? null : onView)),
          const SizedBox(width: 12),
          // ACTION
          SizedBox(width: 190, child: _buildActions(verdict, scanStatus)),
        ],
      ),
    );
  }

  Widget _buildActions(String? verdict, String scanStatus) {
    final busy = isDownloading || isDismissing || isApproving;
    if (scanStatus == 'pending' || scanStatus == 'scanning') {
      return const SizedBox.shrink();
    }
    if (scanStatus == 'error') {
      return Align(
        alignment: Alignment.centerLeft,
        child: _ActionBtn(
          label: 'Retry Scan',
          icon: Icons.refresh_rounded,
          color: const Color(0xFF374151),
          loading: false,
          onTap: onRetryScan,
        ),
      );
    }
    switch (verdict) {
      case 'real':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          _ActionBtn(
            label: 'Import',
            icon: Icons.upload_rounded,
            color: const Color(0xFF1B7A43),
            loading: isDownloading,
            onTap: busy ? null : onImport,
          ),
          const SizedBox(width: 6),
          _ActionBtn(
            label: 'Dismiss',
            icon: Icons.close_rounded,
            color: const Color(0xFF6B7280),
            loading: isDismissing,
            onTap: busy ? null : onDismiss,
          ),
        ]);
      case 'needs_approval':
        return _ApprovalDropdown(
          loading: isApproving,
          onApprove: onApprove,
          onReject: onDismiss,
        );
      case 'fake':
        return Align(
          alignment: Alignment.centerLeft,
          child: _ActionBtn(
            label: 'Dismiss',
            icon: Icons.close_rounded,
            color: const Color(0xFF6B7280),
            loading: isDismissing,
            onTap: busy ? null : onDismiss,
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ── Mobile bill card ──────────────────────────────────────────────────────────

class _MobileBillCard extends StatelessWidget {
  final Map<String, dynamic> bill;
  final IconData fileIcon;
  final Color fileIconColor;
  final String receivedStr;
  final bool isDownloading;
  final bool isDismissing;
  final bool isApproving;
  final bool isViewing;
  final VoidCallback onImport;
  final VoidCallback onDismiss;
  final VoidCallback onApprove;
  final VoidCallback onRetryScan;
  final VoidCallback onView;

  const _MobileBillCard({
    required this.bill,
    required this.fileIcon,
    required this.fileIconColor,
    required this.receivedStr,
    required this.isDownloading,
    required this.isDismissing,
    required this.isApproving,
    required this.isViewing,
    required this.onImport,
    required this.onDismiss,
    required this.onApprove,
    required this.onRetryScan,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final senderEmail = bill['sender_email'] as String? ?? '—';
    final verdict = bill['verdict'] as String?;
    final scanStatus = bill['scan_status'] as String? ?? 'pending';
    final scanResult = bill['scan_result'] as Map<String, dynamic>?;
    final name = _effectiveName(scanResult);
    final isFake = verdict == 'fake';
    final busy = isDownloading || isDismissing || isApproving;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Top row: icon + supplier name + type badge
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: fileIconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(fileIcon, size: 20, color: fileIconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _supplierNameCell(name, isFake, large: true),
                  const SizedBox(height: 5),
                  _TypeBadge(verdict, scanStatus: scanStatus),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 10),
          // RECEIVED AT
          Row(children: [
            const Icon(Icons.access_time, size: 12, color: Color(0xFF9CA3AF)),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                receivedStr,
                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          const SizedBox(height: 4),
          // FROM
          Row(children: [
            const Icon(Icons.email_outlined, size: 12, color: Color(0xFF9CA3AF)),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                senderEmail,
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          // VIEW + ACTION
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ViewBtn(loading: isViewing, onTap: isViewing ? null : onView),
              const SizedBox(width: 8),
              Expanded(child: _buildMobileActions(verdict, scanStatus, busy)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMobileActions(String? verdict, String scanStatus, bool busy) {
    if (scanStatus == 'pending' || scanStatus == 'scanning') {
      return const SizedBox.shrink();
    }
    if (scanStatus == 'error') {
      return _ActionBtn(
        label: 'Retry Scan',
        icon: Icons.refresh_rounded,
        color: const Color(0xFF374151),
        loading: false,
        onTap: onRetryScan,
        expanded: true,
      );
    }
    switch (verdict) {
      case 'real':
        return Row(children: [
          Expanded(
            child: _ActionBtn(
              label: 'Import',
              icon: Icons.upload_rounded,
              color: const Color(0xFF1B7A43),
              loading: isDownloading,
              onTap: busy ? null : onImport,
              expanded: true,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionBtn(
              label: 'Dismiss',
              icon: Icons.close_rounded,
              color: const Color(0xFF6B7280),
              loading: isDismissing,
              onTap: busy ? null : onDismiss,
              expanded: true,
            ),
          ),
        ]);
      case 'needs_approval':
        return _ApprovalDropdown(
          loading: isApproving,
          onApprove: onApprove,
          onReject: onDismiss,
        );
      case 'fake':
        return _ActionBtn(
          label: 'Dismiss',
          icon: Icons.close_rounded,
          color: const Color(0xFF6B7280),
          loading: isDismissing,
          onTap: busy ? null : onDismiss,
          expanded: true,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

// ── Main screen ───────────────────────────────────────────────────────────────

class PendingBillsScreen extends StatefulWidget {
  final VoidCallback? onCountChanged;
  const PendingBillsScreen({super.key, this.onCountChanged});

  @override
  State<PendingBillsScreen> createState() => _PendingBillsScreenState();
}

class _PendingBillsScreenState extends State<PendingBillsScreen> {
  List<Map<String, dynamic>> _bills = [];
  bool _loading = true;
  String? _error;
  bool _fakeExpanded = false;
  DateTime _selectedDate = DateTime.now();
  final Map<String, bool> _downloading = {};
  final Map<String, bool> _dismissing = {};
  final Map<String, bool> _approving = {};
  final Map<String, bool> _viewing = {};

  RealtimeChannel? _channel;

  @override
  void initState() {
    super.initState();
    _load().then((_) => _subscribeRealtime());
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    super.dispose();
  }

  // ── Date picker ───────────────────────────────────────────────────────────────

  String _fmtDateLabel(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final sel = DateTime(d.year, d.month, d.day);
    if (sel == today) return 'Today';
    if (sel == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF1B7A43)),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
      _load();
    }
  }

  // ── Data loading ──────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final dayStart = DateTime(_selectedDate.year, _selectedDate.month, _selectedDate.day).toUtc();
      final dayEnd = dayStart.add(const Duration(days: 1));
      final rows = await Supabase.instance.client
          .from('pending_bills')
          .select()
          .eq('status', 'pending')
          .gte('received_at', dayStart.toIso8601String())
          .lt('received_at', dayEnd.toIso8601String())
          .order('received_at', ascending: false);
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (mounted) setState(() { _bills = list; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _loading = false;
        });
      }
    }
  }

  // ── Realtime subscription — auto-updates rows as scan completes ───────────────

  void _subscribeRealtime() {
    _channel?.unsubscribe();
    _channel = Supabase.instance.client
        .channel('pending_bills_scan_updates')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'pending_bills',
          callback: (payload) {
            if (!mounted) return;
            final updated = Map<String, dynamic>.from(payload.newRecord);
            final id = updated['id'] as String?;
            if (id == null) return;
            setState(() {
              final idx = _bills.indexWhere((b) => b['id'] == id);
              if (idx < 0) return;
              final newStatus = updated['status'] as String? ?? 'pending';
              if (newStatus == 'imported' || newStatus == 'dismissed') {
                _bills.removeAt(idx);
                widget.onCountChanged?.call();
              } else {
                _bills[idx] = updated;
              }
            });
          },
        )
        .subscribe();
  }

  // ── Actions ───────────────────────────────────────────────────────────────────

  Future<void> _dismiss(String id) async {
    setState(() => _dismissing[id] = true);
    try {
      await Supabase.instance.client
          .from('pending_bills')
          .update({'status': 'dismissed'})
          .eq('id', id);
      setState(() {
        _bills.removeWhere((b) => b['id'] == id);
        _dismissing.remove(id);
      });
      widget.onCountChanged?.call();
    } catch (e) {
      setState(() => _dismissing.remove(id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Dismiss failed: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _importBill(Map<String, dynamic> bill) async {
    final id = bill['id'] as String;
    final filePath = bill['file_path'] as String;
    final fileName = bill['file_name'] as String;

    setState(() => _downloading[id] = true);
    try {
      final bytes = await Supabase.instance.client.storage
          .from('supplier-bills')
          .download(filePath);
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AdminAddMedicineScreen(
          preloadedBytes: bytes,
          preloadedFileName: fileName,
          onImportComplete: () async {
            try {
              await Supabase.instance.client
                  .from('pending_bills')
                  .update({
                    'status': 'imported',
                    'imported_at': DateTime.now().toIso8601String(),
                  })
                  .eq('id', id);
            } catch (_) {}
            widget.onCountChanged?.call();
          },
        ),
      ));
      if (!mounted) return;
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Download failed: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _downloading.remove(id));
    }
  }

  Future<void> _approveBill(Map<String, dynamic> bill) async {
    final id = bill['id'] as String;
    final scanResult = bill['scan_result'] as Map<String, dynamic>?;
    final supplierId = scanResult?['matched_supplier_id'] as String?;
    String senderEmail = (bill['sender_email'] as String? ?? '').trim();
    final emailMatch = RegExp(r'<([^>]+)>').firstMatch(senderEmail);
    if (emailMatch != null) senderEmail = emailMatch.group(1)!.trim();
    senderEmail = senderEmail.toLowerCase();

    if (supplierId == null || senderEmail.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Cannot approve: no matched supplier in scan result.'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    setState(() => _approving[id] = true);
    try {
      await Supabase.instance.client.rpc('append_supplier_email', params: {
        'p_supplier_id': supplierId,
        'p_email': senderEmail,
      });
      await Supabase.instance.client
          .from('pending_bills')
          .update({'verdict': 'real'})
          .eq('id', id);
      setState(() => _approving.remove(id));
      await _load();
    } catch (e) {
      setState(() => _approving.remove(id));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Approval failed: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _viewBill(Map<String, dynamic> bill) async {
    final id = bill['id'] as String;
    final filePath = bill['file_path'] as String;
    setState(() => _viewing[id] = true);
    try {
      final signedUrl = await Supabase.instance.client.storage
          .from('supplier-bills')
          .createSignedUrl(filePath, 3600);
      final uri = Uri.parse(signedUrl);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cannot open file: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _viewing.remove(id));
    }
  }

  Future<void> _retryScan(Map<String, dynamic> bill) async {
    final id = bill['id'] as String;
    try {
      final idx = _bills.indexWhere((b) => b['id'] == id);
      if (idx >= 0 && mounted) {
        setState(() => _bills[idx] = Map.from(_bills[idx])
          ..['scan_status'] = 'scanning'
          ..['verdict'] = null
          ..['scan_result'] = null);
      }
      await Supabase.instance.client.from('pending_bills').update({
        'scan_status': 'scanning',
        'verdict': null,
        'scan_result': null,
      }).eq('id', id);
      // ignore: unawaited_futures
      Supabase.instance.client.functions.invoke('scan-bill', body: {
        'record': {
          'id': id,
          'file_path': bill['file_path'],
          'sender_email': bill['sender_email'] ?? '',
        },
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Retry failed: ${e.toString().replaceFirst('Exception: ', '')}'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────────

  static IconData _fileIcon(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'xlsx':
      case 'xls':
      case 'ods':
        return Icons.table_chart_outlined;
      case 'csv':
      case 'tsv':
      case 'txt':
        return Icons.grid_on_outlined;
      case 'docx':
      case 'doc':
        return Icons.description_outlined;
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'webp':
      case 'gif':
        return Icons.image_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  static Color _fileIconColor(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf':
        return const Color(0xFFDC2626);
      case 'xlsx':
      case 'xls':
      case 'ods':
      case 'csv':
        return const Color(0xFF1B7A43);
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'webp':
        return const Color(0xFF1E40AF);
      default:
        return const Color(0xFF374151);
    }
  }

  String _fmtDate(dynamic val) {
    if (val == null) return '—';
    try {
      final dt = DateTime.parse(val.toString()).toLocal();
      final months = [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
      ];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}, '
          '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return val.toString();
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isDesktop = c.maxWidth >= 768;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _buildHeader(isDesktop),
        Expanded(child: _buildBody(isDesktop)),
      ]);
    });
  }

  Widget _buildHeader(bool isDesktop) {
    final actionable = _bills.where((b) {
      final ss = b['scan_status'] as String? ?? 'pending';
      final v = b['verdict'] as String?;
      return ss == 'done' && (v == 'real' || v == 'needs_approval');
    }).length;
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(
        isDesktop ? 24 : 16, 16, isDesktop ? 24 : 16, 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text(
            'Pending Bills',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827),
            ),
          ),
          if (!_loading && actionable > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFDC2626),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$actionable',
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          const Spacer(),
          // Date picker chip
          InkWell(
            onTap: _loading ? null : _pickDate,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE5E7EB)),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.calendar_today_outlined, size: 13, color: Color(0xFF6B7280)),
                const SizedBox(width: 5),
                Text(
                  _fmtDateLabel(_selectedDate),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                ),
                const SizedBox(width: 3),
                const Icon(Icons.arrow_drop_down, size: 16, color: Color(0xFF6B7280)),
              ]),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF6B7280)),
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
          ),
        ]),
      ]),
    );
  }

  Widget _buildBody(bool isDesktop) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2.5),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, size: 40, color: Color(0xFFDC2626)),
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _load,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            child: const Text('Retry'),
          ),
        ]),
      );
    }
    if (_bills.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: const Color(0xFFECFDF5),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(Icons.inbox_outlined, size: 36, color: Color(0xFF1B7A43)),
          ),
          const SizedBox(height: 18),
          const Text(
            'No pending bills',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: Color(0xFF111827),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Bills forwarded by the Gmail script will appear here.',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ]),
      );
    }

    final scanning = _bills.where((b) {
      final ss = b['scan_status'] as String? ?? 'pending';
      return ss == 'pending' || ss == 'scanning';
    }).toList();
    final scanError     = _bills.where((b) => (b['scan_status'] as String?) == 'error').toList();
    final real          = _bills.where((b) => b['verdict'] == 'real').toList();
    final needsApproval = _bills.where((b) => b['verdict'] == 'needs_approval').toList();
    final fake          = _bills.where((b) => b['verdict'] == 'fake').toList();

    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF1B7A43),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.all(isDesktop ? 20 : 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (scanning.isNotEmpty)
            _buildSection(
              icon: Icons.radar_outlined,
              iconColor: const Color(0xFF6B7280),
              title: 'Scanning…',
              badge: scanning.length,
              badgeColor: const Color(0xFF6B7280),
              bills: scanning,
              isDesktop: isDesktop,
            ),
          if (scanError.isNotEmpty)
            _buildSection(
              icon: Icons.error_outline,
              iconColor: const Color(0xFFDC2626),
              title: 'Scan Failed',
              badge: scanError.length,
              badgeColor: const Color(0xFFDC2626),
              bills: scanError,
              isDesktop: isDesktop,
            ),
          if (needsApproval.isNotEmpty)
            _buildSection(
              icon: Icons.pending_outlined,
              iconColor: const Color(0xFFD97706),
              title: 'Needs Approval',
              badge: needsApproval.length,
              badgeColor: const Color(0xFFD97706),
              bills: needsApproval,
              isDesktop: isDesktop,
            ),
          if (real.isNotEmpty)
            _buildSection(
              icon: Icons.verified_outlined,
              iconColor: const Color(0xFF1B7A43),
              title: 'Verified Real',
              badge: real.length,
              badgeColor: const Color(0xFF1B7A43),
              bills: real,
              isDesktop: isDesktop,
            ),
          if (fake.isNotEmpty) _buildFakeSection(fake, isDesktop),
        ]),
      ),
    );
  }

  Widget _buildSection({
    required IconData icon,
    required Color iconColor,
    required String title,
    required int badge,
    required Color badgeColor,
    required List<Map<String, dynamic>> bills,
    required bool isDesktop,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(icon, size: 16, color: iconColor),
          const SizedBox(width: 6),
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: iconColor,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$badge',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: badgeColor,
              ),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        if (isDesktop)
          _buildDesktopTable(bills)
        else
          ...bills.map((b) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _buildMobileCard(b),
              )),
      ]),
    );
  }

  Widget _buildFakeSection(List<Map<String, dynamic>> bills, bool isDesktop) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: const Color(0xFFFECACA)),
          borderRadius: BorderRadius.circular(10),
          color: const Color(0xFFFFF5F5),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: () => setState(() => _fakeExpanded = !_fakeExpanded),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(children: [
                const Icon(Icons.warning_amber_outlined, size: 16, color: Color(0xFFDC2626)),
                const SizedBox(width: 6),
                const Text(
                  'Fake / Unrecognised Bills',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFDC2626),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFECACA),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${bills.length}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFFDC2626),
                    ),
                  ),
                ),
                const Spacer(),
                Icon(
                  _fakeExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: const Color(0xFFDC2626),
                ),
              ]),
            ),
          ),
          if (_fakeExpanded) ...[
            const Divider(height: 1, color: Color(0xFFFECACA)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (isDesktop)
                  _buildDesktopTable(bills)
                else
                  ...bills.map((b) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _buildMobileCard(b),
                      )),
              ]),
            ),
          ],
        ]),
      ),
    );
  }

  // ── Desktop table ─────────────────────────────────────────────────────────────

  Widget _buildDesktopTable(List<Map<String, dynamic>> bills) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Header — padding and widths must mirror the rows exactly.
        Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF9FAFB),
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(12), topRight: Radius.circular(12)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(children: const [
            Expanded(flex: 5, child: Text('SUPPLIER NAME', style: _kTh)),
            SizedBox(width: 12),
            SizedBox(width: 88, child: Text('TYPE', style: _kTh)),
            SizedBox(width: 12),
            Expanded(flex: 3, child: Text('RECEIVED AT', style: _kTh)),
            SizedBox(width: 12),
            Expanded(flex: 4, child: Text('FROM', style: _kTh)),
            SizedBox(width: 12),
            SizedBox(width: 68, child: Text('VIEW', style: _kTh)),
            SizedBox(width: 12),
            SizedBox(width: 190, child: Text('ACTION', style: _kTh)),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        for (int i = 0; i < bills.length; i++)
          _DesktopBillRow(
            bill: bills[i],
            isEven: i % 2 == 0,
            isLast: i == bills.length - 1,
            receivedStr: _fmtDate(bills[i]['received_at']),
            isDownloading: _downloading[bills[i]['id']] == true,
            isDismissing: _dismissing[bills[i]['id']] == true,
            isApproving: _approving[bills[i]['id']] == true,
            isViewing: _viewing[bills[i]['id']] == true,
            onImport: () => _importBill(bills[i]),
            onDismiss: () => _dismiss(bills[i]['id'] as String),
            onApprove: () => _approveBill(bills[i]),
            onRetryScan: () => _retryScan(bills[i]),
            onView: () => _viewBill(bills[i]),
          ),
      ]),
    );
  }

  // ── Mobile card ───────────────────────────────────────────────────────────────

  Widget _buildMobileCard(Map<String, dynamic> bill) {
    final id = bill['id'] as String;
    return _MobileBillCard(
      bill: bill,
      fileIcon: _fileIcon(bill['file_name'] as String? ?? ''),
      fileIconColor: _fileIconColor(bill['file_name'] as String? ?? ''),
      receivedStr: _fmtDate(bill['received_at']),
      isDownloading: _downloading[id] == true,
      isDismissing: _dismissing[id] == true,
      isApproving: _approving[id] == true,
      isViewing: _viewing[id] == true,
      onImport: () => _importBill(bill),
      onDismiss: () => _dismiss(id),
      onApprove: () => _approveBill(bill),
      onRetryScan: () => _retryScan(bill),
      onView: () => _viewBill(bill),
    );
  }
}
