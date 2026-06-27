// CHANGE #208 — Super-Admin UPI Account Manager (Payment Settings)
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class AdminUpiScreen extends StatefulWidget {
  const AdminUpiScreen({super.key});

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

  @override
  void initState() {
    super.initState();
    RenderLog.write('c208_upi_screen_opened', 1);
    _fetchList();
  }

  @override
  void dispose() {
    _paCtrl.dispose();
    _pnCtrl.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _fetchList() async {
    setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('upi_list');
      if (!mounted) return;
      final rows = List<Map<String, dynamic>>.from(res as List);
      setState(() {
        _rows = rows;
        _loading = false;
      });
      RenderLog.write('c208_upi_list_loaded_${rows.length}', 1);
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
              const Text('Payment / UPI',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
              const SizedBox(height: 4),
              const Text(
                'The active UPI is used for the WhatsApp advance-payment QR sent to customers.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
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
        title: const Text('Payment / UPI',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _fetchList,
        color: const Color(0xFF1B7A43),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'The active UPI is used for the WhatsApp advance-payment QR sent to customers.',
              style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
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
                Text(pa,
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                    overflow: TextOverflow.ellipsis),
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
