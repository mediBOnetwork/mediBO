// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart' as xmlp;

import '../../config/api_keys.dart';

// ── Supplier row models ───────────────────────────────────────────────────────

class _SupRow {
  final String id;
  final Map<String, dynamic> rawData;

  const _SupRow({required this.id, required this.rawData});

  factory _SupRow.fromMap(Map<String, dynamic> m) =>
      _SupRow(id: m['id'] as String, rawData: Map<String, dynamic>.from(m));

  String get supplierName   => (rawData['supplier_name']  as String? ?? '').trim();
  String get contactName    => (rawData['contact_name']   as String? ?? '').trim();
  String get phone          => (rawData['phone']          as String? ?? rawData['whatsapp_no'] as String? ?? '').trim();
  String get supplierCode   => (rawData['supplier_code']  as String? ?? '').trim();
  String get paymentTerm    => (rawData['payment_term']   as String? ?? '').trim();
  String get city           => (rawData['city']           as String? ?? '').trim();
  String get state          => (rawData['state']          as String? ?? '').trim();
  String get status         =>  rawData['status']         as String? ?? 'approved';
  bool   get isSuspended    => status == 'suspended';
}

class _PendingRow {
  final String id;
  final Map<String, dynamic> rawData;
  final String supplierName;
  final String contactName;
  final String phone;
  final String? supplierCode;
  final String? paymentTerm;
  final String? city;
  final String? state;
  final DateTime? createdAt;

  const _PendingRow({
    required this.id,
    required this.rawData,
    required this.supplierName,
    required this.contactName,
    required this.phone,
    this.supplierCode,
    this.paymentTerm,
    this.city,
    this.state,
    this.createdAt,
  });

  factory _PendingRow.fromMap(Map<String, dynamic> m) => _PendingRow(
    id:           m['id'] as String,
    rawData:      Map<String, dynamic>.from(m),
    supplierName: m['supplier_name'] as String? ?? '',
    contactName:  m['contact_name']  as String? ?? '',
    phone:        m['phone']         as String? ?? m['whatsapp_no'] as String? ?? '',
    supplierCode: m['supplier_code'] as String?,
    paymentTerm:  m['payment_term']  as String?,
    city:         m['city']          as String?,
    state:        m['state']         as String?,
    createdAt:    m['created_at'] != null ? DateTime.tryParse(m['created_at'] as String) : null,
  );
}

class _OrderRow {
  final String id;
  final String? supplierName;
  final String? description;
  final double? totalAmount;
  final String status;
  final DateTime? createdAt;

  const _OrderRow({
    required this.id,
    this.supplierName,
    this.description,
    this.totalAmount,
    required this.status,
    this.createdAt,
  });

  factory _OrderRow.fromMap(Map<String, dynamic> m) => _OrderRow(
    id:           m['id'] as String,
    supplierName: m['supplier_name'] as String?,
    description:  m['description']  as String?,
    totalAmount:  (m['total_amount'] as num?)?.toDouble(),
    status:       m['status'] as String? ?? 'pending',
    createdAt:    m['created_at'] != null ? DateTime.tryParse(m['created_at'] as String) : null,
  );
}

class _LeadItem {
  final String id;
  String name;
  String email;
  String mobile;
  String status;
  String source;

  _LeadItem({
    required this.id,
    required this.name,
    required this.email,
    required this.mobile,
    required this.status,
    required this.source,
  });
}

// ── Tab enum ──────────────────────────────────────────────────────────────────

enum _SupFilter { suppliers, orders, pending, leads }

// ── Screen ────────────────────────────────────────────────────────────────────

class AdminSupplierScreen extends StatefulWidget {
  const AdminSupplierScreen({super.key});

  @override
  State<AdminSupplierScreen> createState() => _AdminSupplierScreenState();
}

