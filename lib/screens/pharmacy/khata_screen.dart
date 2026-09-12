// CMD #415 — the khata book (patient / doctor udhaar).
//
// Every pharmacy already runs this ledger: a paper diary by the till with a
// name, a date and a running figure nobody reconciles. This is that diary, with
// the two things paper cannot do — it knows how OLD each balance is, and it can
// ask for the money by itself.
//
// THIS FILE ADDS UP NOTHING. Every rupee, every age sentence ("20 days old"),
// every tone, every reminder word, every plural and every empty state is a
// finished string from `khata_home()` / `khata_account_detail()` /
// `khata_reminder_compose()`. A balance is `balance_display`; the screen never
// sees a number it has to format, and never decides that an account is overdue.
//
// The reminder preview is deliberately the SAME string the collector sends —
// `khata_reminder_compose()` composes it once and both the preview and
// `_khata_send` read it, so what the pharmacist reads before tapping Send is
// what the patient receives.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../widgets/pos_upi_qr_card.dart';
import '../../services/khata_api.dart';
import '../../utils/render_log.dart';

String _s(Object? v) => v == null ? '' : v.toString();
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

String _newActionId() {
  final r = Random.secure();
  String h(int n) =>
      List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
  return '${h(8)}-${h(4)}-4${h(3)}-'
      '${(8 + r.nextInt(4)).toRadixString(16)}${h(3)}-${h(12)}';
}

/// The backend names a tone; this maps the NAME to the theme. It never decides
/// which tone a row gets — that is `_khata_acct_json`'s job, from the age and
/// the balance.
Color _toneColor(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    default:
      return Ds.c.info;
  }
}

Color _toneSoft(String tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    default:
      return Ds.c.infoSoft;
  }
}

BoxDecoration _card() => BoxDecoration(
  color: Ds.c.surface,
  borderRadius: Ds.r.rCard,
  boxShadow: Ds.elevation.e1,
);

class KhataScreen extends StatefulWidget {
  const KhataScreen({super.key, this.rpc});

  /// Tests hand a payload instead of a network.
  final KhataRpc? rpc;

  @override
  State<KhataScreen> createState() => _KhataScreenState();
}

