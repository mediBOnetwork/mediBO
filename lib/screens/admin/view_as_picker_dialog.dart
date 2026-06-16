import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';
import '../../view_as_state.dart';

/// Searchable account-picker dialog for the "View As" dev tool.
/// Returns a [ViewAsIdentity] when an account is selected, null on dismiss.
Future<ViewAsIdentity?> showViewAsPicker(
  BuildContext context,
  ViewAsRole role,
) {
  return showDialog<ViewAsIdentity>(
    context: context,
    builder: (_) => _ViewAsPickerDialog(role: role),
  );
}

class _ViewAsPickerDialog extends StatefulWidget {
  final ViewAsRole role;
  const _ViewAsPickerDialog({required this.role});

  @override
  State<_ViewAsPickerDialog> createState() => _ViewAsPickerDialogState();
}

class _ViewAsPickerDialogState extends State<_ViewAsPickerDialog> {
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch('');
    _searchCtrl.addListener(_onSearch);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearch);
    _searchCtrl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearch() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _fetch(_searchCtrl.text.trim()));
  }

  String get _rpcName {
    switch (widget.role) {
      case ViewAsRole.supplier:        return 'admin_list_suppliers';
      case ViewAsRole.customer:        return 'admin_list_customers';
      case ViewAsRole.company:         return 'admin_list_companies';
      case ViewAsRole.deliveryPartner: return 'admin_list_delivery_partners';
    }
  }

  String get _roleLabel {
    switch (widget.role) {
      case ViewAsRole.supplier:        return 'Supplier';
      case ViewAsRole.customer:        return 'Customer';
      case ViewAsRole.company:         return 'Company';
      case ViewAsRole.deliveryPartner: return 'Delivery Partner';
    }
  }

  String _nameField(Map<String, dynamic> r) {
    return (r['supplier_name'] ?? r['display_name'] ?? r['company_name'] ?? r['full_name'] ?? '') as String;
  }

  Future<void> _fetch(String search) async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc(
        _rpcName,
        params: {'p_search': search},
      ) as List;
      if (mounted) {
        setState(() {
          _items = res.map((r) => Map<String, dynamic>.from(r as Map)).toList();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 480, maxHeight: MediaQuery.of(context).size.height * 0.88),
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 8, 12),
              child: Row(
                children: [
                  const Icon(Icons.preview_outlined, size: 20, color: Color(0xFFD97706)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'View As $_roleLabel',
                      style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Search
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'Search by name or email…',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
                  prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF6B7280)),
                  filled: true,
                  fillColor: const Color(0xFFF5F6F8),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFD97706))),
                ),
              ),
            ),
            const Divider(height: 1),
            // List
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFD97706)))
                  : _error != null
                      ? Center(child: Text('Error: $_error', style: const TextStyle(color: Color(0xFF991B1B), fontSize: 13)))
                      : _items.isEmpty
                          ? const Center(child: Text('No accounts found.', style: TextStyle(color: Color(0xFF6B7280), fontSize: 14)))
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: _items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1, indent: 16),
                              itemBuilder: (ctx, i) {
                                final item = _items[i];
                                final name  = _nameField(item);
                                final email = item['email'] as String? ?? '';
                                final city  = item['city']  as String? ?? '';
                                final id    = item['id']    as String? ?? '';
                                return ListTile(
                                  dense: true,
                                  title: Text(name.isNotEmpty ? name : '(no name)',
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
                                  subtitle: Text(
                                    [if (email.isNotEmpty) email, if (city.isNotEmpty) city].join(' · '),
                                    style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                                  ),
                                  trailing: const Icon(Icons.chevron_right, size: 18, color: Color(0xFF9CA3AF)),
                                  onTap: () {
                                    RenderLog.write('view_as_picked', '${widget.role.name}:$id');
                                    // For customers, also capture user_id so OrdersScreen
                                    // can scope to the impersonated customer's orders.
                                    final userId = widget.role == ViewAsRole.customer
                                        ? item['user_id'] as String?
                                        : null;
                                    Navigator.pop(context, ViewAsIdentity(
                                      id: id,
                                      name: name.isNotEmpty ? name : email,
                                      email: email,
                                      userId: userId,
                                      isApproved: item['approved'] as bool? ?? false,
                                    ));
                                  },
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