class _AdminSupplierScreenState extends State<AdminSupplierScreen> {
  List<_SupRow>              _suppliers    = [];
  List<_PendingRow>          _pending      = [];
  List<_OrderRow>            _orders       = [];
  List<_LeadItem>            _leads        = [];
  List<Map<String, dynamic>> _deletedRows  = [];
  bool _deletedExpanded = false;
  bool _loading = true;
  _SupFilter _filter = _SupFilter.suppliers;
  // Supplier detail expand — only one supplier open at a time.
  String? _expandedSupplierId;
  // Companies section — only one supplier open at a time; mutually exclusive with detail.
  String? _companiesSupplierId;
  final Set<String> _expandedLeads = {};
  final Map<String, int> _companyCounts = {};
  final ScrollController _scrollCtrl = ScrollController();
  final List<RealtimeChannel> _channels = [];
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
    _subscribeRealtime();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final ch in _channels) ch.unsubscribe();
    _channels.clear();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _subscribeRealtime() {
    final client = Supabase.instance.client;
    final ts = DateTime.now().millisecondsSinceEpoch;
    for (final table in ['supplier_profiles', 'supplier_orders', 'supplier_leads']) {
      final ch = client
          .channel('admin_sup_${table}_$ts')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: table,
            callback: (_) => _debouncedLoad(),
          )
          .subscribe();
      _channels.add(ch);
    }
  }

  void _debouncedLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _load(showSpinner: false));
  }

  void _toggleCompanies(String id) => setState(() {
    if (_companiesSupplierId == id) {
      _companiesSupplierId = null; // close
    } else {
      _companiesSupplierId = id;
      _expandedSupplierId  = null; // close detail when companies opens
    }
  });

  Future<void> _reloadCompanyCount(String supplierId) async {
    try {
      final rows = await Supabase.instance.client
          .from('supplier_company_terms')
          .select('supplier_id')
          .eq('supplier_id', supplierId);
      if (mounted) setState(() => _companyCounts[supplierId] = (rows as List).length);
    } catch (_) {}
  }

  Future<void> _load({bool showSpinner = true}) async {
    if (!mounted) return;
    if (showSpinner) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final results = await Future.wait<dynamic>([
        client.from('supplier_profiles').select().or('is_deleted.is.null,is_deleted.eq.false')
            .catchError((_) => <dynamic>[]),
        client.from('supplier_orders').select().order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_leads').select().order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_profiles').select().eq('is_deleted', true)
            .order('deleted_at', ascending: false).catchError((_) => <dynamic>[]),
        client.from('supplier_company_terms').select('supplier_id')
            .catchError((_) => <dynamic>[]),
      ]);

      final profRows   = results[0] as List;
      final orderRows  = results[1] as List;
      final leadRows   = results[2] as List;
      final deletedR   = results[3] as List;
      final countRows  = results[4] as List;

      final newCounts = <String, int>{};
      for (final r in countRows) {
        final sid = (r as Map)['supplier_id'] as String? ?? '';
        if (sid.isNotEmpty) newCounts[sid] = (newCounts[sid] ?? 0) + 1;
      }

      final approved = <_SupRow>[];
      final pending  = <_PendingRow>[];

      for (final p in profRows) {
        final m = Map<String, dynamic>.from(p as Map);
        if (m['approved'] == true) {
          approved.add(_SupRow.fromMap(m));
        } else {
          pending.add(_PendingRow.fromMap(m));
        }
      }

      pending.sort((a, b) {
        if (a.createdAt == null && b.createdAt == null) return 0;
        if (a.createdAt == null) return 1;
        if (b.createdAt == null) return -1;
        return b.createdAt!.compareTo(a.createdAt!);
      });

      final orders = orderRows.map((r) => _OrderRow.fromMap(Map<String, dynamic>.from(r as Map))).toList();
      final leads  = leadRows.map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return _LeadItem(
          id:     m['id'] as String,
          name:   m['name']   as String? ?? '',
          email:  m['email']  as String? ?? '',
          mobile: m['mobile'] as String? ?? '',
          status: m['status'] as String? ?? 'new',
          source: m['source'] as String? ?? 'manual',
        );
      }).toList();

      if (mounted) {
        setState(() {
          _suppliers   = approved;
          _pending     = pending;
          _orders      = orders;
          _leads       = leads;
          _deletedRows = deletedR.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _companyCounts
            ..clear()
            ..addAll(newCounts);
          _loading     = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
      // Silently swallow load errors — never surface a red banner on the homepage
    }
  }

  // ── Approve / Reject ────────────────────────────────────────────────────────

  Future<void> _approvePending(_PendingRow row) async {
    await Supabase.instance.client.from('supplier_profiles').update({
      'approved':    true,
      'status':      'approved',
      'approved_at': DateTime.now().toUtc().toIso8601String(),
      'approved_by': 'admin',
    }).eq('id', row.id);
    _load();
  }

  Future<void> _rejectPending(_PendingRow row) async {
    await Supabase.instance.client
        .from('supplier_profiles')
        .update({'approved': false, 'status': 'rejected'})
        .eq('id', row.id);
    _load();
  }

  // ── Suspend / Reactivate / Delete ───────────────────────────────────────────

  Future<void> _suspendSupplier(_SupRow row) async {
    final name = row.supplierName.isNotEmpty ? row.supplierName : row.contactName;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Suspend Supplier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('Suspend $name? They will be blocked until reactivated.', style: const TextStyle(fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Suspend'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'suspended'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Suspend failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _reactivateSupplier(_SupRow row) async {
    try {
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'approved'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reactivate failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  Future<void> _deleteSupplier(_SupRow row) async {
    final name = row.supplierName.isNotEmpty ? row.supplierName : row.contactName;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Delete $name?', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This will remove their supplier profile.', style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final client = Supabase.instance.client;
      final adminEmail = client.auth.currentUser?.email ?? 'admin';
      await client.from('supplier_profiles').update({
        'is_deleted':       true,
        'deleted_at':       DateTime.now().toUtc().toIso8601String(),
        'deleted_by':       adminEmail,
        'deleted_snapshot': row.rawData,
      }).eq('id', row.id);
      _load(showSpinner: false);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Supplier deleted.'), backgroundColor: Color(0xFF1B7A43)));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  // ── Permanent hard-delete one supplier ──────────────────────────────────────

  Future<void> _permanentDeleteSupplier(Map<String, dynamic> deletedRow) async {
    final snap        = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? deletedRow;
    final name        = (snap['supplier_name'] as String? ?? deletedRow['supplier_name'] as String? ?? 'this supplier').trim();
    final displayName = name.isNotEmpty ? name : 'this supplier';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Permanently delete $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This cannot be undone.',
            style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client
          .from('supplier_profiles')
          .delete()
          .eq('id', deletedRow['id'] as String)
          .eq('is_deleted', true);
      _load(showSpinner: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$displayName permanently deleted.'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Delete failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  // ── Permanent hard-delete ALL recently-deleted suppliers ─────────────────────

  Future<void> _clearAllDeleted() async {
    final count = _deletedRows.length;
    if (count == 0) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Permanently delete all?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: Text('Permanently delete all $count recently-deleted supplier${count == 1 ? '' : 's'}? This cannot be undone.',
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client
          .from('supplier_profiles')
          .delete()
          .eq('is_deleted', true);
      _load(showSpinner: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$count supplier${count == 1 ? '' : 's'} permanently deleted.'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Clear all failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  // ── Restore soft-deleted supplier ───────────────────────────────────────────

  Future<void> _restoreSupplier(Map<String, dynamic> deletedRow) async {
    final snap        = deletedRow['deleted_snapshot'] as Map<String, dynamic>? ?? deletedRow;
    final name        = (snap['supplier_name'] as String? ?? deletedRow['supplier_name'] as String? ?? 'this supplier').trim();
    final displayName = name.isNotEmpty ? name : 'this supplier';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: Text('Restore $displayName?',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This will restore the supplier to the active Suppliers list.',
            style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43)),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await Supabase.instance.client.from('supplier_profiles').update({
        'is_deleted':       false,
        'deleted_at':       null,
        'deleted_by':       null,
        'deleted_snapshot': null,
      }).eq('id', deletedRow['id'] as String);
      _load(showSpinner: false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Supplier restored.'),
          backgroundColor: Color(0xFF1B7A43),
          duration: Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Restore failed: $e'),
          backgroundColor: const Color(0xFFDC2626),
        ));
      }
    }
  }

  // ── Edit supplier ────────────────────────────────────────────────────────────

  Future<void> _editSupplier(_SupRow row) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SupplierEditDialog(row: row),
    );
    if (saved == true) _load(showSpinner: false);
  }

  // ── Order status ─────────────────────────────────────────────────────────────

  Future<void> _updateOrderStatus(String orderId, String status) async {
    try {
      await Supabase.instance.client.from('supplier_orders').update({'status': status}).eq('id', orderId);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Update failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
  }

  void _toggleExpand(String key) => setState(() {
    if (_expandedSupplierId == key) {
      _expandedSupplierId = null; // close
    } else {
      _expandedSupplierId  = key;
      _companiesSupplierId = null; // close companies when detail opens
    }
  });

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, box) {
      final isDesktop = box.maxWidth >= 900;
      if (_loading) {
        return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2));
      }
      return PrimaryScrollController(
        controller: _scrollCtrl,
        child: SingleChildScrollView(
          primary: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _buildHeader(isDesktop),
            _buildContent(isDesktop),
          ]),
        ),
      );
    });
  }

  Widget _buildHeader(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Container(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 0),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Supplier Dashboard',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
              SizedBox(height: 2),
              Text('Manage supplier accounts and registrations',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
            ]),
          ),
          TextButton.icon(
            onPressed: _pickAndImportSupplierProfile,
            icon: const Icon(Icons.upload_file_outlined, size: 16),
            label: const Text('Import Supplier'),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
          IconButton(
            onPressed: _load,
            icon: const Icon(Icons.refresh_outlined, color: Color(0xFF6B7280), size: 20),
            tooltip: 'Refresh',
            visualDensity: VisualDensity.compact,
          ),
        ]),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _tab(_SupFilter.suppliers,  'Suppliers (${_suppliers.length})'),
            const SizedBox(width: 4),
            _tab(_SupFilter.orders,     'Supplier Orders (${_orders.length})'),
            const SizedBox(width: 4),
            _tab(_SupFilter.pending,    'Pending Approval (${_pending.length})'),
            const SizedBox(width: 4),
            _tab(_SupFilter.leads,      'Leads (${_leads.length})'),
          ]),
        ),
      ]),
    );
  }

  Widget _tab(_SupFilter f, String label) {
    final active = _filter == f;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          if (_scrollCtrl.hasClients) _scrollCtrl.jumpTo(0);
          setState(() { _filter = f; _expandedSupplierId = null; _companiesSupplierId = null; });
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF1B7A43) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: active ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: active ? Colors.white : const Color(0xFF6B7280))),
        ),
      ),
    );
  }

  Widget _buildContent(bool isDesktop) {
    switch (_filter) {
      case _SupFilter.suppliers:  return _buildSuppliersView(isDesktop);
      case _SupFilter.orders:     return _buildOrdersView(isDesktop);
      case _SupFilter.pending:    return _buildPendingView(isDesktop);
      case _SupFilter.leads:      return _buildLeadsView(isDesktop);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPLIERS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildSuppliersView(bool isDesktop) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (_suppliers.isEmpty)
        _emptyState('0 approved suppliers')
      else ...[
        if (isDesktop) _suppliersTableHeader(),
        ..._suppliers.map((r) => isDesktop ? _desktopSupRow(r) : _mobileSupCard(r)),
      ],
      const SizedBox(height: 32),
      _buildDeletedSection(isDesktop),
      const SizedBox(height: 32),
    ]);
  }

  Widget _buildDeletedSection(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      child: Column(children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() => _deletedExpanded = !_deletedExpanded),
            child: Container(
              width: double.infinity,
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 11),
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                border: Border.all(color: const Color(0xFFE5E7EB)),
                borderRadius: _deletedExpanded
                    ? const BorderRadius.vertical(top: Radius.circular(8))
                    : BorderRadius.circular(8),
              ),
              child: Row(children: [
                AnimatedRotation(
                  turns: _deletedExpanded ? 0.0 : -0.25,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF1B7A43)),
                ),
                const SizedBox(width: 8),
                Text(
                  'Recently Deleted (${_deletedRows.length})',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
                ),
                const Spacer(),
                if (_deletedRows.isNotEmpty)
                  GestureDetector(
                    onTap: _clearAllDeleted,
                    child: const Text('Clear All',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
                  ),
              ]),
            ),
          ),
        ),
        if (_deletedExpanded) ...[
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: const Color(0xFFE5E7EB)),
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
            ),
            child: _deletedRows.isEmpty
                ? Padding(
                    padding: EdgeInsets.symmetric(horizontal: pad, vertical: 20),
                    child: const Text('No deleted suppliers.',
                        style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                  )
                : Column(
                    children: _deletedRows.map((r) => _buildDeletedRow(r, isDesktop)).toList(),
                  ),
          ),
        ],
      ]),
    );
  }

  Widget _buildDeletedRow(Map<String, dynamic> row, bool isDesktop) {
    final snap      = row['deleted_snapshot'] as Map<String, dynamic>? ?? row;
    final name      = (snap['supplier_name']  as String? ?? row['supplier_name']  as String? ?? '').trim();
    final email     = (snap['email']          as String? ?? row['email']          as String? ?? '').trim();
    final deletedAt = _fmtTs(row['deleted_at'] as String?);
    final deletedBy = row['deleted_by'] as String? ?? '';
    final isLast    = _deletedRows.last == row;
    final pad       = isDesktop ? 28.0 : 16.0;

    return Opacity(
      opacity: 0.85,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFFFAFAFA),
          border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
        ),
        child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              name.isNotEmpty ? name : (email.isNotEmpty ? email : 'Deleted Supplier'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 3),
            Text(
              [
                if (email.isNotEmpty)     email,
                if (deletedAt.isNotEmpty) 'Deleted: $deletedAt',
                if (deletedBy.isNotEmpty) 'By: $deletedBy',
              ].join('  ·  '),
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
              overflow: TextOverflow.ellipsis,
            ),
          ])),
          const SizedBox(width: 12),
          InkWell(
            onTap: () => _restoreSupplier(row),
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFF1B7A43)),
              ),
              child: const Text('Restore',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
            ),
          ),
          const SizedBox(width: 8),
          InkWell(
            onTap: () => _permanentDeleteSupplier(row),
            borderRadius: BorderRadius.circular(6),
            mouseCursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: const Color(0xFFDC2626)),
              ),
              child: const Text('Delete',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFFDC2626))),
            ),
          ),
        ]),
      ),
    );
  }


  Widget _suppliersTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER', flex: 4),
        _th('CONTACT', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('CITY', flex: 3),
        const SizedBox(width: 360), // right action cluster placeholder
      ]),
    );
  }

  Widget _desktopSupRow(_SupRow row) {
    final isExpanded = _expandedSupplierId == row.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => _toggleExpand(row.id),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Expanded(flex: 4, child: Text(row.supplierName.isNotEmpty ? row.supplierName : '—',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: Text(row.contactName.isNotEmpty ? row.contactName : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 2, child: Text(row.phone.isNotEmpty ? row.phone : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
            Expanded(flex: 2, child: Text(row.supplierCode.isNotEmpty ? row.supplierCode : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF374151), fontFamily: 'monospace'))),
            Expanded(flex: 3, child: Text(
                [row.city, row.state].where((s) => s.isNotEmpty).join(', ').let((s) => s.isNotEmpty ? s : '—'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)),
            // ── Right action cluster (fixed 360px) — all non-data controls ──────
            SizedBox(width: 360, child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                GestureDetector(
                  onTap: () => _toggleCompanies(row.id),
                  behavior: HitTestBehavior.opaque,
                  child: _SupplierCompaniesButton(
                    count: _companyCounts[row.id] ?? 0,
                    isOpen: _companiesSupplierId == row.id,
                  ),
                ),
                const SizedBox(width: 10),
                _StatusBadge(status: row.status),
                const SizedBox(width: 14),
                _actionBtn('Edit', const Color(0xFF1B7A43), () => _editSupplier(row)),
                const SizedBox(width: 6),
                _actionBtn(
                  row.isSuspended ? 'Reactivate' : 'Suspend',
                  row.isSuspended ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
                  () => row.isSuspended ? _reactivateSupplier(row) : _suspendSupplier(row),
                ),
                const SizedBox(width: 6),
                _actionBtn('Delete', const Color(0xFFDC2626), () => _deleteSupplier(row)),
                const SizedBox(width: 10),
                AnimatedRotation(
                  turns: isExpanded ? 0.5 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF6B7280)),
                ),
              ],
            )),
          ]),
        ),
      ),
      if (_companiesSupplierId == row.id)
        _CompaniesInlineSection(
          supplierId: row.id,
          onCompanyAdded: () => _reloadCompanyCount(row.id),
        ),
      if (isExpanded) _buildDetails(row.rawData, lpad: 28, rpad: 0),
    ]);
  }

  Widget _mobileSupCard(_SupRow row) {
    final isExpanded = _expandedSupplierId == row.id;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: row.isSuspended ? const Color(0xFFFECACA) : const Color(0xFFE5E7EB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _toggleExpand(row.id),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(
                      row.supplierName.isNotEmpty ? row.supplierName : row.contactName.isNotEmpty ? row.contactName : 'Unknown',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _toggleCompanies(row.id),
                    behavior: HitTestBehavior.opaque,
                    child: _SupplierCompaniesButton(
                      count: _companyCounts[row.id] ?? 0,
                      isOpen: _companiesSupplierId == row.id,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _StatusBadge(status: row.status),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF9CA3AF)),
                  ),
                ]),
                if (row.contactName.isNotEmpty) ...[const SizedBox(height: 3), Text(row.contactName, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)],
                if (row.phone.isNotEmpty) ...[const SizedBox(height: 2), Text(row.phone, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))],
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  if (row.supplierCode.isNotEmpty) _mobileField('Code', row.supplierCode),
                  if (row.paymentTerm.isNotEmpty)  _mobileField('Payment', row.paymentTerm),
                  if (row.city.isNotEmpty)          _mobileField('City', [row.city, row.state].where((s) => s.isNotEmpty).join(', ')),
                ]),
                const SizedBox(height: 12),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  _actionBtn('Edit',        const Color(0xFF1B7A43),  () => _editSupplier(row)),
                  _actionBtn(
                    row.isSuspended ? 'Reactivate' : 'Suspend',
                    row.isSuspended ? const Color(0xFF1B7A43) : const Color(0xFFD97706),
                    () => row.isSuspended ? _reactivateSupplier(row) : _suspendSupplier(row),
                  ),
                  _actionBtn('Delete',      const Color(0xFFDC2626),  () => _deleteSupplier(row)),
                ]),
              ]),
            ),
            if (_companiesSupplierId == row.id) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _CompaniesInlineSection(
                supplierId: row.id,
                onCompanyAdded: () => _reloadCompanyCount(row.id),
              ),
            ],
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDetails(row.rawData, lpad: 0, rpad: 0),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SUPPLIER ORDERS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildOrdersView(bool isDesktop) {
    if (_orders.isEmpty) return _emptyState('0 supplier orders');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isDesktop) _ordersTableHeader(),
      ..._orders.map((r) => isDesktop ? _desktopOrderRow(r) : _mobileOrderCard(r)),
      const SizedBox(height: 32),
    ]);
  }

  Widget _ordersTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER', flex: 4),
        _th('DESCRIPTION', flex: 5),
        _th('AMOUNT', flex: 2),
        _th('STATUS', flex: 3),
        _th('DATE', flex: 3),
      ]),
    );
  }

  Widget _desktopOrderRow(_OrderRow row) {
    final dateStr = row.createdAt != null
        ? '${row.createdAt!.day.toString().padLeft(2,'0')}/${row.createdAt!.month.toString().padLeft(2,'0')}/${row.createdAt!.year}'
        : '—';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        Expanded(flex: 4, child: Text(row.supplierName ?? '—',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
            overflow: TextOverflow.ellipsis)),
        Expanded(flex: 5, child: Text(row.description ?? '—',
            style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
        Expanded(flex: 2, child: Text(row.totalAmount != null ? '₹${row.totalAmount!.toStringAsFixed(0)}' : '—',
            style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
        Expanded(flex: 3, child: _OrderStatusActions(orderId: row.id, status: row.status, onUpdate: _updateOrderStatus)),
        Expanded(flex: 3, child: Text(dateStr, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
      ]),
    );
  }

  Widget _mobileOrderCard(_OrderRow row) {
    final dateStr = row.createdAt != null
        ? '${row.createdAt!.day.toString().padLeft(2,'0')}/${row.createdAt!.month.toString().padLeft(2,'0')}/${row.createdAt!.year}'
        : '';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(row.supplierName ?? '—',
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
              overflow: TextOverflow.ellipsis)),
          if (dateStr.isNotEmpty) Text(dateStr, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ]),
        if (row.description?.isNotEmpty == true) ...[
          const SizedBox(height: 4),
          Text(row.description!, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ],
        if (row.totalAmount != null) ...[
          const SizedBox(height: 4),
          Text('₹${row.totalAmount!.toStringAsFixed(0)}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
        ],
        const SizedBox(height: 10),
        _OrderStatusActions(orderId: row.id, status: row.status, onUpdate: _updateOrderStatus),
      ]),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // PENDING APPROVAL TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildPendingView(bool isDesktop) {
    if (_pending.isEmpty) return _emptyState('0 pending supplier registrations');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (isDesktop) _pendingTableHeader(),
      ..._pending.map((r) => isDesktop ? _desktopPendingRow(r) : _mobilePendingCard(r)),
      const SizedBox(height: 32),
    ]);
  }

  Widget _pendingTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFFF9FAFB),
        border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
      ),
      child: Row(children: [
        _th('SUPPLIER NAME', flex: 3),
        _th('CONTACT', flex: 3),
        _th('PHONE', flex: 2),
        _th('CODE', flex: 2),
        _th('PAYMENT', flex: 2),
        _th('CITY / STATE', flex: 2),
        _th('APPROVAL', flex: 3),
        const SizedBox(width: 32),
      ]),
    );
  }

  Widget _desktopPendingRow(_PendingRow row) {
    final isExpanded = _expandedSupplierId == row.id;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      InkWell(
        onTap: () => _toggleExpand(row.id),
        mouseCursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
          ),
          child: Row(children: [
            Expanded(flex: 3, child: Text(row.supplierName.isNotEmpty ? row.supplierName : '—',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: Text(row.contactName.isNotEmpty ? row.contactName : '—',
                style: const TextStyle(fontSize: 13, color: Color(0xFF374151)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 2, child: Text(row.phone.isNotEmpty ? row.phone : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
            Expanded(flex: 2, child: Text(row.supplierCode?.isNotEmpty == true ? row.supplierCode! : '—',
                style: const TextStyle(fontSize: 12, color: Color(0xFF374151), fontFamily: 'monospace'))),
            Expanded(flex: 2, child: row.paymentTerm?.isNotEmpty == true
                ? _PaymentBadge(term: row.paymentTerm!) : const Text('—', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)))),
            Expanded(flex: 2, child: Text(
                [row.city, row.state].where((s) => s != null && s.isNotEmpty).join(', ').let((s) => s.isNotEmpty ? s : '—'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)),
            Expanded(flex: 3, child: _ApproveActions(
                id: row.id, onApprove: () => _approvePending(row), onReject: () => _rejectPending(row))),
            SizedBox(width: 32, child: AnimatedRotation(
              turns: isExpanded ? 0.5 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF6B7280)),
            )),
          ]),
        ),
      ),
      if (isExpanded) _buildDetails(row.rawData, lpad: 28, rpad: 0),
    ]);
  }

  Widget _mobilePendingCard(_PendingRow row) {
    final isExpanded = _expandedSupplierId == row.id;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: () => _toggleExpand(row.id),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(row.supplierName.isNotEmpty ? row.supplierName : 'Unknown',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  _pendingBadge(),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more, size: 18, color: Color(0xFF9CA3AF)),
                  ),
                ]),
                if (row.contactName.isNotEmpty) ...[const SizedBox(height: 3), Text(row.contactName, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)],
                if (row.phone.isNotEmpty) ...[const SizedBox(height: 2), Text(row.phone, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))],
                const SizedBox(height: 8),
                Wrap(spacing: 12, runSpacing: 4, children: [
                  if (row.supplierCode?.isNotEmpty == true) _mobileField('Code', row.supplierCode!),
                  if (row.paymentTerm?.isNotEmpty == true)  _mobileField('Payment', row.paymentTerm!),
                  if (row.city?.isNotEmpty == true)          _mobileField('City', [row.city, row.state].where((s) => s != null && s.isNotEmpty).join(', ')),
                ]),
                const SizedBox(height: 12),
                _ApproveActions(id: row.id, onApprove: () => _approvePending(row), onReject: () => _rejectPending(row)),
              ]),
            ),
            if (isExpanded) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _buildDetails(row.rawData, lpad: 0, rpad: 0),
            ],
          ]),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LEADS TAB
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildLeadsView(bool isDesktop) {
    final pad = isDesktop ? 28.0 : 16.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 16, pad, 32),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Supplier Leads',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 2),
        const Text('CSV-imported and manually added supplier leads',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 10),
        if (_leads.isEmpty)
          const Text('No leads yet', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))
        else
          for (final lead in _leads) _buildLeadRow(lead, isDesktop),
        const SizedBox(height: 32),
        _buildCsvUpload(),
      ]),
    );
  }

  Widget _buildLeadRow(_LeadItem lead, bool isDesktop) {
    final isExpanded = _expandedLeads.contains(lead.id);
    final displayName = lead.name.isNotEmpty ? lead.name : lead.email;
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E7EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: () => setState(() => isExpanded ? _expandedLeads.remove(lead.id) : _expandedLeads.add(lead.id)),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              Icon(isExpanded ? Icons.expand_less : Icons.expand_more, size: 18, color: const Color(0xFF6B7280)),
              const SizedBox(width: 10),
              Expanded(
                child: isDesktop
                    ? Row(children: [
                        _leadCell(displayName, flex: 3, bold: true),
                        _leadCell(lead.email, flex: 3),
                        _leadCell(lead.mobile.isNotEmpty ? lead.mobile : '—', flex: 2),
                      ])
                    : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(displayName, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                        if (lead.email.isNotEmpty) Text(lead.email, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                      ]),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _leadStatusColor(lead.status).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(lead.status, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _leadStatusColor(lead.status))),
              ),
            ]),
          ),
        ),
        if (isExpanded)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE5E7EB)))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 12),
              Wrap(spacing: 20, runSpacing: 12, children: [
                if (lead.name.isNotEmpty)   _detailChip('Name',   lead.name),
                if (lead.email.isNotEmpty)  _detailChip('Email',  lead.email),
                if (lead.mobile.isNotEmpty) _detailChip('Mobile', lead.mobile),
              ]),
              const SizedBox(height: 16),
              _leadDropdown<String>(
                label: 'Status',
                value: lead.status,
                items: const ['new', 'contacted', 'interested', 'converted', 'dropped'],
                display: (v) => v[0].toUpperCase() + v.substring(1),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => lead.status = v);
                  try {
                    await Supabase.instance.client.from('supplier_leads').update({'status': v}).eq('id', lead.id);
                  } catch (_) {}
                },
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _leadCell(String text, {int flex = 1, bool bold = false}) {
    return Expanded(
      flex: flex,
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
              color: bold ? const Color(0xFF111827) : const Color(0xFF374151))),
    );
  }

  Widget _detailChip(String label, String value) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF), fontWeight: FontWeight.w500)),
      const SizedBox(height: 2),
      Text(value, style: const TextStyle(fontSize: 13, color: Color(0xFF111827))),
    ]);
  }

  Widget _leadDropdown<T>({
    required String label, required T value, required List<T> items,
    required String Function(T) display, required ValueChanged<T?> onChanged,
  }) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
      const SizedBox(height: 4),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(border: Border.all(color: const Color(0xFFD1D5DB)), borderRadius: BorderRadius.circular(6), color: Colors.white),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value, isDense: true,
            items: items.map((v) => DropdownMenuItem<T>(value: v, child: Text(display(v), style: const TextStyle(fontSize: 13)))).toList(),
            onChanged: onChanged,
          ),
        ),
      ),
    ]);
  }

  Color _leadStatusColor(String status) {
    return switch (status) {
      'converted'  => const Color(0xFF1B7A43),
      'dropped'    => const Color(0xFFDC2626),
      'interested' => const Color(0xFF2563EB),
      'contacted'  => const Color(0xFFD97706),
      _            => const Color(0xFF6B7280),
    };
  }

  Widget _buildCsvUpload() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Divider(),
      const SizedBox(height: 8),
      const Text('Import CSV', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
      const SizedBox(height: 4),
      const Text('Columns: name, email, mobile (header row required; order flexible)',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 10),
      ElevatedButton.icon(
        onPressed: _pickAndImportCsv,
        icon: const Icon(Icons.upload_file_outlined, size: 16),
        label: const Text('Upload CSV'),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1B7A43), foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ]);
  }

  Future<void> _pickAndImportSupplierProfile() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.tsv,.txt,.xlsx,.xls,.ods,.docx,.pdf,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SupProfileImportDialog(file: file, onImported: () { if (mounted) _load(showSpinner: false); }),
    );
  }

  Future<void> _pickAndImportCsv() async {
    final input = html.FileUploadInputElement()..accept = '.csv,text/csv';
    input.click();
    await input.onChange.first;
    final file = input.files?.first;
    if (file == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SupCsvImportDialog(file: file, onImported: () { if (mounted) _load(showSpinner: false); }),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // DETAILS PANEL (shared)
  // ═══════════════════════════════════════════════════════════════════════════

  static String _str(dynamic v) {
    if (v == null) return '';
    if (v is bool) return v ? 'Yes' : 'No';
    final s = v.toString().trim();
    return s == 'null' ? '' : s;
  }

  static String _fmtTs(dynamic v) {
    final s = _str(v);
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.parse(s).toLocal();
      return '${dt.day.toString().padLeft(2,'0')}/${dt.month.toString().padLeft(2,'0')}/${dt.year}  '
             '${dt.hour.toString().padLeft(2,'0')}:${dt.minute.toString().padLeft(2,'0')}';
    } catch (_) { return s; }
  }

  Widget _buildDetails(Map<String, dynamic> rawData, {required double lpad, required double rpad}) {
    String val(dynamic v, {bool isTs = false}) {
      final s = isTs ? _fmtTs(v) : _str(v);
      return s.isEmpty ? '—' : s;
    }

    final groups = <(String, List<(String, String)>)>[
      ('IDENTITY', [
        ('Supplier Name', val(rawData['supplier_name'])),
        ('Code',          val(rawData['supplier_code'])),
        ('Stockist Type', val(rawData['stockist_type'])),
        ('Status',        val(rawData['status'])),
      ]),
      ('CONTACT', [
        ('Contact Name',  val(rawData['contact_person'] ?? rawData['contact_name'])),
        ('Phone',         val(rawData['phone'])),
        ('WhatsApp No',   val(rawData['whatsapp_no'])),
        ('Contact No',    val(rawData['contact_no'])),
        ('Email',         val(rawData['email'])),
        ('Other Contact', val(rawData['other_contact'])),
      ]),
      ('LOCATION', [
        ('Street Address', val(rawData['street_address'] ?? rawData['address'])),
        ('City',           val(rawData['city'])),
        ('State',          val(rawData['state'])),
        ('PIN Code',       val(rawData['pin_code'] ?? rawData['pincode'])),
        ('Range / Zone',   val(rawData['range_zone'])),
        ('Map Link',       val(rawData['map_link'])),
      ]),
      ('TERMS', [
        ('Margin',        val(rawData['margin'])),
        ('CD Condition',  val(rawData['cd_condition'])),
        ('Payment Type',  val(rawData['payment_type'] ?? rawData['payment_term'])),
        ('Deal',          val(rawData['deal'])),
        ('Behaviour',     val(rawData['behaviour'])),
      ]),
      ('COMPLIANCE', [
        ('DL 1',          val(rawData['dl_1'] ?? rawData['drug_license'])),
        ('DL 2',          val(rawData['dl_2'])),
        ('GST',           val(rawData['gst'] ?? rawData['gstin'])),
        ('Store Type',    val(rawData['store_type'])),
        ('Approved By',   val(rawData['approved_by'])),
      ]),
      ('NOTES', [
        ('Notes', val(rawData['notes'])),
      ]),
    ];

    const gridColor  = Color(0xFFD0D7DE);
    const catBg      = Colors.white;
    const fieldBg    = Colors.white;
    const evenRowBg  = Colors.white;
    const oddRowBg   = Colors.white;
    const emptyColor = Color(0xFF8C959F);
    const valueColor = Color(0xFF24292F);
    const border     = BorderSide(color: gridColor);

    return LayoutBuilder(builder: (ctx, constraints) {
      final isMobile    = constraints.maxWidth < 600;
      final fieldColW   = isMobile ? 120.0 : 180.0;

      // Build a flat list of row widgets: category header + data rows.
      final tableRows = <Widget>[];
      int globalRowIndex = 0;

      for (final group in groups) {
        // Category header — green left accent bar, light bg, no outer L/R border.
        tableRows.add(Row(children: [
          Container(width: 3, height: 28, color: const Color(0xFF1B8A5A)),
          Expanded(child: Container(
            height: 28,
            color: catBg,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.centerLeft,
            child: Text('▸ ${group.$1}',
                style: const TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600,
                    color: Color(0xFF1B8A5A), letterSpacing: 0.8)),
          )),
        ]));

        for (int i = 0; i < group.$2.length; i++) {
          final field    = group.$2[i];
          final isEmpty  = field.$2 == '—';
          final rowColor = globalRowIndex.isEven ? evenRowBg : oddRowBg;
          // Hairline divider between data rows; none above first row (header already provides bottom).
          final topBorder = i == 0 ? BorderSide.none : border;

          tableRows.add(SizedBox(
            height: 36,
            child: Row(children: [
              // FIELD NAME cell — no outer left border, hairline right divider only
              Container(
                width: fieldColW,
                decoration: BoxDecoration(
                  color: fieldBg,
                  border: Border(
                    top:   topBorder,
                    right: border, // vertical divider between label and value
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                alignment: Alignment.centerLeft,
                child: Text(field.$1,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600,
                        color: Color(0xFF57606A)),
                    overflow: TextOverflow.ellipsis),
              ),
              // VALUE cell — no outer right border
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: rowColor,
                    border: Border(top: topBorder),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  alignment: Alignment.centerLeft,
                  child: Text(field.$2,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w400,
                          color: isEmpty ? emptyColor : valueColor),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1),
                ),
              ),
            ]),
          ));
          globalRowIndex++;
        }
      }

      // Pure white. Left padding aligns panel with the supplier name column above.
      return Container(
        color: Colors.white,
        padding: EdgeInsets.only(left: lpad.toDouble()),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: tableRows,
        ),
      );
    });
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _emptyState(String msg) {
    return Padding(
      padding: const EdgeInsets.only(top: 80),
      child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 64, height: 64,
          decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E7EB))),
          child: const Icon(Icons.inbox_outlined, size: 28, color: Color(0xFFD1D5DB)),
        ),
        const SizedBox(height: 16),
        Text(msg, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
      ])),
    );
  }

  static Widget _th(String label, {int flex = 1}) => Expanded(
      flex: flex,
      child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF9CA3AF), letterSpacing: 0.5)));

  static Widget _pendingBadge() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF3C7),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFD97706).withValues(alpha: 0.4)),
      ),
      child: const Text('Pending', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFFD97706))));

  static Widget _mobileField(String label, String value) => RichText(
      text: TextSpan(children: [
        TextSpan(text: '$label: ', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF))),
        TextSpan(text: value,      style: const TextStyle(fontSize: 11, color: Color(0xFF374151))),
      ]));

  static Widget _actionBtn(String label, Color color, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Extension ─────────────────────────────────────────────────────────────────

extension _Let<T> on T {
  R let<R>(R Function(T) fn) => fn(this);
}

// ── Status badge ──────────────────────────────────────────────────────────────

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color color;
    final String label;
    final IconData icon;
    switch (status) {
      case 'suspended':
        color = const Color(0xFFDC2626); label = 'Suspended'; icon = Icons.block_outlined;
        break;
      case 'approved':
        color = const Color(0xFF1B7A43); label = 'Active'; icon = Icons.verified_outlined;
        break;
      default:
        color = const Color(0xFFD97706); label = status.isNotEmpty ? status : 'Active'; icon = Icons.info_outline;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: color), const SizedBox(width: 3),
        Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }
}

