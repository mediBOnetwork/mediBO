// CHANGE #430 — "Unmapped Companies" review screen.
// Lists supplier company entries with no canonical link (list_unmapped_companies())
// and lets an admin pick the right canonical company per row (map_company()), which
// also learns an alias so the same raw name auto-resolves on future imports.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:pharma_b2b/utils/render_log.dart';

class UnmappedCompaniesScreen extends StatefulWidget {
  const UnmappedCompaniesScreen({super.key});

  @override
  State<UnmappedCompaniesScreen> createState() => _UnmappedCompaniesScreenState();
}

class _UnmappedCompaniesScreenState extends State<UnmappedCompaniesScreen> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final _searchCtrl = TextEditingController();

  List<String> _allCompanies = [];
  bool _companiesLoading = false;

  final Set<String> _busyIds = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Data ──────────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final res = await Supabase.instance.client.rpc('list_unmapped_companies');
      if (!mounted) return;
      final rows = (res as List)
          .map((r) => Map<String, dynamic>.from(r as Map))
          .toList();
      setState(() {
        _rows = rows;
        _loading = false;
      });
      RenderLog.write('c430_unmapped', 'screen=on;count=${rows.length}');
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = _mapError(e); });
    }
  }

  Future<void> _ensureCompaniesLoaded() async {
    if (_allCompanies.isNotEmpty || _companiesLoading) return;
    setState(() => _companiesLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('admin_company_names');
      // #589 — names arrive ordered and non-blank from the backend.
      final m = (res is List ? res.first : res) as Map;
      _allCompanies = ((m['names'] as List<dynamic>?) ?? const [])
          .map((r) => r.toString())
          .toList();
    } catch (_) {
      // Free-text mapping still works even if the full list fails to load.
    } finally {
      if (mounted) setState(() => _companiesLoading = false);
    }
  }

  Future<void> _mapRow(Map<String, dynamic> row, String companyName) async {
    final scId = row['sc_id'] as String;
    final name = companyName.trim();
    if (name.isEmpty || _busyIds.contains(scId)) return;
    setState(() => _busyIds.add(scId));
    try {
      final msg = await Supabase.instance.client.rpc('map_company', params: {
        'p_sc_id': scId,
        'p_company_name': name,
        'p_learn': true,
      }) as String?;
      if (!mounted) return;
      setState(() {
        _rows.removeWhere((r) => r['sc_id'] == scId);
        _busyIds.remove(scId);
      });
      RenderLog.write('c430_mapped', 'raw=${row['raw_name']};to=$name');
      showToast(context, msg ?? 'Mapped ${row['raw_name']} → $name');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyIds.remove(scId));
      showToast(context, _mapError(e), isError: true);
    }
  }

  String _mapError(Object e) {
    final msg = e.toString();
    if (msg.contains('forbidden')) return 'Only a super admin can access company mapping.';
    if (msg.contains('no empty company slot')) return 'This row already has 30 linked companies.';
    if (msg.contains('row not found')) return 'This entry was already mapped or removed.';
    if (msg.contains('company required')) return 'Enter a company name.';
    return 'Something went wrong. Please try again.';
  }

  List<Map<String, dynamic>> get _visibleRows {
    if (_query.isEmpty) return _rows;
    return _rows.where((r) {
      final raw = (r['raw_name'] as String? ?? '').toLowerCase();
      final sup = (r['supplier_name'] as String? ?? '').toLowerCase();
      return raw.contains(_query) || sup.contains(_query);
    }).toList();
  }

  // ── Picker ───────────────────────────────────────────────────────────────

  Future<void> _openPicker(Map<String, dynamic> row) async {
    await _ensureCompaniesLoaded();
    if (!mounted) return;
    final candidates = (row['candidates'] as List?)?.cast<String>() ?? const <String>[];
    final chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => _CompanyPickerSheet(
        rawName: row['raw_name'] as String? ?? '',
        candidates: candidates,
        allCompanies: _allCompanies,
        loading: _companiesLoading,
      ),
    );
    if (chosen != null && chosen.trim().isNotEmpty) {
      await _mapRow(row, chosen);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c430_unmapped_build', 'true');
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('Unmapped: ${_rows.length}',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: const Color(0xFFE5E7EB)),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)));
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 32, color: Color(0xFF9CA3AF)),
            const SizedBox(height: 12),
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          ]),
        ),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: TextField(
          controller: _searchCtrl,
          onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
          decoration: InputDecoration(
            hintText: 'Search by company or supplier name',
            prefixIcon: const Icon(Icons.search, size: 18),
            suffixIcon: _query.isEmpty ? null : IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () => setState(() { _searchCtrl.clear(); _query = ''; }),
            ),
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(children: [
          Expanded(
            child: Text(
              'Mapping teaches the system — the same raw name maps automatically next time.',
              style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 4),
      Expanded(
        child: _visibleRows.isEmpty
            ? Center(
                child: Text(
                  _rows.isEmpty ? 'Nothing unmapped 🎉' : 'No matches',
                  style: const TextStyle(fontSize: 14, color: Color(0xFF9CA3AF)),
                ),
              )
            : RefreshIndicator(
                onRefresh: _load,
                color: const Color(0xFF1B7A43),
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: _visibleRows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) => _buildRow(_visibleRows[i]),
                ),
              ),
      ),
    ]);
  }

  Widget _buildRow(Map<String, dynamic> row) {
    final scId = row['sc_id'] as String;
    final busy = _busyIds.contains(scId);
    final rawName = row['raw_name'] as String? ?? '—';
    final supplierName = row['supplier_name'] as String? ?? '';
    final confident = row['confident_company'] as String?;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(rawName,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 2),
        Text('from $supplierName',
            style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (confident != null)
            _MapButton(
              label: 'Map to $confident',
              icon: Icons.auto_awesome,
              highlighted: true,
              busy: busy,
              onTap: () => _mapRow(row, confident),
            ),
          _MapButton(
            label: 'Map to…',
            icon: Icons.search,
            highlighted: false,
            busy: busy,
            onTap: () => _openPicker(row),
          ),
        ]),
      ]),
    );
  }
}

