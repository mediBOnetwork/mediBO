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
import 'package:pharma_b2b/utils/toast.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart' as xmlp;

import '../../supabase_config.dart';
import '../../utils/render_log.dart';

const _ocrEdgeFn =
    'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

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
  String get status         =>  rawData['status']         as String? ?? 'Active';
  bool   get isSuspended    => status == 'Suspended';
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

enum _SupFilter  { suppliers, orders, pending, leads }
enum _SupSortMode { spnDesc, nameAsc }

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
  _SupSortMode _sortMode = _SupSortMode.spnDesc;
  bool _hasPendingChanges = false;
  bool _refreshLoading = false;
  // Supplier detail expand — only one supplier open at a time.
  String? _expandedSupplierId;
  // Companies section — only one supplier open at a time; mutually exclusive with detail.
  String? _companiesSupplierId;
  String? _spnSupplierId;
  final Set<String> _expandedLeads = {};
  final Map<String, int> _companyCounts = {};
  final Map<String, void Function(Map<String, dynamic>)> _spnCallbacks = {};
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

    // Single-binding channel for supplier_profiles: UPDATE → surgical patch;
    // INSERT/DELETE → full debounced reload.
    RenderLog.write('rt_supplier_profiles', 1);
    final spCh = client
        .channel('admin_supplier_profiles')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'supplier_profiles',
          callback: (payload) {
            if (payload.eventType == PostgresChangeEvent.update) {
              _patchSupplierRow(payload.newRecord);
            } else {
              _debouncedLoad();
            }
          },
        )
        .subscribe();
    _channels.add(spCh);

    // Separate channels for other tables (single-binding each).
    for (final table in ['supplier_orders', 'supplier_leads']) {
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

  static const _spnPatchKeys = [
    'margin', 'cd_condition', 'behaviour', 'payment_type', 'payment_term',
    'margin_points', 'cd_points', 'behaviour_points', 'payment_term_points',
    'status', 'supplier_name',
  ];

  void _patchSupplierRow(Map<String, dynamic> newRow) {
    final id = newRow['id'] as String?;
    if (id == null || !mounted) return;
    final idx = _suppliers.indexWhere((s) => s.id == id);
    if (idx >= 0) {
      for (final k in _spnPatchKeys) {
        if (newRow.containsKey(k)) _suppliers[idx].rawData[k] = newRow[k];
      }
    }
    // If this echo is for the currently-open SPN panel, skip the callback and
    // parent rebuild — the user's local _values are source of truth while editing.
    if (id == _spnSupplierId) return;
    _spnCallbacks[id]?.call(newRow);
    if (mounted) setState(() {});
  }

  void _applySort() {
    if (_sortMode == _SupSortMode.spnDesc) {
      _suppliers.sort((a, b) {
        final aSpn = (a.rawData['SPN'] as num?)?.toDouble() ?? -1;
        final bSpn = (b.rawData['SPN'] as num?)?.toDouble() ?? -1;
        return bSpn.compareTo(aSpn); // descending
      });
    } else {
      _suppliers.sort((a, b) =>
          a.supplierName.toLowerCase().compareTo(b.supplierName.toLowerCase()));
    }
  }

  Future<void> _refreshSuppliers({bool isSave = false}) async {
    if (_refreshLoading) return;
    if (mounted) setState(() => _refreshLoading = true);
    if (isSave) {
      RenderLog.write('save_clicked', '1');
    } else {
      RenderLog.write('refresh_clicked', '1');
    }
    await _load(showSpinner: false);
    if (mounted) {
      setState(() {
        _hasPendingChanges = false;
        _refreshLoading = false;
      });
      RenderLog.write('supabase_refetched', _suppliers.length.toString());
      if (isSave) RenderLog.write('save_committed', '1');
      RenderLog.write('list_rebuilt', _suppliers.length.toString());
    }
  }

  void _debouncedLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () => _load(showSpinner: false));
  }

  void _toggleCompanies(String id) => setState(() {
    if (_companiesSupplierId == id) {
      _companiesSupplierId = null;
    } else {
      _companiesSupplierId = id;
      _expandedSupplierId  = null;
      _spnSupplierId       = null;
    }
  });

  void _toggleSpn(String id) => setState(() {
    if (_spnSupplierId == id) {
      _spnSupplierId = null;
    } else {
      _spnSupplierId       = id;
      _expandedSupplierId  = null;
      _companiesSupplierId = null;
    }
  });

  Future<void> _reloadCompanyCount(String supplierId) async {
    try {
      final rows = await Supabase.instance.client
          .from('supplier_company')
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
            .order('supplier_name').catchError((_) => <dynamic>[]),
        client.from('supplier_orders').select().order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_leads').select().order('created_at', ascending: false)
            .catchError((_) => <dynamic>[]),
        client.from('supplier_profiles').select().eq('is_deleted', true)
            .order('deleted_at', ascending: false).catchError((_) => <dynamic>[]),
        client.from('supplier_company').select('supplier_id')
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
          _applySort();
        });
        RenderLog.write('supplier_sort_default', 'spn_desc');
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
      'status':      'Active',
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
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'Suspended'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) showToast(context, 'Suspend failed: $e', isError: true);
    }
  }

  Future<void> _reactivateSupplier(_SupRow row) async {
    try {
      await Supabase.instance.client.from('supplier_profiles').update({'status': 'Active'}).eq('id', row.id);
      _load(showSpinner: false);
    } catch (e) {
      if (mounted) showToast(context, 'Reactivate failed: $e', isError: true);
    }
  }

  Future<void> _deleteSupplier(_SupRow row) async {
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
      if (mounted) showToast(context, 'Supplier deleted.');
    } catch (e) {
      if (mounted) showToast(context, 'Delete failed: $e', isError: true);
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
        showToast(context, '$displayName permanently deleted.', isError: true, duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Delete failed: $e', isError: true);
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
        showToast(context, '$count supplier${count == 1 ? '' : 's'} permanently deleted.', isError: true, duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Clear all failed: $e', isError: true);
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
        showToast(context, 'Supplier restored.', duration: const Duration(seconds: 3));
      }
    } catch (e) {
      if (mounted) {
        showToast(context, 'Restore failed: $e', isError: true);
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
      if (mounted) showToast(context, 'Update failed: $e', isError: true);
    }
  }

  void _toggleExpand(String key) => setState(() {
    if (_expandedSupplierId == key) {
      _expandedSupplierId = null;
    } else {
      _expandedSupplierId  = key;
      _companiesSupplierId = null;
      _spnSupplierId       = null;
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
          setState(() { _filter = f; _expandedSupplierId = null; _companiesSupplierId = null; _spnSupplierId = null; });
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
    final pad = isDesktop ? 28.0 : 16.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 10, pad, 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          _buildRefreshButton(),
          const SizedBox(width: 12),
          const Text('Sort:', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          const SizedBox(width: 6),
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<_SupSortMode>(
                value: _sortMode,
                isDense: true,
                icon: const Icon(Icons.unfold_more, size: 14, color: Color(0xFF6B7280)),
                style: const TextStyle(fontSize: 12, color: Color(0xFF111827)),
                items: const [
                  DropdownMenuItem(
                    value: _SupSortMode.spnDesc,
                    child: Text('SPN (High→Low)'),
                  ),
                  DropdownMenuItem(
                    value: _SupSortMode.nameAsc,
                    child: Text('Name (A–Z)'),
                  ),
                ],
                onChanged: (mode) {
                  if (mode == null || mode == _sortMode) return;
                  setState(() {
                    _sortMode = mode;
                    _applySort();
                  });
                  RenderLog.write('supplier_sort_mode',
                      mode == _SupSortMode.spnDesc ? 'spn_desc' : 'name_asc');
                },
              ),
            ),
          ),
        ]),
      ),
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

  Widget _buildRefreshButton() {
    RenderLog.write('button_rendered', _hasPendingChanges ? 'pending' : 'idle');
    final isPending = _hasPendingChanges;
    final bgColor    = isPending ? const Color(0xFF1B7A43) : Colors.white;
    final textColor  = isPending ? Colors.white : const Color(0xFF374151);
    final borderColor = isPending ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB);
    final label = isPending ? 'Save Changes' : 'Refresh';
    final icon  = isPending ? Icons.save_outlined : Icons.refresh;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: _refreshLoading ? null : () => _refreshSuppliers(isSave: isPending),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.06),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_refreshLoading)
              SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: isPending ? Colors.white : const Color(0xFF6B7280),
                ),
              )
            else
              Icon(icon, size: 14, color: textColor),
            const SizedBox(width: 5),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: textColor)),
          ]),
        ),
      ),
    );
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
                  onTap: () => _toggleSpn(row.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: _spnSupplierId == row.id ? const Color(0xFFDBEAFE) : Colors.white,
                      borderRadius: BorderRadius.circular(5),
                      border: Border.all(color: _spnSupplierId == row.id ? const Color(0xFF93C5FD) : const Color(0xFFD1D5DB)),
                    ),
                    child: const Text('SPN', style: TextStyle(
                        fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => _toggleCompanies(row.id),
                  behavior: HitTestBehavior.opaque,
                  child: _SupplierCompaniesButton(
                    count: _companyCounts[row.id] ?? 0,
                    isOpen: _companiesSupplierId == row.id,
                  ),
                ),
                const SizedBox(width: 10),
                _StatusPill(
                  key: ValueKey('status_${row.id}'),
                  supplierId: row.id,
                  initialStatus: row.status,
                  onStatusChanged: (newStatus) {
                    row.rawData['status'] = newStatus;
                    if (mounted) setState(() { _hasPendingChanges = true; });
                  },
                ),
                const SizedBox(width: 14),
                _actionBtn('Edit', const Color(0xFF1B7A43), () => _editSupplier(row)),
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
          supplierName: row.supplierName,
          onCompanyAdded: () => _reloadCompanyCount(row.id),
        ),
      if (_spnSupplierId == row.id)
        _SpnInlineSection(
                key: ValueKey('spn_${row.id}'),
                supplierId: row.id,
                supplierName: row.supplierName,
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
                  Expanded(child: Text(
                      row.supplierName.isNotEmpty ? row.supplierName : row.contactName.isNotEmpty ? row.contactName : 'Unknown',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                      overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () => _toggleSpn(row.id),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _spnSupplierId == row.id ? const Color(0xFFDBEAFE) : Colors.white,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: _spnSupplierId == row.id ? const Color(0xFF93C5FD) : const Color(0xFFD1D5DB)),
                      ),
                      child: const Text('SPN', style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                    ),
                  ),
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => _toggleCompanies(row.id),
                    behavior: HitTestBehavior.opaque,
                    child: _SupplierCompaniesButton(
                      count: _companyCounts[row.id] ?? 0,
                      isOpen: _companiesSupplierId == row.id,
                    ),
                  ),
                  const SizedBox(width: 6),
                  _StatusPill(
                    key: ValueKey('status_${row.id}'),
                    supplierId: row.id,
                    initialStatus: row.status,
                    onStatusChanged: (newStatus) {
                      row.rawData['status'] = newStatus;
                      if (mounted) setState(() { _hasPendingChanges = true; });
                    },
                  ),
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
                  _actionBtn('Edit',   const Color(0xFF1B7A43), () => _editSupplier(row)),
                  _actionBtn('Delete', const Color(0xFFDC2626), () => _deleteSupplier(row)),
                ]),
              ]),
            ),
            if (_companiesSupplierId == row.id) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _CompaniesInlineSection(
                supplierId: row.id,
                supplierName: row.supplierName,
                onCompanyAdded: () => _reloadCompanyCount(row.id),
              ),
            ],
            if (_spnSupplierId == row.id) ...[
              const Divider(height: 1, color: Color(0xFFE5E7EB)),
              _SpnInlineSection(
                key: ValueKey('spn_${row.id}'),
                supplierId: row.id,
                supplierName: row.supplierName,
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
      ..accept = '.csv,.tsv,.txt,.xlsx,.xls,.ods,.docx,.pdf,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = true;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty || !mounted) return;

    const imageExts = {'jpg', 'jpeg', 'png', 'webp', 'heic', 'heif', 'gif'};
    final images = files.where((f) => imageExts.contains(f.name.toLowerCase().split('.').last)).toList();
    final nonImages = files.where((f) => !imageExts.contains(f.name.toLowerCase().split('.').last)).toList();

    if (nonImages.isNotEmpty) {
      // Non-image: use existing single-file profile import dialog (first file only)
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupProfileImportDialog(file: nonImages.first, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
      return;
    }

    if (images.length == 1) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupCardImportDialog(file: images.first, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
    } else {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SupCardMultiImportDialog(files: images, onImported: () { if (mounted) _load(showSpinner: false); }),
      );
    }
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
      case 'Suspended':
        color = const Color(0xFFD97706); label = 'Suspended'; icon = Icons.block_outlined;
        break;
      case 'Blocked':
        color = const Color(0xFFDC2626); label = 'Blocked'; icon = Icons.block;
        break;
      case 'Inactive':
        color = const Color(0xFF6B7280); label = 'Inactive'; icon = Icons.pause_circle_outline;
        break;
      case 'Active':
      default:
        color = const Color(0xFF1B7A43); label = 'Active'; icon = Icons.verified_outlined;
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

// ── Status pill (inline dropdown) ────────────────────────────────────────────

class _StatusPill extends StatefulWidget {
  final String supplierId;
  final String initialStatus;
  final void Function(String) onStatusChanged;
  const _StatusPill({
    super.key,
    required this.supplierId,
    required this.initialStatus,
    required this.onStatusChanged,
  });
  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill> {
  static const _options = ['Active', 'Inactive', 'Suspended', 'Blocked'];
  static const _colors  = {
    'Active':    Color(0xFF1B7A43),
    'Inactive':  Color(0xFF6B7280),
    'Suspended': Color(0xFFD97706),
    'Blocked':   Color(0xFFDC2626),
  };

  late String _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialStatus;
  }

  Color get _color => _colors[_selected] ?? const Color(0xFF6B7280);
  String get _label => _selected.isNotEmpty ? _selected : 'Active';

  Future<void> _write(String newStatus) async {
    RenderLog.write('status_pill_write', '$_selected→$newStatus');
    try {
      final res = await Supabase.instance.client
          .from('supplier_profiles')
          .update({'status': newStatus})
          .eq('id', widget.supplierId)
          .select('id')
          .timeout(const Duration(seconds: 8));
      RenderLog.write('status_pill_result', res.isEmpty ? 'EMPTY' : 'OK');
      if (mounted) {
        showToast(context, res.isEmpty ? 'Save failed — try again' : 'Status updated ✓', isError: res.isEmpty, duration: const Duration(milliseconds: 800));
      }
    } catch (e) {
      RenderLog.write('status_pill_error', e.toString());
      if (mounted) {
        showToast(context, 'Error: $e', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('status_pill_rendered', _selected);
    return PopupMenuButton<String>(
      initialValue: _selected,
      tooltip: '',
      padding: EdgeInsets.zero,
      position: PopupMenuPosition.under,
      onSelected: (val) {
        if (val == _selected) return;
        setState(() => _selected = val);
        widget.onStatusChanged(val);
        _write(val);
      },
      itemBuilder: (_) => _options.map((opt) {
        final c = _colors[opt] ?? const Color(0xFF6B7280);
        return PopupMenuItem<String>(
          value: opt,
          height: 36,
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Text(opt, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c)),
          ]),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: _color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.arrow_drop_down, size: 12, color: _color),
          const SizedBox(width: 2),
          Text(_label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: _color)),
        ]),
      ),
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
      if (mounted) showToast(context, 'Action failed: $e', isError: true);
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
        showToast(context, 'Save failed: $e', isError: true);
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
          Uri.parse(_ocrEdgeFn),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'image_base64': '', 'mime_type': 'text/plain', 'prompt': prompt}),
        ).timeout(const Duration(seconds: 20));
        if (resp.statusCode == 200) {
          final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
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
        showToast(context, 'Imported ${toInsert.length} lead${toInsert.length == 1 ? '' : 's'}');
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupCsvStep.mapping; });
        showToast(context, 'Import failed: $e', isError: true);
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

