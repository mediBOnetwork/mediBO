import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';

import '../../services/ui_copy.dart';
import '../../user_state.dart';

class AdminAddAdminScreen extends StatefulWidget {
  const AdminAddAdminScreen({super.key});

  @override
  State<AdminAddAdminScreen> createState() => _AdminAddAdminScreenState();
}

class _AdminAddAdminScreenState extends State<AdminAddAdminScreen> {
  final _emailCtrl = TextEditingController();
  bool _adding = false;
  String? _error;
  String? _success;
  List<Map<String, dynamic>> _admins = [];
  bool _loadingAdmins = true;

  @override
  void initState() {
    super.initState();
    _loadAdmins();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAdmins() async {
    try {
      final raw = await Supabase.instance.client.rpc('admin_list_admins_rows');
      final res = ((raw is List ? raw.first : raw) as Map)['rows'] as List? ?? const [];
      if (mounted) {
        setState(() {
          _admins = List<Map<String, dynamic>>.from(res);
          _loadingAdmins = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingAdmins = false);
    }
  }

  Future<void> _addAdmin() async {
    final email = _emailCtrl.text.trim().toLowerCase();
    if (email.isEmpty || !email.contains('@')) {
      setState(() => _error = c('admin_add_admin.err_invalid_email'));
      return;
    }
    setState(() {
      _adding = true;
      _error = null;
      _success = null;
    });
    try {
      // CHANGE #580 — admin_add_admin() already existed and was being
      // BYPASSED by this direct insert into `admins`, the most privilege-
      // bearing table in the app. The RPC requires super_admin and resolves
      // added_by from the session; the raw insert required neither, and took
      // added_by from auth.currentUser.email with a '' fallback.
      await Supabase.instance.client
          .rpc('admin_add_admin', params: {'p_email': email});
      _emailCtrl.clear();
      if (mounted) setState(() => _success = cf('admin_add_admin.success_added', {'email': email}));
      await _loadAdmins();
    } on PostgrestException catch (e) {
      if (e.code == '23505') {
        if (mounted) {
          setState(() => _error = c('admin_add_admin.err_duplicate'));
        }
      } else {
        if (mounted) {
          setState(() => _error = cf('admin_add_admin.err_failed', {'msg': e.message}));
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = c('admin_add_admin.err_generic'));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _removeAdmin(String email) async {
    try {
      await Supabase.instance.client
          // #592 — admin_remove_admin() already existed and requires
          // super_admin; the raw delete required nothing.
          .rpc('admin_remove_admin', params: {'p_email': email});
      await _loadAdmins();
    } catch (_) {
      if (mounted) {
        showToast(context, c('admin_add_admin.toast_remove_failed'), isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = UserState.of(context);

    if (!auth.isSuperAdmin) {
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
          title: Text(c('admin_add_admin.title'),
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF111827))),
        ),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48, color: Color(0xFF9CA3AF)),
              const SizedBox(height: 16),
              Text(c('admin_add_admin.denied_title'),
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF374151))),
              const SizedBox(height: 8),
              Text(c('admin_add_admin.denied_body'),
                  style: const
                      TextStyle(fontSize: 14, color: Color(0xFF9CA3AF))),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          c('admin_add_admin.title'),
          style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827)),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Add admin form ──────────────────────────────────────
                Container(
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
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        c('admin_add_admin.form_title'),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF111827),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        c('admin_add_admin.form_hint'),
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFF6B7280)),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        textCapitalization: TextCapitalization.none,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          hintText: c('admin_add_admin.email_hint'),
                          hintStyle: const TextStyle(
                              color: Color(0xFF9CA3AF), fontSize: 14),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 13),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: Color(0xFFD1D5DB)),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: Color(0xFFD1D5DB)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                                color: Color(0xFF1B7A43), width: 1.5),
                          ),
                          filled: true,
                          fillColor: const Color(0xFFFAFAFA),
                        ),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 8),
                        Text(_error!,
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFDC2626))),
                      ],
                      if (_success != null) ...[
                        const SizedBox(height: 8),
                        Text(_success!,
                            style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFF15803D))),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 46,
                        child: FilledButton(
                          onPressed: _adding ? null : _addAdmin,
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF1B7A43),
                            disabledBackgroundColor: const Color(0xFF1B7A43)
                                .withValues(alpha: 0.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8)),
                          ),
                          child: _adding
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                      color: Colors.white, strokeWidth: 2.5),
                                )
                              : Text(c('admin_add_admin.btn_add'),
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 28),

                // ── Current admins list ─────────────────────────────────
                Row(
                  children: [
                    Text(
                      c('admin_add_admin.list_title'),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF374151),
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      onPressed: _loadAdmins,
                      icon: const Icon(Icons.refresh,
                          size: 18, color: Color(0xFF9CA3AF)),
                      tooltip: c('admin_add_admin.tooltip_refresh'),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  c('admin_add_admin.list_note'),
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF9CA3AF)),
                ),
                const SizedBox(height: 12),

                if (_loadingAdmins)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                          color: Color(0xFF1B7A43), strokeWidth: 2),
                    ),
                  )
                else if (_admins.isEmpty)
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Text(
                      c('admin_add_admin.list_empty'),
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF9CA3AF)),
                      textAlign: TextAlign.center,
                    ),
                  )
                else
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5E7EB)),
                    ),
                    child: Column(
                      children: _admins.asMap().entries.map((entry) {
                        final i = entry.key;
                        final admin = entry.value;
                        final isLast = i == _admins.length - 1;
                        final email = admin['email'] as String? ?? '';
                        final addedBy =
                            admin['added_by'] as String? ?? '';
                        return Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFFECFDF5),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.admin_panel_settings_outlined,
                                      size: 18,
                                      color: Color(0xFF1B7A43),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(email,
                                            style: const TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: Color(0xFF111827),
                                            )),
                                        if (addedBy.isNotEmpty)
                                          Text(
                                            cf('admin_add_admin.added_by', {'who': addedBy}),
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Color(0xFF9CA3AF),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                        Icons.remove_circle_outline,
                                        size: 18,
                                        color: Color(0xFFDC2626)),
                                    tooltip: c('admin_add_admin.tooltip_remove'),
                                    onPressed: () =>
                                        _confirmRemove(context, email),
                                  ),
                                ],
                              ),
                            ),
                            if (!isLast)
                              const Divider(
                                  height: 1,
                                  indent: 64,
                                  color: Color(0xFFF3F4F6)),
                          ],
                        );
                      }).toList(),
                    ),
                  ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _confirmRemove(BuildContext context, String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c('admin_add_admin.confirm_title'),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: Text(
          cf('admin_add_admin.confirm_body', {'email': email}),
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(c('admin_add_admin.btn_cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626)),
            onPressed: () {
              Navigator.of(ctx).pop();
              _removeAdmin(email);
            },
            child: Text(c('admin_add_admin.btn_remove')),
          ),
        ],
      ),
    );
  }
}