// ── Payment badge ─────────────────────────────────────────────────────────────

class _PaymentBadge extends StatelessWidget {
  final String term;
  const _PaymentBadge({required this.term});

  @override
  Widget build(BuildContext context) {
    final isAdvance = term.toLowerCase().contains('advance') || term.toLowerCase() == 'adv';
    final color = isAdvance ? const Color(0xFF1E40AF) : const Color(0xFF0891B2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(term, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}

// ── Order status actions ───────────────────────────────────────────────────────

class _OrderStatusActions extends StatefulWidget {
  final String orderId;
  final String status;
  final Future<void> Function(String id, String status) onUpdate;
  const _OrderStatusActions({required this.orderId, required this.status, required this.onUpdate});

  @override
  State<_OrderStatusActions> createState() => _OrderStatusActionsState();
}

class _OrderStatusActionsState extends State<_OrderStatusActions> {
  bool _busy = false;

  Future<void> _act(String status) async {
    if (_busy) return;
    setState(() => _busy = true);
    await widget.onUpdate(widget.orderId, status);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)));
    final s = widget.status;
    if (s == 'confirmed') return _chip('Confirmed', const Color(0xFF1B7A43));
    if (s == 'rejected')  return _chip('Rejected',  const Color(0xFFDC2626));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Accept', const Color(0xFF1B7A43), () => _act('confirmed')),
      const SizedBox(width: 4),
      _btn('Reject', const Color(0xFFDC2626), () => _act('rejected')),
    ]);
  }

  Widget _chip(String label, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)));

  Widget _btn(String label, Color color, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Approve / Reject actions ──────────────────────────────────────────────────

class _ApproveActions extends StatefulWidget {
  final String id;
  final Future<void> Function() onApprove;
  final Future<void> Function() onReject;
  const _ApproveActions({required this.id, required this.onApprove, required this.onReject});

  @override
  State<_ApproveActions> createState() => _ApproveActionsState();
}

class _ApproveActionsState extends State<_ApproveActions> {
  bool _busy = false;

  Future<void> _act(Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try { await fn(); } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Action failed: $e'), backgroundColor: const Color(0xFFDC2626)));
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)));
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _btn('Approve', const Color(0xFF1B7A43), () => _act(widget.onApprove)),
      const SizedBox(width: 4),
      _btn('Reject',  const Color(0xFFDC2626), () => _act(widget.onReject)),
    ]);
  }

  Widget _btn(String label, Color color, VoidCallback onTap) => InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.07), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.3))),
        child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
      ));
}