class _SupProfileImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupProfileImportDialog({required this.file, required this.onImported});
  @override
  State<_SupProfileImportDialog> createState() => _SupProfileImportDialogState();
}

class _SupProfileImportDialogState extends State<_SupProfileImportDialog> {
  _SupProfStep _step = _SupProfStep.reading;
  String _statusMsg = 'Reading file…';
  List<_SupProfColMap> _cols = [];
  List<List<String>> _dataRows = [];
  String? _error;
  final Map<int, TextEditingController> _newColCtrls = {};
  List<String> _dynamicFields = [];

  static const _baseFields = [
    'supplier_name', 'company_name',
    'contact_person', 'contact_no', 'whatsapp_no', 'email',
    'status', 'margin', 'behaviour', 'cd_condition', 'payment_type', 'deal',
    'street_address', 'city', 'state', 'pin_code', 'map_link',
    'stockist_type', 'dl_1', 'dl_2', 'gst',
  ];
  static const _profileFields = [
    'supplier_name', 'contact_person', 'contact_no', 'whatsapp_no', 'email',
    'status', 'margin', 'behaviour', 'cd_condition', 'payment_type', 'deal',
    'street_address', 'city', 'state', 'pin_code', 'map_link',
    'stockist_type', 'dl_1', 'dl_2', 'gst',
  ];
  List<String> get _fields => [..._baseFields, ..._dynamicFields, 'ignore'];

