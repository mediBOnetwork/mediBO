// CMD #427 — PRICE CHECK. The one place a pharmacy is told that its own bills
// sit above what pharmacies near it pay for the same pack.
//
// THIS FILE COMPARES NOTHING. The rate, the peer median, the percentage, the
// rupee impact, the "across N nearby pharmacies" line, the month name and the
// privacy sentence all arrive finished from `pharmacy_overpay_insights()`.
// There is no median here, no subtraction, no percentage and no threshold —
// because the floor that makes those numbers safe to show (at least five OTHER
// pharmacies, the subject removed from its own median) lives in the backend and
// must never be re-derived by a screen that cannot see the cohort.
//
// AND IT NAMES NOBODY. There is no field on this screen for another pharmacy or
// a supplier, because the payload has none. The strongest guarantee a screen can
// give is that it could not leak what it was never handed.
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../services/demand_engine_api.dart';
import '../../utils/render_log.dart';
import 'pharmacy_expiry_screen.dart' show toneColor, toneSoft;

String _s(Object? v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

class PharmacyOverpayScreen extends StatefulWidget {
  const PharmacyOverpayScreen({super.key, this.rpc, this.onOpenRoute});

  /// Injected in tests so the screen is proven against a payload, never a
  /// network.
  final DemandRpc? rpc;

  /// Where "Get the mediBO price" goes. The ROUTE is the backend's
  /// (`/product/<id>`); this callback only carries it to the navigator.
  final void Function(String route)? onOpenRoute;

  @override
  State<PharmacyOverpayScreen> createState() => _PharmacyOverpayScreenState();
}

class _PharmacyOverpayScreenState extends State<PharmacyOverpayScreen> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : DemandEngineApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('pharmacy_overpay_insights', const {});
    } catch (_) {
      res = const {};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('overpay_rows', _rows(res['rows']).length);
    RenderLog.write('overpay_screen', 1);
  }

  Future<void> _dismiss(Map<String, dynamic> row) async {
    final res = await _call('pharmacy_overpay_dismiss', {'p_id': row['id']});
    if (!mounted) return;
    final message = _s(res['message']);
    if (message.isNotEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
    await _load();
  }

  void _open(Map<String, dynamic> row) {
    final route = _s(row['route']);
    if (route.isEmpty) return;
    if (widget.onOpenRoute != null) {
      widget.onOpenRoute!(route);
    } else {
      Navigator.of(context).pushNamed(route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _payload['ok'] == true;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_payload['title'])),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _OverpaySkeleton()
          : !ok
          ? _Refusal(message: _s(_payload['message']), onRetry: _load)
          : RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    final rows = _rows(_payload['rows']);
    final total = _s(_payload['total_label']);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text(_s(_payload['subtitle']), style: Ds.t.caption),
        if (total.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(total, style: Ds.t.subtitle),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          _Empty(text: _s(_payload['empty']))
        else
          ...rows.map(
            (r) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x12),
              child: _InsightCard(
                row: r,
                onOpen: () => _open(r),
                onDismiss: () => _dismiss(r),
              ),
            ),
          ),
        SizedBox(height: Ds.space.x24),
        _Privacy(text: _s(_payload['privacy'])),
      ],
    );
  }
}

/// One note. Every line on it is a string the backend already wrote.
class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.row,
    required this.onOpen,
    required this.onDismiss,
  });

  final Map<String, dynamic> row;
  final VoidCallback onOpen;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final tone = _s(row['tone']);
    final pack = _s(row['pack_label']);
    final month = _s(row['month_label']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(_s(row['name']), style: Ds.t.subtitle)),
              if (month.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8,
                    vertical: Ds.space.x4,
                  ),
                  decoration: BoxDecoration(
                    color: toneSoft(tone),
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    month,
                    style: Ds.t.caption.copyWith(color: toneColor(tone)),
                  ),
                ),
            ],
          ),
          if (pack.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(pack, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x12),
          Text(
            _s(row['headline']),
            style: Ds.t.body.copyWith(color: toneColor(tone)),
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(row['detail']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: onOpen,
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape: RoundedRectangleBorder(
                        borderRadius: Ds.r.rButton,
                      ),
                    ),
                    child: Text(_s(row['action_label'])),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: onDismiss,
                  style: TextButton.styleFrom(
                    foregroundColor: Ds.c.textSecondary,
                  ),
                  child: Text(_s(row['dismiss_label'])),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The promise, in the backend's own words, at the bottom of the screen where
/// a pharmacist who has just read a number about their neighbours looks for it.
class _Privacy extends StatelessWidget {
  const _Privacy({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.infoSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lock_outline, size: Ds.space.x16, color: Ds.c.info),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Text(text, style: Ds.t.caption.copyWith(color: Ds.c.info)),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.all(Ds.space.x24),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      boxShadow: Ds.elevation.e1,
    ),
    child: Center(child: Text(text, style: Ds.t.bodySecondary)),
  );
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x16),
          OutlinedButton(onPressed: onRetry, child: const Text('↻')),
        ],
      ),
    ),
  );
}

class _OverpaySkeleton extends StatelessWidget {
  const _OverpaySkeleton();

  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.all(Ds.space.x16),
    children: List.generate(
      3,
      (_) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Container(
          height: Ds.space.x48 + Ds.space.x24,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        ),
      ),
    ),
  );
}
