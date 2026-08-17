import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';

// CHANGE #177 — admin screen for short-dated supplier offers.
// Two tabs: Offers (list + confirm/edit) and Ladder (discount config).
class ShortDatedAdminScreen extends StatefulWidget {
  const ShortDatedAdminScreen({super.key});

  @override
  State<ShortDatedAdminScreen> createState() => _ShortDatedAdminScreenState();
}

class _ShortDatedAdminScreenState extends State<ShortDatedAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text('Short-dated offers',
              style: Ds.t.title.copyWith(color: Ds.c.text)),
          backgroundColor: Ds.c.surface,
          foregroundColor: Ds.c.text,
          elevation: 0,
          bottom: TabBar(
            controller: _tabs,
            labelColor: Ds.c.brand,
            unselectedLabelColor: Ds.c.textSecondary,
            indicatorColor: Ds.c.brand,
            tabs: const [
              Tab(text: 'Offers'),
              Tab(text: 'Discount ladder'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: const [
            _OffersTab(),
            _LadderTab(),
          ],
        ),
      );
}

// ── Offers tab ────────────────────────────────────────────────────────────────
class _OffersTab extends StatefulWidget {
  const _OffersTab();
  @override
  State<_OffersTab> createState() => _OffersTabState();
}

class _OffersTabState extends State<_OffersTab> {
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;
  String _filter = 'all'; // all | pending_confirm | active

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('short_dated_offer_list',
              params: _filter == 'all' ? {} : {'p_status': _filter})
          .single() as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _rows = ((res['rows'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Filter chips
        Padding(
          padding:
              EdgeInsets.symmetric(horizontal: Ds.space.x16, vertical: Ds.space.x8),
          child: Row(
            children: [
              for (final (label, val) in [
                ('All', 'all'),
                ('Pending', 'pending_confirm'),
                ('Active', 'active'),
              ])
                Padding(
                  padding: EdgeInsets.only(right: Ds.space.x8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _filter == val,
                    selectedColor: Ds.c.brand.withOpacity(0.15),
                    labelStyle: Ds.t.caption.copyWith(
                      color: _filter == val ? Ds.c.brand : Ds.c.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                    onSelected: (_) {
                      setState(() => _filter = val);
                      _load();
                    },
                  ),
                ),
              const Spacer(),
              IconButton(
                  icon: const Icon(Icons.refresh),
                  color: Ds.c.textSecondary,
                  onPressed: _load),
            ],
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorState(error: _error!, onRetry: _load)
                  : _rows.isEmpty
                      ? _EmptyState(filter: _filter)
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: EdgeInsets.all(Ds.space.x16),
                            itemCount: _rows.length,
                            separatorBuilder: (_, __) =>
                                SizedBox(height: Ds.space.x12),
                            itemBuilder: (_, i) => _OfferCard(
                              row: _rows[i],
                              onRefresh: _load,
                            ),
                          ),
                        ),
        ),
      ],
    );
  }
}

