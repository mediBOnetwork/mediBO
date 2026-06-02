import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_add_medicine_screen.dart';

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
  final Map<String, TextEditingController> _supplierCtrls = {};
  final Map<String, bool> _downloading = {};
  final Map<String, bool> _dismissing = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _supplierCtrls.values) c.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await Supabase.instance.client
          .from('pending_bills')
          .select()
          .eq('status', 'pending')
          .order('received_at', ascending: false);
      final list = List<Map<String, dynamic>>.from(rows as List);
      final existing = Set<String>.from(_supplierCtrls.keys);
      final incoming = Set<String>.from(list.map((b) => b['id'] as String));
      for (final id in existing.difference(incoming)) {
        _supplierCtrls[id]?.dispose();
        _supplierCtrls.remove(id);
      }
      for (final bill in list) {
        final id = bill['id'] as String;
        if (!_supplierCtrls.containsKey(id)) {
          _supplierCtrls[id] = TextEditingController(text: bill['supplier_name'] ?? '');
        }
      }
      setState(() { _bills = list; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString().replaceFirst('Exception: ', ''); _loading = false; });
    }
  }

  Future<void> _dismiss(String id) async {
    setState(() => _dismissing[id] = true);
    try {
      await Supabase.instance.client
          .from('pending_bills')
          .update({'status': 'dismissed'})
          .eq('id', id);
      setState(() {
        _bills.removeWhere((b) => b['id'] == id);
        _supplierCtrls[id]?.dispose();
        _supplierCtrls.remove(id);
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

  Future<void> _saveSupplier(String id) async {
    final name = _supplierCtrls[id]?.text.trim() ?? '';
    try {
      await Supabase.instance.client
          .from('pending_bills')
          .update({'supplier_name': name.isNotEmpty ? name : null})
          .eq('id', id);
    } catch (_) {}
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

  // ── Helpers ───────────────────────────────────────────────────────────────────

  static IconData _fileIcon(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf': return Icons.picture_as_pdf_outlined;
      case 'xlsx': case 'xls': case 'ods': return Icons.table_chart_outlined;
      case 'csv': case 'tsv': case 'txt': return Icons.grid_on_outlined;
      case 'docx': case 'doc': return Icons.description_outlined;
      case 'jpg': case 'jpeg': case 'png': case 'webp': case 'gif': return Icons.image_outlined;
      default: return Icons.insert_drive_file_outlined;
    }
  }

  static Color _fileIconColor(String name) {
    final ext = name.toLowerCase().split('.').last;
    switch (ext) {
      case 'pdf': return const Color(0xFFDC2626);
      case 'xlsx': case 'xls': case 'ods': case 'csv': return const Color(0xFF16A34A);
      case 'jpg': case 'jpeg': case 'png': case 'webp': return const Color(0xFF7C3AED);
      default: return const Color(0xFF374151);
    }
  }

  String _fmtDate(dynamic val) {
    if (val == null) return '—';
    try {
      final dt = DateTime.parse(val.toString()).toLocal();
      final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
      return '${dt.day} ${months[dt.month - 1]} ${dt.year}, ${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return val.toString(); }
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
    return Container(
      color: Colors.white,
      padding: EdgeInsets.fromLTRB(isDesktop ? 24 : 16, 16, isDesktop ? 24 : 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Text('Pending Bills',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
            if (!_loading && _bills.isNotEmpty) ...[
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFFDC2626),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_bills.length}',
                  style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.w700),
                ),
              ),
            ],
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.refresh, size: 20, color: Color(0xFF6B7280)),
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
            ),
          ]),
          const SizedBox(height: 2),
          const Text(
            'Supplier bills forwarded by email — import or dismiss each one.',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDesktop) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF16A34A), strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, size: 40, color: Color(0xFFDC2626)),
        const SizedBox(height: 12),
        Text(_error!, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _load,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF16A34A)),
          child: const Text('Retry'),
        ),
      ]));
    }
    if (_bills.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 72, height: 72,
          decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(18)),
          child: const Icon(Icons.inbox_outlined, size: 36, color: Color(0xFF16A34A))),
        const SizedBox(height: 18),
        const Text('No pending bills', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 6),
        const Text('Bills forwarded by the Gmail script will appear here.',
            style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
      ]));
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: const Color(0xFF16A34A),
      child: isDesktop ? _buildDesktopList() : _buildMobileList(),
    );
  }

  // ── Desktop ───────────────────────────────────────────────────────────────────

  Widget _buildDesktopList() {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(20),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Table header
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(children: const [
                SizedBox(width: 40),
                Expanded(flex: 5, child: Text('FILE', style: _kTh)),
                Expanded(flex: 4, child: Text('FROM', style: _kTh)),
                Expanded(flex: 4, child: Text('SUPPLIER', style: _kTh)),
                Expanded(flex: 3, child: Text('RECEIVED', style: _kTh)),
                SizedBox(width: 180, child: Text('ACTIONS', style: _kTh)),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            for (int i = 0; i < _bills.length; i++)
              _DesktopBillRow(
                bill: _bills[i],
                isEven: i % 2 == 0,
                isLast: i == _bills.length - 1,
                supplierCtrl: _supplierCtrls[_bills[i]['id']]!,
                onSaveSupplier: () => _saveSupplier(_bills[i]['id'] as String),
                fileIcon: _fileIcon(_bills[i]['file_name'] as String? ?? ''),
                fileIconColor: _fileIconColor(_bills[i]['file_name'] as String? ?? ''),
                receivedStr: _fmtDate(_bills[i]['received_at']),
                isDownloading: _downloading[_bills[i]['id']] == true,
                isDismissing: _dismissing[_bills[i]['id']] == true,
                onImport: () => _importBill(_bills[i]),
                onDismiss: () => _dismiss(_bills[i]['id'] as String),
              ),
          ]),
        ),
      )),
    );
  }

  // ── Mobile ────────────────────────────────────────────────────────────────────

  Widget _buildMobileList() {
    return ListView.separated(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      itemCount: _bills.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final bill = _bills[i];
        final id = bill['id'] as String;
        return _MobileBillCard(
          bill: bill,
          supplierCtrl: _supplierCtrls[id]!,
          onSaveSupplier: () => _saveSupplier(id),
          fileIcon: _fileIcon(bill['file_name'] as String? ?? ''),
          fileIconColor: _fileIconColor(bill['file_name'] as String? ?? ''),
          receivedStr: _fmtDate(bill['received_at']),
          isDownloading: _downloading[id] == true,
          isDismissing: _dismissing[id] == true,
          onImport: () => _importBill(bill),
          onDismiss: () => _dismiss(id),
        );
      },
    );
  }
}

