// CMD #411 — the pharmacy counter (POS).
//
// A mediBO pharmacy sells to a walk-in patient and prints its OWN GST tax
// invoice, on its own GSTIN and drug licence. This is the anchor of the free
// shop-management layer: the reason a pharmacy opens mediBO on a morning when
// it is not ordering anything.
//
// THIS FILE ADDS UP NOTHING. Every rupee, percentage, quantity, plural, label,
// empty state and toast on this screen is a finished string from
// `pos_home()` / `pos_quote()` / `pos_commit_sale()` / `pos_day_close()`. The
// bill the operator watches while typing comes from the SAME engine that writes
// the sale (`pos_price_bill`), so the saved invoice can never disagree with
// what was on screen when they tapped Save.
//
// The counter flow is built for speed, not for browsing: type two letters, tap
// the medicine, type the quantity, repeat, Save. Search results and the cart
// share one column so a bill is a single downward gesture.
//
// Offline: Save mints a client_action_id, parks the payload on disk and posts
// it. If the post fails the bill is still made — it replays on the next open
// and the backend's UNIQUE constraint makes the replay resolve to the sale it
// already wrote rather than a second bill.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import 'pharmacy_stock_screen.dart';
import '../../services/pharmacy_stock_api.dart';
import '../../services/pos_api.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

/// A uuid v4 for the offline key. Minted on the device, before the network is
/// known to exist — that is the whole point of it.
String _newActionId() {
  final r = Random.secure();
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-'
      '${(8 + r.nextInt(4)).toRadixString(16)}${h(3)}-${h(12)}';
}

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

/// One line the operator has put on the bill. Holds only what the OPERATOR
/// chose — never a price, never a total. The backend prices it.
class PosCartLine {
  final int? medicineId;
  final String productName;
  final String packLabel;
  num qty;
  num discPct;
  String batchNo;
  String expiry;

  PosCartLine({
    required this.medicineId,
    required this.productName,
    this.packLabel = '',
    this.qty = 1,
    this.discPct = 0,
    this.batchNo = '',
    this.expiry = '',
  });

  Map<String, dynamic> toPayload() => {
    if (medicineId != null) 'medicine_id': medicineId,
    'product_name': productName,
    'qty': qty,
    'disc_pct': discPct,
    if (batchNo.isNotEmpty) 'batch_no': batchNo,
    if (expiry.isNotEmpty) 'expiry': expiry,
  };
}

class PosScreen extends StatefulWidget {
  /// Test seam. Null in production -> the real RPCs.
  final PosRpc? rpc;
  const PosScreen({super.key, this.rpc});