// ── Supplier edit dialog ───────────────────────────────────────────────────────

class _SupplierEditDialog extends StatefulWidget {
  final _SupRow row;
  const _SupplierEditDialog({required this.row});

  @override
  State<_SupplierEditDialog> createState() => _SupplierEditDialogState();
}

class _SupplierEditDialogState extends State<_SupplierEditDialog> {
  late final Map<String, TextEditingController> _ctrls;
  bool _saving = false;

  static const _fields = [
    ('supplier_name', 'Supplier Name'),
    ('contact_name',  'Contact Name'),
    ('phone',         'Phone'),
    ('whatsapp_no',   'WhatsApp No.'),
    ('email',         'Email'),
    ('supplier_code', 'Supplier Code'),
    ('payment_term',  'Payment Term'),
    ('city',          'City'),
    ('state',         'State'),
    ('pincode',       'PIN Code'),
    ('gstin',         'GSTIN'),
    ('drug_license',  'Drug License'),
    ('notes',         'Notes'),
  ];

  @override
  void initState() {
    super.initState();
    _ctrls = {
      for (final f in _fields)
        f.$1: TextEditingController(text: widget.row.rawData[f.$1]?.toString() ?? '')
    };
  }

  @override
  void dispose() {
    for (final c in _ctrls.values) c.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final update = {for (final f in _fields) f.$1: _ctrls[f.$1]!.text.trim()};
      await Supabase.instance.client.from('supplier_profiles').update(update).eq('id', widget.row.id);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Expanded(child: Text('Edit Supplier', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
              IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => Navigator.pop(context), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: Wrap(spacing: 12, runSpacing: 12, children: [
                  for (final f in _fields)
                    SizedBox(
                      width: 220,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(f.$2, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280), fontWeight: FontWeight.w500)),
                        const SizedBox(height: 4),
                        TextField(
                          controller: _ctrls[f.$1],
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                          ),
                          style: const TextStyle(fontSize: 13),
                        ),
                      ]),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ── CSV import dialog ─────────────────────────────────────────────────────────

class _SupCsvColMap {
  final int index;
  final String header;
  final List<String> samples;
  String mappedTo;
  _SupCsvColMap({required this.index, required this.header, required this.samples, required this.mappedTo});
}

enum _SupCsvStep { reading, mapping, importing }

class _SupCsvImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupCsvImportDialog({required this.file, required this.onImported});

  @override
  State<_SupCsvImportDialog> createState() => _SupCsvImportDialogState();
}

class _SupCsvImportDialogState extends State<_SupCsvImportDialog> {
  _SupCsvStep _step = _SupCsvStep.reading;
  String _statusMsg = 'Reading file…';
  List<_SupCsvColMap> _cols = [];
  List<List<String>> _dataRows = [];
  String? _error;

  static const _leadFields = ['name', 'email', 'mobile', 'ignore'];

  @override
  void initState() {
    super.initState();
    _readAndMap();
  }

  Future<void> _readAndMap() async {
    try {
      final reader = html.FileReader();
      reader.readAsText(widget.file);
      await reader.onLoad.first;
      final csvText = reader.result as String;
      final lines = csvText.split(RegExp(r'\r?\n'));
      if (lines.isEmpty || lines.first.trim().isEmpty) {
        setState(() { _error = 'The CSV file is empty.'; });
        return;
      }
      final headers  = lines.first.split(',').map((h) => h.trim()).toList();
      final dataRows = <List<String>>[];
      for (final line in lines.skip(1)) {
        if (line.trim().isEmpty) continue;
        dataRows.add(line.split(',').map((c) => c.trim()).toList());
      }
      if (dataRows.isEmpty) {
        setState(() { _error = 'No data rows found (only a header row).'; });
        return;
      }
      setState(() { _statusMsg = 'Mapping columns with Gemini…'; });

      final entries = <Map<String, dynamic>>[];
      for (int i = 0; i < headers.length; i++) {
        final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(5).toList();
        entries.add({'index': i, 'header': headers[i], 'samples': samples});
      }
      final prompt = 'Map each CSV column to the correct lead field.\n\n'
          'Lead fields:\n- name: full name\n- email: email address\n- mobile: phone/mobile number\n- ignore: skip\n\n'
          'Columns:\n${jsonEncode(entries)}\n\nReturn ONLY a JSON array: [{"index":0,"mapped_to":"name"},...]';

      final idxMap = <int, String>{};
      try {
        final resp = await http.post(
          Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=$geminiApiKey'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'contents': [{'parts': [{'text': prompt}]}], 'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 512}}),
        ).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) {
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final txt = ((body['candidates'] as List?)?.firstOrNull?['content']?['parts'] as List?)?.firstOrNull?['text'] as String? ?? '';
          final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
          if (jm != null) {
            final mappings = jsonDecode(jm.group(0)!) as List<dynamic>;
            for (final m in mappings) {
              final mm = m as Map<String, dynamic>;
              final idx = mm['index'] as int?;
              final mapped = mm['mapped_to'] as String? ?? 'ignore';
              if (idx != null) idxMap[idx] = _leadFields.contains(mapped) ? mapped : 'ignore';
            }
          }
        }
      } catch (_) {}

      // Heuristic fallback
      for (int i = 0; i < headers.length; i++) {
        if (idxMap.containsKey(i)) continue;
        final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
        if (['name','fullname','suppliername','contactname','leadname'].contains(h)) {
          idxMap[i] = 'name';
        } else if (['email','emailaddress','mail'].contains(h)) {
          idxMap[i] = 'email';
        } else if (['mobile','phone','mobilenumber','phonenumber','contact','cell'].contains(h)) {
          idxMap[i] = 'mobile';
        } else {
          idxMap[i] = 'ignore';
        }
      }

      final cols = List.generate(headers.length, (i) {
        final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(3).toList();
        return _SupCsvColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
      });

      setState(() { _cols = cols; _dataRows = dataRows; _step = _SupCsvStep.mapping; });
    } catch (e) {
      setState(() { _error = 'Failed to read CSV: $e'; });
    }
  }

  Future<void> _doImport() async {
    setState(() { _step = _SupCsvStep.importing; });
    try {
      final nameCol   = _cols.firstWhereOrNull((c) => c.mappedTo == 'name');
      final emailCol  = _cols.firstWhereOrNull((c) => c.mappedTo == 'email');
      final mobileCol = _cols.firstWhereOrNull((c) => c.mappedTo == 'mobile');
      final toInsert  = <Map<String, dynamic>>[];
      for (final row in _dataRows) {
        final name   = nameCol   != null && nameCol.index   < row.length ? row[nameCol.index]   : '';
        final email  = emailCol  != null && emailCol.index  < row.length ? row[emailCol.index]  : '';
        final mobile = mobileCol != null && mobileCol.index < row.length ? row[mobileCol.index] : '';
        if (name.isEmpty && email.isEmpty && mobile.isEmpty) continue;
        toInsert.add({'name': name, 'email': email, 'mobile': mobile, 'source': 'csv_import', 'status': 'new'});
      }
      if (toInsert.isNotEmpty) {
        await Supabase.instance.client.from('supplier_leads').insert(toInsert);
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported ${toInsert.length} lead${toInsert.length == 1 ? '' : 's'}'),
          backgroundColor: const Color(0xFF1B7A43),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupCsvStep.mapping; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null ? _buildError() : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildError() {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
      const SizedBox(height: 12),
      Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF111827))),
      const SizedBox(height: 16),
      TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
    ]);
  }

  Widget _buildContent() {
    if (_step == _SupCsvStep.reading || _step == _SupCsvStep.importing) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
        const SizedBox(height: 16),
        Text(_step == _SupCsvStep.reading ? _statusMsg : 'Importing…',
            style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]);
    }
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Expanded(child: Text('Map CSV Columns', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
        IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(), padding: EdgeInsets.zero, constraints: const BoxConstraints()),
      ]),
      const SizedBox(height: 4),
      const Text('Gemini has auto-mapped your columns. Correct any mismatches before importing.',
          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),
      ...List.generate(_cols.length, (i) {
        final col = _cols[i];
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(children: [
            Expanded(flex: 3, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
              if (col.samples.isNotEmpty)
                Text(col.samples.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
            ])),
            const SizedBox(width: 12),
            Expanded(flex: 2, child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(color: const Color(0xFFF5F6F8), border: Border.all(color: const Color(0xFFE5E7EB)), borderRadius: BorderRadius.circular(8)),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: col.mappedTo, isExpanded: true,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                  items: const [
                    DropdownMenuItem(value: 'name',   child: Text('name')),
                    DropdownMenuItem(value: 'email',  child: Text('email')),
                    DropdownMenuItem(value: 'mobile', child: Text('mobile')),
                    DropdownMenuItem(value: 'ignore', child: Text('ignore')),
                  ],
                  onChanged: (v) => setState(() => col.mappedTo = v ?? 'ignore'),
                ),
              ),
            )),
          ]),
        );
      }),
      const SizedBox(height: 8),
      Text('${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported',
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
      const SizedBox(height: 16),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _doImport,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ),
      ]),
    ]);
  }
}