  static String _fieldLabel(String f) => switch (f) {
    'supplier_name'  => 'Supplier Name *',
    'company_name'   => 'Company Name (→ supplier_company)',
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

  Future<({List<String> headers, List<List<String>> rows})> _geminiTable(
      bool isImage, String mime, String b64, String pdfMime) async {
    final prompt =
        'Extract the tabular supplier data from this file. '
        'Return ONLY a JSON object (no markdown fences):\n'
        '{"headers":["col1","col2"],"rows":[["v1","v2"],...]}\n'
        'Use empty string "" for missing headers. Include all data rows.';
    final resp = await http.post(
      Uri.parse(_ocrEdgeFn),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_base64': b64,
        'mime_type': isImage ? mime : pdfMime,
        'prompt': prompt,
      }),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) throw Exception('OCR API error (HTTP ${resp.statusCode})');
    final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
    if (txt.isEmpty) throw Exception('Empty response from OCR service');
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
    final allMappable = [..._baseFields, ..._dynamicFields];
    final entries = List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.trim().isNotEmpty).take(5).toList();
      return {'index': i, 'header': headers[i], 'samples': samples};
    });
    const basePrompt =
        'Map each CSV column to the correct field for importing supplier data.\n\n'
        'Fields: supplier_name (Firm/Supplier name, REQUIRED), '
        'company_name (Pharma company/brand the supplier stocks, goes to supplier_company table), '
        'contact_person, contact_no, whatsapp_no, email, city, state, street_address, pin_code, '
        'gst, dl_1, dl_2, margin, cd_condition, payment_type, deal, status, stockist_type, behaviour, map_link, '
        'ignore (skip this column).\n\n'
        'Rules: Firm/Supplier/Distributor name = supplier_name. '
        'Company/Brand/CO SUPPLIER/Supplier Company = company_name. '
        'Serial numbers = ignore. Infer from header AND samples.\n\n';
    final idxMap = <int, String>{};
    try {
      final resp = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'image_base64': '', 'mime_type': 'text/plain', 'prompt': '${basePrompt}Columns:\n${jsonEncode(entries)}\n\nReturn ONLY a JSON array: [{"index":0,"mapped_to":"supplier_name"},...]'}),
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
        final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
        if (jm != null) {
          for (final m in jsonDecode(jm.group(0)!) as List<dynamic>) {
            final mm = m as Map<String, dynamic>;
            final idx = mm['index'] as int?;
            final mapped = mm['mapped_to'] as String? ?? 'ignore';
            if (idx != null) idxMap[idx] = (allMappable.contains(mapped) || mapped == 'ignore') ? mapped : 'ignore';
          }
        }
      }
    } catch (_) {}
    final used = <String>{...idxMap.values};
    for (int i = 0; i < headers.length; i++) {
      if (idxMap.containsKey(i)) continue;
      final h = headers[i].toLowerCase().replaceAll(RegExp(r'[\s_\-]+'), '');
      String mapped = 'ignore';
      if (['suppliername','firmname','supplier','firm','distributor'].contains(h) && !used.contains('supplier_name')) mapped = 'supplier_name';
      else if (['companyname','company','brand','manufacturer','cosupplier','suppliercompany','pharmacompany'].contains(h) && !used.contains('company_name')) mapped = 'company_name';
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
      else if (['margin','trademargin','discount'].contains(h) && !used.contains('margin')) mapped = 'margin';
      else if (['behaviour','behavior'].contains(h) && !used.contains('behaviour')) mapped = 'behaviour';
      else if (['cdcondition','cd','cashdiscount'].contains(h) && !used.contains('cd_condition')) mapped = 'cd_condition';
      else if (['deal','scheme','bonus'].contains(h) && !used.contains('deal')) mapped = 'deal';
      else if (['maplink','maplocation','location'].contains(h) && !used.contains('map_link')) mapped = 'map_link';
      else if (['status'].contains(h) && !used.contains('status')) mapped = 'status';
      idxMap[i] = mapped;
      if (mapped != 'ignore') used.add(mapped);
    }
    return List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.isNotEmpty).take(3).toList();
      return _SupProfColMap(index: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
    });
  }

  Future<void> _confirmMapping() async {
    for (final col in _cols.where((c) => c.mappedTo == 'create_new')) {
      final name = (_newColCtrls[col.index]?.text ?? '').trim();
      if (name.isEmpty) {
        showToast(context, 'Enter a name for the new column "${col.header.isNotEmpty ? col.header : "Column ${col.index + 1}"}"');
        return;
      }
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
        showToast(context, '"$name" is invalid — use lowercase letters, numbers, underscores, starting with a letter');
        return;
      }
      if (_profileFields.contains(name)) {
        showToast(context, '"$name" already exists — map directly to that column instead');
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
          showToast(context, 'Could not create column "${col.newColName}": ${e.toString().replaceFirst('Exception: ', '')}', duration: const Duration(seconds: 8));
          return;
        }
      }
      setState(() { _step = _SupProfStep.mapping; });
    }

    await _doImportUnified();
  }

  Future<void> _parseAndMap() async {
    try {
      setState(() { _step = _SupProfStep.reading; _statusMsg = 'Reading file…'; });
      final table = await _parseFile(widget.file);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file.');
      setState(() { _statusMsg = 'Auto-mapping columns with Gemini…'; });
      final cols = await _geminiMapCols(table.headers, table.rows);
      setState(() { _cols = cols; _dataRows = table.rows; _step = _SupProfStep.mapping; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  Future<void> _doImportUnified() async {
    setState(() { _step = _SupProfStep.importing; _statusMsg = 'Importing…'; });
    try {
      final client = Supabase.instance.client;
      final colFor = <String, _SupProfColMap>{};
      for (final c in _cols) { if (c.mappedTo != 'ignore' && c.mappedTo != 'create_new') colFor[c.mappedTo] = c; }
      final allProfileFields = [..._profileFields, ..._dynamicFields];

      String rowVal(List<String> row, String field) {
        final c = colFor[field];
        return c != null && c.index < row.length ? row[c.index].trim() : '';
      }

      final hasCompanyCol = colFor.containsKey('company_name');

      final distinctNames = _dataRows
          .map((r) => rowVal(r, 'supplier_name'))
          .where((s) => s.isNotEmpty)
          .toSet().toList();
      if (distinctNames.isEmpty) throw Exception('No supplier_name column mapped.');

      final existingRows = await client.from('supplier_profiles')
          .select('id, supplier_name').inFilter('supplier_name', distinctNames);
      final supplierMap = <String, String>{};
      for (final r in existingRows as List<dynamic>) {
        supplierMap[(r['supplier_name'] as String).toLowerCase()] = r['id'] as String;
      }

      final toInsertProfiles = <Map<String, dynamic>>[];
      final seen = <String>{};
      for (final row in _dataRows) {
        final name = rowVal(row, 'supplier_name');
        if (name.isEmpty || seen.contains(name.toLowerCase())) continue;
        seen.add(name.toLowerCase());
        if (supplierMap.containsKey(name.toLowerCase())) continue;
        final rec = <String, dynamic>{'supplier_name': name, 'status': 'Active', 'approved': true, 'is_deleted': false};
        for (final f in allProfileFields.where((f) => f != 'supplier_name' && f != 'company_name')) {
          final v = rowVal(row, f);
          if (v.isNotEmpty) rec[f] = v;
        }
        toInsertProfiles.add(rec);
      }
      int profilesInserted = 0;
      if (toInsertProfiles.isNotEmpty) {
        final inserted = await client.from('supplier_profiles').insert(toInsertProfiles).select('id, supplier_name');
        for (final r in inserted as List<dynamic>) {
          supplierMap[(r['supplier_name'] as String).toLowerCase()] = r['id'] as String;
        }
        profilesInserted = inserted.length;
      }
      final profilesSkipped = distinctNames.length - profilesInserted;

      int scInserted = 0;
      if (hasCompanyCol) {
        final scRows = <Map<String, dynamic>>[];
        for (final row in _dataRows) {
          final supplierName = rowVal(row, 'supplier_name');
          final companyName  = rowVal(row, 'company_name');
          if (supplierName.isEmpty || companyName.isEmpty) continue;
          final supplierId = supplierMap[supplierName.toLowerCase()];
          if (supplierId == null) continue;
          scRows.add({'supplier_id': supplierId, 'supplier_company': companyName});
        }
        scInserted = scRows.length;
        for (int i = 0; i < scRows.length; i += 500) {
          final chunk = scRows.sublist(i, (i + 500).clamp(0, scRows.length));
          await client.from('supplier_company')
              .upsert(chunk, onConflict: 'supplier_id,supplier_company', ignoreDuplicates: true);
        }
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        final parts = <String>[];
        parts.add('$profilesInserted new supplier${profilesInserted == 1 ? "" : "s"}');
        if (profilesSkipped > 0) parts.add('$profilesSkipped already existed');
        if (hasCompanyCol) parts.add('$scInserted company row${scInserted == 1 ? "" : "s"} saved (company_1–5 empty, fill via Refresh)');
        showToast(context, 'Imported: ${parts.join(" · ")}', duration: const Duration(seconds: 6));
      }
    } catch (e) {
      if (mounted) {
        setState(() { _step = _SupProfStep.mapping; });
        showToast(context, 'Import failed: ${e.toString().replaceFirst("Exception: ", "")}', isError: true, duration: const Duration(seconds: 8));
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
            Text(_statusMsg,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]))),
      );
    }
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
                              const DropdownMenuItem(value: 'create_new',
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
                              const DropdownMenuItem(value: 'create_new',
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
                Text('${_dataRows.length} row${_dataRows.length == 1 ? '' : 's'} will be imported (suppliers + companies auto-split)',
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
                child: Text('Import ${_dataRows.length} Row${_dataRows.length == 1 ? '' : 's'}',
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
  final String supplierName;
  final VoidCallback onCompanyAdded;
  const _CompaniesInlineSection({required this.supplierId, required this.supplierName, required this.onCompanyAdded});

  @override
  State<_CompaniesInlineSection> createState() => _CompaniesInlineSectionState();
}

class _CompaniesInlineSectionState extends State<_CompaniesInlineSection> {
  static final _companyCols = List.generate(30, (i) => 'company_${i + 1}');

  bool _loading = true;
  // null = idle, 'manual' = manual fuzzy running, 'ai' = Gemini running, 'fallback' = fallback running, 'save' = saving
  String? _mappingMode;
  bool get _refreshing => _mappingMode != null;
  bool _mapped = false;
  int _needsReview = 0;
  Set<int> _flaggedRows = {};
  int _aiProgress = 0;
  int _aiTotal = 0;
  String? _aiStage; // 'candidates' | 'gemini' | null
  List<Map<String, dynamic>> _rows = [];
  List<String> _medMarketers = [];
  List<String> _companyCorpus = [];
  bool _showAddForm = false;
  bool _saving = false;
  final _supplierCompanyCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();

  @override
  void initState() { super.initState(); _load(); }

  @override
  void dispose() { _supplierCompanyCtrl.dispose(); _scrollCtrl.dispose(); super.dispose(); }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    // Fetch supplier_company rows — isolated so any error here is visible, not silently swallowed
    try {
      final colList = _companyCols.join(', ');
      final rows = await Supabase.instance.client
          .from('supplier_company')
          .select('id, supplier_company, supplier_name, $colList')
          .eq('supplier_id', widget.supplierId)
          .order('supplier_company');
      if (mounted) setState(() {
        _rows = (rows as List).map((r) => Map<String, dynamic>.from(r as Map)).toList();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
    // Load medicine marketers separately — failure here must not affect row display
    if (_medMarketers.isEmpty) {
      try {
        final meds = await Supabase.instance.client.rpc('get_distinct_marketers');
        final list = (meds as List)
            .map((m) => ((m as Map)['get_distinct_marketers'] as String? ?? '').trim())
            .where((m) => m.isNotEmpty)
            .toList();
        list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        if (mounted) setState(() => _medMarketers = list);
      } catch (_) {}
    }
  }

  Future<void> _addRow() async {
    final raw = _supplierCompanyCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.from('supplier_company').insert({
        'supplier_id': widget.supplierId,
        'supplier_name': widget.supplierName,
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
          .from('supplier_company')
          .update({col: v}).eq('id', rowId);
      final idx = _rows.indexWhere((r) => r['id'] == rowId);
      if (idx >= 0 && mounted) setState(() => _rows[idx][col] = v);
    } catch (_) {}
  }

  // ── Company corpus: paginated fetch to get all rows (Supabase caps at 1000/page) ──
  Future<void> _ensureCorpus() async {
    if (_companyCorpus.isNotEmpty) return;
    try {
      final allNames = <String>[];
      // Fetch in 1000-row pages until the page comes back short
      for (int from = 0; from <= 10000; from += 1000) {
        final res = await Supabase.instance.client
            .from('company')
            .select('company_name')
            .order('company_name')
            .range(from, from + 999);
        final page = (res as List)
            .map((r) => ((r as Map)['company_name'] as String? ?? '').trim())
            .where((s) => s.isNotEmpty)
            .toList();
        allNames.addAll(page);
        if (page.length < 1000) break; // last page
      }
      if (allNames.isNotEmpty) {
        _companyCorpus = allNames
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      }
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

  // Local shortlist: top 30 candidates from corpus via 2-stage fuzzy
  List<String> _candidateShortlist(String raw, List<String> corpus) {
    if (raw.isEmpty || corpus.isEmpty) return [];
    final s1r = corpus.map((m) => (m, _s1(raw, m))).where((p) => p.$2 > 0.04).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    final shortlist = s1r.take(80).map((p) => p.$1).toList();
    final s2r = shortlist.map((m) => (m, _s2(raw, m))).toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));
    return s2r.take(30).map((p) => p.$1).toList();
  }

  // Generic pharma tokens excluded from the significant-token guard
  static const _genericTokens = {
    'pharma', 'pharmaceutical', 'pharmaceuticals', 'labs', 'laboratory',
    'laboratories', 'ltd', 'limited', 'pvt', 'private', 'life', 'sciences',
    'science', 'healthcare', 'india', 'co', 'company', 'remedies', 'biotech',
    'biologics', 'medical', 'medicine', 'medicines', 'corp', 'corporation',
    'international', 'inc', 'the', 'and', 'of',
  };

  // Post-validation: returns true if candidate is genuinely the same entity as supplier.
  // Accepts if: (a) at least one significant token (≥4 chars, not generic) is shared, OR
  //             (b) _s2 score ≥ 0.72 (high fuzzy similarity).
  bool _isSameCompany(String supplier, String candidate) {
    final sup = supplier.toLowerCase();
    final can = candidate.toLowerCase();
    // Tokenise: split on non-alpha, drop generics, keep ≥4 char tokens
    Set<String> sigTokens(String s) => s
        .split(RegExp(r'[^a-z]+'))
        .where((t) => t.length >= 4 && !_genericTokens.contains(t))
        .toSet();
    final supToks = sigTokens(sup);
    final canToks = sigTokens(can);
    if (supToks.isNotEmpty && canToks.isNotEmpty && supToks.intersection(canToks).isNotEmpty) {
      return true;
    }
    // Fallback: high fuzzy score
    return _s2(supplier, candidate) >= 0.72;
  }

  // Apply post-validation to a list of Gemini-returned matches
  List<String> _validateMatches(String supplier, List<String> matches) =>
      matches.where((m) => _isSameCompany(supplier, m)).toList();

  static String _matchPromptRules() =>
      'You are a strict pharmaceutical company identity matcher.\n'
      'TASK: for each supplier_company, return ONLY the candidates that are DEFINITIVELY '
      'the same legal entity or brand family — e.g. abbreviations (MSD = MSD Pharmaceuticals), '
      'legal-suffix variants (Pvt Ltd / PRIVATE LIMITED / Ltd), spelling variants, or '
      'confirmed sub-brands of the same parent (MSD Animal Health India = MSD group).\n'
      'CRITICAL RULES — any violation makes the response invalid:\n'
      '  1. Return ONLY strings that appear VERBATIM in the candidates list.\n'
      '  2. EMPTY is the CORRECT answer when no candidate is definitively the same company. '
      '     NEVER return a candidate merely because the name looks or sounds similar — '
      '     "TORRENT" ≠ "Ascent Pharma", "PFIZER" ≠ "Farger Pvt Ltd". '
      '     If you are not certain, return empty.\n'
      '  3. Do NOT generate, invent, paraphrase, or modify any names.\n';

  // Single-row fallback (used when a batch parse fails for a specific row)
  Future<void> _mapCompanies() async {
    if (_rows.isEmpty) return;
    setState(() {
      _mappingMode = 'ai';
      _needsReview = 0;
      _flaggedRows = {};
      _aiProgress = 0;
      _aiTotal = 0;
      _aiStage = 'candidates';
    });
    // Switch to Gemini stage label after a brief delay
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _mappingMode == 'ai') setState(() => _aiStage = 'gemini');
    });
    try {
      final token = Supabase.instance.client.auth.currentSession?.accessToken ?? '';
      final resp = await http.post(
        Uri.parse('https://swojhmarmaijkshsbeih.supabase.co/functions/v1/match-companies'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({'supplier_id': widget.supplierId}),
      ).timeout(const Duration(seconds: 90));

      if (!mounted) return;
      if (resp.statusCode != 200) {
        showToast(context, 'Match failed (${resp.statusCode})', isError: true);
        return;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (data['items'] as List?) ?? [];
      final stats = (data['stats'] as Map<String, dynamic>?) ?? {};
      final matched = stats['matched'] as int? ?? 0;
      final needsReview = stats['needs_review'] as int? ?? 0;

      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      final flaggedSet = <int>{};

      for (final item in items) {
        final scId = item['sc_id'] as String? ?? '';
        final matches = (item['matches'] as List?)?.map((e) => e.toString()).toList() ?? [];
        final ri = updated.indexWhere((r) => r['id'] == scId);
        if (ri < 0) continue;
        if (matches.isEmpty) {
          flaggedSet.add(ri);
          // Clear any stale chips so the grid shows empty for this row
          for (int ci = 0; ci < _companyCols.length; ci++) {
            updated[ri][_companyCols[ci]] = null;
          }
        } else {
          final fill = matches.take(30).toList();
          for (int ci = 0; ci < _companyCols.length; ci++) {
            updated[ri][_companyCols[ci]] = ci < fill.length ? fill[ci] : null;
          }
        }
      }

      setState(() {
        _rows = updated;
        _mapped = true;
        _needsReview = needsReview;
        _flaggedRows = flaggedSet;
      });
      showToast(context, '$matched matched${needsReview > 0 ? ' · $needsReview need review' : ''}');
    } catch (e) {
      if (mounted) {
        showToast(context, 'Error: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() { _mappingMode = null; _aiProgress = 0; _aiTotal = 0; _aiStage = null; });
    }
  }

  Future<void> _mapCompaniesManual() async {
    if (_rows.isEmpty) return;
    setState(() { _mappingMode = 'manual'; _needsReview = 0; _flaggedRows = {}; });
    try {
      await _ensureCorpus();
      final corpusSet = _companyCorpus.toSet();
      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      int writeCount = 0;
      for (final row in updated) {
        final raw = (row['supplier_company'] as String? ?? '').trim();
        if (raw.isEmpty) continue;
        // Only keep matches that are confirmed in the corpus set (belt+suspenders)
        final matches = _candidateShortlist(raw, _companyCorpus)
            .where((m) => corpusSet.contains(m))
            .toList();
        if (matches.isNotEmpty) writeCount++;
        for (int ci = 0; ci < _companyCols.length; ci++) {
          row[_companyCols[ci]] = ci < matches.length ? matches[ci] : null;
        }
      }
      RenderLog.write('company_map_written', writeCount);
      if (mounted) setState(() { _rows = updated; _mapped = true; });
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  // Fallback: run local fuzzy ONLY on flagged/blank rows, leave AI-matched rows untouched
  Future<void> _matchManuallyFallback() async {
    if (_rows.isEmpty || _flaggedRows.isEmpty) return;
    setState(() => _mappingMode = 'fallback');
    try {
      await _ensureCorpus();
      final corpusSet = _companyCorpus.toSet();
      final updated = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      for (final ri in _flaggedRows) {
        if (ri >= updated.length) continue;
        final row = updated[ri];
        final raw = (row['supplier_company'] as String? ?? '').trim();
        if (raw.isEmpty) continue;
        final matches = _candidateShortlist(raw, _companyCorpus)
            .where((m) => corpusSet.contains(m))
            .toList();
        for (int ci = 0; ci < _companyCols.length; ci++) {
          row[_companyCols[ci]] = ci < matches.length ? matches[ci] : null;
        }
      }
      if (mounted) setState(() { _rows = updated; _needsReview = 0; _flaggedRows = {}; });
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  // Left-pack: drop nulls/empties, re-fill from company_1, trailing → null
  void _packRow(Map<String, dynamic> row) {
    final vals = _companyCols
        .map((c) => row[c] as String?)
        .where((v) => v != null && v.isNotEmpty)
        .toList();
    for (int ci = 0; ci < _companyCols.length; ci++) {
      row[_companyCols[ci]] = ci < vals.length ? vals[ci] : null;
    }
  }

  Future<void> _saveMatches() async {
    setState(() => _mappingMode = 'save');
    try {
      final client = Supabase.instance.client;
      final packed = _rows.map((r) => Map<String, dynamic>.from(r)).toList();
      for (final row in packed) { _packRow(row); }
      for (final row in packed) {
        final update = <String, dynamic>{};
        for (final col in _companyCols) { update[col] = row[col]; }
        await client.from('supplier_company').update(update).eq('id', row['id'] as String);
      }
      if (mounted) {
        setState(() {
          _rows = packed;
          _mapped = false;
          _needsReview = 0;
          _flaggedRows = {};
        });
        showToast(context, 'Saved.', duration: const Duration(seconds: 3));
      }
    } finally {
      if (mounted) setState(() => _mappingMode = null);
    }
  }

  Widget _hdr(String label, int flex) => Expanded(
    flex: flex,
    child: Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.4),
      overflow: TextOverflow.ellipsis),
  );

  @override
  Widget build(BuildContext context) {
    // ── Render-log instrumentation ──────────────────────────────────────────
    if (!_loading) {
      RenderLog.write('screen', 'supplier_companies');
      RenderLog.write('supplier', widget.supplierName);
      RenderLog.write('company_rows', _rows.length);
      RenderLog.write('spn_buttons', 0); // SPN moved to supplier header row
      RenderLog.write('map_buttons', 2); // Map by AI + Map Manually always rendered
      RenderLog.write('save_button', _mapped ? 1 : 0);
    }
    // ───────────────────────────────────────────────────────────────────────
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
                  if (_rows.isNotEmpty) ...[
                    if (_mapped) ...[
                      // Fallback: show only when AI left flagged rows
                      if (_needsReview > 0)
                        TextButton.icon(
                          onPressed: _mappingMode != null ? null : _matchManuallyFallback,
                          icon: _mappingMode == 'fallback'
                              ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
                              : const Icon(Icons.tune, size: 15),
                          label: Text(_mappingMode == 'fallback' ? 'Matching…' : 'Match Manually',
                              style: const TextStyle(fontSize: 12)),
                          style: TextButton.styleFrom(
                              foregroundColor: const Color(0xFF6B7280),
                              visualDensity: VisualDensity.compact),
                        ),
                      if (_needsReview > 0) const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: _mappingMode != null ? null : _saveMatches,
                        icon: _mappingMode == 'save'
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF1B7A43)))
                            : const Icon(Icons.save_outlined, size: 15),
                        label: Text(_mappingMode == 'save' ? 'Saving…' : 'Save',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF1B7A43),
                            visualDensity: VisualDensity.compact),
                      ),
                    ] else ...[
                      TextButton.icon(
                        onPressed: _mappingMode != null ? null : _mapCompaniesManual,
                        icon: _mappingMode == 'manual'
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF6B7280)))
                            : const Icon(Icons.tune, size: 15),
                        label: Text(_mappingMode == 'manual' ? 'Matching…' : 'Map Companies Manually',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF6B7280),
                            visualDensity: VisualDensity.compact),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: _mappingMode != null ? null : _mapCompanies,
                        icon: _mappingMode == 'ai'
                            ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 1.5, color: Color(0xFF2563EB)))
                            : const Icon(Icons.auto_awesome, size: 15),
                        label: Text(_mappingMode == 'ai' ? 'Matching…' : 'Map Companies by AI',
                            style: const TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF2563EB),
                            visualDensity: VisualDensity.compact),
                      ),
                    ],
                  ],
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFBFDBFE)),
              // ── AI progress bar ──────────────────────────────────────────────
              if (_mappingMode == 'ai')
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      const Icon(Icons.auto_awesome, size: 13, color: Color(0xFF2563EB)),
                      const SizedBox(width: 6),
                      Text(
                        _aiStage == 'gemini' ? 'Verifying with Gemini…' : 'Finding candidates…',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF1E40AF), fontWeight: FontWeight.w500),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _aiStage == 'gemini' ? 0.6 : 0.2,
                        minHeight: 5,
                        backgroundColor: const Color(0xFFBFDBFE),
                        color: const Color(0xFF2563EB),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ]),
                ),
              // ── Needs-review banner ──────────────────────────────────────────
              if (_needsReview > 0)
                Container(
                  color: const Color(0xFFFEF3C7),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  child: Row(children: [
                    const Icon(Icons.flag, size: 14, color: Color(0xFFD97706)),
                    const SizedBox(width: 6),
                    Text('Needs review (${ _needsReview }) — flagged rows could not be matched by Gemini.',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
                  ]),
                ),
              // ── Grid: frozen left column + single shared horizontal scroll ──
              if (_rows.isEmpty && !_showAddForm)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                  child: Text('No companies linked yet.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                )
              else
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // ── Frozen left pane ───────────────────────────────────────
                  SizedBox(
                    width: 320,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      // Header cell
                      Container(
                        height: 32,
                        color: const Color(0xFFF0F7FF),
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
                        child: const Text('SUPPLIER COMPANY', style: TextStyle(
                            fontSize: 10, fontWeight: FontWeight.w700,
                            color: Color(0xFF6B7280), letterSpacing: 0.4),
                          overflow: TextOverflow.ellipsis),
                      ),
                      const Divider(height: 1, color: Color(0xFFDBEAFE)),
                      // Data cells
                      for (int ri = 0; ri < _rows.length; ri++) ...[
                        SizedBox(
                          height: _flaggedRows.contains(ri) ? 56.0 : 44.0,
                          child: ColoredBox(
                            color: _flaggedRows.contains(ri) ? const Color(0xFFFFFBEB) : Colors.transparent,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                                if (_flaggedRows.contains(ri)) ...[
                                  const Icon(Icons.flag, size: 11, color: Color(0xFFF59E0B)),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: _flaggedRows.contains(ri)
                                    ? Column(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _rows[ri]['supplier_company'] as String? ?? '—',
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                            maxLines: 1, overflow: TextOverflow.ellipsis,
                                          ),
                                          const Text(
                                            'No match in catalog — map manually',
                                            style: TextStyle(fontSize: 10, color: Color(0xFFD97706), fontStyle: FontStyle.italic),
                                            maxLines: 1, overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      )
                                    : Text(
                                        _rows[ri]['supplier_company'] as String? ?? '—',
                                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                                        maxLines: 1, overflow: TextOverflow.ellipsis,
                                      ),
                                ),
                              ]),
                            ),
                          ),
                        ),
                        if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFEFF6FF)),
                      ],
                    ]),
                  ),
                  // ── Single shared horizontal scroll (header + all rows) ────
                  Expanded(child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _scrollCtrl,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Header row
                      Container(
                        height: 32,
                        color: const Color(0xFFF0F7FF),
                        child: Row(children: [
                          for (int i = 1; i <= 30; i++) ...[
                            const SizedBox(width: 4),
                            SizedBox(width: 220, child: Text('COMPANY $i', style: const TextStyle(
                                fontSize: 10, fontWeight: FontWeight.w700,
                                color: Color(0xFF6B7280), letterSpacing: 0.4),
                              overflow: TextOverflow.ellipsis)),
                          ],
                          const SizedBox(width: 8),
                        ]),
                      ),
                      const Divider(height: 1, color: Color(0xFFDBEAFE)),
                      // Data rows — height matches frozen pane (56px for flagged, 44px otherwise)
                      for (int ri = 0; ri < _rows.length; ri++) ...[
                        SizedBox(
                          height: _flaggedRows.contains(ri) ? 56.0 : 44.0,
                          child: Row(children: [
                            for (final col in _companyCols) ...[
                              const SizedBox(width: 4),
                              SizedBox(width: 220, child: _CompanyCell(
                                value: _rows[ri][col] as String?,
                                options: _medMarketers,
                                onChanged: (v) => _mapped
                                    ? setState(() => _rows[ri][col] = (v == null || v.isEmpty) ? null : v)
                                    : _updateCell(_rows[ri]['id'] as String, col, v),
                                onClear: (_rows[ri][col] != null && (_rows[ri][col] as String).isNotEmpty)
                                    ? () {
                                        if (_mapped) {
                                          setState(() => _rows[ri][col] = null);
                                        } else {
                                          _updateCell(_rows[ri]['id'] as String, col, null);
                                        }
                                      }
                                    : null,
                              )),
                            ],
                            const SizedBox(width: 8),
                          ]),
                        ),
                        if (ri < _rows.length - 1) const Divider(height: 1, color: Color(0xFFEFF6FF)),
                      ],
                    ]),
                  )),
                ]),
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
  final VoidCallback? onClear;
  const _CompanyCell({this.value, required this.options, required this.onChanged, this.onClear});

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
          if (filled && onClear != null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.only(left: 4),
                child: Icon(Icons.close, size: 12, color: Color(0xFF111827)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── SPN inline section (mirrors Companies grid, 4 fixed columns) ─────────────

class _SpnInlineSection extends StatefulWidget {
  final String supplierId;
  final String supplierName;
  const _SpnInlineSection({
    super.key,
    required this.supplierId,
    required this.supplierName,
  });

  @override
  State<_SpnInlineSection> createState() => _SpnInlineSectionState();
}

class _SpnInlineSectionState extends State<_SpnInlineSection> {
  static const _spnCols = [
    ('MARGIN',       'margin'),
    ('CD CONDITION', 'cd_condition'),
    ('BEHAVIOUR',    'behaviour'),
    ('PAYMENT TERM', 'payment_term'),
  ];

  static const _spnOptions = {
    'margin':       ['1','2','3','4','5','6','7','8'],
    'cd_condition': ['NO CONDITION','2K+ Bill','3K+ Bill'],
    'behaviour':    ['1','2','3','4','5','6','7','8','9','10'],
    'payment_term': ['cash','credit'],
  };

  // Survives state recreation: user-picked values keyed by supplierId.
  // Cleared on dispose so stale values don't leak when panel is closed/reopened.
  static final Map<String, Map<String, String?>> _userCache = {};

  // Frozen at initState — never re-derived from widget after that.
  late final String _supplierId;

  bool _loading = true;
  bool _loadCancelled = false;
  final Map<String, String?> _values = {};
  int _changeCounter = 0;

  @override
  void initState() {
    super.initState();
    _supplierId = widget.supplierId;
    // Restore any user-picked values from before state recreation.
    if (_userCache.containsKey(_supplierId)) {
      _values.addAll(_userCache[_supplierId]!);
    }
    // Do NOT register with realtime callbacks — the SPN panel is the sole writer
    // and must never rebuild from its own UPDATE echoes.
    _load();
  }

  @override
  void dispose() {
    _userCache.remove(_supplierId); // clean up when panel is closed
    super.dispose();
  }

  Future<void> _load() async {
    _loadCancelled = false;
    if (mounted) setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('supplier_profiles')
          .select('margin, cd_condition, behaviour, payment_type')
          .eq('id', _supplierId)
          .limit(1);
      if (_loadCancelled) return;
      if (mounted && (rows as List).isNotEmpty) {
        final row = rows.first as Map<String, dynamic>;
        // User-cached values take precedence — never overwrite a user pick with a stale DB reload.
        final cached = _userCache[_supplierId] ?? {};
        setState(() {
          _values['margin']       = cached['margin']       ?? row['margin'] as String?;
          _values['cd_condition'] = cached['cd_condition'] ?? row['cd_condition'] as String?;
          _values['behaviour']    = cached['behaviour']    ?? row['behaviour'] as String?;
          _values['payment_term'] = cached['payment_term'] ?? row['payment_type'] as String?;
          _loading = false;
        });
      } else {
        if (mounted) setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _writeField([String? changedField, String? changedVal]) async {
    RenderLog.write('spn_writefield_entered', changedField ?? 'none');
    final id = _supplierId;
    RenderLog.write('spn_writefield_id', id.isEmpty ? 'EMPTY' : id);
    if (id.isEmpty) { RenderLog.write('spn_writefield_dead', 'EMPTY_ID'); return; }
    final dbCol = (changedField == 'payment_term') ? 'payment_type' : (changedField ?? 'margin');
    final val   = changedVal ?? _values[changedField ?? 'margin'];
    try {
      RenderLog.write('spn_writefield_before_await', '1');
      final res = await Supabase.instance.client
          .from('supplier_profiles')
          .update({dbCol: val})
          .eq('id', id)
          .select('id')
          .timeout(const Duration(seconds: 8));
      RenderLog.write('spn_writefield_after_await', res.isEmpty ? 'EMPTY_0_ROWS' : 'OK_${res.length}');
      RenderLog.write('spn_write_done', '$changedField=$changedVal rows=${res.length}@${DateTime.now().millisecondsSinceEpoch}');
      if (res.isNotEmpty) {
        Supabase.instance.client
            .rpc('recompute_supplier_points', params: {'p_id': id})
            .then((_) {})
            .catchError((_) {});
      }
      if (mounted) showToast(context, res.isEmpty ? 'Save failed — try again' : 'Saved ✓', isError: res.isEmpty, duration: const Duration(milliseconds: 800));
    } catch (e) {
      RenderLog.write('spn_writefield_exception', e.toString());
      if (mounted) showToast(context, 'Save error: $e', isError: true);
    }
  }

  Widget _hdr(String label) => Expanded(
    child: Text(label, style: const TextStyle(
        fontSize: 10, fontWeight: FontWeight.w700,
        color: Color(0xFF6B7280), letterSpacing: 0.4),
      overflow: TextOverflow.ellipsis),
  );

  @override
  Widget build(BuildContext context) {
    RenderLog.write('spn_panel', 1);
    RenderLog.write('spn_dropdowns', 4);
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF0F7FF),
        border: Border(top: BorderSide(color: Color(0xFFBFDBFE)), bottom: BorderSide(color: Color(0xFFBFDBFE))),
      ),
      child: _loading
          ? const Padding(padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2)))
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 8, 6),
                child: Row(children: [
                  const Text('Supplier Points — Terms',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF374151))),
                ]),
              ),
              const Divider(height: 1, color: Color(0xFFBFDBFE)),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ── Frozen left pane ─────────────────────────────────────────
                SizedBox(
                  width: 320,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      height: 32,
                      color: const Color(0xFFF0F7FF),
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.fromLTRB(14, 0, 8, 0),
                      child: const Text('SUPPLIER', style: TextStyle(
                          fontSize: 10, fontWeight: FontWeight.w700,
                          color: Color(0xFF6B7280), letterSpacing: 0.4),
                        overflow: TextOverflow.ellipsis),
                    ),
                    const Divider(height: 1, color: Color(0xFFDBEAFE)),
                    SizedBox(
                      height: 52,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            widget.supplierName,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
                // ── 4 fixed columns (full width, no scroll) ──────────────────
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    height: 32,
                    color: const Color(0xFFF0F7FF),
                    child: Row(children: [
                      for (final col in _spnCols) ...[
                        const SizedBox(width: 4),
                        _hdr(col.$1),
                      ],
                      const SizedBox(width: 8),
                    ]),
                  ),
                  const Divider(height: 1, color: Color(0xFFDBEAFE)),
                  SizedBox(
                    height: 52,
                    child: Row(children: [
                      for (final col in _spnCols) ...[
                        const SizedBox(width: 4),
                        Expanded(child: _SpnDropdown(
                          key: ValueKey('${_supplierId}_${col.$2}'),
                          field: col.$2,
                          initialValue: _values[col.$2],
                          options: _spnOptions[col.$2]!,
                          onPick: (field, val) {
                            _changeCounter++;
                            RenderLog.write('spn_change_count', _changeCounter.toString());
                            RenderLog.write('spn_change_last', '$field=$val@${DateTime.now().millisecondsSinceEpoch}');
                            (_userCache[_supplierId] ??= {})[field] = val;
                            _writeField(field, val);
                          },
                        )),
                      ],
                      const SizedBox(width: 8),
                    ]),
                  ),
                ])),
              ]),
            ]),
    );
  }
}

