// CHANGE #208 — Super-Admin UPI Account Manager (Payment Settings)
// CHANGE #494 — renamed to "Payment and Partner"; added Partner section
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/utils/bill_mime.dart';
import 'package:pharma_b2b/widgets/fullscreen_image.dart';

class AdminUpiScreen extends StatefulWidget {
  // Injected RPCs — tests stub these; production leaves them null and hits
  // Supabase directly.
  final Future<List<Map<String, dynamic>>> Function()? fetchUpiListRpc;
  final Future<Map<String, dynamic>> Function()? fetchPartnerConfig;
  final Future<List<Map<String, dynamic>>> Function()? fetchPartnersRpc;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> params)? saveRegionPartnerRpc;
  final Future<Map<String, dynamic>> Function(String area)? setActivePartnerRpc;
  final Future<Map<String, dynamic>> Function(String area)? deleteRegionPartnerRpc;

  const AdminUpiScreen({
    super.key,
    this.fetchUpiListRpc,
    this.fetchPartnerConfig,
    this.fetchPartnersRpc,
    this.saveRegionPartnerRpc,
    this.setActivePartnerRpc,
    this.deleteRegionPartnerRpc,
  });

  @override
  State<AdminUpiScreen> createState() => _AdminUpiScreenState();
}

class _AdminUpiScreenState extends State<AdminUpiScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;

  final _paCtrl = TextEditingController();
  final _pnCtrl = TextEditingController();
  bool _makeActive = true;
  bool _adding = false;
  String? _addError;

  final Set<String> _busy = {};

  // ── Partner state ────────────────────────────────────────────────────────
  Map<String, dynamic>? _config;
  List<Map<String, dynamic>> _partners = [];
  bool _partnersLoading = true;
  final Set<String> _partnerBusy = {};
  final Set<String> _docBusy = {};

  @override
  void initState() {
    super.initState();
    RenderLog.write('c208_upi_screen_opened', 1);
    RenderLog.write('c209_upi_screen_opened', 1);
    RenderLog.write('c494_partner_screen_opened', 1);
    _fetchList();
    _fetchPartnerData();
  }

  @override
  void dispose() {
    _paCtrl.dispose();
    _pnCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAll() async {
    await Future.wait([_fetchList(), _fetchPartnerData()]);
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> _rpcUpiList() {
    if (widget.fetchUpiListRpc != null) return widget.fetchUpiListRpc!();
    return Supabase.instance.client
        .rpc('upi_list')
        .then((r) => List<Map<String, dynamic>>.from(r as List));
  }

  Future<void> _fetchList() async {
    setState(() => _loading = true);
    try {
      final rows = await _rpcUpiList();
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
      RenderLog.write('c208_upi_list_loaded_${rows.length}', 1);
      RenderLog.write('c232_copy_fix',
          'change:232,paycard_copy_right:true,upi_copy:true,covers:cash+online');
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c208_upi_error', 1);
      setState(() => _loading = false);
      showToast(context, _mapError(e), isError: true);
    }
  }

  Future<void> _addUpi() async {
    final pa = _paCtrl.text.trim();
    final pn = _pnCtrl.text.trim();

    // Client-side validation
    if (pa.isEmpty || !pa.contains('@')) {
      setState(() => _addError = 'Enter a valid UPI ID (must contain @).');
      return;
    }
    if (pn.isEmpty) {
      setState(() => _addError = 'Enter the payee name.');
      return;
    }
    setState(() { _addError = null; _adding = true; });

    try {
      await Supabase.instance.client.rpc('upi_add', params: {
        'p_pa': pa,
        'p_pn': pn,
        'p_make_active': _makeActive,
      });
      if (!mounted) return;
      RenderLog.write('c208_upi_added', 1);
      _paCtrl.clear();
      _pnCtrl.clear();
      setState(() { _makeActive = true; _adding = false; });
      await _fetchList();
      if (mounted) showToast(context, 'UPI added');
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c208_upi_error', 1);
      final msg = _mapError(e);
      if (msg.contains('Only a super admin')) RenderLog.write('c208_upi_denied', 1);
      setState(() { _addError = msg; _adding = false; });
    }
  }

  Future<void> _setActive(String id) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await Supabase.instance.client.rpc('upi_set_active', params: {'p_id': id});
      if (!mounted) return;
      RenderLog.write('c208_upi_set_active', 1);
      await _fetchList();
      if (mounted) showToast(context, 'Active UPI updated');
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c208_upi_error', 1);
      final msg = _mapError(e);
      if (msg.contains('Only a super admin')) RenderLog.write('c208_upi_denied', 1);
      showToast(context, msg, isError: true);
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  Future<void> _confirmRemove(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove this UPI?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This cannot be undone.',
            style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) _doRemove(id);
  }

  Future<void> _doRemove(String id) async {
    if (_busy.contains(id)) return;
    setState(() => _busy.add(id));
    try {
      await Supabase.instance.client.rpc('upi_remove', params: {'p_id': id});
      if (!mounted) return;
      RenderLog.write('c208_upi_removed', 1);
      await _fetchList();
      if (mounted) showToast(context, 'UPI removed');
    } catch (e) {
      if (!mounted) return;
      RenderLog.write('c208_upi_error', 1);
      final msg = _mapError(e);
      if (msg.contains('Only a super admin')) RenderLog.write('c208_upi_denied', 1);
      showToast(context, msg, isError: true);
    }
    if (mounted) setState(() => _busy.remove(id));
  }

  String _mapError(Object e) {
    final msg = e.toString();
    if (msg.contains('not_authorized')) return 'Only a super admin can change this.';
    if (msg.contains('invalid_upi')) return 'Enter a valid UPI ID (must contain @).';
    if (msg.contains('invalid_name')) return 'Enter the payee name.';
    if (msg.contains('not_found')) return 'That UPI was already removed.';
    return 'Something went wrong. Please try again.';
  }

  // ── Data: Partner ────────────────────────────────────────────────────────

  Future<Map<String, dynamic>> _rpcPartnerConfig() {
    if (widget.fetchPartnerConfig != null) return widget.fetchPartnerConfig!();
    return Supabase.instance.client
        .rpc('partner_screen_config')
        .then((r) => Map<String, dynamic>.from(r as Map));
  }

  Future<List<Map<String, dynamic>>> _rpcPartners() {
    if (widget.fetchPartnersRpc != null) return widget.fetchPartnersRpc!();
    return Supabase.instance.client
        .rpc('admin_region_partners')
        .then((r) => List<Map<String, dynamic>>.from(r as List));
  }

  Future<Map<String, dynamic>> _rpcSetActivePartner(String area) {
    if (widget.setActivePartnerRpc != null) return widget.setActivePartnerRpc!(area);
    return Supabase.instance.client
        .rpc('set_active_partner', params: {'p_area': area})
        .then((r) => Map<String, dynamic>.from(r as Map));
  }

  Future<Map<String, dynamic>> _rpcDeletePartner(String area) {
    if (widget.deleteRegionPartnerRpc != null) return widget.deleteRegionPartnerRpc!(area);
    return Supabase.instance.client
        .rpc('delete_region_partner', params: {'p_area': area})
        .then((r) => Map<String, dynamic>.from(r as Map));
  }

  Future<void> _fetchPartnerData() async {
    setState(() => _partnersLoading = true);
    try {
      final configFuture = _rpcPartnerConfig();
      final partnersFuture = _rpcPartners();
      final config = await configFuture;
      final partners = await partnersFuture;
      if (!mounted) return;
      setState(() {
        _config = config;
        _partners = partners;
        _partnersLoading = false;
      });
      RenderLog.write('c494_partners_loaded_${partners.length}', 1);
    } catch (e) {
      if (!mounted) return;
      setState(() => _partnersLoading = false);
      showToast(context, 'Could not load partner details', isError: true);
    }
  }

  Future<void> _setActivePartner(String area) async {
    if (_partnerBusy.contains(area)) return;
    setState(() => _partnerBusy.add(area));
    try {
      final data = await _rpcSetActivePartner(area);
      final message = data['message'] as String?;
      if (mounted && message != null) {
        showToast(context, message, isError: data['ok'] != true);
      }
      if (data['ok'] == true) await _fetchPartnerData();
    } catch (e) {
      if (mounted) showToast(context, 'Something went wrong. Please try again.', isError: true);
    }
    if (mounted) setState(() => _partnerBusy.remove(area));
  }

  Future<void> _confirmDeletePartner(String area) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove this partner?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: const Text('This cannot be undone.',
            style: TextStyle(fontSize: 14, color: Color(0xFF374151))),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFDC2626),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) _deletePartner(area);
  }

  Future<void> _deletePartner(String area) async {
    if (_partnerBusy.contains(area)) return;
    setState(() => _partnerBusy.add(area));
    try {
      final data = await _rpcDeletePartner(area);
      final message = data['message'] as String?;
      if (mounted && message != null) {
        showToast(context, message, isError: data['ok'] != true);
      }
      if (data['ok'] == true) await _fetchPartnerData();
    } catch (e) {
      if (mounted) showToast(context, 'Something went wrong. Please try again.', isError: true);
    }
    if (mounted) setState(() => _partnerBusy.remove(area));
  }

  void _openPartnerForm({Map<String, dynamic>? editing}) {
    final cfg = _config;
    if (cfg == null) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PartnerFormDialog(
        config: cfg,
        editing: editing,
        onSaved: _fetchPartnerData,
        saveRegionPartner: widget.saveRegionPartnerRpc,
      ),
    );
  }

  Future<void> _uploadDoc(String area, Map<String, dynamic> doc) async {
    final kind = doc['kind'] as String? ?? '';
    final busyKey = '$area|$kind';
    if (_docBusy.contains(busyKey)) return;

    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      allowMultiple: false,
      withData: true,
    );
    final picked = result?.files.singleOrNull;
    final bytes = picked?.bytes;
    if (picked == null || bytes == null) return;
    final ext = picked.extension?.toLowerCase() ?? 'jpg';

    setState(() => _docBusy.add(busyKey));
    try {
      final pathRes = await Supabase.instance.client.rpc('partner_doc_upload_path',
          params: {'p_area': area, 'p_kind': kind, 'p_ext': ext});
      final pathData = Map<String, dynamic>.from(pathRes as Map);
      if (pathData['ok'] != true) {
        if (mounted) {
          final message = pathData['message'] as String?;
          if (message != null) showToast(context, message, isError: true);
        }
        return;
      }
      final bucket = pathData['bucket'] as String;
      final path = pathData['path'] as String;

      await Supabase.instance.client.storage.from(bucket).uploadBinary(
            path, bytes,
            fileOptions: FileOptions(contentType: mimeFromBillName(picked.name)),
          );

      final saveRes = await Supabase.instance.client.rpc('save_region_partner_doc',
          params: {'p_area': area, 'p_kind': kind, 'p_path': path});
      final saveData = Map<String, dynamic>.from(saveRes as Map);
      final message = saveData['message'] as String?;
      if (mounted && message != null) {
        showToast(context, message, isError: saveData['ok'] != true);
      }
      if (saveData['ok'] == true) await _fetchPartnerData();
    } catch (e) {
      if (mounted) showToast(context, 'Something went wrong. Please try again.', isError: true);
    }
    if (mounted) setState(() => _docBusy.remove(busyKey));
  }

  Future<void> _viewDoc(String area, Map<String, dynamic> doc) async {
    final kind = doc['kind'] as String? ?? '';
    try {
      final res = await Supabase.instance.client
          .rpc('region_partner_doc_url', params: {'p_area': area, 'p_kind': kind});
      final data = Map<String, dynamic>.from(res as Map);
      if (data['ok'] != true) {
        if (mounted) {
          final message = data['message'] as String?;
          if (message != null) showToast(context, message, isError: true);
        }
        return;
      }
      final bucket = data['bucket'] as String;
      final path = data['path'] as String;
      final url = await Supabase.instance.client.storage.from(bucket).createSignedUrl(path, 3600);
      if (mounted) openFullscreenImage(context, url);
    } catch (e) {
      if (mounted) showToast(context, 'Something went wrong. Please try again.', isError: true);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      if (c.maxWidth >= 768) return _buildDesktop(ctx);
      return _buildMobile(ctx);
    });
  }

  // ── Desktop ──────────────────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext ctx) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Payment and Partner',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
              const SizedBox(height: 20),
              Text(_config?['payment_heading'] as String? ?? '',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 4),
              Text(
                _config?['payment_helper'] as String? ?? '',
                style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 24),
              _AddUpiCard(
                paCtrl: _paCtrl,
                pnCtrl: _pnCtrl,
                makeActive: _makeActive,
                adding: _adding,
                error: _addError,
                onToggleActive: (v) => setState(() => _makeActive = v),
                onAdd: _addUpi,
              ),
              const SizedBox(height: 24),
              _buildList(),
              const SizedBox(height: 32),
              const Divider(color: Color(0xFFE5E7EB)),
              const SizedBox(height: 24),
              _buildPartnerSection(),
            ],
          ),
        ),
      ),
    );
  }

  // ── Mobile ───────────────────────────────────────────────────────────────

  Widget _buildMobile(BuildContext ctx) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(ctx).maybePop(),
        ),
        title: const Text('Payment and Partner',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        color: const Color(0xFF1B7A43),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_config?['payment_heading'] as String? ?? '',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(height: 4),
            Text(
              _config?['payment_helper'] as String? ?? '',
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 16),
            _AddUpiCard(
              paCtrl: _paCtrl,
              pnCtrl: _pnCtrl,
              makeActive: _makeActive,
              adding: _adding,
              error: _addError,
              onToggleActive: (v) => setState(() => _makeActive = v),
              onAdd: _addUpi,
            ),
            const SizedBox(height: 16),
            _buildList(),
            const SizedBox(height: 32),
            const Divider(color: Color(0xFFE5E7EB)),
            const SizedBox(height: 24),
            _buildPartnerSection(),
          ],
        ),
      ),
    );
  }

  // ── List ─────────────────────────────────────────────────────────────────

  Widget _buildList() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 3),
        ),
      );
    }
    if (_rows.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64, height: 64,
              decoration: BoxDecoration(
                color: const Color(0xFFF9FAFB),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: const Icon(Icons.qr_code_outlined, size: 28, color: Color(0xFFD1D5DB)),
            ),
            const SizedBox(height: 16),
            const Text(
              'No UPI added yet. Add one to enable QR payments.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Color(0xFF9CA3AF)),
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Column(
          children: _rows.asMap().entries.map((e) {
            final isLast = e.key == _rows.length - 1;
            return _UpiRow(
              row: e.value,
              isLast: isLast,
              totalCount: _rows.length,
              busy: _busy.contains(e.value['id'] as String? ?? ''),
              onSetActive: () => _setActive(e.value['id'] as String),
              onRemove: () => _confirmRemove(e.value['id'] as String),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ── Partner section ──────────────────────────────────────────────────────

  Widget _buildPartnerSection() {
    final cfg = _config;
    if (cfg == null || _partnersLoading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 3),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(cfg['partner_heading'] as String? ?? '',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            ),
            TextButton.icon(
              onPressed: () => _openPartnerForm(),
              icon: const Icon(Icons.add, size: 18, color: Color(0xFF1B7A43)),
              label: const Text('Add Partner',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          cfg['partner_helper'] as String? ?? '',
          style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
        ),
        const SizedBox(height: 16),
        if (_partners.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: const Center(
              child: Text('No partners added yet.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
            ),
          )
        else
          Column(
            children: _partners.map((p) {
              final area = p['area'] as String;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _PartnerCard(
                  partner: p,
                  busy: _partnerBusy.contains(area),
                  docBusyKind: (kind) => _docBusy.contains('$area|$kind'),
                  onMakeActive: () => _setActivePartner(area),
                  onDelete: () => _confirmDeletePartner(area),
                  onEdit: () => _openPartnerForm(editing: p),
                  onUploadDoc: (doc) => _uploadDoc(area, doc),
                  onViewDoc: (doc) => _viewDoc(area, doc),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }
}

// ── UPI Row ───────────────────────────────────────────────────────────────────

class _UpiRow extends StatelessWidget {
  final Map<String, dynamic> row;
  final bool isLast;
  final int totalCount;
  final bool busy;
  final VoidCallback onSetActive;
  final VoidCallback onRemove;

  const _UpiRow({
    required this.row,
    required this.isLast,
    required this.totalCount,
    required this.busy,
    required this.onSetActive,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final pa = row['pa'] as String? ?? '';
    final pn = row['pn'] as String? ?? '';
    final isActive = row['is_active'] as bool? ?? false;
    final onlyOne = totalCount == 1;

    return Container(
      decoration: BoxDecoration(
        border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        color: isActive ? const Color(0xFFF0FDF4) : Colors.white,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Icon
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFFD1FAE5) : const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.account_balance_wallet_outlined, size: 20,
                color: isActive ? const Color(0xFF065F46) : const Color(0xFF9CA3AF)),
          ),
          const SizedBox(width: 12),
          // Text
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(pn,
                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF6EE7B7)),
                        ),
                        child: const Text('Active',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(
                    child: Text(pa,
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                        overflow: TextOverflow.ellipsis),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: const Icon(Icons.copy, size: 15, color: Color(0xFF9CA3AF)),
                    tooltip: 'Copy UPI ID',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: pa));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('UPI ID copied'),
                            duration: Duration(seconds: 1)),
                      );
                    },
                  ),
                ]),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Actions
          if (busy)
            const SizedBox(width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!isActive)
                  Tooltip(
                    message: 'Set as active UPI',
                    child: TextButton(
                      onPressed: onSetActive,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF1B7A43),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('Make Active',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                  ),
                if (onlyOne)
                  Tooltip(
                    message: 'At least one UPI must remain.',
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFD1D5DB)),
                      onPressed: null,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                    ),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626)),
                    tooltip: 'Remove UPI',
                    onPressed: onRemove,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

// ── Add UPI Card ──────────────────────────────────────────────────────────────

class _AddUpiCard extends StatelessWidget {
  final TextEditingController paCtrl;
  final TextEditingController pnCtrl;
  final bool makeActive;
  final bool adding;
  final String? error;
  final ValueChanged<bool> onToggleActive;
  final VoidCallback onAdd;

  const _AddUpiCard({
    required this.paCtrl,
    required this.pnCtrl,
    required this.makeActive,
    required this.adding,
    required this.error,
    required this.onToggleActive,
    required this.onAdd,
  });

  static InputDecoration _inputDec(String hint) => InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
      isDense: true,
    );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add UPI',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 12),
          TextField(
            controller: paCtrl,
            decoration: _inputDec('UPI ID (e.g. name@bank)'),
            style: const TextStyle(fontSize: 13),
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: pnCtrl,
            decoration: _inputDec('Payee Name'),
            style: const TextStyle(fontSize: 13),
            onSubmitted: (_) => adding ? null : onAdd(),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => onToggleActive(!makeActive),
            child: Row(
              children: [
                SizedBox(
                  width: 18, height: 18,
                  child: Checkbox(
                    value: makeActive,
                    onChanged: (v) => onToggleActive(v ?? true),
                    activeColor: const Color(0xFF1B7A43),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Set as active', style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
          const SizedBox(height: 12),
          SizedBox(
            height: 40,
            child: ElevatedButton(
              onPressed: adding ? null : onAdd,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B7A43),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                elevation: 0,
              ),
              child: adding
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Add UPI', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Partner Card ─────────────────────────────────────────────────────────────

class _PartnerCard extends StatelessWidget {
  final Map<String, dynamic> partner;
  final bool busy;
  final bool Function(String kind) docBusyKind;
  final VoidCallback onMakeActive;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final void Function(Map<String, dynamic> doc) onUploadDoc;
  final void Function(Map<String, dynamic> doc) onViewDoc;

  const _PartnerCard({
    required this.partner,
    required this.busy,
    required this.docBusyKind,
    required this.onMakeActive,
    required this.onDelete,
    required this.onEdit,
    required this.onUploadDoc,
    required this.onViewDoc,
  });

  @override
  Widget build(BuildContext context) {
    final name = partner['partner_name'] as String? ?? '';
    final badge = partner['badge'] as String?;
    final canMakeActive = partner['can_make_active'] as bool? ?? false;
    final canDelete = partner['can_delete'] as bool? ?? false;
    final blockedReason = partner['delete_blocked_reason'] as String?;
    final detailLines =
        (partner['detail_lines'] as List? ?? []).cast<Map<String, dynamic>>();
    final docs = (partner['docs'] as List? ?? []).cast<Map<String, dynamic>>();

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(name,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                    if (badge != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF6EE7B7)),
                        ),
                        child: Text(badge,
                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF065F46))),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (busy)
                const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
              else
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF6B7280)),
                      tooltip: 'Edit',
                      onPressed: onEdit,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    if (canMakeActive)
                      TextButton(
                        onPressed: onMakeActive,
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF1B7A43),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Make Active',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    if (canDelete)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626)),
                        tooltip: 'Remove partner',
                        onPressed: onDelete,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      )
                    else
                      Tooltip(
                        message: blockedReason ?? '',
                        child: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFD1D5DB)),
                          onPressed: null,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ),
                  ],
                ),
            ],
          ),
          if (!canDelete && blockedReason != null) ...[
            const SizedBox(height: 4),
            Text(blockedReason, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
          ],
          const SizedBox(height: 10),
          ...detailLines.map((line) => Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text('${line['label']}: ${line['value']}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
              )),
          const SizedBox(height: 12),
          const Divider(color: Color(0xFFE5E7EB), height: 1),
          const SizedBox(height: 12),
          ...docs.map((doc) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _DocRow(
                  doc: doc,
                  busy: docBusyKind(doc['kind'] as String? ?? ''),
                  onUpload: () => onUploadDoc(doc),
                  onView: () => onViewDoc(doc),
                ),
              )),
        ],
      ),
    );
  }
}