// ─── Supplier Profile Import (CSV / Excel / ODS / PDF / DOCX / Images) ── #70 ─

class _SupProfColMap {
  final int index;
  final String header;
  final List<String> samples;
  String mappedTo;
  String newColName;
  String newColType;
  _SupProfColMap({required this.index, required this.header, required this.samples, required this.mappedTo,
    this.newColName = '', this.newColType = 'text'});
}

enum _SupProfStep { reading, mapping, importing }
enum _SupImportDest { supplierProfiles, supplierCompanyTerms }

class _SupProfileImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupProfileImportDialog({required this.file, required this.onImported});
  @override
  State<_SupProfileImportDialog> createState() => _SupProfileImportDialogState();
}

class _SupProfileImportDialogState extends State<_SupProfileImportDialog> {
  _SupProfStep _step = _SupProfStep.reading;
  _SupImportDest _dest = _SupImportDest.supplierProfiles;
  bool _destUserOverridden = false;
  String _statusMsg = 'Reading file…';
  List<_SupProfColMap> _cols = [];
  List<List<String>> _dataRows = [];
  String? _error;
  final Map<int, TextEditingController> _newColCtrls = {};
  List<String> _dynamicFields = [];

  static const _baseFields = [
    'supplier_name', 'contact_person', 'contact_no', 'whatsapp_no', 'email',
    'status', 'margin', 'behaviour', 'cd_condition', 'payment_type', 'deal',
    'street_address', 'city', 'state', 'pin_code', 'map_link',
    'stockist_type', 'dl_1', 'dl_2', 'gst',
  ];
  static const _sctFields = [
    'supplier_name', 'company_name', 'margin', 'cd_condition', 'payment_type', 'deal', 'status',
  ];
  List<String> get _activeBaseFields => _dest == _SupImportDest.supplierProfiles ? _baseFields : _sctFields;
  List<String> get _fields => _dest == _SupImportDest.supplierProfiles
      ? [..._baseFields, ..._dynamicFields, 'ignore']
      : [..._sctFields, 'ignore'];

  static String _fieldLabel(String f) => switch (f) {
    'supplier_name'  => 'Supplier Name *',
    'company_name'   => 'Company Name *',
    'contact_person' => 'Contact Person',
    'contact_no'     => 'Contact No',
    'whatsapp_no'    => 'WhatsApp No',
    'email'          => 'Email',
    'status'         => 'Status',
    'margin'         => 'Margin',
    'behaviour'      => 'Behaviour',
    'cd_condition'   => 'CD Condition',
    'payment_type'   => 'Payment Type',
    'deal'           => 'Deal',
    'street_address' => 'Street Address',
    'city'           => 'City',
    'state'          => 'State',
    'pin_code'       => 'Pin Code',
    'map_link'       => 'Map Link',
    'stockist_type'  => 'Stockist Type',
    'dl_1'           => 'DL 1',
    'dl_2'           => 'DL 2',
    'gst'            => 'GST',
    _                => '— Ignore —',
  };

  @override
  void initState() { super.initState(); _parseAndMap(); }

  @override
  void dispose() {
    for (final c in _newColCtrls.values) c.dispose();
    super.dispose();
  }

  // ── Destination sniffing ──────────────────────────────────────────────────────

  _SupImportDest _sniffDest(List<String> headers) {
    final hs = headers.map((h) => h.toLowerCase().replaceAll(RegExp(r'[\s_\-./]+'), '')).toSet();
    final sctHits = ['companyname','margin','cd','cdcondition','cddiscount','paymenttype','paymentterm','deal']
        .where(hs.contains).length;
    final profileHits = ['phone','mobile','contactno','city','state','address','stockisttype','gst','gstin','druglicense','dl1','dl2']
        .where(hs.contains).length;
    return sctHits >= 2 && sctHits > profileHits
        ? _SupImportDest.supplierCompanyTerms
        : _SupImportDest.supplierProfiles;
  }

  // ── File parsing (reused from Add-Medicine pipeline) ─────────────────────────

  Future<String> _readAsText(html.File f) async {
    final r = html.FileReader(); r.readAsText(f); await r.onLoad.first;
    return (r.result as String).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  Future<String> _pdfText(Uint8List bytes) async {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final t = PdfTextExtractor(doc).extractText();
      doc.dispose(); return t;
    } catch (_) { return ''; }
  }