  @override
  State<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends State<PosScreen> {
  Map<String, dynamic>? _home;
  /// The backend's own refusal copy. Permanent — a retry cannot change it.
  String? _bootRefusal;
  /// The request never landed. That IS retryable, and it must never put a Dart
  /// exception string on screen.
  bool _bootFailed = false;

  final List<PosCartLine> _cart = [];
  Map<String, dynamic> _quote = const {};
  num _billDiscPct = 0;
  String _payMode = '';

  final _searchCtl = TextEditingController();
  final _patientName = TextEditingController();
  final _patientPhone = TextEditingController();
  List<Map<String, dynamic>> _results = const [];
  String _searchMessage = '';
  Timer? _debounce;
  bool _searching = false;
  bool _saving = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PosApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    _patientName.dispose();
    _patientPhone.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final home = await _call('pos_home', const {});
      if (!mounted) return;
      if (home['ok'] != true) {
        setState(() => _bootRefusal = _s(home['message']));
        RenderLog.write('c411_pos_denied', 1);
        return;
      }
      setState(() {
        _home = home;
        _payMode = _s(home['default_payment']);
      });
      RenderLog.write('c411_pos_home', 1);
      // Anything billed while the network was gone lands now, before the
      // operator starts a new bill on a day-close that would be wrong.
      unawaited(_replayPending());
    } catch (_) {
      // Never print the exception: a dart2js error string is not copy, and it
      // is not the backend's. Offer the retry instead.
      if (mounted) setState(() => _bootFailed = true);
    }
  }

  Future<void> _replayPending() async {
    if (widget.rpc != null) return; // tests drive replay directly
    try {
      final res = await PosOfflineQueue.replay();
      if (!mounted || !res.didAnything) return;
      RenderLog.write(
        'c411_pos_replay',
        'applied=${res.applied} already=${res.alreadyApplied}',
      );
    } catch (_) {
      /* the queue survives; it will try again on the next open */
    }
  }

  // ── search ────────────────────────────────────────────────────────────────
  void _onSearchChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () => _runSearch(q));
  }

  Future<void> _runSearch(String q) async {
    final term = q.trim();
    if (term.isEmpty) {
      if (mounted) {
        setState(() {
          _results = const [];
          _searchMessage = '';
        });
      }
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await _call('pos_search', {'p_q': term, 'p_limit': 20});
      if (!mounted) return;
      final rows = _rows(res['rows']);
      setState(() {
        _results = rows;
        _searching = false;
        _searchMessage = rows.isEmpty
            ? _s(res['message']).isNotEmpty
                  ? _s(res['message'])
                  : _s(res['empty_message'])
            : '';
      });
      RenderLog.write('c411_pos_search_rows', rows.length);
    } catch (_) {
      if (mounted) setState(() => _searching = false);
    }
  }

  void _addFromRow(Map<String, dynamic> row) {
    final id = row['medicine_id'];
    final mid = id is num ? id.toInt() : int.tryParse(_s(id));
    final existing = _cart.indexWhere((l) => l.medicineId == mid);
    setState(() {
      if (existing >= 0) {
        _cart[existing].qty = _cart[existing].qty + 1;
      } else {
        _cart.add(
          PosCartLine(
            medicineId: mid,
            productName: _s(row['product_name']),
            packLabel: _s(row['pack_label']),
          ),
        );
      }
      _searchCtl.clear();
      _results = const [];
      _searchMessage = '';
    });
    _requote();
  }

  // ── the live bill ─────────────────────────────────────────────────────────
  Future<void> _requote() async {
    if (_cart.isEmpty) {
      if (mounted) setState(() => _quote = const {});
      return;
    }
    try {
      final res = await _call('pos_quote', {
        'p_lines': _cart.map((l) => l.toPayload()).toList(),
        'p_bill_discount_pct': _billDiscPct,
      });
      if (!mounted) return;
      setState(() => _quote = res);
      if (res['ok'] == true) RenderLog.write('c411_pos_quote', _cart.length);
    } catch (_) {
      /* keep the last good quote on screen */
    }
  }

  // ── save ──────────────────────────────────────────────────────────────────
  Future<void> _save() async {
    if (_cart.isEmpty || _saving) return;
    setState(() => _saving = true);

    final payload = <String, dynamic>{
      'p_client_action_id': _newActionId(),
      'p_lines': _cart.map((l) => l.toPayload()).toList(),
      'p_bill_discount_pct': _billDiscPct,
      'p_payment_mode': _payMode,
      'p_patient': {
        'name': _patientName.text.trim(),
        'phone': _patientPhone.text.trim(),
      },
    };

    // Disk FIRST, network second. A bill the operator confirmed must survive a
    // dead connection, a closed tab and a flat battery.
    if (widget.rpc == null) {
      await PosOfflineQueue.enqueue(
        PosPendingSale(
          clientActionId: _s(payload['p_client_action_id']),
          payload: payload,
          queuedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    Map<String, dynamic> res;
    try {
      res = await _call('pos_commit_sale', payload);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(_s(_labels()['saving']), queued: true);
      _resetBill();
      return;
    }

    if (!mounted) return;
    setState(() => _saving = false);

    if (res['ok'] != true) {
      if (PosReplayResult.isPermanent(res['error']) && widget.rpc == null) {
        await PosOfflineQueue.remove(_s(payload['p_client_action_id']));
      }
      _toast(_s(res['message']), isError: true);
      return;
    }

    if (widget.rpc == null) {
      await PosOfflineQueue.remove(_s(payload['p_client_action_id']));
    }
    RenderLog.write('c411_pos_sale', 1);
    _resetBill();
    if (mounted) _openReceipt(res);
  }

  void _resetBill() {
    setState(() {
      _cart.clear();
      _quote = const {};
      _billDiscPct = 0;
      _patientName.clear();
      _patientPhone.clear();
      _payMode = _s(_home?['default_payment']);
    });
  }

  void _toast(String msg, {bool isError = false, bool queued = false}) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError
            ? Ds.c.danger
            : (queued ? Ds.c.info : Ds.c.brand),
      ),
    );
  }

  void _openReceipt(Map<String, dynamic> sale) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => PosReceiptSheet(sale: sale, rpc: widget.rpc),
    );
  }

  Map<String, dynamic> _labels() => _m(_home?['labels']);

  // ── build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    if (_bootRefusal != null) return _Refusal(message: _bootRefusal!);
    if (_bootFailed) {
      return _Refusal(
        message: c('pos.boot_failed'),
        retryLabel: c('pos.retry'),
        onRetry: () {
          setState(() => _bootFailed = false);
          _boot();
        },
      );
    }
    if (_home == null) return const _BootSkeleton();

    final labels = _labels();
    final header = _m(_home!['header']);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_s(labels['title']), style: Ds.t.subtitle),
            if (_s(header['name']).isNotEmpty)
              Text(_s(header['name']), style: Ds.t.caption),
          ],
        ),
        actions: [
          // CMD #412 — the shelf, from the counter. The two are one shop: what
          // is sold here comes off there (FEFO, on pos_sale_event), so the way
          // between them is a tap. Icon and tooltip come from
          // pharmacy_stock_entry(); the button is absent when it said nothing.
          ValueListenableBuilder<Map<String, dynamic>>(
            valueListenable: StockEntry.value,
            builder: (context, entry, _) {
              if (entry['show'] != true) return const SizedBox.shrink();
              return IconButton(
                icon: Icon(StockMenuTile.icon, color: Ds.c.brand),
                tooltip: _s(entry['label']),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const PharmacyStockScreen(),
                  ),
                ),
              );
            },
          ),
          TextButton(
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => PosDayCloseScreen(rpc: widget.rpc),
              ),
            ),
            child: Text(
              _s(labels['day_close']),
              style: Ds.t.body.copyWith(color: Ds.c.brand),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  Ds.space.x16,
                  Ds.space.x16,
                  Ds.space.x16,
                  Ds.space.x24,
                ),
                children: [
                  _searchField(labels),
                  if (_results.isNotEmpty || _searchMessage.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x12),
                    _resultsCard(),
                  ],
                  SizedBox(height: Ds.space.x24),
                  _cartCard(labels),
                  if (_cart.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x24),
                    _patientCard(labels),
                    SizedBox(height: Ds.space.x24),
                    _totalsCard(labels),
                  ],
                ],
              ),
            ),
            if (_cart.isNotEmpty) _saveBar(labels),
          ],
        ),
      ),
    );
  }

  Widget _searchField(Map<String, dynamic> labels) => TextField(
    controller: _searchCtl,
    autofocus: true,
    textInputAction: TextInputAction.search,
    onChanged: _onSearchChanged,
    onSubmitted: _runSearch,
    style: Ds.t.body,
    decoration: InputDecoration(
      hintText: _s(labels['search_hint']),
      hintStyle: Ds.t.caption,
      prefixIcon: Icon(Icons.search, color: Ds.c.textSecondary),
      suffixIcon: _searching
          ? Padding(
              padding: EdgeInsets.all(Ds.space.x12),
              child: SizedBox(
                width: Ds.space.x16,
                height: Ds.space.x16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Ds.c.brand,
                ),
              ),
            )
          : null,
      filled: true,
      fillColor: Ds.c.surface,
      border: OutlineInputBorder(
        borderRadius: Ds.r.rButton,
        borderSide: BorderSide(color: Ds.c.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: Ds.r.rButton,
        borderSide: BorderSide(color: Ds.c.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: Ds.r.rButton,
        borderSide: BorderSide(color: Ds.c.brand),
      ),
    ),
  );

  Widget _resultsCard() {
    if (_results.isEmpty) {
      return _Card(child: Text(_searchMessage, style: Ds.t.bodySecondary));
    }
    return _Card(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(
        children: [
          for (final row in _results)
            InkWell(
              onTap: () => _addFromRow(row),
              child: Container(
                constraints: BoxConstraints(
                  minHeight: Ds.touch.listRowMinHeight,
                ),
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16,
                  vertical: Ds.space.x12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_s(row['product_name']), style: Ds.t.body),
                          if (_s(row['pack_label']).isNotEmpty)
                            Text(_s(row['pack_label']), style: Ds.t.caption),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(_s(row['mrp_display']), style: Ds.t.bodyStrong),
                        Text(_s(row['gst_label']), style: Ds.t.caption),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _cartCard(Map<String, dynamic> labels) {
    if (_cart.isEmpty) {
      return _Card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(labels['cart_empty']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x4),
            Text(_s(labels['cart_empty_hint']), style: Ds.t.caption),
          ],
        ),
      );
    }

    final quoteLines = _rows(_quote['lines']);
    return _Card(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(
        children: [
          for (var i = 0; i < _cart.length; i++)
            _cartRow(
              i,
              i < quoteLines.length ? quoteLines[i] : const {},
              labels,
            ),
        ],
      ),
    );
  }

  Widget _cartRow(
    int i,
    Map<String, dynamic> priced,
    Map<String, dynamic> labels,
  ) {
    final line = _cart[i];
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x16,
        vertical: Ds.space.x12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(line.productName, style: Ds.t.body)),
              SizedBox(width: Ds.space.x8),
              Text(_s(priced['amount_display']), style: Ds.t.bodyStrong),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              _stepper(labels, line),
              SizedBox(width: Ds.space.x12),
              if (_s(priced['mrp_display']).isNotEmpty)
                Text(_s(priced['mrp_display']), style: Ds.t.caption),
              const Spacer(),
              IconButton(
                tooltip: _s(labels['remove']),
                onPressed: () {
                  setState(() => _cart.removeAt(i));
                  _requote();
                },
                icon: Icon(Icons.delete_outline, color: Ds.c.danger),
                constraints: BoxConstraints(
                  minWidth: Ds.touch.minTarget,
                  minHeight: Ds.touch.minTarget,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stepper(Map<String, dynamic> labels, PosCartLine line) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('${_s(labels['qty'])} ', style: Ds.t.caption),
      _qtyButton(Icons.remove, () {
        if (line.qty <= 1) return;
        setState(() => line.qty = line.qty - 1);
        _requote();
      }),
      Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        child: Text('${line.qty}', style: Ds.t.bodyStrong),
      ),
      _qtyButton(Icons.add, () {
        setState(() => line.qty = line.qty + 1);
        _requote();
      }),
    ],
  );

  Widget _qtyButton(IconData icon, VoidCallback onTap) => InkWell(
    onTap: onTap,
    borderRadius: Ds.r.rButton,
    child: Container(
      width: Ds.touch.minTarget,
      height: Ds.touch.minTarget,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: Ds.r.rButton,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Icon(icon, size: Ds.t.bodySize, color: Ds.c.text),
    ),
  );

  Widget _patientCard(Map<String, dynamic> labels) => _Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _field(_patientName, _s(labels['patient_name'])),
        SizedBox(height: Ds.space.x12),
        _field(_patientPhone, _s(labels['patient_phone']), digits: true),
        SizedBox(height: Ds.space.x16),
        Text(_s(labels['pay']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final mode in _rows(_home?['payment_modes']))
              ChoiceChip(
                label: Text(_s(mode['label'])),
                selected: _payMode == _s(mode['key']),
                onSelected: (_) => setState(() => _payMode = _s(mode['key'])),
                labelStyle: Ds.t.body,
                selectedColor: Ds.c.brandSoft,
                backgroundColor: Ds.c.bg,
              ),
          ],
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController ctl,
    String label, {
    bool digits = false,
  }) => TextField(
    controller: ctl,
    style: Ds.t.body,
    keyboardType: digits ? TextInputType.phone : TextInputType.text,
    inputFormatters: digits ? [FilteringTextInputFormatter.digitsOnly] : null,
    decoration: InputDecoration(
      labelText: label,
      labelStyle: Ds.t.caption,
      isDense: true,
      border: OutlineInputBorder(borderRadius: Ds.r.rButton),
    ),
  );

  Widget _totalsCard(Map<String, dynamic> labels) {
    if (_quote['ok'] != true) {
      final msg = _s(_quote['message']);
      if (msg.isEmpty) return const SizedBox.shrink();
      return _Card(
        child: Text(msg, style: Ds.t.body.copyWith(color: Ds.c.danger)),
      );
    }
    final t = _m(_quote['totals']);
    return _Card(
      child: Column(
        children: [
          _totalRow(_s(labels['gross']), _s(t['gross_display'])),
          if (t['has_line_discount'] == true)
            _totalRow(
              _s(labels['line_discount']),
              _s(t['line_discount_display']),
            ),
          if (t['has_bill_discount'] == true)
            _totalRow(
              _s(labels['bill_discount']),
              _s(t['bill_discount_display']),
            ),
          _totalRow(_s(labels['taxable']), _s(t['taxable_display'])),
          _totalRow(_s(labels['cgst']), _s(t['cgst_display'])),
          _totalRow(_s(labels['sgst']), _s(t['sgst_display'])),
          if (t['has_round_off'] == true)
            _totalRow(_s(labels['round_off']), _s(t['round_off_display'])),
          Divider(color: Ds.c.divider),
          _totalRow(_s(labels['net']), _s(t['net_display']), strong: true),
          SizedBox(height: Ds.space.x8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(_s(t['mrp_note']), style: Ds.t.caption),
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, String value, {bool strong = false}) =>
      Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: strong ? Ds.t.bodyStrong : Ds.t.bodySecondary,
              ),
            ),
            Text(value, style: strong ? Ds.t.subtitle : Ds.t.body),
          ],
        ),
      );

  Widget _saveBar(Map<String, dynamic> labels) {
    final t = _m(_quote['totals']);
    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        boxShadow: Ds.elevation.e2,
        border: Border(top: BorderSide(color: Ds.c.divider)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: Ds.touch.minTarget,
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Ds.c.brand,
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            onPressed: _saving ? null : _save,
            child: Text(
              _saving
                  ? _s(labels['saving'])
                  : '${_s(labels['save'])}  ${_s(t['net_display'])}',
              style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface),
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE RECEIPT — print or WhatsApp, on the backend's own bucket + path
// ═══════════════════════════════════════════════════════════════════════════
class PosReceiptSheet extends StatefulWidget {
  final Map<String, dynamic> sale;
  final PosRpc? rpc;
  const PosReceiptSheet({super.key, required this.sale, this.rpc});

  @override
  State<PosReceiptSheet> createState() => _PosReceiptSheetState();
}

class _PosReceiptSheetState extends State<PosReceiptSheet> {
  late Map<String, dynamic> _sale;
  Timer? _poll;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : PosApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _sale = widget.sale;
    RenderLog.write('c411_pos_receipt', 1);
    _schedulePoll();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// The backend says how long to wait before asking again. This screen never
  /// invents an interval and never decides the invoice has failed on its own.
  void _schedulePoll() {
    final receipt = _m(_sale['receipt']);
    if (receipt['is_building'] != true) return;
    final ms = receipt['poll_ms'];
    _poll?.cancel();
    _poll = Timer(
      Duration(milliseconds: ms is num ? ms.toInt() : 1500),
      () async {
        final id = _s(_sale['sale_id']);
        if (id.isEmpty) return;
        try {
          final res = await _call('pos_sale_detail', {'p_sale_id': id});
          if (!mounted || res['ok'] != true) return;
          setState(() => _sale = res);
          _schedulePoll();
        } catch (_) {
          /* the sheet keeps what it has */
        }
      },
    );
  }

  Future<void> _open() async {
    final receipt = _m(_sale['receipt']);
    final exp = receipt['expires_s'];
    final url = await PosApi.signedUrl(
      _s(receipt['bucket']),
      _s(receipt['path']),
      expiresIn: exp is num ? exp.toInt() : 300,
    );
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _whatsapp() async {
    final invoice = _m(_sale['invoice']);
    final res = await _call('pos_invoice_wa', {
      'p_sale_id': _s(_sale['sale_id']),
      'p_phone': _s(invoice['patient_phone']),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_s(res['message'])),
        backgroundColor: res['ok'] == true ? Ds.c.brand : Ds.c.danger,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final invoice = _m(_sale['invoice']);
    final totals = _m(_sale['totals']);
    final receipt = _m(_sale['receipt']);
    final ready = receipt['is_ready'] == true;

    return Padding(
      padding: EdgeInsets.all(Ds.space.x24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(invoice['number_label']), style: Ds.t.title),
          SizedBox(height: Ds.space.x4),
          Text(_s(invoice['date_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          Row(
            children: [
              Expanded(
                child: Text(_s(totals['net_display']), style: Ds.t.display),
              ),
              Chip(
                label: Text(_s(invoice['payment_label']), style: Ds.t.caption),
                backgroundColor: Ds.c.brandSoft,
                side: BorderSide.none,
              ),
            ],
          ),
          if (_s(totals['net_words']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(totals['net_words']), style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x24),
          Text(_s(receipt['message']), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: OutlinedButton.icon(
                    onPressed: ready ? _open : null,
                    icon: const Icon(Icons.print_outlined),
                    label: Text(_s(receipt['print_label'])),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Ds.c.brand,
                      side: BorderSide(color: Ds.c.brand),
                      shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton.icon(
                    onPressed: ready ? _whatsapp : null,
                    icon: const Icon(Icons.chat_outlined),
                    label: Text(_s(receipt['whatsapp_label'])),
                    style: FilledButton.styleFrom(
                      backgroundColor: Ds.c.brand,
                      shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DAY CLOSE — how many bills, how much, and how it was paid
// ═══════════════════════════════════════════════════════════════════════════
class PosDayCloseScreen extends StatefulWidget {
  final PosRpc? rpc;
  const PosDayCloseScreen({super.key, this.rpc});

  @override
  State<PosDayCloseScreen> createState() => _PosDayCloseScreenState();
}

class _PosDayCloseScreenState extends State<PosDayCloseScreen> {
  Map<String, dynamic>? _day;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = widget.rpc != null
          ? await widget.rpc!('pos_day_close', const {})
          : await PosApi.dayClose();
      if (mounted) setState(() => _day = res);
      RenderLog.write('c411_pos_day_close', 1);
    } catch (_) {
      /* leave the skeleton up */
    }
  }

  @override
  Widget build(BuildContext context) {
    final day = _day;
    if (day == null) return const _BootSkeleton();
    if (day['ok'] != true) return _Refusal(message: _s(day['message']));

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_s(day['title']), style: Ds.t.subtitle),
            Text(_s(day['date_label']), style: Ds.t.caption),
          ],
        ),
      ),
      body: ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          Row(
            children: [
              for (final tile in _rows(day['tiles'])) ...[
                Expanded(
                  child: _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s(tile['label']), style: Ds.t.caption),
                        SizedBox(height: Ds.space.x4),
                        Text(_s(tile['value']), style: Ds.t.subtitle),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x8),
              ],
            ],
          ),
          SizedBox(height: Ds.space.x24),
          _Card(
            child: Column(
              children: [
                for (final split in _rows(day['splits']))
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_s(split['label']), style: Ds.t.body),
                        ),
                        Text(_s(split['bills_label']), style: Ds.t.caption),
                        SizedBox(width: Ds.space.x12),
                        Text(
                          _s(split['amount_display']),
                          style: Ds.t.bodyStrong,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (day['has_any'] != true) ...[
            SizedBox(height: Ds.space.x24),
            _Card(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_s(day['empty_message']), style: Ds.t.bodyStrong),
                  SizedBox(height: Ds.space.x4),
                  Text(_s(day['empty_hint']), style: Ds.t.caption),
                ],
              ),
            ),
          ],
          if (_rows(day['recent']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x24),
            _Card(
              padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
              child: Column(
                children: [
                  for (final r in _rows(day['recent']))
                    Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x16,
                        vertical: Ds.space.x12,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_s(r['invoice_no']), style: Ds.t.body),
                                Text(
                                  '${_s(r['time_label'])} · ${_s(r['payment_label'])}',
                                  style: Ds.t.caption,
                                ),
                              ],
                            ),
                          ),
                          Text(_s(r['net_display']), style: Ds.t.bodyStrong),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared chrome
// ═══════════════════════════════════════════════════════════════════════════
class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  const _Card({required this.child, this.padding});

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: padding ?? EdgeInsets.all(Ds.space.x16),
    decoration: BoxDecoration(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      boxShadow: Ds.elevation.e1,
    ),
    child: child,
  );
}

class _BootSkeleton extends StatelessWidget {
  const _BootSkeleton();

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Ds.c.bg,
    body: ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        for (var i = 0; i < 4; i++)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x16),
            child: Container(
              height: Ds.space.x48,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
          ),
      ],
    ),
  );
}

/// The backend's own refusal, printed. No Dart copy, no role test.
///
/// A Retry appears ONLY when asking again could actually help: a request that
/// never landed. A refusal like "the counter is available on a pharmacy
/// account" is an ANSWER, and offering to ask it again would be a lie.
class _Refusal extends StatelessWidget {
  final String message;
  final String? retryLabel;
  final VoidCallback? onRetry;
  const _Refusal({required this.message, this.retryLabel, this.onRetry});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Ds.c.bg,
    appBar: AppBar(
      backgroundColor: Ds.c.surface,
      surfaceTintColor: Ds.c.surface,
    ),
    body: Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: Ds.t.bodySecondary,
            ),
            if (onRetry != null && (retryLabel ?? '').isNotEmpty) ...[
              SizedBox(height: Ds.space.x24),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Ds.c.brand,
                    side: BorderSide(color: Ds.c.brand),
                    shape: RoundedRectangleBorder(
                      borderRadius: Ds.r.rButton,
                    ),
                  ),
                  child: Text(retryLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// The counter's entry point, drawn wherever an account menu is shown.
///
/// Renders NOTHING unless `pos_entry()` said `show:true` — so a supplier, a
/// rider or an admin never sees it, and this widget makes no role test of its
/// own to decide that. The label and the icon are the payload's too.
class PosMenuTile extends StatelessWidget {
  /// Called before navigating, so a bottom sheet can close itself first.
  final VoidCallback? onBeforeOpen;
  const PosMenuTile({super.key, this.onBeforeOpen});

  static IconData get _icon => Icons.point_of_sale_outlined;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, dynamic>>(
        valueListenable: PosEntry.value,
        builder: (context, entry, _) {
          if (entry['show'] != true) return const SizedBox.shrink();
          RenderLog.write('c411_pos_entry_tile', 1);
          return InkWell(
            onTap: () {
              onBeforeOpen?.call();
              Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const PosScreen()),
              );
            },
            borderRadius: Ds.r.rButton,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x4,
                vertical: Ds.space.x12,
              ),
              child: Row(
                children: [
                  Icon(_icon, size: Ds.t.subtitleSize, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(_s(entry['label']), style: Ds.t.bodyStrong),
                        if (_s(entry['sub_label']).isNotEmpty)
                          Text(_s(entry['sub_label']), style: Ds.t.caption),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
}