class _OfferCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final VoidCallback onRefresh;
  const _OfferCard({required this.row, required this.onRefresh});

  String get _status => row['status']?.toString() ?? '';
  bool get _isPending => _status == 'pending_confirm';
  bool get _isActive => _status == 'active';

  Color get _statusBg {
    switch (_status) {
      case 'pending_confirm':
        return Ds.c.warningSoft;
      case 'active':
        return Ds.c.successSoft;
      case 'exhausted':
      case 'expired':
      case 'disabled':
        return Ds.c.bg;
      default:
        return Ds.c.bg;
    }
  }

  Color get _statusFg {
    switch (_status) {
      case 'pending_confirm':
        return Ds.c.warning;
      case 'active':
        return Ds.c.success;
      default:
        return Ds.c.textSecondary;
    }
  }

  String get _statusLabel {
    switch (_status) {
      case 'pending_confirm':
        return 'Pending confirm';
      case 'active':
        return 'Active';
      case 'exhausted':
        return 'Exhausted';
      case 'expired':
        return 'Expired';
      case 'disabled':
        return 'Disabled';
      default:
        return _status;
    }
  }

  @override
  Widget build(BuildContext context) {
    final warning = row['expiry_warning'] as Map? ?? {};
    final warnShow = warning['show'] == true;
    final warnBg = warnShow
        ? _hexColor(warning['colors']?['bg']?.toString())
        : null;
    final warnFg = warnShow
        ? _hexColor(warning['colors']?['fg']?.toString())
        : null;

    return Container(
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    row['product_name']?.toString() ?? '—',
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w600, color: Ds.c.text),
                  ),
                ),
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _statusBg,
                    borderRadius: BorderRadius.circular(Ds.r.chip),
                  ),
                  child: Text(_statusLabel,
                      style: Ds.t.caption.copyWith(
                          fontWeight: FontWeight.w600,
                          color: _statusFg)),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            // Expiry chip
            if (warnShow && warnBg != null)
              Container(
                margin: EdgeInsets.only(bottom: Ds.space.x8),
                padding:
                    EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: 3),
                decoration: BoxDecoration(
                  color: warnBg,
                  borderRadius: BorderRadius.circular(Ds.r.chip),
                ),
                child: Text(warning['label']?.toString() ?? '',
                    style: Ds.t.caption.copyWith(
                        fontWeight: FontWeight.w500,
                        color: warnFg ?? Ds.c.text)),
              ),
            _InfoRow('Supplier', row['supplier_name']?.toString() ?? '—'),
            if ((row['batch_no']?.toString() ?? '').isNotEmpty)
              _InfoRow('Batch', row['batch_no'].toString()),
            _InfoRow('Discount', row['discount_label']?.toString() ?? '—'),
            _InfoRow('Available qty',
                '${row['remaining_qty'] ?? 0} remaining of ${row['available_qty'] ?? 0}'),
            if ((row['bulk_clear_extra_pct'] as num? ?? 0) > 0)
              _InfoRow('Bulk-clear extra',
                  '+${row['bulk_clear_extra_pct']}% off full batch'),
            if ((row['admin_notes']?.toString() ?? '').isNotEmpty)
              _InfoRow('Notes', row['admin_notes'].toString()),
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                if (_isPending)
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                          backgroundColor: Ds.c.brand,
                          minimumSize: const Size(double.infinity, 44)),
                      onPressed: () => _confirm(context),
                      child: const Text('Confirm offer',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ),
                if (_isPending) SizedBox(width: Ds.space.x8),
                if (_isPending || _isActive)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Ds.c.brand),
                        minimumSize: const Size(0, 44)),
                    onPressed: () => _edit(context),
                    child: Text('Edit',
                        style: TextStyle(color: Ds.c.brand)),
                  ),
                if (_isActive) ...[
                  SizedBox(width: Ds.space.x8),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        side: BorderSide(color: Ds.c.danger),
                        minimumSize: const Size(0, 44)),
                    onPressed: () => _pushWa(context),
                    child: Text('Push WA',
                        style: TextStyle(color: Ds.c.danger)),
                  ),
                ],
                if (!_isPending && !_isActive) const Spacer(),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    try {
      await Supabase.instance.client.rpc('short_dated_offer_confirm',
          params: {'p_id': row['id']});
      onRefresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _pushWa(BuildContext context) async {
    try {
      await Supabase.instance.client
          .rpc('short_dated_push_wa', params: {'p_id': row['id']});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('WhatsApp push sent')));
      }
      onRefresh();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _edit(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Ds.r.card)),
      builder: (_) => _EditOfferSheet(row: row, onSaved: onRefresh),
    );
  }

  Color? _hexColor(String? hex) {
    if (hex == null) return null;
    final s = hex.startsWith('#') ? hex.substring(1) : hex;
    final v = int.tryParse('FF$s', radix: 16);
    return v == null ? null : Color(v);
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x4),
        child: Row(
          children: [
            Text('$label: ',
                style: Ds.t.caption.copyWith(
                    color: Ds.c.textSecondary,
                    fontWeight: FontWeight.w500)),
            Expanded(
              child: Text(value,
                  style: Ds.t.caption.copyWith(
                      color: Ds.c.text,
                      fontWeight: FontWeight.w500)),
            ),
          ],
        ),
      );
}

class _EditOfferSheet extends StatefulWidget {
  final Map<String, dynamic> row;
  final VoidCallback onSaved;
  const _EditOfferSheet({required this.row, required this.onSaved});

  @override
  State<_EditOfferSheet> createState() => _EditOfferSheetState();
}

class _EditOfferSheetState extends State<_EditOfferSheet> {
  late final TextEditingController _discountCtl =
      TextEditingController(text: widget.row['discount_pct']?.toString() ?? '');
  late final TextEditingController _bulkCtl = TextEditingController(
      text: widget.row['bulk_clear_extra_pct']?.toString() ?? '0');
  late final TextEditingController _notesCtl =
      TextEditingController(text: widget.row['admin_notes']?.toString() ?? '');
  bool _saving = false;

  @override
  void dispose() {
    _discountCtl.dispose();
    _bulkCtl.dispose();
    _notesCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x16 + padding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Edit offer',
              style: Ds.t.title.copyWith(color: Ds.c.text)),
          SizedBox(height: Ds.space.x16),
          _Field(label: 'Discount %', controller: _discountCtl,
              keyboardType: TextInputType.number),
          SizedBox(height: Ds.space.x12),
          _Field(
              label: 'Bulk-clear extra % (0 = none)',
              controller: _bulkCtl,
              keyboardType: TextInputType.number),
          SizedBox(height: Ds.space.x12),
          _Field(label: 'Admin notes', controller: _notesCtl),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Save',
                      style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('short_dated_offer_edit', params: {
        'p_id': widget.row['id'],
        'p_discount_pct': double.tryParse(_discountCtl.text),
        'p_bulk_clear_extra_pct': double.tryParse(_bulkCtl.text) ?? 0,
        'p_admin_notes':
            _notesCtl.text.isEmpty ? null : _notesCtl.text,
      });
      if (mounted) Navigator.pop(context);
      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _saving = false);
      }
    }
  }
}

// ── Ladder tab ────────────────────────────────────────────────────────────────
class _LadderTab extends StatefulWidget {
  const _LadderTab();
  @override
  State<_LadderTab> createState() => _LadderTabState();
}