// ── Shared constants ──────────────────────────────────────────────────────────

const _kTh = TextStyle(
  fontSize: 11, fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF), letterSpacing: 0.5,
);

// ── Desktop bill row ──────────────────────────────────────────────────────────

class _DesktopBillRow extends StatelessWidget {
  final Map<String, dynamic> bill;
  final bool isEven;
  final bool isLast;
  final TextEditingController supplierCtrl;
  final VoidCallback onSaveSupplier;
  final IconData fileIcon;
  final Color fileIconColor;
  final String receivedStr;
  final bool isDownloading;
  final bool isDismissing;
  final VoidCallback onImport;
  final VoidCallback onDismiss;

  const _DesktopBillRow({
    required this.bill, required this.isEven, required this.isLast,
    required this.supplierCtrl, required this.onSaveSupplier,
    required this.fileIcon, required this.fileIconColor,
    required this.receivedStr, required this.isDownloading,
    required this.isDismissing, required this.onImport, required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = bill['file_name'] as String? ?? '—';
    final senderEmail = bill['sender_email'] as String? ?? '—';

    return Container(
      decoration: BoxDecoration(
        color: isEven ? Colors.white : const Color(0xFFFAFAFA),
        border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 40, child: Icon(fileIcon, size: 22, color: fileIconColor)),
        Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(fileName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
              maxLines: 2, overflow: TextOverflow.ellipsis),
        ])),
        Expanded(flex: 4, child: Text(senderEmail,
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            maxLines: 1, overflow: TextOverflow.ellipsis)),
        Expanded(flex: 4, child: _SupplierField(ctrl: supplierCtrl, onSaved: onSaveSupplier)),
        Expanded(flex: 3, child: Text(receivedStr,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))),
        SizedBox(width: 180, child: Row(children: [
          _ActionBtn(
            label: 'Import',
            icon: Icons.upload_rounded,
            color: const Color(0xFF16A34A),
            loading: isDownloading,
            onTap: isDownloading || isDismissing ? null : onImport,
          ),
          const SizedBox(width: 6),
          _ActionBtn(
            label: 'Dismiss',
            icon: Icons.close_rounded,
            color: const Color(0xFF6B7280),
            loading: isDismissing,
            onTap: isDownloading || isDismissing ? null : onDismiss,
          ),
        ])),
      ]),
    );
  }
}