  String _xlsxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open Excel file.'); }
    ArchiveFile? find(String p) {
      final lo = p.toLowerCase();
      for (final x in archive) { if (x.name.toLowerCase() == lo) return x; }
      return null;
    }
    final ss = <String>[];
    final ssf = find('xl/sharedStrings.xml');
    if (ssf != null) {
      try {
        final doc = xmlp.XmlDocument.parse(utf8.decode(ssf.content as List<int>));
        for (final si in doc.findAllElements('si')) {
          ss.add(si.findAllElements('t').map((t) => t.innerText).join());
        }
      } catch (_) {}
    }
    ArchiveFile? shf;
    for (int n = 1; n <= 10; n++) { shf = find('xl/worksheets/sheet$n.xml'); if (shf != null) break; }
    if (shf == null) throw Exception('No worksheet found in Excel file.');
    final wsDoc = xmlp.XmlDocument.parse(utf8.decode(shf.content as List<int>));
    String? rc(xmlp.XmlElement cell) {
      final t = cell.getAttribute('t');
      if (t == 'inlineStr') return cell.findAllElements('t').map((e) => e.innerText).join();
      if (t == 's') {
        final v = cell.findElements('v').firstOrNull?.innerText;
        if (v == null) return null;
        final idx = int.tryParse(v);
        if (idx == null || idx >= ss.length) return null;
        return ss[idx];
      }
      return cell.findElements('v').firstOrNull?.innerText;
    }
    final sb = StringBuffer();
    for (final row in wsDoc.findAllElements('row')) {
      final cells = <String, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final col = ref.replaceAll(RegExp(r'[0-9]'), '');
        if (col.isNotEmpty) cells[col] = rc(cell) ?? '';
      }
      if (cells.isEmpty) continue;
      final cols = cells.keys.toList()..sort();
      sb.writeln(cols.map((c) => cells[c]!).join('\t'));
    }
    return sb.toString();
  }

  String _odsBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open ODS file.'); }
    ArchiveFile? cf;
    for (final x in archive) { if (x.name.toLowerCase() == 'content.xml') { cf = x; break; } }
    if (cf == null) throw Exception('Not a valid ODS file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(cf.content as List<int>));
    String ct(xmlp.XmlElement cell) {
      final ps = cell.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p');
      return ps.isNotEmpty ? ps.map((e) => e.innerText).join(' ').trim() : '';
    }
    final sb = StringBuffer();
    for (final tbl in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table')) {
      for (final row in tbl.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table-row')) {
        final cells = row.descendants.whereType<xmlp.XmlElement>()
            .where((e) => e.localName == 'table-cell' || e.localName == 'covered-table-cell').toList();
        if (cells.isEmpty) continue;
        sb.writeln(cells.map(ct).join('\t'));
      }
    }
    return sb.toString();
  }

  String _docxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open DOCX file.'); }
    ArchiveFile? df;
    for (final x in archive) { if (x.name.toLowerCase() == 'word/document.xml') { df = x; break; } }
    if (df == null) throw Exception('Not a valid DOCX file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(df.content as List<int>));
    final sb = StringBuffer();
    for (final p in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p')) {
      final t = p.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 't').map((e) => e.innerText).join();
      if (t.trim().isNotEmpty) sb.writeln(t);
    }
    return sb.toString();
  }

  ({List<String> headers, List<List<String>> rows}) _textToTable(String text) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return (headers: [], rows: []);
    final sep = lines.first.contains('\t') ? '\t' : ',';
    var allRows = lines.map((l) =>
        l.split(sep).map((c) => c.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), '')).toList()
    ).toList();
    if (allRows.isEmpty) return (headers: [], rows: []);
    final maxCols = allRows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    allRows = allRows.map((r) {
      if (r.length < maxCols) return [...r, ...List.filled(maxCols - r.length, '')];
      return r;
    }).toList();
    final first = allRows[0];
    final isHdr = first.every((c) => double.tryParse(c.replaceAll(RegExp(r'[₹,\s]'), '')) == null);
    if (isHdr && allRows.length > 1) return (headers: first, rows: allRows.sublist(1));
    return (headers: List.filled(maxCols, ''), rows: allRows);
  }

  String _geminiResponseText(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final cands = data['candidates'] as List<dynamic>?;
      if (cands == null || cands.isEmpty) return '';
      final content = (cands[0] as Map<String, dynamic>)['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List<dynamic>?;
      final out = parts?.where((p) => (p as Map<String, dynamic>)['thought'] != true).toList();
      return out?.isNotEmpty == true ? (out![0] as Map<String, dynamic>)['text'] as String? ?? '' : '';
    } catch (_) { return ''; }
  }

  Future<({List<String> headers, List<List<String>> rows})> _geminiTable(
      bool isImage, String mime, String b64, String pdfMime) async {
    final prompt =
        'Extract the tabular supplier data from this file. '
        'Return ONLY a JSON object (no markdown fences):\n'
        '{"headers":["col1","col2"],"rows":[["v1","v2"],...]}\n'
        'Use empty string "" for missing headers. Include all data rows.';
    final parts = isImage
        ? [{'inline_data': {'mime_type': mime, 'data': b64}}, {'text': prompt}]
        : [{'inline_data': {'mime_type': pdfMime, 'data': b64}}, {'text': prompt}];
    final resp = await http.post(
      Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=$geminiApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'contents': [{'parts': parts}], 'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 4096}}),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) throw Exception('Gemini API error (HTTP ${resp.statusCode})');
    final txt = _geminiResponseText(resp.body);
    if (txt.isEmpty) throw Exception('Empty response from Gemini');
    final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
    if (jm == null) throw Exception('Could not parse table from file');
    final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
    final headers = (dec['headers'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final rows = (dec['rows'] as List<dynamic>?)
        ?.map((r) => (r as List<dynamic>).map((e) => e.toString()).toList()).toList() ?? [];
    return (headers: headers, rows: rows);
  }

  Future<({List<String> headers, List<List<String>> rows})> _parseFile(html.File f) async {
    final ext = f.name.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv': case 'tsv': case 'txt':
        return _textToTable(await _readAsText(f));
      case 'xlsx': case 'xls':
        return _textToTable(_xlsxBytesText(await _readBytes(f)));
      case 'ods':
        return _textToTable(_odsBytesText(await _readBytes(f)));
      case 'docx':
        return _textToTable(_docxBytesText(await _readBytes(f)));
      case 'pdf':
        final bytes = await _readBytes(f);
        final local = await _pdfText(bytes);
        if (local.trim().length > 20) return _textToTable(local);
        return _geminiTable(false, '', base64Encode(bytes), 'application/pdf');
      case 'jpg': case 'jpeg':
        return _geminiTable(true, 'image/jpeg', base64Encode(await _readBytes(f)), '');
      case 'png':
        return _geminiTable(true, 'image/png', base64Encode(await _readBytes(f)), '');
      case 'webp':
        return _geminiTable(true, 'image/webp', base64Encode(await _readBytes(f)), '');
      case 'heic': case 'heif':
        return _geminiTable(true, 'image/heic', base64Encode(await _readBytes(f)), '');
      case 'gif':
        return _geminiTable(true, 'image/gif', base64Encode(await _readBytes(f)), '');
      default:
        return _textToTable(await _readAsText(f));
    }
  }

  Future<List<_SupProfColMap>> _geminiMapCols(List<String> headers, List<List<String>> dataRows) async {
    final isSCT = _dest == _SupImportDest.supplierCompanyTerms;
    final activeBase = _activeBaseFields;
    final entries = List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.trim().isNotEmpty).take(5).toList();
      return {'index': i, 'header': headers[i], 'samples': samples};
    });
    final String prompt;
    if (isSCT) {
      prompt =
          'Map each column to the correct supplier_company_terms field.\n\n'
          'Fields: supplier_name (required — Firm/Supplier/Distributor name), '
          'company_name (required — Pharma company/brand name), '
          'margin (discount %, trade margin), cd_condition (CD/cash discount), '
          'payment_type (payment terms, credit days), deal (scheme/bonus deal), '
          'status (active/inactive), ignore (skip)\n\n'
          'Infer from BOTH header AND sample values. '
          '"Firm","Supplier","Distributor" → supplier_name. '
          '"Company","Brand","Manufacturer" → company_name. '
          'Serial/index numbers → ignore.\n\n'
          'Columns:\n${jsonEncode(entries)}\n\n'
          'Return ONLY a JSON array: [{"index":0,"mapped_to":"supplier_name"},...]';
    } else {
      prompt =
          'Map each column to the correct supplier_profiles field.\n\n'
          'Fields: supplier_name (required — Firm Name/Company Name/Supplier maps here), '
          'contact_person (Contact Person/Name), contact_no (Phone/Mobile/Contact No), '
          'whatsapp_no, email, status, margin, behaviour, cd_condition, payment_type, deal, '
          'street_address (Address/Street), city, state, pin_code (Pincode/ZIP), map_link, '
          'stockist_type (Type/Category), dl_1 (Drug License 1), dl_2 (Drug License 2), '
          'gst (GST/GSTIN), ignore (skip)\n\n'
          'Infer from BOTH header AND sample values. '
          '"Firm Name","Company Name","Supplier" → supplier_name. '
          '"Contact","Contact Person","Name" → contact_person. '
          '"Phone","Mobile","Contact No" → contact_no. '
          'Serial/index numbers → ignore.\n\n'
          'Columns:\n${jsonEncode(entries)}\n\n'
          'Return ONLY a JSON array: [{"index":0,"mapped_to":"supplier_name"},...]';
    }
    final idxMap = <int, String>{};
    try {
      final resp = await http.post(
        Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash:generateContent?key=$geminiApiKey'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'contents': [{'parts': [{'text': prompt}]}], 'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 1024}}),
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final txt = _geminiResponseText(resp.body);
        final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
        if (jm != null) {
          for (final m in jsonDecode(jm.group(0)!) as List<dynamic>) {
            final mm = m as Map<String, dynamic>;
            final idx = mm['index'] as int?;
            final mapped = mm['mapped_to'] as String? ?? 'ignore';
            if (idx != null) idxMap[idx] = (activeBase.contains(mapped) || mapped == 'ignore') ? mapped : 'ignore';
          }
        }
      }
    } catch (_) {}
    // Heuristic fallback for unmapped columns
    final used = <String>{...idxMap.values};
    for (int i = 0; i < headers.length; i++) {
      if (idxMap.containsKey(i)) continue;
      final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
      String mapped = 'ignore';
      if (isSCT) {
        if (['suppliername','firmname','supplier','firm','distributor'].contains(h) && !used.contains('supplier_name')) mapped = 'supplier_name';
        else if (['companyname','company','brand','manufacturer','pharmacompany'].contains(h) && !used.contains('company_name')) mapped = 'company_name';
        else if (['margin','trademargin','discount'].contains(h) && !used.contains('margin')) mapped = 'margin';
        else if (['cdcondition','cd','cashdiscount','cddiscount'].contains(h) && !used.contains('cd_condition')) mapped = 'cd_condition';
        else if (['paymenttype','paymentterm','paymentterms','creditdays'].contains(h) && !used.contains('payment_type')) mapped = 'payment_type';
        else if (['deal','scheme','bonus'].contains(h) && !used.contains('deal')) mapped = 'deal';
        else if (['status'].contains(h) && !used.contains('status')) mapped = 'status';
      } else {
        if (['suppliername','firmname','companyname','supplier'].contains(h) && !used.contains('supplier_name')) mapped = 'supplier_name';
        else if (['contactname','contactperson','contact','name'].contains(h) && !used.contains('contact_person')) mapped = 'contact_person';
        else if (['phone','mobile','mobilenumber','phonenumber','cell','contactno'].contains(h) && !used.contains('contact_no')) mapped = 'contact_no';
        else if (['email','emailaddress','mail'].contains(h) && !used.contains('email')) mapped = 'email';
        else if (['whatsapp','whatsappno'].contains(h) && !used.contains('whatsapp_no')) mapped = 'whatsapp_no';
        else if (['city','town'].contains(h) && !used.contains('city')) mapped = 'city';
        else if (['state','province'].contains(h) && !used.contains('state')) mapped = 'state';
        else if (['address','addr','streetaddress','street'].contains(h) && !used.contains('street_address')) mapped = 'street_address';
        else if (['pincode','pin','zip','pinno'].contains(h) && !used.contains('pin_code')) mapped = 'pin_code';
        else if (['gst','gstin','gstnumber'].contains(h) && !used.contains('gst')) mapped = 'gst';
        else if (['dl1','druglicense1','druglicense'].contains(h) && !used.contains('dl_1')) mapped = 'dl_1';
        else if (['dl2','druglicense2'].contains(h) && !used.contains('dl_2')) mapped = 'dl_2';
        else if (['paymenttype','paymentterm','paymentterms','creditdays'].contains(h) && !used.contains('payment_type')) mapped = 'payment_type';
        else if (['stockisttype','storetype','type','vendortype'].contains(h) && !used.contains('stockist_type')) mapped = 'stockist_type';
        else if (['margin'].contains(h) && !used.contains('margin')) mapped = 'margin';
        else if (['behaviour','behavior'].contains(h) && !used.contains('behaviour')) mapped = 'behaviour';
        else if (['cdcondition','cd'].contains(h) && !used.contains('cd_condition')) mapped = 'cd_condition';
        else if (['deal'].contains(h) && !used.contains('deal')) mapped = 'deal';
        else if (['maplink','maplocation','location'].contains(h) && !used.contains('map_link')) mapped = 'map_link';
        else if (['status'].contains(h) && !used.contains('status')) mapped = 'status';
      }
      idxMap[i] = mapped;
      if (mapped != 'ignore') used.add(mapped);
    }
    return List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(3).toList();
      return _SupProfColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
    });
  }

  Future<void> _confirmMapping() async {
    if (_dest == _SupImportDest.supplierCompanyTerms) {
      await _doImportSCT();
      return;
    }
    // Validate create_new entries
    for (final col in _cols.where((c) => c.mappedTo == 'create_new')) {
      final name = (_newColCtrls[col.index]?.text ?? '').trim();
      if (name.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Enter a name for the new column "${col.header.isNotEmpty ? col.header : "Column ${col.index + 1}"}"'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$name" is invalid — use lowercase letters, numbers, underscores, starting with a letter'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      if (_baseFields.contains(name)) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('"$name" already exists — map directly to that column instead'),
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }
      col.newColName = name;
    }

    // Create new columns via RPC
    final toCreate = _cols.where((c) => c.mappedTo == 'create_new').toList();
    if (toCreate.isNotEmpty) {
      setState(() { _step = _SupProfStep.importing; _statusMsg = 'Creating new columns…'; });
      for (final col in toCreate) {
        try {
          await Supabase.instance.client.rpc('add_supplier_column', params: {
            'col_name': col.newColName,
            'col_type': col.newColType,
          });
          setState(() {
            col.mappedTo = col.newColName;
            if (!_dynamicFields.contains(col.newColName)) _dynamicFields.add(col.newColName);
          });
        } catch (e) {
          if (!mounted) return;
          setState(() { _step = _SupProfStep.mapping; });
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not create column "${col.newColName}": ${e.toString().replaceFirst('Exception: ', '')}'),
            behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 8),
          ));
          return;
        }
      }
      setState(() { _step = _SupProfStep.mapping; });
    }

    await _doImport();
  }

  Future<void> _parseAndMap() async {
    try {
      setState(() { _step = _SupProfStep.reading; _statusMsg = 'Reading file…'; });
      final table = await _parseFile(widget.file);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file.');
      // Auto-suggest destination from headers if admin hasn't overridden
      if (!_destUserOverridden) {
        _dest = _sniffDest(table.headers);
      }
      setState(() { _statusMsg = 'Auto-mapping columns with Gemini…'; });
      final cols = await _geminiMapCols(table.headers, table.rows);
      setState(() { _cols = cols; _dataRows = table.rows; _step = _SupProfStep.mapping; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  Future<void> _remapCols() async {
    setState(() { _step = _SupProfStep.reading; _statusMsg = 'Re-mapping columns…'; });
    try {
      final cols = await _geminiMapCols(
        _cols.map((c) => c.header).toList(),
        _dataRows,
      );
      setState(() { _cols = cols; _step = _SupProfStep.mapping; });
    } catch (e) {
      if (mounted) setState(() { _step = _SupProfStep.mapping; });
    }
  }

  Future<void> _doImport() async {
    setState(() { _step = _SupProfStep.importing; });
    try {
      final colFor = <String, _SupProfColMap>{};
      for (final c in _cols) { if (c.mappedTo != 'ignore' && c.mappedTo != 'create_new') colFor[c.mappedTo] = c; }
      final allFields = [..._baseFields, ..._dynamicFields];
      final toInsert = <Map<String, dynamic>>[];
      for (final row in _dataRows) {
        String val(String field) {
          final c = colFor[field];
          return c != null && c.index < row.length ? row[c.index].trim() : '';
        }
        final name = val('supplier_name');
        if (name.isEmpty) continue;
        final rec = <String, dynamic>{'supplier_name': name, 'status': 'approved', 'approved': true, 'is_deleted': false};
        for (final f in allFields.where((f) => f != 'supplier_name')) {
          final v = val(f);
          if (v.isNotEmpty) rec[f] = v;
        }
        toInsert.add(rec);
      }
      if (toInsert.isNotEmpty) {
        await Supabase.instance.client.from('supplier_profiles').insert(toInsert);
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported ${toInsert.length} supplier${toInsert.length == 1 ? '' : 's'}'),
          backgroundColor: const Color(0xFF1B7A43),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupProfStep.mapping; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
    }
  }

  Future<void> _doImportSCT() async {
    setState(() { _step = _SupProfStep.importing; _statusMsg = 'Resolving suppliers & companies…'; });
    try {
      final colFor = <String, _SupProfColMap>{};
      for (final c in _cols) { if (c.mappedTo != 'ignore') colFor[c.mappedTo] = c; }
      String rowVal(List<String> row, String field) {
        final c = colFor[field];
        return c != null && c.index < row.length ? row[c.index].trim() : '';
      }
      // Collect unique names
      final supplierNames = _dataRows.map((r) => rowVal(r, 'supplier_name')).where((s) => s.isNotEmpty).toSet().toList();
      final companyNames  = _dataRows.map((r) => rowVal(r, 'company_name')).where((s) => s.isNotEmpty).toSet().toList();
      if (supplierNames.isEmpty || companyNames.isEmpty) throw Exception('No supplier_name or company_name column mapped.');

      // Resolve supplier names → IDs
      final supplierRows = await Supabase.instance.client
          .from('supplier_profiles').select('id, supplier_name').inFilter('supplier_name', supplierNames);
      final supplierMap = <String, String>{};
      for (final r in supplierRows as List<dynamic>) {
        supplierMap[(r['supplier_name'] as String).toLowerCase()] = r['id'] as String;
      }

      // Resolve company names → IDs (via pharma_companies + company_aliases)
      final companyMap = <String, String>{};
      final existingCos = await Supabase.instance.client
          .from('pharma_companies').select('id, canonical_name').inFilter('canonical_name', companyNames);
      for (final r in existingCos as List<dynamic>) {
        companyMap[(r['canonical_name'] as String).toLowerCase()] = r['id'] as String;
      }
      // Check aliases for remaining
      final unmatchedByName = companyNames.where((n) => !companyMap.containsKey(n.toLowerCase())).toList();
      if (unmatchedByName.isNotEmpty) {
        final aliasRows = await Supabase.instance.client
            .from('company_aliases').select('company_id, alias_name').inFilter('alias_name', unmatchedByName);
        for (final r in aliasRows as List<dynamic>) {
          companyMap[(r['alias_name'] as String).toLowerCase()] = r['company_id'] as String;
        }
      }
      // Create pharma_companies entries for any still-missing companies
      final stillMissing = companyNames.where((n) => !companyMap.containsKey(n.toLowerCase())).toList();
      for (final name in stillMissing) {
        final newCo = await Supabase.instance.client
            .from('pharma_companies').insert({'canonical_name': name}).select('id').single();
        companyMap[name.toLowerCase()] = newCo['id'] as String;
      }

      // Build insert rows
      final toInsert = <Map<String, dynamic>>[];
      int skipped = 0;
      for (final row in _dataRows) {
        final supplierName = rowVal(row, 'supplier_name');
        final companyName  = rowVal(row, 'company_name');
        if (supplierName.isEmpty || companyName.isEmpty) { skipped++; continue; }
        final supplierId = supplierMap[supplierName.toLowerCase()];
        final companyId  = companyMap[companyName.toLowerCase()];
        if (supplierId == null) { skipped++; continue; } // supplier not in DB
        if (companyId == null)  { skipped++; continue; }
        final rec = <String, dynamic>{'supplier_id': supplierId, 'company_id': companyId};
        for (final f in ['margin', 'cd_condition', 'payment_type', 'deal', 'status']) {
          final v = rowVal(row, f);
          if (v.isNotEmpty) rec[f] = v;
        }
        toInsert.add(rec);
      }
      if (toInsert.isNotEmpty) {
        await Supabase.instance.client.from('supplier_company_terms').insert(toInsert);
      }
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        final skipNote = skipped > 0 ? ' ($skipped skipped — supplier not found)' : '';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Imported ${toInsert.length} term${toInsert.length == 1 ? '' : 's'}$skipNote'),
          backgroundColor: const Color(0xFF1B7A43),
          duration: const Duration(seconds: 5),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupProfStep.mapping; });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import failed: $e'), backgroundColor: const Color(0xFFDC2626)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }
    if (_step == _SupProfStep.reading || _step == _SupProfStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(_step == _SupProfStep.reading ? _statusMsg
                : (_dest == _SupImportDest.supplierCompanyTerms ? _statusMsg : 'Importing suppliers…'),
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]))),
      );
    }
    final isSCT = _dest == _SupImportDest.supplierCompanyTerms;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 860, maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Import Suppliers — Map Columns',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text('${widget.file.name} · Gemini auto-mapped columns. Correct mismatches before importing.',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 12),
          // ── Destination selector ────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('IMPORT DESTINATION', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5)),
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F6F8),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFE5E7EB)),
                ),
                padding: const EdgeInsets.all(4),
                child: Row(children: [
                  Expanded(child: _DestTab(
                    label: 'Supplier',
                    sublabel: '→ supplier_profiles',
                    selected: !isSCT,
                    onTap: () {
                      if (isSCT) {
                        setState(() { _dest = _SupImportDest.supplierProfiles; _destUserOverridden = true; });
                        _remapCols();
                      }
                    },
                  )),
                  const SizedBox(width: 4),
                  Expanded(child: _DestTab(
                    label: "Supplier's Company",
                    sublabel: '→ supplier_company_terms',
                    selected: isSCT,
                    onTap: () {
                      if (!isSCT) {
                        setState(() { _dest = _SupImportDest.supplierCompanyTerms; _destUserOverridden = true; });
                        _remapCols();
                      }
                    },
                  )),
                ]),
              ),
            ]),
          ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Flexible(child: LayoutBuilder(builder: (ctx, bc) {
            final isMobile = bc.maxWidth < 600;
            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (!isMobile) ...[
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
                    child: Row(children: const [
                      Expanded(flex: 4, child: Text('FILE COLUMN', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                      Expanded(flex: 5, child: Text('SAMPLE VALUES', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                      Expanded(flex: 5, child: Text('MAPS TO', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5))),
                    ])),
                  const Divider(color: Color(0xFFE5E7EB)),
                ],
                ...List.generate(_cols.length, (i) {
                  final col = _cols[i];
                  if (isMobile) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: const Color(0xFFE5E7EB))),
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                          if (col.samples.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(col.samples.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                          ],
                          const SizedBox(height: 8),
                          DropdownButtonFormField<String>(
                            value: _fields.contains(col.mappedTo) || col.mappedTo == 'create_new' ? col.mappedTo : 'ignore',
                            isExpanded: true,
                            decoration: InputDecoration(isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                              filled: true, fillColor: Colors.white,
                            ),
                            items: [
                              ..._fields.map((f) => DropdownMenuItem(value: f,
                                  child: Text(_fieldLabel(f), style: const TextStyle(fontSize: 13)))),
                              if (!isSCT) const DropdownMenuItem(value: 'create_new',
                                  child: Text('+ Create new field', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600))),
                            ],
                            onChanged: (v) { if (v != null) setState(() => col.mappedTo = v); },
                          ),
                          if (col.mappedTo == 'create_new') ...[
                            const SizedBox(height: 8),
                            TextFormField(
                              controller: _newColCtrls[col.index] ??= TextEditingController(),
                              onChanged: (v) => col.newColName = v,
                              decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                                hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ]),
                      ),
                    );
                  }
                  final isCreate = col.mappedTo == 'create_new';
                  final ctrl = _newColCtrls[col.index] ??= TextEditingController();
                  return Column(children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                          Expanded(flex: 4, child: Text(
                            col.header.isNotEmpty ? col.header : 'Column ${i + 1}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                          )),
                          Expanded(flex: 5, child: Text(
                            col.samples.join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                          )),
                          Expanded(flex: 5, child: DropdownButtonFormField<String>(
                            value: _fields.contains(col.mappedTo) || col.mappedTo == 'create_new' ? col.mappedTo : 'ignore',
                            decoration: InputDecoration(isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                              filled: true, fillColor: Colors.white,
                            ),
                            items: [
                              ..._fields.map((f) => DropdownMenuItem(value: f,
                                  child: Text(_fieldLabel(f), style: const TextStyle(fontSize: 13)))),
                              if (!isSCT) const DropdownMenuItem(value: 'create_new',
                                  child: Text('+ Create new field', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43), fontWeight: FontWeight.w600))),
                            ],
                            onChanged: (v) { if (v != null) setState(() => col.mappedTo = v); },
                            style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                          )),
                        ]),
                        if (isCreate) ...[
                          const SizedBox(height: 8),
                          Row(children: [
                            const SizedBox(width: 12),
                            const Icon(Icons.subdirectory_arrow_right, size: 16, color: Color(0xFF9CA3AF)),
                            const SizedBox(width: 8),
                            Expanded(flex: 3, child: TextFormField(
                              controller: ctrl,
                              onChanged: (v) => col.newColName = v,
                              decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                                hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              style: const TextStyle(fontSize: 13),
                            )),
                            const SizedBox(width: 10),
                            const Text('Type:', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                            const SizedBox(width: 6),
                            Expanded(flex: 2, child: DropdownButtonFormField<String>(
                              value: col.newColType,
                              decoration: InputDecoration(isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                                filled: true, fillColor: const Color(0xFFECFDF5),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'text', child: Text('text', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'numeric', child: Text('number', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'date', child: Text('date', style: TextStyle(fontSize: 13))),
                                DropdownMenuItem(value: 'boolean', child: Text('boolean', style: TextStyle(fontSize: 13))),
                              ],
                              onChanged: (v) { if (v != null) setState(() => col.newColType = v); },
                              style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                            )),
                          ]),
                        ],
                      ]),
                    ),
                    if (i < _cols.length - 1) const Divider(height: 1, color: Color(0xFFF3F4F6)),
                  ]);
                }),
                const SizedBox(height: 8),
                Text(isSCT
                    ? '${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported into supplier_company_terms'
                    : '${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported as approved suppliers',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ]),
            );
          })),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280)))),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _confirmMapping,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
                child: Text(isSCT
                    ? 'Import ${_dataRows.length} Term${_dataRows.length == 1 ? '' : 's'}'
                    : 'Import ${_dataRows.length} Supplier${_dataRows.length == 1 ? '' : 's'}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ── Destination tab widget for import dialog ──────────────────────────────────

class _DestTab extends StatelessWidget {
  final String label;
  final String sublabel;
  final bool selected;
  final VoidCallback onTap;
  const _DestTab({required this.label, required this.sublabel, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: selected ? Border.all(color: const Color(0xFF1B7A43), width: 1.5) : null,
          boxShadow: selected ? [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 4, offset: const Offset(0, 1))] : null,
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: TextStyle(fontSize: 13, fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? const Color(0xFF1B7A43) : const Color(0xFF6B7280))),
          const SizedBox(height: 2),
          Text(sublabel, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ]),
      ),
    );
  }
}

