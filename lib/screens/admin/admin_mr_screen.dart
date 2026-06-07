import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../user_state.dart';

class AdminMrScreen extends StatefulWidget {
  const AdminMrScreen({super.key});

  @override
  State<AdminMrScreen> createState() => _AdminMrScreenState();
}

class _AdminMrScreenState extends State<AdminMrScreen> with SingleTickerProviderStateMixin {
  late TabController _tab;
  bool _loading = true;
  List<Map<String, dynamic>> _pending = [];
  List<Map<String, dynamic>> _approved = [];
  List<Map<String, dynamic>> _rejected = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _load();
  }

  @override
  void dispose() { _tab.dispose(); super.dispose(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final rows = await Supabase.instance.client
          .from('mr_registrations')
          .select()
          .eq('is_deleted', false)
          .order('submitted_at', ascending: false) as List;
      final all = List<Map<String, dynamic>>.from(rows);
      if (!mounted) return;
      setState(() {
        _pending = all.where((r) => r['status'] == 'pending').toList();
        _approved = all.where((r) => r['status'] == 'approved').toList();
        _rejected = all.where((r) => r['status'] == 'rejected').toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _review(Map<String, dynamic> row, String status) async {
    final adminEmail = Supabase.instance.client.auth.currentUser?.id ?? '';
    await Supabase.instance.client.from('mr_registrations').update({
      'status': status,
      'reviewed_by': adminEmail,
      'reviewed_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', row['id']);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text('MR Registrations', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        bottom: TabBar(
          controller: _tab,
          labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
          indicatorColor: const Color(0xFF1B5E20),
          labelColor: const Color(0xFF1B5E20),
          unselectedLabelColor: const Color(0xFF6B7280),
          tabs: [
            Tab(text: 'Pending (${_pending.length})'),
            Tab(text: 'Approved (${_approved.length})'),
            Tab(text: 'Rejected (${_rejected.length})'),
          ],
        ),
        actions: [
          IconButton(icon: const Icon(Icons.refresh, color: Color(0xFF374151)), onPressed: _load, tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF1B5E20)))
          : TabBarView(controller: _tab, children: [
              _buildList(_pending, showActions: true),
              _buildList(_approved),
              _buildList(_rejected),
            ]),
    );
  }

  Widget _buildList(List<Map<String, dynamic>> rows, {bool showActions = false}) {
    if (rows.isEmpty) {
      return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
        const Icon(Icons.badge_outlined, size: 48, color: Color(0xFFD1D5DB)),
        const SizedBox(height: 12),
        Text(showActions ? 'No pending MR registrations' : 'No records here', style: const TextStyle(fontSize: 15, color: Color(0xFF6B7280))),
      ]));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, i) => _buildCard(rows[i], showActions: showActions),
    );
  }

  Widget _buildCard(Map<String, dynamic> r, {bool showActions = false}) {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE5E7EB)), boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2))]),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(r['full_name'] ?? '—', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
            _StatusChip(r['status'] ?? 'pending'),
          ]),
          const SizedBox(height: 8),
          _InfoRow(icon: Icons.business_outlined, text: r['company_represented'] ?? '—'),
          _InfoRow(icon: Icons.map_outlined, text: r['territory_zone'] ?? '—'),
          _InfoRow(icon: Icons.location_city_outlined, text: '${r['city'] ?? '—'}, ${r['state'] ?? '—'}'),
          _InfoRow(icon: Icons.phone_outlined, text: r['phone'] ?? '—'),
          if ((r['email'] ?? '').isNotEmpty) _InfoRow(icon: Icons.email_outlined, text: r['email']),
          if ((r['id_proof_type'] ?? '').isNotEmpty) _InfoRow(icon: Icons.badge_outlined, text: 'ID: ${r['id_proof_type']}'),
          if ((r['reviewed_by'] ?? '').isNotEmpty) _InfoRow(icon: Icons.admin_panel_settings_outlined, text: 'Reviewed by: ${r['reviewed_by']}', subtle: true),
          if (showActions) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            const SizedBox(height: 14),
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => _review(r, 'rejected'),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Reject'),
                style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFF991B1B), side: const BorderSide(color: Color(0xFF991B1B)), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              )),
              const SizedBox(width: 12),
              Expanded(child: FilledButton.icon(
                onPressed: () => _review(r, 'approved'),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Approve'),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B5E20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              )),
            ]),
          ],
        ]),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool subtle;
  const _InfoRow({required this.icon, required this.text, this.subtle = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Row(children: [
        Icon(icon, size: 14, color: subtle ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280)),
        const SizedBox(width: 7),
        Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: subtle ? const Color(0xFF9CA3AF) : const Color(0xFF374151)))),
      ]),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip(this.status);

  @override
  Widget build(BuildContext context) {
    Color bg, fg;
    switch (status) {
      case 'approved': bg = const Color(0xFFD1FAE5); fg = const Color(0xFF065F46); break;
      case 'rejected': bg = const Color(0xFFFEE2E2); fg = const Color(0xFF991B1B); break;
      default: bg = const Color(0xFFFEF3C7); fg = const Color(0xFF92400E);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(status[0].toUpperCase() + status.substring(1), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}
