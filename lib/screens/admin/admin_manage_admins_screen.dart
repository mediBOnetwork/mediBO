import 'package:flutter/material.dart';

import '../../services/date_labels.dart';
import '../../widgets/date_label_text.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';

// Emails that can never be removed or demoted — matches DB-side lock list.
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
  bool _addIsSuper = false;
  String? _error;
  // Tracks in-progress operations keyed by email.
  final Set<String> _busy = {};

  String get _myEmail =>
      (Supabase.instance.client.auth.currentUser?.email ?? '').toLowerCase();

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
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('admin_list_admins');
      if (!mounted) return;
      setState(() {
        _admins = List<Map<String, dynamic>>.from(res as List);
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { _error = _friendlyError(e); _loading = false; });
    }
  }

  Future<void> _addAdmin() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty) return;
    setState(() { _adding = true; _error = null; });
    try {
      await Supabase.instance.client.rpc('admin_add_admin', params: {
        'p_email': email,
        'p_is_super': _addIsSuper,
      });
      _emailCtrl.clear();
      setState(() => _addIsSuper = false);
      await _fetchAdmins();
    } catch (e) {
      if (mounted) setState(() { _error = _friendlyError(e); _adding = false; });
    }
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _setSuper(String email, bool makeSuper) async {
    if (_busy.contains(email)) return;
    setState(() => _busy.add(email));
    try {
      await Supabase.instance.client.rpc('admin_set_super', params: {
        'p_email': email,
        'p_is_super': makeSuper,
      });
      await _fetchAdmins();
    } catch (e) {
      if (mounted) showToast(context, _friendlyError(e), isError: true);
    }
    if (mounted) setState(() => _busy.remove(email));
  }

  Future<void> _removeAdmin(String email) async {
    if (_busy.contains(email)) return;
    setState(() => _busy.add(email));
    try {
      await Supabase.instance.client.rpc('admin_remove_admin', params: {'p_email': email});
      await _fetchAdmins();
    } catch (e) {
      if (mounted) showToast(context, _friendlyError(e), isError: true);
    }
    if (mounted) setState(() => _busy.remove(email));
  }

  Future<void> _confirmRemove(String email) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Remove admin?',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        content: Text('$email will lose all admin access immediately.',
            style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
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
    if (ok == true) _removeAdmin(email);
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('invalid_email')) return 'Enter a valid email address.';
    if (msg.contains('not_authorized')) return 'Super-admin access required.';
    if (msg.contains('cannot_remove_locked')) return 'This account cannot be removed.';
    if (msg.contains('cannot_remove_self')) return 'You cannot remove your own account.';
    if (msg.contains('cannot_demote_locked')) return 'This super-admin cannot be demoted.';
    if (msg.contains('cannot_demote_self')) return 'You cannot demote yourself.';
    if (msg.contains('admin_not_found')) return 'Admin not found.';
    return 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      if (c.maxWidth >= 768) return _buildDesktop(ctx);
      return _buildMobile(ctx);
    });
  }

  // ── Desktop ──────────────────────────────────────────────────────────────────

  Widget _buildDesktop(BuildContext ctx) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Manage Admins',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
              const SizedBox(height: 4),
              const Text('Add or remove admin accounts and grant or revoke super-admin access.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
              const SizedBox(height: 24),
              _AddAdminCard(
                ctrl: _emailCtrl,
                isSuper: _addIsSuper,
                loading: _adding,
                error: _error,
                onToggleSuper: (v) => setState(() => _addIsSuper = v),
                onAdd: _addAdmin,
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
      return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: Color(0xFF1B7A43))));
    }
    if (_admins.isEmpty) {
      return _emptyBox('No admins found.');
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
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(3),
            1: FixedColumnWidth(120),
            2: FlexColumnWidth(2.5),
            3: FixedColumnWidth(80),
            4: FixedColumnWidth(52),
          },
          children: [
            TableRow(
              decoration: const BoxDecoration(color: Color(0xFFF9FAFB)),
              children: [
                _th('Email'),
                _th('Role'),
                _th('Added By'),
                _th('Joined'),
                _th(''),
              ],
            ),
            ..._admins.map(_buildRow),
          ],
        ),
      ),
    );
  }

  TableRow _buildRow(Map<String, dynamic> row) {
    final email = (row['email'] as String? ?? '').toLowerCase();
    final isSuper = row['is_super'] as bool? ?? false;
    final isLocked = row['is_locked'] as bool? ?? false;
    final isSelf = email == _myEmail;
    final busy = _busy.contains(email);
    final canToggle = !isLocked && !isSelf && !busy;
    final canRemove = !isLocked && !isSelf && !busy;

    return TableRow(
      decoration: BoxDecoration(
        border: const Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        color: isLocked ? const Color(0xFFF0FDF4) : Colors.white,
      ),
      children: [
        _td(Row(children: [
          if (isLocked) ...[
            const Icon(Icons.lock_outline, size: 13, color: Color(0xFF1B7A43)),
            const SizedBox(width: 4),
          ],
          Expanded(child: Text(email, style: const TextStyle(fontSize: 13, color: Color(0xFF111827)))),
          if (isSelf)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(4)),
              child: const Text('You', style: TextStyle(fontSize: 10, color: Color(0xFF1E40AF), fontWeight: FontWeight.w600)),
            ),
        ])),
        _td(_RoleToggle(isSuper: isSuper, enabled: canToggle, busy: busy, onToggle: () => _setSuper(email, !isSuper))),
        _td(Text(row['added_by'] ?? '—', style: const TextStyle(fontSize: 13, color: Color(0xFF374151)))),
        // CHANGE #548: backend-formatted, rendered verbatim.
        _td(DateLabelText(
            ts: row['created_at']?.toString(),
            style: DateStyle.dayMonYear,
            textStyle: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
        TableCell(
          verticalAlignment: TableCellVerticalAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: busy
                ? const Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFDC2626))))
                : (isLocked || isSelf)
                    ? const Tooltip(message: 'Cannot remove', child: Icon(Icons.shield_outlined, size: 16, color: Color(0xFF9CA3AF)))
                    : canRemove
                        ? IconButton(
                            icon: const Icon(Icons.delete_outline, size: 17, color: Color(0xFFDC2626)),
                            tooltip: 'Remove admin',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () => _confirmRemove(email),
                          )
                        : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  Widget _th(String text) => TableCell(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6B7280), letterSpacing: 0.5)),
    ),
  );

  Widget _td(Widget child) => TableCell(
    verticalAlignment: TableCellVerticalAlignment.middle,
    child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12), child: child),
  );

  // ── Mobile ───────────────────────────────────────────────────────────────────

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
              isSuper: _addIsSuper,
              loading: _adding,
              error: _error,
              onToggleSuper: (v) => setState(() => _addIsSuper = v),
              onAdd: _addAdmin,
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator(color: Color(0xFF1B7A43))))
            else if (_admins.isEmpty)
              _emptyBox('No admins found.')
            else
              ..._admins.map(_buildMobileRow),
          ],
        ),
      ),
    );
  }

  Widget _buildMobileRow(Map<String, dynamic> row) {
    final email = (row['email'] as String? ?? '').toLowerCase();
    final isSuper = row['is_super'] as bool? ?? false;
    final isLocked = row['is_locked'] as bool? ?? false;
    final isSelf = email == _myEmail;
    final busy = _busy.contains(email);
    final canToggle = !isLocked && !isSelf && !busy;
    final canRemove = !isLocked && !isSelf && !busy;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isLocked ? const Color(0xFFF0FDF4) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isLocked ? const Color(0xFFBBF7D0) : const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (isLocked)
            const Padding(padding: EdgeInsets.only(right: 8), child: Icon(Icons.lock_outline, size: 14, color: Color(0xFF1B7A43))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Expanded(child: Text(email, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)))),
                  if (isSelf)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(4)),
                      child: const Text('You', style: TextStyle(fontSize: 10, color: Color(0xFF1E40AF), fontWeight: FontWeight.w600)),
                    ),
                ]),
                const SizedBox(height: 4),
                Text('Added by: ${row['added_by'] ?? '—'}',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                DateLabelText(
                    ts: row['created_at']?.toString(),
                    style: DateStyle.dayMonYear,
                    textStyle: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
                const SizedBox(height: 8),
                _RoleToggle(isSuper: isSuper, enabled: canToggle, busy: busy, onToggle: () => _setSuper(email, !isSuper)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (busy)
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFDC2626)))
          else if (isLocked || isSelf)
            const Tooltip(message: 'Cannot remove', child: Icon(Icons.shield_outlined, size: 18, color: Color(0xFF9CA3AF)))
          else if (canRemove)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Color(0xFFDC2626)),
              onPressed: () => _confirmRemove(email),
            ),
        ],
      ),
    );
  }

  Widget _emptyBox(String msg) => Container(
    padding: const EdgeInsets.all(40),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFFE5E7EB)),
    ),
    child: Center(child: Text(msg, style: const TextStyle(color: Color(0xFF6B7280), fontSize: 14))),
  );

  // CHANGE #548: _fmtDate() and its hardcoded _months = ['Jan',...] array are
  // DELETED. Month names and date layout are backend-owned (ist_fmt).
}