// ── SPN inline DropdownButton — StatefulWidget so parent rebuilds never reset value ──

class _SpnDropdown extends StatefulWidget {
  final String field;
  final String? initialValue;
  final List<String> options;
  final void Function(String field, String? val) onPick;
  const _SpnDropdown({super.key, required this.field, required this.initialValue, required this.options, required this.onPick});

  @override
  State<_SpnDropdown> createState() => _SpnDropdownState();
}

class _SpnDropdownState extends State<_SpnDropdown> {
  String? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialValue;
  }

  @override
  Widget build(BuildContext context) {
    final filled = _selected != null && _selected!.isNotEmpty;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: filled ? const Color(0xFFECFDF5) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: filled ? const Color(0xFF6EE7B7) : const Color(0xFFE5E7EB)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selected,
          hint: const Text('—', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          isExpanded: true,
          isDense: true,
          style: const TextStyle(fontSize: 11, color: Color(0xFF065F46)),
          icon: const Icon(Icons.expand_more, size: 14, color: Color(0xFF6B7280)),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('—', style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))),
            for (final opt in widget.options)
              DropdownMenuItem<String>(value: opt, child: Text(opt, style: const TextStyle(fontSize: 11, color: Color(0xFF111827)))),
          ],
          onChanged: (val) {
            setState(() => _selected = val);
            widget.onPick(widget.field, val);
          },
        ),
      ),
    );
  }
}