class _MapButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool highlighted;
  final bool busy;
  final VoidCallback onTap;
  const _MapButton({
    required this.label,
    required this.icon,
    required this.highlighted,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = highlighted ? const Color(0xFF065F46) : const Color(0xFF374151);
    final bg = highlighted ? const Color(0xFFD1FAE5) : const Color(0xFFF3F4F6);
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            SizedBox(width: 13, height: 13,
                child: CircularProgressIndicator(strokeWidth: 1.5, color: fg))
          else
            Icon(icon, size: 14, color: fg),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
        ]),
      ),
    );
  }
}

// ── Company picker bottom sheet ─────────────────────────────────────────────

class _CompanyPickerSheet extends StatefulWidget {
  final String rawName;
  final List<String> candidates;
  final List<String> allCompanies;
  final bool loading;
  const _CompanyPickerSheet({
    required this.rawName,
    required this.candidates,
    required this.allCompanies,
    required this.loading,
  });

  @override
  State<_CompanyPickerSheet> createState() => _CompanyPickerSheetState();
}

class _CompanyPickerSheetState extends State<_CompanyPickerSheet> {
  String _q = '';
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final filteredCandidates =
        widget.candidates.where((c) => q.isEmpty || c.toLowerCase().contains(q)).toList();
    final filteredAll = q.isEmpty
        ? const <String>[]
        : widget.allCompanies
            .where((c) => c.toLowerCase().contains(q) && !widget.candidates.contains(c))
            .take(50)
            .toList();
    final exactMatch = widget.allCompanies.any((c) => c.toLowerCase() == q) ||
        widget.candidates.any((c) => c.toLowerCase() == q);

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Map "${widget.rawName}" to…',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
              const SizedBox(height: 10),
              TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: (v) => setState(() => _q = v),
                decoration: InputDecoration(
                  hintText: 'Search or type a company name',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onSubmitted: (v) {
                  if (v.trim().isNotEmpty) Navigator.of(context).pop(v.trim());
                },
              ),
            ]),
          ),
          if (widget.loading)
            const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(minHeight: 2, color: Color(0xFF1B7A43)),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (q.isNotEmpty && !exactMatch)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.add_circle_outline, color: Color(0xFF1B7A43)),
                    title: Text('Add "${_ctrl.text.trim()}" as new company',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1B7A43))),
                    onTap: () => Navigator.of(context).pop(_ctrl.text.trim()),
                  ),
                if (filteredCandidates.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('Suggested',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF9CA3AF))),
                  ),
                  ...filteredCandidates.map((c) => ListTile(
                        dense: true,
                        leading: const Icon(Icons.auto_awesome, size: 18, color: Color(0xFF2563EB)),
                        title: Text(c, style: const TextStyle(fontSize: 13)),
                        onTap: () => Navigator.of(context).pop(c),
                      )),
                ],
                if (q.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('All companies',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF9CA3AF))),
                  ),
                  if (filteredAll.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('No matches — use "Add" above to map anyway.',
                          style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                    )
                  else
                    ...filteredAll.map((c) => ListTile(
                          dense: true,
                          leading: const Icon(Icons.business_outlined, size: 18, color: Color(0xFF6B7280)),
                          title: Text(c, style: const TextStyle(fontSize: 13)),
                          onTap: () => Navigator.of(context).pop(c),
                        )),
                ] else
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Type to search all companies.',
                        style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