// ── Role Toggle ───────────────────────────────────────────────────────────────

class _RoleToggle extends StatelessWidget {
  final bool isSuper;
  final bool enabled;
  final bool busy;
  final VoidCallback onToggle;
  const _RoleToggle({required this.isSuper, required this.enabled, required this.busy, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43)));
    }
    final bg = isSuper ? const Color(0xFFD1FAE5) : const Color(0xFFF3F4F6);
    final fg = isSuper ? const Color(0xFF065F46) : const Color(0xFF6B7280);
    final label = isSuper ? 'Super-admin' : 'Admin';

    return GestureDetector(
      onTap: enabled ? onToggle : null,
      child: Tooltip(
        message: enabled ? (isSuper ? 'Click to revoke super-admin' : 'Click to grant super-admin') : '',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isSuper ? const Color(0xFF6EE7B7) : const Color(0xFFE5E7EB)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(isSuper ? Icons.verified_user_outlined : Icons.person_outline, size: 12, color: fg),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
              if (enabled) ...[
                const SizedBox(width: 4),
                Icon(Icons.swap_horiz, size: 11, color: fg.withValues(alpha: 0.6)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Add Admin Card ────────────────────────────────────────────────────────────

class _AddAdminCard extends StatelessWidget {
  final TextEditingController ctrl;
  final bool isSuper;
  final bool loading;
  final String? error;
  final ValueChanged<bool> onToggleSuper;
  final VoidCallback onAdd;

  const _AddAdminCard({
    required this.ctrl,
    required this.isSuper,
    required this.loading,
    required this.error,
    required this.onToggleSuper,
    required this.onAdd,
  });

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
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD1D5DB))),
                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43), width: 1.5)),
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
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => onToggleSuper(!isSuper),
            child: Row(
              children: [
                SizedBox(
                  width: 18,
                  height: 18,
                  child: Checkbox(
                    value: isSuper,
                    onChanged: (v) => onToggleSuper(v ?? false),
                    activeColor: const Color(0xFF1B7A43),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 8),
                const Text('Grant super-admin access',
                    style: TextStyle(fontSize: 13, color: Color(0xFF374151))),
              ],
            ),
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