class _LadderTabState extends State<_LadderTab> {
  List<Map<String, dynamic>> _bands = [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client
          .rpc('short_dated_config_get')
          .single() as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _bands = ((res['bands'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await Supabase.instance.client.rpc('short_dated_config_save',
          params: {'p_bands': _bands});
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Ladder saved')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _addBand() {
    setState(() {
      _bands.add({
        'months_max': 6,
        'discount_pct': 10,
        'label': 'Near expiry',
        'enabled': true,
        'sort_order': _bands.length,
      });
    });
  }

  void _removeBand(int i) => setState(() => _bands.removeAt(i));

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _ErrorState(error: _error!, onRetry: _load);
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Text(
            'Set the discount for each expiry window. When a batch is scanned at receiving with an expiry date in one of these windows, an offer is auto-created with this discount. Admin can edit per offer.',
            style: TextStyle(fontSize: 13, color: Ds.c.textSecondary),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            itemCount: _bands.length,
            separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
            itemBuilder: (_, i) => _BandCard(
              band: _bands[i],
              onChanged: (b) => setState(() => _bands[i] = b),
              onRemove: () => _removeBand(i),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Ds.c.brand),
                    minimumSize: const Size(double.infinity, 44)),
                onPressed: _addBand,
                icon: Icon(Icons.add, color: Ds.c.brand, size: 18),
                label:
                    Text('Add band', style: TextStyle(color: Ds.c.brand)),
              ),
              SizedBox(height: Ds.space.x12),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save ladder',
                          style: TextStyle(color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BandCard extends StatefulWidget {
  final Map<String, dynamic> band;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final VoidCallback onRemove;
  const _BandCard(
      {required this.band, required this.onChanged, required this.onRemove});

  @override
  State<_BandCard> createState() => _BandCardState();
}

class _BandCardState extends State<_BandCard> {
  late final TextEditingController _monthsCtl;
  late final TextEditingController _pctCtl;
  late final TextEditingController _labelCtl;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _monthsCtl = TextEditingController(
        text: widget.band['months_max']?.toString() ?? '6');
    _pctCtl = TextEditingController(
        text: widget.band['discount_pct']?.toString() ?? '10');
    _labelCtl =
        TextEditingController(text: widget.band['label']?.toString() ?? '');
    _enabled = widget.band['enabled'] == true;
  }

  @override
  void dispose() {
    _monthsCtl.dispose();
    _pctCtl.dispose();
    _labelCtl.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged({
        ...widget.band,
        'months_max': int.tryParse(_monthsCtl.text) ?? 6,
        'discount_pct': double.tryParse(_pctCtl.text) ?? 10,
        'label': _labelCtl.text,
        'enabled': _enabled,
      });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: BorderRadius.circular(Ds.r.card),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Expiry window',
                    style: Ds.t.body.copyWith(fontWeight: FontWeight.w600, color: Ds.c.text)),
              ),
              Switch(
                value: _enabled,
                activeColor: Ds.c.brand,
                onChanged: (v) {
                  setState(() => _enabled = v);
                  _emit();
                },
              ),
              IconButton(
                icon: Icon(Icons.delete_outline,
                    color: Ds.c.textSecondary, size: 20),
                onPressed: widget.onRemove,
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              Expanded(
                child: _Field(
                  label: 'Months max (< N months)',
                  controller: _monthsCtl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _emit(),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: _Field(
                  label: 'Discount %',
                  controller: _pctCtl,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => _emit(),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          _Field(
              label: 'Label',
              controller: _labelCtl,
              onChanged: (_) => _emit()),
        ],
      ),
    );
  }
}

// ── Shared widgets ────────────────────────────────────────────────────────────
class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    this.keyboardType,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: keyboardType,
        onChanged: onChanged,
        style: TextStyle(fontSize: 14, color: Ds.c.text),
        decoration: InputDecoration(
          labelText: label,
          labelStyle:
              TextStyle(fontSize: 13, color: Ds.c.textSecondary),
          filled: true,
          fillColor: Ds.c.bg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.r.button - 4),
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.r.button - 4),
            borderSide: BorderSide(color: Ds.c.divider),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(Ds.r.button - 4),
            borderSide: BorderSide(color: Ds.c.brand, width: 1.5),
          ),
          contentPadding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x12),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: Ds.c.textSecondary, size: 40),
              SizedBox(height: Ds.space.x12),
              Text(error,
                  textAlign: TextAlign.center,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              SizedBox(height: Ds.space.x16),
              OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  final String filter;
  const _EmptyState({required this.filter});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined,
                  color: Ds.c.textSecondary, size: 40),
              SizedBox(height: Ds.space.x12),
              Text(
                filter == 'pending_confirm'
                    ? 'No offers awaiting confirmation'
                    : filter == 'active'
                        ? 'No active offers'
                        : 'No short-dated offers yet.\nThey appear automatically when a batch with near-expiry is scanned at receiving.',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 13, color: Ds.c.textSecondary),
              ),
            ],
          ),
        ),
      );
}
