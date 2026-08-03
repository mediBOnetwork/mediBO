import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

/// CHANGE #639 PART D — the admin Demand preview.
///
/// One RPC, printed. `admin_demand_preview()` returns the column headers, the
/// zone label, the empty-state sentence and every number already turned into a
/// display string, with the rows in the order it wants them shown. This file
/// adds up nothing, sorts nothing and words nothing.
///
/// Both parameters are OMITTED deliberately. The admin date and zone are
/// server-side state (`admin_active_date()` / `admin_active_zone()`), and the
/// date-scope rule is explicit that sending an explicit null means "all dates"
/// to several RPCs. Omitting lets the backend read the same two pickers every
/// other admin screen reads, so this screen cannot disagree with them — and a
/// super-admin on "All zones" already resolves to NULL there, which is exactly
/// the all-zones case the spec asks for.
class DemandPreviewSheet extends StatefulWidget {
  const DemandPreviewSheet({super.key});

  /// Test seam — mirrors CartModel.rpcTransport.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  static Future<void> show(BuildContext context) {
    RenderLog.write('c639_demand_preview_open', 1);
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, __) => const ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          child: Material(
            color: Color(0xFFF5F6F8),
            child: DemandPreviewSheet(),
          ),
        ),
      ),
    );
  }

  @override
  State<DemandPreviewSheet> createState() => _DemandPreviewSheetState();
}

class _DemandPreviewSheetState extends State<DemandPreviewSheet> {
  bool _loading = true;
  String _error = '';

  /// The backend's own wording for a refusal. Empty when the call simply did
  /// not complete — pull-to-refresh is the way out of that, and this file does
  /// not invent a sentence to fill the gap.
  String _errorText = '';
  Map<String, dynamic> _payload = const {};
  List<Map<String, dynamic>> _rows = const [];
  List<Map<String, dynamic>> _columns = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      // No p_date, no p_zone — see the class comment.
      final raw = await DemandPreviewSheet.rpc('admin_demand_preview');
      if (!mounted) return;
      final data = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (data is! Map) {
        setState(() {
          _error = 'load_failed';
          _loading = false;
        });
        return;
      }
      final map = data.cast<String, dynamic>();
      if (map['error'] != null) {
        setState(() {
          _error = map['error'].toString();
          // The refusal's own sentence, when the backend sent one.
          _errorText = (map['error_text'] ?? '').toString();
          _loading = false;
        });
        return;
      }
      setState(() {
        _payload = map;
        // Payload order, verbatim.
        _rows = ((map['rows'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _columns = ((map['columns'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _error = '';
        _errorText = '';
        _loading = false;
      });
      RenderLog.write('c639_demand_preview_rows', _rows.length);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'load_failed';
        _loading = false;
      });
    }
  }

  String _s(String key) => (_payload[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(),
        const Divider(height: 1, color: Color(0xFFE5E7EB)),
        Expanded(
          child: RefreshIndicator(
            color: const Color(0xFF1B7A43),
            onRefresh: _load,
            child: _loading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: CircularProgressIndicator(
                          color: Color(0xFF1B7A43), strokeWidth: 2.5),
                    ),
                  )
                : _error.isNotEmpty
                    ? _scrollableMessage(_errorText)
                    : _rows.isEmpty
                        ? _scrollableMessage(_s('empty_text'))
                        : _buildTable(),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final zone = _s('zone_label');
    final date = _s('date_display');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _s('title'),
                  style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827)),
                ),
                if (zone.isNotEmpty || date.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(children: [
                    if (date.isNotEmpty)
                      Text(date,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280))),
                    if (date.isNotEmpty && zone.isNotEmpty)
                      const SizedBox(width: 10),
                    if (zone.isNotEmpty)
                      Text(zone,
                          style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF1B7A43))),
                  ]),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20, color: Color(0xFF6B7280)),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _scrollableMessage(String text) => ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
            child: Center(
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ),
          ),
        ],
      );

  // Column widths: the product name takes the slack, the four numbers are
  // fixed so they stay on a strict grid. The whole table scrolls sideways
  // inside its own box rather than squeezing the text.
  static const double _kNumW = 78;
  static const double _kNameW = 220;

  Widget _buildTable() {
    final tableWidth = _kNameW + _kNumW * (_columns.length - 1).clamp(0, 8);
    return LayoutBuilder(builder: (context, c) {
      final width = tableWidth < c.maxWidth ? c.maxWidth : tableWidth;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: ListView.separated(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: _rows.length + 1,
            separatorBuilder: (_, __) =>
                const Divider(height: 1, color: Color(0xFFE5E7EB)),
            itemBuilder: (_, i) {
              if (i == 0) return _headerRow(width);
              return _dataRow(_rows[i - 1], width);
            },
          ),
        ),
      );
    });
  }

  Widget _headerRow(double width) {
    return Container(
      height: 40,
      width: width,
      color: const Color(0xFFF9FAFB),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < _columns.length; i++)
            SizedBox(
              width: i == 0 ? _kNameW : _kNumW,
              child: Text(
                (_columns[i]['label'] ?? '').toString(),
                textAlign: (_columns[i]['align'] ?? 'left') == 'right'
                    ? TextAlign.right
                    : TextAlign.left,
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF6B7280)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _dataRow(Map<String, dynamic> row, double width) {
    return Container(
      height: 52,
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < _columns.length; i++)
            SizedBox(
              width: i == 0 ? _kNameW : _kNumW,
              child: Text(
                // Every cell is a backend display string. The numeric columns
                // read <key>_display so nothing is formatted here.
                _cell(row, (_columns[i]['key'] ?? '').toString(), i == 0),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: (_columns[i]['align'] ?? 'left') == 'right'
                    ? TextAlign.right
                    : TextAlign.left,
                style: TextStyle(
                  fontSize: i == 0 ? 13 : 14,
                  fontWeight: i == 0 ? FontWeight.w500 : FontWeight.w600,
                  color: const Color(0xFF111827),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _cell(Map<String, dynamic> row, String key, bool isName) {
    if (isName) return (row[key] ?? '').toString();
    final display = row['${key}_display'];
    if (display != null) return display.toString();
    return (row[key] ?? '').toString();
  }
}