// ── Supplier Companies pill button (stateless — count from parent) ────────────

class _SupplierCompaniesButton extends StatelessWidget {
  final int count;
  final bool isOpen;
  const _SupplierCompaniesButton({required this.count, required this.isOpen});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isOpen ? const Color(0xFFDBEAFE) : const Color(0xFFEFF6FF),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: const Color(0xFF93C5FD)),
        ),
        child: Text('Companies ($count)',
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                color: Color(0xFF2563EB))),
      ),
    );
  }
}

// ── Inline companies section (expands below row, not a popup) ─────────────────

class _CompaniesInlineSection extends StatefulWidget {
  final String supplierId;
  final VoidCallback onCompanyAdded;
  const _CompaniesInlineSection({required this.supplierId, required this.onCompanyAdded});

  @override
  State<_CompaniesInlineSection> createState() => _CompaniesInlineSectionState();
}

class _CompaniesInlineSectionState extends State<_CompaniesInlineSection> {
  bool _loading = true;
  bool _refreshing = false;
  List<Map<String, dynamic>> _rows = [];
  List<String> _medMarketers = [];
  bool _showAddForm = false;
  bool _saving = false;
  final _supplierCompanyCtrl = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _supplierCompanyCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final client = Supabase.instance.client;
      final rows = await client
          .from('supplier_company_terms')
          .select('id, supplier_company, company_1, company_2, company_3, company_4, company_5, margin, cd_condition, payment_type, deal')
          .eq('supplier_id', widget.supplierId)
          .order('created_at');