class _KhataScreenState extends State<KhataScreen> {
  Map<String, dynamic> _home = const {};
  String _refusal = '';
  bool _failed = false;
  bool _loading = true;
  String _filter = 'due';
  String _query = '';
  Timer? _debounce;
  final TextEditingController _search = TextEditingController();

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : KhataApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final res = await _call('khata_home', {
        'p_filter': _filter,
        if (_query.isNotEmpty) 'p_q': _query,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _refusal = _s(res['message']);
          _loading = false;
        });
        RenderLog.write('c415_khata_denied', 1);
        return;
      }
      setState(() {
        _home = res;
        _loading = false;
        _failed = false;
      });
      RenderLog.write('c415_khata_home', 1);
      RenderLog.write('c415_khata_accounts', _rows(res['accounts']).length);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  void _onSearch(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      _query = q.trim();
      _boot();
    });
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = _m(_home['labels']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
          _s(labels['title']).isEmpty
              ? _s(_home['shop_name'])
              : _s(labels['title']),
        ),
        actions: [
          if (_home.isNotEmpty)
            IconButton(
              tooltip: _s(labels['settings']),
              icon: const Icon(Icons.tune),
              onPressed: _openSettings,
            ),
        ],
      ),
      floatingActionButton: _home.isEmpty
          ? null
          : FloatingActionButton.extended(
              backgroundColor: Ds.c.brand,
              foregroundColor: Ds.c.surface,
              onPressed: () => _openAccountSheet(null),
              icon: const Icon(Icons.person_add_alt),
              label: Text(_s(labels['add'])),
            ),
      body: _body(labels),
    );
  }

  Widget _body(Map<String, dynamic> labels) {
    if (_loading) return const _Skeleton();
    if (_refusal.isNotEmpty) return _Refusal(message: _refusal);
    if (_failed) {
      return _Refusal(
        message: _s(labels['load_failed']),
        retryLabel: _s(labels['retry']),
        onRetry: () {
          setState(() => _loading = true);
          _boot();
        },
      );
    }

    final accounts = _rows(_home['accounts']);
    final totals = _m(_home['totals']);
    final empty = _m(_home['empty']);

    return RefreshIndicator(
      onRefresh: _boot,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x48 + Ds.space.x32,
        ),
        children: [
          _totalsCard(totals, labels),
          SizedBox(height: Ds.space.x24),
          _collectorCard(),
          SizedBox(height: Ds.space.x24),
          _searchField(labels),
          SizedBox(height: Ds.space.x12),
          _filterRow(),
          SizedBox(height: Ds.space.x16),
          if (accounts.isEmpty)
            _EmptyState(title: _s(empty['title']), hint: _s(empty['hint']))
          else
            ...accounts.map(_accountTile),
        ],
      ),
    );
  }

  Widget _totalsCard(Map<String, dynamic> totals, Map<String, dynamic> labels) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(labels['outstanding']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(
            _s(totals['outstanding_display']),
            style: Ds.t.display.copyWith(color: Ds.c.brand),
          ),
          SizedBox(height: Ds.space.x8),
          Text(
            '${_s(totals['accounts_label'])} · ${_s(totals['due_label'])}',
            style: Ds.t.caption,
          ),
        ],
      ),
    );
  }

  Widget _collectorCard() {
    final col = _m(_home['collector']);
    if (col.isEmpty) return const SizedBox.shrink();
    final upi = _m(col['upi']);
    final tone = _s(col['status_tone']);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: _card(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(col['title']), style: Ds.t.subtitle)),
              Switch(
                value: col['enabled'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: (v) => _saveSettings({'enabled': v}),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Container(
            width: double.infinity,
            padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12,
              vertical: Ds.space.x8,
            ),
            decoration: BoxDecoration(
              color: _toneSoft(tone),
              borderRadius: Ds.r.rChip,
            ),
            child: Text(
              _s(col['status_label']),
              style: Ds.t.caption.copyWith(color: _toneColor(tone)),
            ),
          ),
          SizedBox(height: Ds.space.x12),
          Text(_s(upi['label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                  _s(upi['vpa']).isEmpty ? _s(upi['hint']) : _s(upi['vpa']),
                  style: _s(upi['vpa']).isEmpty
                      ? Ds.t.caption
                      : Ds.t.bodyStrong,
                ),
              ),
              SizedBox(width: Ds.space.x8),
              TextButton(
                onPressed: _openUpiSheet,
                child: Text(
                  upi['verified'] == true
                      ? _s(upi['set_label'])
                      : _s(upi['set_label']),
                ),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(col['sent_today_label']), style: Ds.t.caption),
        ],
      ),
    );
  }

  Widget _searchField(Map<String, dynamic> labels) {
    return TextField(
      controller: _search,
      onChanged: _onSearch,
      decoration: InputDecoration(
        hintText: _s(labels['search_hint']),
        prefixIcon: const Icon(Icons.search),
        isDense: true,
      ),
    );
  }

  Widget _filterRow() {
    final filters = _rows(_home['filters']);
    if (filters.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Ds.space.x8,
      children: filters.map((f) {
        final sel = f['selected'] == true;
        return ChoiceChip(
          label: Text(_s(f['label'])),
          selected: sel,
          selectedColor: Ds.c.brandSoft,
          onSelected: (_) {
            _filter = _s(f['key']);
            setState(() => _loading = true);
            _boot();
          },
        );
      }).toList(),
    );
  }

  Widget _accountTile(Map<String, dynamic> a) {
    final tone = _s(a['tone']);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Material(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () => _openAccount(_s(a['id'])),
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.all(Ds.space.x16),
            decoration: _card(),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_s(a['name']), style: Ds.t.bodyStrong),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        '${_s(a['kind_label'])} · ${_s(a['phone_display'])}',
                        style: Ds.t.caption,
                      ),
                      if (_s(a['age_label']).isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(
                          _s(a['age_label']),
                          style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                        ),
                      ],
                      if (_s(a['limit_warning']).isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(
                          _s(a['limit_warning']),
                          style: Ds.t.caption.copyWith(color: Ds.c.danger),
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Text(
                  _s(a['balance_display']),
                  style: Ds.t.subtitle.copyWith(color: _toneColor(tone)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openAccount(String id) async {
    if (id.isEmpty) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => KhataAccountScreen(accountId: id, rpc: widget.rpc),
      ),
    );
    if (mounted) _boot();
  }

  Future<void> _saveSettings(Map<String, dynamic> patch) async {
    final res = await _call('khata_settings_save', {'p_patch': patch});
    if (!mounted) return;
    _toast(_s(res['message']));
    _boot();
  }

  Future<void> _openSettings() async {
    final col = _m(_home['collector']);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _SettingsSheet(
        collector: col,
        labels: _m(_home['labels']),
        onSave: _saveSettings,
      ),
    );
  }

  Future<void> _openUpiSheet() async {
    final col = _m(_home['collector']);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _UpiSheet(
        upi: _m(col['upi']),
        call: _call,
        onDone: (msg) {
          _toast(msg);
          _boot();
        },
      ),
    );
  }

  Future<void> _openAccountSheet(Map<String, dynamic>? existing) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _AccountSheet(
        labels: _m(_home['labels']),
        kinds: _rows(_home['kinds']),
        existing: existing,
        call: _call,
        onDone: (msg) {
          _toast(msg);
          _boot();
        },
      ),
    );
  }
}