// ── Mobile bill card ──────────────────────────────────────────────────────────

class _MobileBillCard extends StatelessWidget {
  final Map<String, dynamic> bill;
  final TextEditingController supplierCtrl;
  final VoidCallback onSaveSupplier;
  final IconData fileIcon;
  final Color fileIconColor;
  final String receivedStr;
  final bool isDownloading;
  final bool isDismissing;
  final VoidCallback onImport;
  final VoidCallback onDismiss;

  const _MobileBillCard({
    required this.bill, required this.supplierCtrl, required this.onSaveSupplier,
    required this.fileIcon, required this.fileIconColor, required this.receivedStr,
    required this.isDownloading, required this.isDismissing,
    required this.onImport, required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = bill['file_name'] as String? ?? '—';
    final senderEmail = bill['sender_email'] as String? ?? '—';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: fileIconColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(fileIcon, size: 20, color: fileIconColor),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(fileName,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(senderEmail, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ])),
        ]),
        const SizedBox(height: 10),
        _SupplierField(ctrl: supplierCtrl, onSaved: onSaveSupplier),
        const SizedBox(height: 6),
        Text(receivedStr, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _ActionBtn(
            label: 'Import',
            icon: Icons.upload_rounded,
            color: const Color(0xFF16A34A),
            loading: isDownloading,
            onTap: isDownloading || isDismissing ? null : onImport,
            expanded: true,
          )),
          const SizedBox(width: 8),
          Expanded(child: _ActionBtn(
            label: 'Dismiss',
            icon: Icons.close_rounded,
            color: const Color(0xFF6B7280),
            loading: isDismissing,
            onTap: isDownloading || isDismissing ? null : onDismiss,
            expanded: true,
          )),
        ]),
      ]),
    );
  }
}

// ── Supplier inline field ─────────────────────────────────────────────────────

class _SupplierField extends StatelessWidget {
  final TextEditingController ctrl;
  final VoidCallback onSaved;
  const _SupplierField({required this.ctrl, required this.onSaved});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: TextField(
        controller: ctrl,
        style: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
        decoration: InputDecoration(
          hintText: 'Supplier name…',
          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFFD1D5DB)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: const BorderSide(color: Color(0xFF16A34A), width: 1.5),
          ),
        ),
        onSubmitted: (_) => onSaved(),
        onTapOutside: (_) => onSaved(),
        textInputAction: TextInputAction.done,
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
    required this.label, required this.icon, required this.color,
    required this.loading, required this.onTap, this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget child = loading
        ? SizedBox(
            width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: color),
          )
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: onTap != null ? color : const Color(0xFFD1D5DB)),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600,
                  color: onTap != null ? color : const Color(0xFFD1D5DB),
                )),
          ]);

    final btn = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: onTap != null ? color.withOpacity(0.4) : const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(child: child),
      ),
    );

    return expanded ? SizedBox(width: double.infinity, child: btn) : btn;
  }
}