// ── Partner Doc Row ────────────────────────────────────────────────────────

class _DocRow extends StatelessWidget {
  final Map<String, dynamic> doc;
  final bool busy;
  final VoidCallback onUpload;
  final VoidCallback onView;

  const _DocRow({
    required this.doc,
    required this.busy,
    required this.onUpload,
    required this.onView,
  });

  @override
  Widget build(BuildContext context) {
    final label = doc['label'] as String? ?? '';
    final statusText = doc['status_text'] as String? ?? '';
    final canView = doc['can_view'] as bool? ?? false;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
              Text(statusText, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
            ],
          ),
        ),
        if (busy)
          const SizedBox(width: 16, height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)))
        else ...[
          TextButton(
            onPressed: onUpload,
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Upload', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: canView ? onView : null,
            style: TextButton.styleFrom(
              foregroundColor: canView ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('View', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ],
    );
  }
}

// ── Partner Add/Edit Form ─────────────────────────────────────────────────────

class _PartnerFormDialog extends StatefulWidget {
  final Map<String, dynamic> config;
  final Map<String, dynamic>? editing;
  final VoidCallback onSaved;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic> params)? saveRegionPartner;

  const _PartnerFormDialog({
    required this.config,
    required this.editing,
    required this.onSaved,
    this.saveRegionPartner,
  });

  @override
  State<_PartnerFormDialog> createState() => _PartnerFormDialogState();
}

