import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _kLockedEmails = {'masteromprakashsahu@gmail.com', 'medibonetwork@gmail.com'};

class AdminManageAdminsScreen extends StatefulWidget {
  const AdminManageAdminsScreen({super.key});

  @override
  State<AdminManageAdminsScreen> createState() => _AdminManageAdminsScreenState();
}

class _AdminManageAdminsScreenState extends State<AdminManageAdminsScreen> {
  final _emailCtrl = TextEditingController();
  List<Map<String, dynamic>> _admins = [];
  bool _loading = true;
  bool _adding = false;
  String? _error;
  String? _removingId;

  @override
  void initState() {
    super.initState();
    _fetchAdmins();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchAdmins() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client
          .from('admins')
          .select('id, email, added_by, created_at')
          .order('created_at');
      if (mounted) setState(() { _admins = List<Map<String, dynamic>>.from(res); _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _addAdmin() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty) return;
    final currentEmail = Supabase.instance.client.auth.currentUser?.email ?? '';
    setState(() { _adding = true; _error = null; });
    try {
      await Supabase.instance.client.from('admins').insert({
        'email': email,
        'added_by': currentEmail,
      });
      _emailCtrl.clear();
      await _fetchAdmins();
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _adding = false; });
    }
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _removeAdmin(String id, String email) async {
    if (_kLockedEmails.contains(email.toLowerCase())) return;
    setState(() => _removingId = id);
    try {
      await Supabase.instance.client.from('admins').delete().eq('id', id);
      await _fetchAdmins();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Remove failed: $e'), backgroundColor: const Color(0xFFDC2626)),
        );
      }
    }
    if (mounted) setState(() => _removingId = null);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      if (c.maxWidth >= 768) return _buildDesktop(ctx);
      return _buildMobile(ctx);
    });
  }

  // ── Desktop ─────────────────────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext ctx) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Manage Admins',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827)),
              ),
              const SizedBox(height: 4),
              const Text(
                'Super-admins can add and remove admin accounts. Locked accounts cannot be removed.',
                style: TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 24),
              _AddAdminCard(
                ctrl: _emailCtrl,
                loading: _adding,
                onAdd: _addAdmin,
                error: _error,
              ),
              const SizedBox(height: 24),
              _buildTable(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTable() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
        ),
      );
    }
    if (_admins.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: const Center(
          child: Text('No admins yet.', style: TextStyle(color: Color(0xFF6B7280), fontSize: 14)),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(3),
            1: FlexColumnWidth(3),
            2: FlexColumnWidth(2),
            3: FixedColumnWidth(60),
          },
          children: [
            TableRow(
              decoration: const BoxDecoration(color: Color(0xFFF9FAFB)),
              children: [
                _th('Email'),
                _th('Added By'),
                _th('Created At'),
                _th(''),
              ],
            ),
            ..._admins.map((row) {
              final email = (row['email'] as String? ?? '').toLowerCase();
              final locked = _kLockedEmails.contains(email);
              final id = row['id'] as String;
              final createdAt = _formatDate(row['created_at']);
              final removing = _removingId == id;
              return TableRow(
                decoration: BoxDecoration(
                  border: const Border(top: BorderSide(color: Color(0xFFE5E7EB))),
                  color: locked ? const Color(0xFFF0FDF4) : Colors.white,
                ),
                children: [
                  _td(Row(children: [
                    if (locked) ...[
                      const Icon(Icons.lock, size: 13, color: Color(0xFF1B7A43)),
                      const SizedBox(width: 4),
                    ],
                    Expanded(child: Text(email, style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
                  ])),
                  _td(Text(row['added_by'] ?? '—', style: const TextStyle(fontSize: 13, color: Color(0xFF374151)))),
                  _td(Text(createdAt, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
                  TableCell(
                    verticalAlignment: TableCellVerticalAlignment.middle,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: locked
                          ? const Tooltip(
                              message: 'Super-admin — cannot be removed',
                              child: Icon(Icons.shield, size: 18, color: Color(0xFF1B7A43)),
                            )
                          : removing
                          ? const SizedBox(
                              width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFDC2626)),
                            )
                          : IconButton(
                              icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFDC2626)),
                              tooltip: 'Remove admin',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              onPressed: () => _confirmRemove(id, email),
                            ),
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _th(String text) => TableCell(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5)),
    ),
  );

  Widget _td(Widget child) => TableCell(
    verticalAlignment: TableCellVerticalAlignment.middle,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), child: child),
  );

  // ── Mobile ──────────────────────────────────────────────────────────────────

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
        title: const Text('Manage Admins',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _fetchAdmins,
        color: const Color(0xFF1B7A43),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _AddAdminCard(
              ctrl: _emailCtrl,
              loading: _adding,
              onAdd: _addAdmin,
              error: _error,
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: CircularProgressIndicator(color: Color(0xFF1B7A43)),
                ),
              )
            else if (_admins.isEmpty)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(40),
                  child: Text('No admins yet.', style: TextStyle(color: Color(0xFF6B7280))),
                ),
              )
            else
              ..._admins.map((row) {
                final email = (row['email'] as String? ?? '').toLowerCase();
                final locked = _kLockedEmails.contains(email);
                final id = row['id'] as String;
                final removing = _removingId == id;
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: locked ? const Color(0xFFF0FDF4) : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: locked ? const Color(0xFFBBF7D0) : const Color(0xFFE5E7EB)),
                  ),
                  child: Row(
                    children: [
                      if (locked)
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: Icon(Icons.lock, size: 14, color: Color(0xFF1B7A43)),
                        ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(email, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                            const SizedBox(height: 2),
                            Text('Added by: ${row['added_by'] ?? '—'}',
                                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                            Text(_formatDate(row['created_at']),
                                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                          ],
                        ),
                      ),
                      if (locked)
                        const Tooltip(
                          message: 'Super-admin — cannot be removed',
                          child: Icon(Icons.shield, size: 18, color: Color(0xFF1B7A43)),
                        )
                      else if (removing)
                        const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFDC2626)),
                        )
                      else
                        IconButton(
                          icon: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)),
                          onPressed: () => _confirmRemove(id, email),
                        ),
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Future<void> _confirmRemove(String id, String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove admin?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text('$email will lose admin access.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) _removeAdmin(id, email);
  }

  String _formatDate(dynamic raw) {
    if (raw == null) return '—';
    try {
      final dt = DateTime.parse(raw.toString()).toLocal();
      return '${dt.day} ${_months[dt.month - 1]} ${dt.year}';
    } catch (_) {
      return raw.toString();
    }
  }

  static const _months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
}

// ── Add Admin Card ────────────────────────────────────────────────────────────

class _AddAdminCard extends StatelessWidget {
  final TextEditingController ctrl;
  final bool loading;
  final VoidCallback onAdd;
  final String? error;

  const _AddAdminCard({
    required this.ctrl,
    required this.loading,
    required this.onAdd,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Add Admin',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    hintText: 'admin@example.com',
                    hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 13),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFD1D5DB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5),
                    ),
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                  onSubmitted: (_) => onAdd(),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 38,
                child: ElevatedButton(
                  onPressed: loading ? null : onAdd,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF1B7A43),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: loading
                      ? const SizedBox(
                          width: 16, height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(fontSize: 12, color: Color(0xFFDC2626))),
          ],
        ],
      ),
    );
  }
}