      if (_medMarketers.isEmpty) {
        final meds = await client.rpc('get_distinct_marketers');
        final list = (meds as List)
            .map((m) => (m as String? ?? '').trim())
            .where((m) => m.isNotEmpty)
            .toList();
        list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _medMarketers = list;
      }

      if (mounted) setState(() {
        _rows = (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addRow() async {
    final raw = _supplierCompanyCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('supplier_company_terms').insert({
        'supplier_id': widget.supplierId,
        'supplier_company': raw,
      });
      _supplierCompanyCtrl.clear();
      if (mounted) setState(() { _showAddForm = false; _saving = false; });
      widget.onCompanyAdded();
      await _load();
    } catch (_) {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _updateCell(String rowId, String col, String? value) async {
    final v = (value == null || value.isEmpty) ? null : value;
    try {
      await Supabase.instance.client
          .from('supplier_company_terms')
          .update({col: v}).eq('id', rowId);
      final idx = _rows.indexWhere((r) => r['id'] == rowId);
      if (idx >= 0 && mounted) setState(() => _rows[idx][col] = v);
    } catch (_) {}
  }

  // ── 2-stage fuzzy matcher (trigram → DL, same weights as bulk_upload) ────────
  String _normS(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

  Set<String> _tri(String s) {
    if (s.length < 3) return {};
    final t = <String>{};
    for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
    return t;
  }

  int _ed(String s, String t) {
    final m = s.length, n = t.length;
    if (m == 0) return n; if (n == 0) return m;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;
    for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
      if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
      else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
    }
    return dp[m][n];
  }

  int _dl(String s, String t) {
    final m = s.length, n = t.length;
    if (m == 0) return n; if (n == 0) return m;
    final dp = List.generate(m + 1, (_) => List.filled(n + 1, 0));
    for (int i = 0; i <= m; i++) dp[i][0] = i;
    for (int j = 0; j <= n; j++) dp[0][j] = j;
    for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
      if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
      else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
      if (i > 1 && j > 1 && s[i-1] == t[j-2] && s[i-2] == t[j-1]) {
        final tr = dp[i-2][j-2] + 1; if (tr < dp[i][j]) dp[i][j] = tr;
      }
    }
    return dp[m][n];
  }

  double _s1(String q, String c) {
    final qn = _normS(q).replaceAll(' ', ''), cn = _normS(c).replaceAll(' ', '');
    if (qn.isEmpty || cn.isEmpty) return 0.0;
    final qt = _tri(qn), ct = _tri(cn);
    final tri = qt.union(ct).isEmpty ? 0.0 : qt.intersection(ct).length / qt.union(ct).length.toDouble();
    final ml = qn.length > cn.length ? qn.length : cn.length;
    return 0.55 * tri + 0.45 * (1.0 - _ed(qn, cn) / ml);
  }

  double _s2(String q, String c) {
    final qn = _normS(q), cn = _normS(c);
    if (qn.isEmpty || cn.isEmpty) return 0.0;
    final ml = qn.length > cn.length ? qn.length : cn.length;
    final er = 1.0 - _dl(qn, cn) / ml;
    final qw = qn.split(' ').where((t) => t.isNotEmpty).toSet();
    final cw = cn.split(' ').where((t) => t.isNotEmpty).toSet();
    final tj = qw.union(cw).isEmpty ? 0.0 : qw.intersection(cw).length / qw.union(cw).length.toDouble();
    final tr = qw.isEmpty ? 0.0 : qw.where((t) => cw.contains(t)).length / qw.length;
    final ql = qn.split(' ').where((t) => t.isNotEmpty).toList();
    final cl = cn.split(' ').where((t) => t.isNotEmpty).toList();
    final qf = ql.isEmpty ? '' : ql[0], cf = cl.isEmpty ? '' : cl[0];
    final fm = qf.length > cf.length ? qf.length : cf.length;
    final pr = fm == 0 ? 0.0 : 1.0 - _dl(qf, cf) / fm;
    final qft = _tri(qf), cft = _tri(cf);
    final fw = qft.union(cft).isEmpty ? 0.0 : qft.intersection(cft).length / qft.union(cft).length.toDouble();
    return 0.50 * er + 0.12 * tj + 0.13 * tr + 0.20 * pr + 0.05 * fw;
  }

  List<String> _top5(String raw) {
    if (raw.isEmpty || _medMarketers.isEmpty) return [];
    final s1 = _medMarketers.map((m) => (m, _s1(raw, m))).where((p) => p.$2 > 0.05).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final shortlist = s1.take(60).map((p) => p.$1).toList();
    final s2 = shortlist.map((m) => (m, _s2(raw, m))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return s2.take(5).map((p) => p.$1).toList();
  }

  Future<void> _refresh() async {
    if (_rows.isEmpty) return;
    setState(() => _refreshing = true);
    try {
      final client = Supabase.instance.client;
      for (final row in _rows) {
        final raw = (row['supplier_company'] as String? ?? '').trim();
        if (raw.isEmpty) continue;
        final top = _top5(raw);
        String? n(int i) => i < top.length && top[i].isNotEmpty ? top[i] : null;
        await client.from('supplier_company_terms').update({
          'company_1': n(0), 'company_2': n(1), 'company_3': n(2),
          'company_4': n(3), 'company_5': n(4),
        }).eq('id', row['id'] as String);
      }
      await _load();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Widget _hdr(String label, double w) => SizedBox(
    width: w,
    child: Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.4)),
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0F7FF),
        border: Border(top: BorderSide(color: Color(0xFFBFDBFE)), bottom: BorderSide(color: Color(0xFFBFDBFE))),
      ),
      child: _loading
          ? const Padding(padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // ── Header ───────────────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Row(children: [
                  const Text("Supplier's Companies",
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                  const Spacer(),
                  if (_rows.isNotEmpty)
                    TextButton.icon(
                      onPressed: _refreshing ? null : _refresh,
                      icon: _refreshing
                          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2563EB)))
                          : const Icon(Icons.refresh, size: 15),
                      label: Text(_refreshing ? 'Matching…' : 'Refresh',
                          style: const TextStyle(fontSize: 12)),
                      style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF2563EB),
                          visualDensity: VisualDensity.compact),
                    ),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFBFDBFE)),
              // ── Empty state ──────────────────────────────────────────────────
              if (_rows.isEmpty && !_showAddForm)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: Text('No companies linked yet.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ),
              // ── Grid ─────────────────────────────────────────────────────────
              if (_rows.isNotEmpty)
                Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      final outer = PrimaryScrollController.of(context);
                      if (outer.hasClients) {
                        final dy = e.scrollDelta.dy;
                        final next = (outer.offset + dy).clamp(0.0, outer.position.maxScrollExtent);
                        outer.jumpTo(next);
                      }
                    }
                  },
                  child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                        child: Row(children: [
                          _hdr('SUPPLIER COMPANY', 172),
                          const SizedBox(width: 4),
                          _hdr('COMPANY 1', 156),
                          const SizedBox(width: 4),
                          _hdr('COMPANY 2', 156),
                          const SizedBox(width: 4),
                          _hdr('COMPANY 3', 156),
                          const SizedBox(width: 4),
                          _hdr('COMPANY 4', 156),
                          const SizedBox(width: 4),
                          _hdr('COMPANY 5', 156),
                        ]),
                      ),
                      const Divider(height: 1, color: Color(0xFFDBEAFE)),
                      for (int ri = 0; ri < _rows.length; ri++) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                            SizedBox(width: 172, child: Text(
                              _rows[ri]['supplier_company'] as String? ?? '—',
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                              maxLines: 2, overflow: TextOverflow.ellipsis,
                            )),
                            for (final col in ['company_1','company_2','company_3','company_4','company_5']) ...[
                              const SizedBox(width: 4),
                              _CompanyCell(
                                value: _rows[ri][col] as String?,
                                options: _medMarketers,
                                onChanged: (v) => _updateCell(_rows[ri]['id'] as String, col, v),
                              ),
                            ],
                          ]),
                        ),
                        if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFEFF6FF)),
                      ],
                    ]),
                  ),
                  ), // SingleChildScrollView
                ), // Listener
              // ── Add-row form ─────────────────────────────────────────────────
              if (_showAddForm)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(children: [
                    Expanded(child: TextField(
                      controller: _supplierCompanyCtrl,
                      autofocus: true,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Company name as supplier wrote it',
                        hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                      ),
                    )),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => setState(() { _showAddForm = false; _supplierCompanyCtrl.clear(); }),
                      child: const Text('Cancel', style: TextStyle(fontSize: 13)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: _saving ? null : _addRow,
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
                      child: _saving
                          ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                          : const Text('Add', style: TextStyle(fontSize: 13)),
                    ),
                  ]),
                ),
              // ── Footer ───────────────────────────────────────────────────────
              if (!_showAddForm)
                Container(
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFBFDBFE)))),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                    TextButton.icon(
                      onPressed: () => setState(() => _showAddForm = true),
                      icon: const Icon(Icons.add, size: 15),
                      label: const Text('Add Company', style: TextStyle(fontSize: 13)),
                      style: TextButton.styleFrom(foregroundColor: const Color(0xFF2563EB), visualDensity: VisualDensity.compact),
                    ),
                  ]),
                ),
            ]),
    );
  }
}

// ── Tappable company cell (opens marketer picker) ─────────────────────────────

class _CompanyCell extends StatelessWidget {
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;
  const _CompanyCell({this.value, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final filled = value != null && value!.isNotEmpty;
    return GestureDetector(
      onTap: () async {
        final result = await showDialog<String>(
          context: context,
          builder: (_) => _MarketersPickerDialog(options: options, current: value),
        );
        if (result != null) onChanged(result.isEmpty ? null : result);
      },
      child: Container(
        width: 152,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: filled ? const Color(0xFFECFDF5) : Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: filled ? const Color(0xFF6EE7B7) : const Color(0xFFE5E7EB)),
        ),
        child: Row(children: [
          Expanded(child: Text(
            filled ? value! : '—',
            style: TextStyle(fontSize: 11,
                color: filled ? const Color(0xFF065F46) : const Color(0xFF9CA3AF)),
            overflow: TextOverflow.ellipsis, maxLines: 1,
          )),
          const Icon(Icons.arrow_drop_down, size: 14, color: Color(0xFF9CA3AF)),
        ]),
      ),
    );
  }
}

// ── Marketer picker dialog ────────────────────────────────────────────────────

class _MarketersPickerDialog extends StatefulWidget {
  final List<String> options;
  final String? current;
  const _MarketersPickerDialog({required this.options, this.current});
  @override
  State<_MarketersPickerDialog> createState() => _MarketersPickerDialogState();
}

class _MarketersPickerDialogState extends State<_MarketersPickerDialog> {
  String _q = '';
  List<String> get _filtered => _q.isEmpty
      ? widget.options
      : widget.options.where((o) => o.toLowerCase().contains(_q.toLowerCase())).toList();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 380, maxHeight: MediaQuery.of(context).size.height * 0.72),
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _q = v),
              decoration: InputDecoration(
                hintText: 'Search MEDICINE company…',
                hintStyle: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)),
                prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                filled: true, fillColor: const Color(0xFFF9FAFB),
              ),
            ),
          ),
          if (widget.current != null && widget.current!.isNotEmpty)
            InkWell(
              onTap: () => Navigator.of(context).pop(''),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(Icons.clear, size: 14, color: Color(0xFF9CA3AF)),
                  SizedBox(width: 8),
                  Text('Clear selection', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ]),
              ),
            ),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Expanded(child: ListView.builder(
            itemCount: _filtered.length,
            itemBuilder: (_, i) {
              final opt = _filtered[i];
              final isCur = opt == widget.current;
              return InkWell(
                onTap: () => Navigator.of(context).pop(opt),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(children: [
                    Expanded(child: Text(opt, style: TextStyle(
                        fontSize: 13,
                        fontWeight: isCur ? FontWeight.w700 : FontWeight.normal,
                        color: isCur ? const Color(0xFF1B7A43) : const Color(0xFF111827)))),
                    if (isCur) const Icon(Icons.check, size: 15, color: Color(0xFF1B7A43)),
                  ]),
                ),
              );
            },
          )),
        ]),
      ),
    );
  }
}

extension _ListExt<T> on List<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) { if (test(e)) return e; }
    return null;
  }
}