class _PartnerFormDialogState extends State<_PartnerFormDialog> {
  final Map<String, TextEditingController> _controllers = {};
  String? _area;
  bool _active = false;
  bool _saving = false;

  List<Map<String, dynamic>> get _fields =>
      (widget.config['fields'] as List).cast<Map<String, dynamic>>();

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      if (f['type'] == 'dropdown') continue;
      final key = f['key'] as String;
      _controllers[key] = TextEditingController(text: widget.editing?[key]?.toString() ?? '');
    }
    _area = widget.editing?['area'] as String?;
    _active = widget.editing?['is_active'] as bool? ?? false;
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _canSave {
    for (final f in _fields) {
      if (f['required'] != true) continue;
      if (f['type'] == 'dropdown') {
        if (_area == null || _area!.isEmpty) return false;
      } else {
        final ctrl = _controllers[f['key'] as String];
        if (ctrl == null || ctrl.text.trim().isEmpty) return false;
      }
    }
    return true;
  }

  Future<Map<String, dynamic>> _rpcSave(Map<String, dynamic> params) {
    if (widget.saveRegionPartner != null) return widget.saveRegionPartner!(params);
    return Supabase.instance.client
        .rpc('save_region_partner', params: params)
        .then((r) => Map<String, dynamic>.from(r as Map));
  }

  Future<void> _save() async {
    if (_saving || !_canSave) return;
    setState(() => _saving = true);
    try {
      final data = await _rpcSave({
        'p_area': _area,
        'p_partner_name': _controllers['partner_name']?.text.trim(),
        'p_address': _controllers['address']?.text.trim(),
        'p_gstin': _controllers['gstin']?.text.trim(),
        'p_dl_20b': _controllers['dl_20b']?.text.trim(),
        'p_dl_21b': _controllers['dl_21b']?.text.trim(),
        'p_state': null,
        'p_make_active': _active,
      });
      if (!mounted) return;
      final message = data['message'] as String?;
      if (data['ok'] == true) {
        if (message != null) showToast(context, message);
        Navigator.of(context).pop();
        widget.onSaved();
        return;
      }
      if (message != null) showToast(context, message, isError: true);
    } catch (e) {
      if (mounted) showToast(context, 'Something went wrong. Please try again.', isError: true);
    }
    if (mounted) setState(() => _saving = false);
  }

  static final InputBorder _border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: const BorderSide(color: Color(0xFFD1D5DB)));

  Widget _buildField(Map<String, dynamic> f) {
    final type = f['type'] as String? ?? 'text';
    final label = f['label'] as String? ?? '';
    final decoration = InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Color(0xFF6B7280), fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: _border,
      enabledBorder: _border,
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
      isDense: true,
    );

    if (type == 'dropdown') {
      final options = (widget.config['area_options'] as List).cast<String>();
      return DropdownButtonFormField<String>(
        initialValue: _area,
        decoration: decoration,
        items: options
            .map((o) => DropdownMenuItem(value: o, child: Text(o, style: const TextStyle(fontSize: 13))))
            .toList(),
        onChanged: (v) => setState(() => _area = v),
      );
    }

    final ctrl = _controllers[f['key'] as String]!;
    return TextField(
      controller: ctrl,
      maxLines: type == 'multiline' ? 3 : 1,
      style: const TextStyle(fontSize: 13),
      decoration: decoration,
      onChanged: (_) => setState(() {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.editing != null;
    final activeLabel = widget.config['active_checkbox_label'] as String? ?? '';

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(isEditing ? 'Edit Partner' : 'Add Partner',
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
                const SizedBox(height: 16),
                for (final f in _fields) ...[
                  _buildField(f),
                  const SizedBox(height: 10),
                ],
                GestureDetector(
                  onTap: () => setState(() => _active = !_active),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 18, height: 18,
                        child: Checkbox(
                          value: _active,
                          onChanged: (v) => setState(() => _active = v ?? false),
                          activeColor: const Color(0xFF1B7A43),
                          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text(activeLabel, style: const TextStyle(fontSize: 13, color: Color(0xFF374151)))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving ? null : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: (_saving || !_canSave) ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1B7A43),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        elevation: 0,
                      ),
                      child: _saving
                          ? const SizedBox(width: 16, height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Text('Save', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