// ── one account: the statement, the payment, the reminder ───────────────────
class KhataAccountScreen extends StatefulWidget {
  const KhataAccountScreen({super.key, required this.accountId, this.rpc});

  final String accountId;
  final KhataRpc? rpc;

  @override
  State<KhataAccountScreen> createState() => _KhataAccountScreenState();
}

class _KhataAccountScreenState extends State<KhataAccountScreen> {
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  bool _failed = false;
  String _refusal = '';
  bool _busy = false;

  Future<Map<String, dynamic>> _call(String fn, Map<String, dynamic> p) =>
      widget.rpc != null ? widget.rpc!(fn, p) : KhataApi.call(fn, p);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await _call('khata_account_detail', {
        'p_account_id': widget.accountId,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _refusal = _s(res['message']);
          _loading = false;
        });
        return;
      }
      setState(() {
        _data = res;
        _loading = false;
        _failed = false;
      });
      RenderLog.write('c415_khata_account', 1);
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final labels = _m(_data['labels']);
    final acct = _m(_data['account']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(acct['name']))),
      body: _body(labels, acct),
    );
  }

  Widget _body(Map<String, dynamic> labels, Map<String, dynamic> acct) {
    if (_loading) return const _Skeleton();
    if (_refusal.isNotEmpty) return _Refusal(message: _refusal);
    if (_failed) {
      return _Refusal(
        message: _s(labels['load_failed']),
        retryLabel: _s(labels['retry']),
        onRetry: () {
          setState(() => _loading = true);
          _load();
        },
      );
    }

    final lines = _rows(_data['lines']);
    final tone = _s(acct['tone']);
    final empty = _m(_data['empty']);

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: _card(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _s(acct['balance_display']),
                style: Ds.t.display.copyWith(color: _toneColor(tone)),
              ),
              SizedBox(height: Ds.space.x4),
              Text(
                '${_s(acct['kind_label'])} · ${_s(acct['phone_display'])}',
                style: Ds.t.caption,
              ),
              if (_s(acct['age_label']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(
                  _s(acct['age_label']),
                  style: Ds.t.caption.copyWith(color: _toneColor(tone)),
                ),
              ],
              if (_s(acct['last_payment_label']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x4),
                Text(_s(acct['last_payment_label']), style: Ds.t.caption),
              ],
              if (_s(acct['limit_warning']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(
                  _s(acct['limit_warning']),
                  style: Ds.t.caption.copyWith(color: Ds.c.danger),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Ds.c.brand,
              foregroundColor: Ds.c.surface,
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
            ),
            onPressed: _busy ? null : _openPayment,
            child: Text(_s(labels['record_payment'])),
          ),
        ),
        SizedBox(height: Ds.space.x8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _busy ? null : _statement,
                child: Text(_s(labels['statement_btn'])),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: OutlinedButton(
                onPressed: _data['can_remind'] == true && !_busy
                    ? _remind
                    : null,
                child: Text(_s(labels['remind'])),
              ),
            ),
          ],
        ),
        SizedBox(height: Ds.space.x24),
        Text(_s(labels['statement']), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x8),
        if (lines.isEmpty)
          _EmptyState(title: _s(empty['title']), hint: '')
        else
          ...lines.map((e) => _entryTile(e, labels)),
      ],
    );
  }

  Widget _entryTile(Map<String, dynamic> e, Map<String, dynamic> labels) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: _card(),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(e['type_label']), style: Ds.t.bodyStrong),
                SizedBox(height: Ds.space.x4),
                Text(
                  [
                    _s(e['date_label']),
                    if (_s(e['note']).isNotEmpty) _s(e['note']),
                    if (_s(e['method_label']).isNotEmpty) _s(e['method_label']),
                  ].join(' · '),
                  style: Ds.t.caption,
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _s(e['amount_display']),
                style: Ds.t.bodyStrong.copyWith(
                  color: _toneColor(_s(e['tone'])),
                ),
              ),
              SizedBox(height: Ds.space.x4),
              Text(_s(e['balance_display']), style: Ds.t.caption),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openPayment() async {
    final labels = _m(_data['labels']);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _PaymentSheet(
        accountId: widget.accountId,
        labels: labels,
        methods: _rows(_data['methods']),
        // CMD #432 — the settlement QR. khata_account_detail() already carries
        // the shop's UPI block for THIS balance, built by the same
        // upi_qr_string() the counter's bills use, so the patient scans the
        // same picture whether they are settling a khata or paying a bill.
        upi: _m(_data['upi']),
        call: _call,
        onDone: (msg) {
          _toast(msg);
          _load();
        },
      ),
    );
  }

  /// Ask for the statement, then poll on the BACKEND's own `poll_ms`. The
  /// screen never invents a timeout and never builds a URL — it opens the
  /// bucket + path the backend named.
  Future<void> _statement() async {
    setState(() => _busy = true);
    try {
      var res = await _call('khata_statement_request', {
        'p_account_id': widget.accountId,
      });
      if (res['ok'] != true) {
        _toast(_s(res['message']));
        return;
      }
      final id = _s(res['statement_id']);
      var guard = 0;
      while (_s(res['status']) == 'building' && guard < 20 && mounted) {
        final ms = (res['poll_ms'] is num)
            ? (res['poll_ms'] as num).toInt()
            : 1500;
        await Future<void>.delayed(Duration(milliseconds: ms));
        res = await _call('khata_statement_status', {'p_statement_id': id});
        guard++;
      }
      if (!mounted) return;
      if (_s(res['status']) != 'ready') {
        _toast(_s(res['message']));
        return;
      }
      final url = await KhataApi.signedUrl(
        _s(res['bucket']),
        _s(res['path']),
        expiresIn: (res['expires_s'] is num)
            ? (res['expires_s'] as num).toInt()
            : 300,
      );
      if (url.isNotEmpty) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      if (!mounted) return;
      final send = await _call('khata_statement_wa', {'p_statement_id': id});
      _toast(_s(send['message']));
    } catch (_) {
      _toast(_s(_m(_data['labels'])['load_failed']));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Preview first, always. The pharmacist reads the exact sentence the patient
  /// will read, and the UPI link inside it, before anything is sent.
  Future<void> _remind() async {
    setState(() => _busy = true);
    try {
      final preview = await _call('khata_reminder_compose', {
        'p_account_id': widget.accountId,
      });
      if (!mounted) return;
      if (preview['ok'] != true) {
        _toast(_s(preview['message']));
        return;
      }
      final labels = _m(_data['labels']);
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: Ds.c.surface,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
          title: Text(_s(preview['stage_label']), style: Ds.t.subtitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(preview['preview_label']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x8),
              Text(_s(preview['body']), style: Ds.t.body),
              if (_s(preview['blocked_reason']).isNotEmpty) ...[
                SizedBox(height: Ds.space.x8),
                Text(
                  _s(preview['blocked_reason']),
                  style: Ds.t.caption.copyWith(color: Ds.c.danger),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(_s(labels['cancel'])),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
              onPressed: preview['can_send'] == true
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: Text(_s(labels['remind'])),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
      final res = await _call('khata_remind_now', {
        'p_account_id': widget.accountId,
      });
      if (!mounted) return;
      _toast(_s(res['message']));
      _load();
    } catch (_) {
      _toast(_s(_m(_data['labels'])['load_failed']));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ── sheets ──────────────────────────────────────────────────────────────────
class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({
    required this.accountId,
    required this.labels,
    required this.methods,
    required this.upi,
    required this.call,
    required this.onDone,
  });

  final String accountId;
  final Map<String, dynamic> labels;
  final List<Map<String, dynamic>> methods;
  final Map<String, dynamic> upi;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final void Function(String) onDone;

  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final TextEditingController _amount = TextEditingController();
  final TextEditingController _note = TextEditingController();
  String _method = '';
  bool _busy = false;
  String _error = '';
  late final String _actionId = _newActionId();

  @override
  void initState() {
    super.initState();
    if (widget.methods.isNotEmpty) _method = _s(widget.methods.first['key']);
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final amt = num.tryParse(_amount.text.trim());
    if (amt == null) return;
    setState(() => _busy = true);
    try {
      final res = await widget.call('khata_entry_add', {
        'p_account_id': widget.accountId,
        'p_type': 'payment',
        'p_amount': amt,
        'p_method': _method,
        if (_note.text.trim().isNotEmpty) 'p_note': _note.text.trim(),
        'p_client_action_id': _actionId,
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _error = _s(res['message']);
          _busy = false;
        });
        return;
      }
      Navigator.pop(context);
      widget.onDone(_s(res['message']));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_s(widget.labels['record_payment']), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              autofocus: true,
              decoration: InputDecoration(
                labelText: _s(widget.labels['amount']),
                isDense: true,
              ),
            ),
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              children: widget.methods.map((m) {
                final k = _s(m['key']);
                return ChoiceChip(
                  label: Text(_s(m['label'])),
                  selected: _method == k,
                  selectedColor: Ds.c.brandSoft,
                  onSelected: (_) => setState(() => _method = k),
                );
              }).toList(),
            ),
            if (_method == 'upi' && widget.upi['has'] == true) ...[
              SizedBox(height: Ds.space.x16),
              UpiQrCard(
                view: UpiQrView(
                  has: true,
                  title: _s(widget.upi['qr_caption']),
                  qrString: _s(widget.upi['qr_string']),
                  vpa: _s(widget.upi['vpa']),
                  payee: _s(widget.upi['payee']),
                  rows: [
                    {
                      'label': _s(widget.labels['amount']),
                      'value': _s(widget.upi['amount_display']),
                      'strong': true,
                    },
                    {
                      'label': _s(widget.upi['label']),
                      'value': _s(widget.upi['vpa']),
                      'strong': false,
                    },
                  ],
                ),
                size: 180,
              ),
            ],
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _note,
              decoration: InputDecoration(
                labelText: _s(widget.labels['note']),
                isDense: true,
              ),
            ),
            if (_error.isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
            ],
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  foregroundColor: Ds.c.surface,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: _busy ? null : _save,
                child: Text(_s(widget.labels['save'])),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccountSheet extends StatefulWidget {
  const _AccountSheet({
    required this.labels,
    required this.kinds,
    required this.existing,
    required this.call,
    required this.onDone,
  });

  final Map<String, dynamic> labels;
  final List<Map<String, dynamic>> kinds;
  final Map<String, dynamic>? existing;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final void Function(String) onDone;

  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _limit = TextEditingController();
  String _kind = 'patient';
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _name.text = _s(e['name']);
      _phone.text = _s(e['phone']);
      _kind = _s(e['kind']).isEmpty ? 'patient' : _s(e['kind']);
    } else if (widget.kinds.isNotEmpty) {
      _kind = _s(widget.kinds.first['key']);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _limit.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await widget.call('khata_account_upsert', {
        if (widget.existing != null) 'p_id': _s(widget.existing!['id']),
        'p_name': _name.text.trim(),
        'p_phone': _phone.text.trim(),
        'p_kind': _kind,
        if (num.tryParse(_limit.text.trim()) != null)
          'p_limit': num.parse(_limit.text.trim()),
      });
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _error = _s(res['message']);
          _busy = false;
        });
        return;
      }
      Navigator.pop(context);
      widget.onDone(_s(res['message']));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(widget.labels['add']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          Wrap(
            spacing: Ds.space.x8,
            children: widget.kinds.map((k) {
              final key = _s(k['key']);
              return ChoiceChip(
                label: Text(_s(k['label'])),
                selected: _kind == key,
                selectedColor: Ds.c.brandSoft,
                onSelected: (_) => setState(() => _kind = key),
              );
            }).toList(),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: _s(widget.labels['name']),
              isDense: true,
            ),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: InputDecoration(
              labelText: _s(widget.labels['phone']),
              isDense: true,
            ),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _limit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: _s(widget.labels['limit']),
              isDense: true,
            ),
          ),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: _busy ? null : _save,
              child: Text(_s(widget.labels['save'])),
            ),
          ),
        ],
      ),
    );
  }
}