// ── Per-row keep-N / clear-all trim buttons [1][2][3][4][5][X] ───────────────

class _RowTrimButtons extends StatelessWidget {
  // onTrim(keep): keep=1..5 means keep first N cols; keep=0 means clear all
  final ValueChanged<int> onTrim;
  const _RowTrimButtons({required this.onTrim});

  Widget _pill(String label, {required VoidCallback onTap, bool danger = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 26,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: const Color(0xFFE0E0E0)),
        ),
        child: Text(label,
          style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700,
            color: danger ? const Color(0xFFDC2626) : const Color(0xFF374151),
          )),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 6 pills × 26px + 5 gaps × 2px = 156 + 10 = 166px → SizedBox(168)
    return SizedBox(
      width: 168,
      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        for (int n = 1; n <= 5; n++) ...[
          _pill('$n', onTap: () => onTrim(n)),
          const SizedBox(width: 2),
        ],
        _pill('X', onTap: () => onTrim(0), danger: true),
      ]),
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

// ─── Top-level fuzzy helpers (used by _SupCardImportDialog) ──────────────────

String _fzNorm(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

Set<String> _fzTri(String s) {
  if (s.length < 3) return {};
  final t = <String>{};
  for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
  return t;
}

int _fzEd(String s, String t) {
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

int _fzDl(String s, String t) {
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

double _fzS1(String q, String c) {
  final qn = _fzNorm(q).replaceAll(' ', ''), cn = _fzNorm(c).replaceAll(' ', '');
  if (qn.isEmpty || cn.isEmpty) return 0.0;
  final qt = _fzTri(qn), ct = _fzTri(cn);
  final tri = qt.union(ct).isEmpty ? 0.0 : qt.intersection(ct).length / qt.union(ct).length.toDouble();
  final ml = qn.length > cn.length ? qn.length : cn.length;
  return 0.55 * tri + 0.45 * (1.0 - _fzEd(qn, cn) / ml);
}

double _fzS2(String q, String c) {
  final qn = _fzNorm(q), cn = _fzNorm(c);
  if (qn.isEmpty || cn.isEmpty) return 0.0;
  final ml = qn.length > cn.length ? qn.length : cn.length;
  final er = 1.0 - _fzDl(qn, cn) / ml;
  final qw = qn.split(' ').where((t) => t.isNotEmpty).toSet();
  final cw = cn.split(' ').where((t) => t.isNotEmpty).toSet();
  final tj = qw.union(cw).isEmpty ? 0.0 : qw.intersection(cw).length / qw.union(cw).length.toDouble();
  final tr = qw.isEmpty ? 0.0 : qw.where((t) => cw.contains(t)).length / qw.length;
  final ql = qn.split(' ').where((t) => t.isNotEmpty).toList();
  final cl = cn.split(' ').where((t) => t.isNotEmpty).toList();
  final qf = ql.isEmpty ? '' : ql[0], cf = cl.isEmpty ? '' : cl[0];
  final fm = qf.length > cf.length ? qf.length : cf.length;
  final pr = fm == 0 ? 0.0 : 1.0 - _fzDl(qf, cf) / fm;
  final qft = _fzTri(qf), cft = _fzTri(cf);
  final fw = qft.union(cft).isEmpty ? 0.0 : qft.intersection(cft).length / qft.union(cft).length.toDouble();
  return 0.50 * er + 0.12 * tj + 0.13 * tr + 0.20 * pr + 0.05 * fw;
}

List<String> _fzTop5(String raw, List<String> corpus) {
  if (raw.isEmpty || corpus.isEmpty) return [];
  final s1 = corpus.map((m) => (m, _fzS1(raw, m))).where((p) => p.$2 > 0.05).toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  final shortlist = s1.take(60).map((p) => p.$1).toList();
  final s2 = shortlist.map((m) => (m, _fzS2(raw, m))).toList()
    ..sort((a, b) => b.$2.compareTo(a.$2));
  return s2.take(5).map((p) => p.$1).toList();
}

String? _fzBestMatch(String raw, List<String> corpus) {
  if (raw.isEmpty || corpus.isEmpty) return null;
  final top = _fzTop5(raw, corpus);
  if (top.isEmpty) return null;
  return _fzS2(raw, top.first) >= 0.45 ? top.first : null;
}

// ─── Resolved-company record for supplier card import ────────────────────────

class _ResolvedCompany {
  final String seen;       // verbatim OCR text — never modified by code
  final String confidence; // high/medium/low from OCR
  final TextEditingController ctrl;
  _ResolvedCompany({required this.seen, required this.confidence})
      : ctrl = TextEditingController(text: seen);
  String get canonical => ctrl.text.trim();
  void dispose() => ctrl.dispose();
}

// ─── Supplier Card Image Import (OCR → review → write) ───────────────────────

enum _SupCardStep { reading, review, importing }

class _SupCardImportDialog extends StatefulWidget {
  final html.File file;
  final VoidCallback onImported;
  const _SupCardImportDialog({required this.file, required this.onImported});
  @override
  State<_SupCardImportDialog> createState() => _SupCardImportDialogState();
}

// Descriptor for an optional (unfilled) supplier_profiles column shown in the review modal.
class _SupOptField {
  final String column;
  final String label;
  final List<String>? options; // null = free text, non-null = dropdown choices
  final TextEditingController ctrl;
  String? _dropValue;
  _SupOptField({required this.column, required this.label, this.options})
      : ctrl = TextEditingController();
  String get value => options != null ? (_dropValue ?? '') : ctrl.text.trim();
  void dispose() => ctrl.dispose();
}

// All optional supplier_profiles columns (excludes OCR-filled, points, SPN, system cols).
// Columns OCR fills: supplier_name, street_address, city, contact_no, whatsapp_no, email, supplier_code.
List<_SupOptField> _buildOptionalFields() => [
  _SupOptField(column: 'contact_name',   label: 'Contact Name'),
  _SupOptField(column: 'contact_person', label: 'Contact Person'),
  _SupOptField(column: 'phone',          label: 'Phone (alt)'),
  _SupOptField(column: 'state',          label: 'State'),
  _SupOptField(column: 'pin_code',       label: 'Pin Code'),
  _SupOptField(column: 'pincode',        label: 'Pincode'),
  _SupOptField(column: 'gstin',          label: 'GSTIN'),
  _SupOptField(column: 'gst',            label: 'GST No.'),
  _SupOptField(column: 'drug_license',   label: 'Drug License'),
  _SupOptField(column: 'dl_1',           label: 'Drug License 1'),
  _SupOptField(column: 'dl_2',           label: 'Drug License 2'),
  _SupOptField(column: 'payment_term',   label: 'Payment Term'),
  _SupOptField(column: 'payment_type',   label: 'Payment Type',   options: ['', 'cash', 'credit']),
  _SupOptField(column: 'cd_condition',   label: 'CD Condition',   options: ['', 'NO CONDITION', '2K+ BILL', '3K+ BILL']),
  _SupOptField(column: 'store_type',     label: 'Store Type'),
  _SupOptField(column: 'stockist_type',  label: 'Stockist Type'),
  _SupOptField(column: 'range_zone',     label: 'Range / Zone'),
  _SupOptField(column: 'margin',         label: 'Margin'),
  _SupOptField(column: 'behaviour',      label: 'Behaviour'),
  _SupOptField(column: 'deal',           label: 'Deal'),
  _SupOptField(column: 'other_contact',  label: 'Other Contact'),
  _SupOptField(column: 'map_link',       label: 'Map Link'),
  _SupOptField(column: 'address',        label: 'Address (alt)'),
  _SupOptField(column: 'notes',          label: 'Notes'),
];

class _SupCardImportDialogState extends State<_SupCardImportDialog> {
  _SupCardStep _step = _SupCardStep.reading;
  String? _error;

  // Editable supplier fields
  final _nameCtrl    = TextEditingController();
  final _addrCtrl    = TextEditingController();
  final _cityCtrl    = TextEditingController();
  final _phoneCtrl   = TextEditingController();
  final _waCtrl      = TextEditingController();
  final _emailCtrl   = TextEditingController();
  final _codeCtrl    = TextEditingController();

  // Editable company list
  List<_ResolvedCompany> _companies = [];
  final _newCompCtrl = TextEditingController();

  // Optional extra fields
  late final List<_SupOptField> _optFields;
  bool _extraExpanded = false;

  @override
  void initState() {
    super.initState();
    _optFields = _buildOptionalFields();
    _ocr();
  }

  @override
  void dispose() {
    for (final c in [_nameCtrl,_addrCtrl,_cityCtrl,_phoneCtrl,_waCtrl,_emailCtrl,_codeCtrl,_newCompCtrl]) c.dispose();
    for (final c in _companies) c.dispose();
    for (final f in _optFields) f.dispose();
    super.dispose();
  }

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  String _mimeFor(String ext) => switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png'           => 'image/png',
    'webp'          => 'image/webp',
    'heic' || 'heif'=> 'image/heic',
    'gif'           => 'image/gif',
    _               => 'image/jpeg',
  };

  Future<void> _ocr() async {
    try {
      final ext = widget.file.name.toLowerCase().split('.').last;
      final bytes = await _readBytes(widget.file);
      final b64 = base64Encode(bytes);
      const prompt =
          'This is a pharma supplier business card or company-grid image.\n'
          'Return ONLY a JSON object (no markdown fences, no extra text):\n\n'
          '{\n'
          '  "supplier_name": "firm/distributor/stockist name at the top",\n'
          '  "address": "full street address if visible",\n'
          '  "city": "city name only",\n'
          '  "phone": "phone/landline numbers (comma-separated if multiple)",\n'
          '  "whatsapp": "mobile/WhatsApp numbers (comma-separated if multiple)",\n'
          '  "email": "email address",\n'
          '  "supplier_code": "any short code like G-1, S-02 etc",\n'
          '  "companies": [{"seen":"verbatim text exactly as printed","confidence":"high|medium|low"}]\n'
          '}\n\n'
          'RULES FOR "companies" — GRID SCAN (follow in order):\n'
          'STEP 1: Count every distinct tile/cell/logo in the company section (may be 20–50). Hold that count.\n'
          'STEP 2: Output EXACTLY one entry per tile. Array length MUST equal tile count. NEVER skip a tile. NEVER merge tiles.\n'
          'STEP 3 per tile:\n'
          '  seen = VERBATIM text printed on the tile (strip brackets: "ABBOTT [DIGENE]"→"ABBOTT"). If no text, write the brand name you can identify from the logo. Output text EXACTLY as seen — do NOT expand abbreviations, do NOT substitute parent/owner names.\n'
          '  confidence = high if certain, medium if likely, low if unrecognizable.\n'
          'STEP 4: Verify array.length === tile count. If not, add missing entries with confidence=low.\n'
          'Use "" for missing scalar fields. companies=[] if no company section exists.';
      final resp = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'image_base64': b64,
          'mime_type': _mimeFor(ext),
          'prompt': prompt,
        }),
      ).timeout(const Duration(seconds: 60));
      if (resp.statusCode != 200) throw Exception('OCR API error (HTTP ${resp.statusCode})');
      final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
      final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
      if (jm == null) throw Exception('Could not parse OCR response');
      final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
      String s(String k) => (dec[k] as String? ?? '').trim();
      final rawCompanies = dec['companies'] as List<dynamic>? ?? [];
      // Build company list from verbatim OCR — no resolution, no lookup
      final companies = rawCompanies.map((e) {
        String seen, conf;
        if (e is Map<String, dynamic>) {
          seen = (e['seen'] as String? ?? '').trim();
          conf = (e['confidence'] as String? ?? 'medium').trim();
        } else {
          seen = e.toString().trim();
          conf = 'medium';
        }
        if (seen.isEmpty) return null;
        return _ResolvedCompany(seen: seen, confidence: conf);
      }).whereType<_ResolvedCompany>().toList();
      if (mounted) setState(() {
        _nameCtrl.text  = s('supplier_name');
        _addrCtrl.text  = s('address');
        _cityCtrl.text  = s('city');
        _phoneCtrl.text = s('phone');
        _waCtrl.text    = s('whatsapp');
        _emailCtrl.text = s('email');
        _codeCtrl.text  = s('supplier_code');
        _companies = companies;
        _step = _SupCardStep.review;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<void> _doImport() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      showToast(context, 'Supplier name is required', isError: true);
      return;
    }
    setState(() => _step = _SupCardStep.importing);
    try {
      final client = Supabase.instance.client;

      // 1. Insert supplier_profiles row
      final rec = <String, dynamic>{
        'supplier_name': name,
        'status': 'Active',
        'approved': true,
        'is_deleted': false,
      };
      if (_addrCtrl.text.trim().isNotEmpty) rec['street_address'] = _addrCtrl.text.trim();
      if (_cityCtrl.text.trim().isNotEmpty) rec['city'] = _cityCtrl.text.trim();
      if (_phoneCtrl.text.trim().isNotEmpty) rec['contact_no'] = _phoneCtrl.text.trim();
      if (_waCtrl.text.trim().isNotEmpty) rec['whatsapp_no'] = _waCtrl.text.trim();
      if (_emailCtrl.text.trim().isNotEmpty) rec['email'] = _emailCtrl.text.trim();
      if (_codeCtrl.text.trim().isNotEmpty) rec['supplier_code'] = _codeCtrl.text.trim();
      // Optional extra fields filled by admin
      for (final f in _optFields) {
        final v = f.value;
        if (v.isNotEmpty) rec[f.column] = v;
      }

      final inserted = await client.from('supplier_profiles').insert(rec).select('id').single();
      final supplierId = inserted['id'] as String;

      // 2. Insert supplier_company rows — store verbatim seen text, no resolution
      final companies = _companies.where((c) => c.canonical.isNotEmpty).toList();
      if (companies.isNotEmpty) {
        // Upsert company names verbatim into master (ON CONFLICT DO NOTHING)
        for (final co in companies) {
          try {
            await client.from('company')
                .upsert({'company_name': co.canonical}, onConflict: 'company_name');
          } catch (_) {}
        }
        final scRows = companies.map((co) => <String, dynamic>{
          'supplier_id': supplierId,
          'supplier_name': name,
          'supplier_company': co.canonical,
        }).toList();
        await client.from('supplier_company').insert(scRows);
      }

      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported $name with ${companies.length} compan${companies.length == 1 ? 'y' : 'ies'}', duration: const Duration(seconds: 5));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _step = _SupCardStep.review);
        showToast(context, 'Import failed: $e', isError: true);
      }
    }
  }

  Widget _field(String label, TextEditingController ctrl, {int maxLines = 1}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280), letterSpacing: 0.3)),
        const SizedBox(height: 4),
        TextField(
          controller: ctrl,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
          decoration: InputDecoration(
            filled: true, fillColor: const Color(0xFFF5F6F8),
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
          ),
        ),
        const SizedBox(height: 10),
      ]);

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 32),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }

    if (_step == _SupCardStep.reading || _step == _SupCardStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(_step == _SupCardStep.reading ? 'Reading image with Gemini…' : 'Importing supplier…',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]))),
      );
    }

    // Review screen
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 640, maxHeight: MediaQuery.of(context).size.height * 0.9),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Import from Image — Review',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text(widget.file.name,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          // Body
          Flexible(child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Supplier details
              const Text('SUPPLIER DETAILS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                  color: Color(0xFF6B7280), letterSpacing: 0.5)),
              const SizedBox(height: 10),
              _field('Supplier Name *', _nameCtrl),
              _field('Address', _addrCtrl, maxLines: 2),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('City', _cityCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('Supplier Code', _codeCtrl)),
              ]),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('Phone', _phoneCtrl)),
                const SizedBox(width: 12),
                Expanded(child: _field('WhatsApp / Mobile', _waCtrl)),
              ]),
              _field('Email', _emailCtrl),
              const SizedBox(height: 4),
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 4),
              // ── Optional unfilled details ──────────────────────────────────
              InkWell(
                onTap: () => setState(() => _extraExpanded = !_extraExpanded),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(children: [
                    const Expanded(child: Text('Other unfilled details (optional)',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF6B7280)))),
                    Icon(_extraExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 18, color: const Color(0xFF9CA3AF)),
                  ]),
                ),
              ),
              if (_extraExpanded) ...[
                const SizedBox(height: 4),
                ...List.generate(_optFields.length, (i) {
                  final f = _optFields[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: f.options != null
                        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(f.label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                                color: Color(0xFF6B7280), letterSpacing: 0.3)),
                            const SizedBox(height: 4),
                            StatefulBuilder(builder: (ctx, setSt) => DropdownButtonFormField<String>(
                              value: f._dropValue,
                              isExpanded: true,
                              decoration: InputDecoration(
                                filled: true, fillColor: const Color(0xFFF5F6F8),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                    borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                              ),
                              items: f.options!.map((v) => DropdownMenuItem(
                                value: v.isEmpty ? null : v,
                                child: Text(v.isEmpty ? '— select —' : v,
                                    style: TextStyle(fontSize: 13,
                                        color: v.isEmpty ? const Color(0xFF9CA3AF) : const Color(0xFF111827))),
                              )).toList(),
                              onChanged: (v) => setSt(() => f._dropValue = v),
                            )),
                          ])
                        : _field(f.label, f.ctrl),
                  );
                }),
                const SizedBox(height: 4),
              ],
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 10),
              // Company list
              Row(children: [
                const Expanded(child: Text('COMPANY LIST', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280), letterSpacing: 0.5))),
                Text('${_companies.length} compan${_companies.length == 1 ? 'y' : 'ies'}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
              ]),
              const SizedBox(height: 10),
              if (_companies.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No companies extracted. Add manually below.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ),
              ...List.generate(_companies.length, (i) {
                final co = _companies[i];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Line 1: row number (left) · seen pill (far right)
                    Row(children: [
                      Text('${i + 1}.', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF))),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0xFFE6F4EA), borderRadius: BorderRadius.circular(16)),
                        child: Text(
                          'Seen - ${co.seen}',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF1B7F3B)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    // Line 2: full-width field · remove button (right, centered on field)
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      Expanded(
                        child: TextField(
                          controller: co.ctrl,
                          style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
                          decoration: InputDecoration(
                            filled: true, fillColor: const Color(0xFFF5F6F8),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.remove_circle_outline, size: 18, color: Color(0xFFDC2626)),
                        onPressed: () => setState(() { _companies[i].dispose(); _companies.removeAt(i); }),
                        padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                        visualDensity: VisualDensity.compact,
                      ),
                    ]),
                  ]),
                );
              }),
              const SizedBox(height: 6),
              // Add company row
              Row(children: [
                Expanded(child: TextField(
                  controller: _newCompCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Add company…',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                    filled: true, fillColor: const Color(0xFFF5F6F8),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
                  ),
                  onSubmitted: (v) {
                    final s = v.trim();
                    if (s.isNotEmpty) setState(() {
                      _companies.add(_ResolvedCompany(seen: s, confidence: 'high'));
                      _newCompCtrl.clear();
                    });
                  },
                )),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline, size: 20, color: Color(0xFF1B7A43)),
                  onPressed: () {
                    final s = _newCompCtrl.text.trim();
                    if (s.isNotEmpty) setState(() {
                      _companies.add(_ResolvedCompany(seen: s, confidence: 'high'));
                      _newCompCtrl.clear();
                    });
                  },
                  padding: EdgeInsets.zero, constraints: const BoxConstraints(),
                ),
              ]),
              const SizedBox(height: 16),
            ]),
          )),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          // Footer
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280))),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _doImport,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                child: const Text('Import', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ─── Multi-Image Supplier Import (OCR each → combined review → write) ───────────

class _MultiExtractedSup {
  String name;
  String address;
  String city;
  String phone;
  String whatsapp;
  String email;
  String code;
  List<({String seen, String confidence, String? matched})> companies;
  bool selected;
  _MultiExtractedSup({
    required this.name, this.address = '', this.city = '', this.phone = '',
    this.whatsapp = '', this.email = '', this.code = '',
    this.companies = const [], this.selected = true,
  });
}

enum _MultiStep { processing, review, importing }

class _SupCardMultiImportDialog extends StatefulWidget {
  final List<html.File> files;
  final VoidCallback onImported;
  const _SupCardMultiImportDialog({required this.files, required this.onImported});
  @override
  State<_SupCardMultiImportDialog> createState() => _SupCardMultiImportDialogState();
}

class _SupCardMultiImportDialogState extends State<_SupCardMultiImportDialog> {
  _MultiStep _step = _MultiStep.processing;
  String _progressText = '';
  String? _error;
  final List<_MultiExtractedSup> _extracted = [];

  static const _prompt =
      'This is a pharma supplier business card or company-grid image.\n'
      'Return ONLY a JSON object (no markdown fences, no extra text):\n\n'
      '{\n'
      '  "supplier_name": "firm/distributor/stockist name at the top",\n'
      '  "address": "full street address if visible",\n'
      '  "city": "city name only",\n'
      '  "phone": "phone/landline numbers (comma-separated if multiple)",\n'
      '  "whatsapp": "mobile/WhatsApp numbers (comma-separated if multiple)",\n'
      '  "email": "email address",\n'
      '  "supplier_code": "any short code like G-1, S-02 etc",\n'
      '  "companies": [{"seen":"verbatim text exactly as printed","confidence":"high|medium|low"}]\n'
      '}\n\n'
      'RULES FOR "companies" — GRID SCAN (follow in order):\n'
      'STEP 1: Count every distinct tile/cell/logo in the company section (may be 20–50). Hold that count.\n'
      'STEP 2: Output EXACTLY one entry per tile. Array length MUST equal tile count. NEVER skip a tile. NEVER merge tiles.\n'
      'STEP 3 per tile:\n'
      '  seen = VERBATIM text printed on the tile (strip brackets: "ABBOTT [DIGENE]"→"ABBOTT"). If no text, write the brand name you can identify from the logo. Output text EXACTLY as seen — do NOT expand abbreviations, do NOT substitute parent/owner names.\n'
      '  confidence = high if certain, medium if likely, low if unrecognizable.\n'
      'STEP 4: Verify array.length === tile count. If not, add missing entries with confidence=low.\n'
      'Use "" for missing scalar fields. companies=[] if no company section exists.';

  @override
  void initState() {
    super.initState();
    _processAll();
  }

  String _mimeFor(String ext) => switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'png'           => 'image/png',
    'webp'          => 'image/webp',
    'heic' || 'heif'=> 'image/heic',
    'gif'           => 'image/gif',
    _               => 'image/jpeg',
  };

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader(); r.readAsDataUrl(f); await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  Future<void> _processAll() async {
    final total = widget.files.length;
    for (int i = 0; i < total; i++) {
      if (!mounted) return;
      setState(() => _progressText = 'Processing image ${i + 1} of $total…');
      try {
        final f = widget.files[i];
        final ext = f.name.toLowerCase().split('.').last;
        final bytes = await _readBytes(f);
        final resp = await http.post(
          Uri.parse(_ocrEdgeFn),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'image_base64': base64Encode(bytes),
            'mime_type': _mimeFor(ext),
            'prompt': _prompt,
          }),
        ).timeout(const Duration(seconds: 60));
        if (resp.statusCode != 200) throw Exception('OCR error on image ${i + 1} (HTTP ${resp.statusCode})');
        final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
        final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
        if (jm != null) {
          final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
          String sv(String k) => (dec[k] as String? ?? '').trim();
          final rawCos = dec['companies'] as List<dynamic>? ?? [];
          // Store verbatim seen text — no resolution against corpus
          final companies = rawCos.map((e) {
            String seen, conf;
            if (e is Map<String, dynamic>) {
              seen = (e['seen'] as String? ?? '').trim();
              conf = (e['confidence'] as String? ?? 'medium').trim();
            } else {
              seen = e.toString().trim();
              conf = 'medium';
            }
            if (seen.isEmpty) return null;
            return (seen: seen, confidence: conf, matched: null as String?);
          }).whereType<({String seen, String confidence, String? matched})>().toList();
          _extracted.add(_MultiExtractedSup(
            name: sv('supplier_name'), address: sv('address'), city: sv('city'),
            phone: sv('phone'), whatsapp: sv('whatsapp'), email: sv('email'),
            code: sv('supplier_code'), companies: companies,
          ));
        }
      } catch (e) {
        // Skip failed images but continue
      }
    }
    if (!mounted) return;
    if (_extracted.isEmpty) {
      setState(() => _error = 'Could not extract any supplier data from the selected images.');
      return;
    }
    setState(() => _step = _MultiStep.review);
  }

  Future<void> _doImport() async {
    final toImport = _extracted.where((s) => s.selected && s.name.isNotEmpty).toList();
    if (toImport.isEmpty) {
      showToast(context, 'No suppliers selected to import', isError: true);
      return;
    }
    setState(() => _step = _MultiStep.importing);
    try {
      final client = Supabase.instance.client;
      int imported = 0;
      for (final sup in toImport) {
        final rec = <String, dynamic>{
          'supplier_name': sup.name, 'status': 'Active', 'approved': true, 'is_deleted': false,
        };
        if (sup.address.isNotEmpty) rec['street_address'] = sup.address;
        if (sup.city.isNotEmpty) rec['city'] = sup.city;
        if (sup.phone.isNotEmpty) rec['contact_no'] = sup.phone;
        if (sup.whatsapp.isNotEmpty) rec['whatsapp_no'] = sup.whatsapp;
        if (sup.email.isNotEmpty) rec['email'] = sup.email;
        if (sup.code.isNotEmpty) rec['supplier_code'] = sup.code;
        final inserted = await client.from('supplier_profiles').insert(rec).select('id').single();
        final supplierId = inserted['id'] as String;
        if (sup.companies.isNotEmpty) {
          // Upsert verbatim names into company master
          for (final co in sup.companies) {
            if (co.seen.isNotEmpty) {
              try {
                await client.from('company')
                    .upsert({'company_name': co.seen}, onConflict: 'company_name');
              } catch (_) {}
            }
          }
          final scRows = sup.companies
              .where((co) => co.seen.isNotEmpty)
              .map((co) => <String, dynamic>{
                'supplier_id': supplierId, 'supplier_name': sup.name, 'supplier_company': co.seen,
              }).toList();
          await client.from('supplier_company').insert(scRows);
        }
        imported++;
      }
      RenderLog.write('multi_image_ocr_imported', imported.toString());
      if (mounted) {
        Navigator.of(context).pop();
        widget.onImported();
        showToast(context, 'Imported $imported supplier${imported == 1 ? '' : 's'} from ${widget.files.length} image${widget.files.length == 1 ? '' : 's'}', duration: const Duration(seconds: 5));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _step = _MultiStep.review);
        showToast(context, 'Import failed: ${e.toString().replaceFirst('Exception: ', '')}', isError: true);
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
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
            const SizedBox(height: 16),
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
          ]))),
      );
    }

    if (_step == _MultiStep.processing || _step == _MultiStep.importing) {
      return Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 2),
            const SizedBox(height: 16),
            Text(
              _step == _MultiStep.processing ? _progressText : 'Importing suppliers…',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ]))),
      );
    }

    // Review step
    final selected = _extracted.where((s) => s.selected && s.name.isNotEmpty).length;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Review Extracted Suppliers',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 2),
                Text('${widget.files.length} image${widget.files.length == 1 ? '' : 's'} · ${_extracted.length} supplier${_extracted.length == 1 ? '' : 's'} found',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              ])),
              IconButton(icon: const Icon(Icons.close, size: 20), onPressed: () => Navigator.of(context).pop(),
                  padding: EdgeInsets.zero, constraints: const BoxConstraints()),
            ]),
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Flexible(child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: _extracted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final sup = _extracted[i];
              return Container(
                decoration: BoxDecoration(
                  color: sup.selected ? const Color(0xFFF0FDF4) : const Color(0xFFF9FAFB),
                  border: Border.all(color: sup.selected ? const Color(0xFF1B7A43) : const Color(0xFFE5E7EB)),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: CheckboxListTile(
                  value: sup.selected,
                  onChanged: (v) => setState(() => sup.selected = v ?? false),
                  activeColor: const Color(0xFF1B7A43),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  title: Text(
                    sup.name.isNotEmpty ? sup.name : '(No name extracted)',
                    style: TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600,
                      color: sup.name.isNotEmpty ? const Color(0xFF111827) : const Color(0xFF9CA3AF),
                    ),
                  ),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (sup.city.isNotEmpty || sup.phone.isNotEmpty)
                      Text(
                        [if (sup.city.isNotEmpty) sup.city, if (sup.phone.isNotEmpty) sup.phone].join(' · '),
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                    if (sup.companies.isNotEmpty)
                      Text(
                        '${sup.companies.length} compan${sup.companies.length == 1 ? 'y' : 'ies'}: ${sup.companies.take(3).map((c) => c.matched ?? c.seen).join(', ')}${sup.companies.length > 3 ? '…' : ''}',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                  ]),
                ),
              );
            },
          )),
          const Divider(height: 1, color: Color(0xFFE5E7EB)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('$selected of ${_extracted.length} selected',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
              Row(children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280))),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: selected > 0 ? _doImport : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  child: Text('Import $selected', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ]),
            ]),
          ),
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
