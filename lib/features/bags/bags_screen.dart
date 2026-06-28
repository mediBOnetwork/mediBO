import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../utils/render_log.dart';

class BagsScreen extends StatefulWidget {
  const BagsScreen({super.key});

  @override
  State<BagsScreen> createState() => _BagsScreenState();
}

class _BagsScreenState extends State<BagsScreen> {
  List<Map<String, dynamic>> _bags = [];
  List<Map<String, dynamic>> _filtered = [];
  bool _loading = true;
  String _query = '';
  final _searchCtrl = TextEditingController();

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

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client.rpc('bags_list');
      final rows = (res as List).cast<Map<String, dynamic>>();
      RenderLog.write('c250_bags_loaded', rows.length);
      if (!mounted) return;
      setState(() {
        _bags = rows;
        _filtered = _applyFilter(rows, _query);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  List<Map<String, dynamic>> _applyFilter(List<Map<String, dynamic>> src, String q) {
    if (q.isEmpty) return src;
    return src.where((b) => b['bag_no'].toString().contains(q)).toList();
  }

  void _onSearch(String q) {
    setState(() {
      _query = q.trim();
      _filtered = _applyFilter(_bags, _query);
    });
  }

  Future<void> _toggleStatus(int bagNo, String current) async {
    final next = current == 'used' ? 'empty' : 'used';
    // optimistic update
    setState(() {
      for (final b in _bags) {
        if (b['bag_no'] == bagNo) b['status'] = next;
      }
      _filtered = _applyFilter(_bags, _query);
    });
    RenderLog.write('c250_bag_toggle', 'bag_no=$bagNo;status=$next');
    try {
      final res = await Supabase.instance.client.rpc(
        'bag_set_status',
        params: {'p_bag_no': bagNo, 'p_status': next},
      );
      final row = (res is List && res.isNotEmpty) ? res.first as Map<String, dynamic> : null;
      if (row != null && mounted) {
        setState(() {
          for (final b in _bags) {
            if (b['bag_no'] == bagNo) b['status'] = row['status'];
          }
          _filtered = _applyFilter(_bags, _query);
        });
      }
    } catch (_) {
      // revert
      if (!mounted) return;
      setState(() {
        for (final b in _bags) {
          if (b['bag_no'] == bagNo) b['status'] = current;
        }
        _filtered = _applyFilter(_bags, _query);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update bag status')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final cols = w >= 1100 ? 4 : (w >= 700 ? 3 : 2);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1B7A43),
        foregroundColor: Colors.white,
        title: const Text('Bags', style: TextStyle(fontWeight: FontWeight.w700)),
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF1B7A43)))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: _onSearch,
                  decoration: InputDecoration(
                    hintText: 'Search bag number…',
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF6B7280)),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1B7A43)),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.72,
                  ),
                  itemCount: _filtered.length,
                  itemBuilder: (context, i) {
                    final b = _filtered[i];
                    return _BagCard(
                      bag: b,
                      onToggle: () => _toggleStatus(b['bag_no'] as int, b['status'] as String),
                    );
                  },
                ),
              ),
            ]),
    );
  }
}

class _BagCard extends StatelessWidget {
  final Map<String, dynamic> bag;
  final VoidCallback onToggle;

  const _BagCard({required this.bag, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final bagNo = bag['bag_no'] as int;
    final bagCode = bag['bag_code'] as String;
    final status = bag['status'] as String;

    return Card(
      elevation: 2,
      shadowColor: Colors.black.withOpacity(0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8),
          color: const Color(0xFF1B7A43),
          child: Text(
            'Bag $bagNo',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: QrImageView(
              data: bagCode,
              version: QrVersions.auto,
              size: 140,
              gapless: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _StatusBadge(status: status, onTap: onToggle),
        ),
      ]),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final VoidCallback onTap;

  const _StatusBadge({required this.status, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isUsed = status == 'used';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: isUsed ? const Color(0xFF1B7A43) : const Color(0xFFECECEC),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(
            isUsed ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: isUsed ? Colors.white : const Color(0xFF6B7280),
          ),
          const SizedBox(width: 5),
          Text(
            isUsed ? 'Used' : 'Empty',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isUsed ? Colors.white : const Color(0xFF374151),
            ),
          ),
        ]),
      ),
    );
  }
}