/// Save, then CONFIRM. Two steps on purpose: an unconfirmed VPA never ships in
/// a reminder, because a reminder that sends money to a typo is worse than no
/// reminder at all.
class _UpiSheet extends StatefulWidget {
  const _UpiSheet({
    required this.upi,
    required this.call,
    required this.onDone,
  });

  final Map<String, dynamic> upi;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
  call;
  final void Function(String) onDone;

  @override
  State<_UpiSheet> createState() => _UpiSheetState();
}

class _UpiSheetState extends State<_UpiSheet> {
  final TextEditingController _vpa = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _busy = false;
  String _error = '';
  String _confirmPrompt = '';
  String _savedVpa = '';

  @override
  void initState() {
    super.initState();
    _vpa.text = _s(widget.upi['vpa']);
    _name.text = _s(widget.upi['name']);
  }

  @override
  void dispose() {
    _vpa.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final res = await widget.call('khata_upi_save', {
        'p_vpa': _vpa.text.trim(),
        'p_name': _name.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        if (res['ok'] != true) {
          _error = _s(res['message']);
        } else {
          _error = '';
          _savedVpa = _s(res['vpa']);
          _confirmPrompt = _s(res['confirm_prompt']);
        }
      });
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      final res = await widget.call('khata_upi_confirm', {'p_vpa': _savedVpa});
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _error = _s(res['message']);
          _busy = false;
        });
        return;
      }
      Navigator.pop(context);
      widget.onDone(_s(res['message']));
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(widget.upi['label']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x4),
          Text(_s(widget.upi['hint']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x16),
          TextField(
            controller: _vpa,
            autofocus: true,
            decoration: InputDecoration(
              labelText: _s(widget.upi['vpa_label']),
              isDense: true,
            ),
          ),
          SizedBox(height: Ds.space.x12),
          TextField(
            controller: _name,
            decoration: InputDecoration(
              labelText: _s(widget.upi['name_label']),
              isDense: true,
            ),
          ),
          if (_error.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(_error, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
          ],
          if (_confirmPrompt.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(
                _confirmPrompt,
                style: Ds.t.caption.copyWith(color: Ds.c.warning),
              ),
            ),
          ],
          SizedBox(height: Ds.space.x16),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Ds.c.brand,
                foregroundColor: Ds.c.surface,
                shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
              ),
              onPressed: _busy
                  ? null
                  : (_confirmPrompt.isEmpty ? _save : _confirm),
              child: Text(
                _confirmPrompt.isEmpty
                    ? _s(widget.upi['set_label'])
                    : _s(widget.upi['confirm_label']),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends StatelessWidget {
  const _SettingsSheet({
    required this.collector,
    required this.labels,
    required this.onSave,
  });

  final Map<String, dynamic> collector;
  final Map<String, dynamic> labels;
  final Future<void> Function(Map<String, dynamic>) onSave;

  @override
  Widget build(BuildContext context) {
    final ladder = _rows(collector['ladder']);
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(labels['settings']), style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x16),
          ...ladder.map(
            (r) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: Text(_s(r['label']), style: Ds.t.body),
            ),
          ),
          SizedBox(height: Ds.space.x8),
          Text(_s(collector['cap_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(_s(collector['quiet_label']), style: Ds.t.caption),
          SizedBox(height: Ds.space.x24),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_s(labels['save'])),
            ),
          ),
        ],
      ),
    );
  }
}

// ── shared states ───────────────────────────────────────────────────────────
class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 5,
      itemBuilder: (_, i) => Container(
        height: Ds.space.x48 + Ds.space.x24,
        margin: EdgeInsets.only(bottom: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.divider,
          borderRadius: Ds.r.rCard,
        ),
      ),
    );
  }
}

class _Refusal extends StatelessWidget {
  const _Refusal({required this.message, this.onRetry, this.retryLabel = ''});

  final String message;
  final VoidCallback? onRetry;

  /// The button's own word, separate from the sentence above it. Both are the
  /// backend's; the screen never writes either.
  final String retryLabel;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center, style: Ds.t.body),
            if (onRetry != null) ...[
              SizedBox(height: Ds.space.x16),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: Text(retryLabel),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x24),
      decoration: _card(),
      child: Column(
        children: [
          Text(title, style: Ds.t.bodyStrong, textAlign: TextAlign.center),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption, textAlign: TextAlign.center),
          ],
        ],
      ),
    );
  }
}
