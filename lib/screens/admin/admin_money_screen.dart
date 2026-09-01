// CMD #450 — THE MONEY SCREEN. Four answers that had no screen at all.
//
// feature_gaps 18, 19, 20 and 23 are one complaint told four times: the data is
// in the database, nothing ages it, and no surface shows it. So:
//
//   Owed to us       (#23) — Rs 2.8 lakh open, per customer, bucketed by age.
//   To verify        (#18) — payments waiting, OLDEST FIRST, and a missing UTR
//                            as a state with an ask, never a blank field.
//   Unattached money (#19) — money that arrived with no order, one-tap attach.
//   Supplier bills   (#20) — bills that stalled after a successful scan.
//
// THE TAB LIST IS THE BACKEND'S. admin_money_home() names the tabs, their
// labels and their badges; a tab_key this build has never heard of renders an
// empty body instead of throwing, so a fifth tab is one INSERT away and never a
// deploy. Nothing here is a Dart literal that a person reads: every rupee,
// age, plural, bucket name, tone, empty state and toast arrives finished.
//
// THIS FILE COMPUTES NOTHING. It does not add, it does not subtract, it does
// not decide what is old. `Rs 1,42,682.11`, `42 days old`, `13 open orders`,
// `Stalled 90 days` and `6 of them have no UTR` are all strings the backend
// sent.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

typedef MoneyRpc =
    Future<Map<String, dynamic>> Function(String fn, Map<String, dynamic> args);

String _s(Object? v) => v == null ? '' : v.toString();
List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const [];

Future<Map<String, dynamic>> _liveRpc(
  String fn,
  Map<String, dynamic> args,
) async {
  final raw = await Supabase.instance.client.rpc(
    fn,
    params: args.isEmpty ? null : args,
  );
  final one = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
  return one is Map ? Map<String, dynamic>.from(one) : <String, dynamic>{};
}

/// The backend's tone vocabulary, mapped onto the design tokens and nowhere
/// else. A tone this build does not know falls back to muted — never to a
/// colour picked here.
Color moneyToneColor(String tone) {
  switch (tone) {
    case 'bad':
      return Ds.c.danger;
    case 'warn':
      return Ds.c.warning;
    case 'good':
      return Ds.c.success;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color moneyToneSoft(String tone) {
  switch (tone) {
    case 'bad':
      return Ds.c.dangerSoft;
    case 'warn':
      return Ds.c.warningSoft;
    case 'good':
      return Ds.c.successSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

class AdminMoneyScreen extends StatefulWidget {
  const AdminMoneyScreen({super.key, this.rpc});

  /// Injected in tests so the screen is proven against a payload, not a network.
  final MoneyRpc? rpc;

  @override
  State<AdminMoneyScreen> createState() => _AdminMoneyScreenState();
}

class _AdminMoneyScreenState extends State<AdminMoneyScreen> {
  Map<String, dynamic> _home = const {};
  bool _loading = true;
  String _tab = '';

  MoneyRpc get _call => widget.rpc ?? _liveRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await _call('admin_money_home', const {});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'error': e.toString()};
    }
    if (!mounted) return;
    final tabs = _rows(res['tabs']);
    setState(() {
      _home = res;
      _loading = false;
      if (_tab.isEmpty && tabs.isNotEmpty) _tab = _s(tabs.first['tab_key']);
    });
    RenderLog.write('c450_money_tabs', tabs.length);
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _rows(_home['tabs']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_home['title']))),
      body: _loading
          ? const _Skeleton()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: EdgeInsets.all(Ds.space.x16),
                children: [
                  if (_s(_home['subtitle']).isNotEmpty)
                    Padding(
                      padding: EdgeInsets.only(bottom: Ds.space.x16),
                      child: Text(
                        _s(_home['subtitle']),
                        style: Ds.t.caption.copyWith(
                          color: Ds.c.textSecondary,
                        ),
                      ),
                    ),
                  _TabBar(
                    tabs: tabs,
                    active: _tab,
                    onTap: (k) => setState(() => _tab = k),
                  ),
                  SizedBox(height: Ds.space.x24),
                  // An unknown tab_key is an EMPTY body, never a throw — a tab
                  // added in the backend must not break an older build.
                  _MoneyTabBody(key: ValueKey(_tab), tabKey: _tab, rpc: _call),
                ],
              ),
            ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.active,
    required this.onTap,
  });
  final List<Map<String, dynamic>> tabs;
  final String active;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final t in tabs)
          _TabChip(
            label: _s(t['label']),
            badge: _s(t['badge']),
            badgeTone: _s(t['badge_tone']),
            selected: _s(t['tab_key']) == active,
            onTap: () => onTap(_s(t['tab_key'])),
          ),
      ],
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.label,
    required this.badge,
    required this.badgeTone,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final String badge;
  final String badgeTone;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16,
          vertical: Ds.space.x12,
        ),
        decoration: BoxDecoration(
          color: selected ? Ds.c.brand : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Ds.t.body.copyWith(
                color: selected ? Ds.c.surface : Ds.c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (badge.isNotEmpty) ...[
              SizedBox(width: Ds.space.x8),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x8,
                  vertical: Ds.space.x4,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? Ds.c.surface
                      : moneyToneSoft(badgeTone),
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  badge,
                  style: Ds.t.caption.copyWith(
                    color: selected
                        ? Ds.c.brand
                        : moneyToneColor(badgeTone),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One body per tab. The RPC each tab calls is the only thing that differs;
/// everything below renders whatever that RPC returned.
class _MoneyTabBody extends StatefulWidget {
  const _MoneyTabBody({super.key, required this.tabKey, required this.rpc});
  final String tabKey;
  final MoneyRpc rpc;

  @override
  State<_MoneyTabBody> createState() => _MoneyTabBodyState();
}

class _MoneyTabBodyState extends State<_MoneyTabBody> {
  static const Map<String, String> _fnForTab = {
    'receivables': 'admin_receivables',
    'claims': 'admin_claim_queue',
    'unmatched': 'admin_unmatched_payments',
    'bills': 'admin_bill_queue',
  };

  Map<String, dynamic> _payload = const {};
  bool _loading = true;
  String _busy = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fn = _fnForTab[widget.tabKey];
    if (fn == null) {
      setState(() {
        _loading = false;
        _payload = const {};
      });
      return;
    }
    setState(() => _loading = true);
    Map<String, dynamic> res;
    try {
      res = await widget.rpc(fn, const {});
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'error': e.toString()};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
    RenderLog.write('c450_money_${widget.tabKey}', _rows(res['rows']).length);
  }

  /// Every action here is the same shape: call, show the backend's sentence,
  /// reload. No optimistic state, no Dart-written toast.
  Future<void> _act(String fn, Map<String, dynamic> args, String busyKey) async {
    if (_busy.isNotEmpty) return;
    setState(() => _busy = busyKey);
    Map<String, dynamic> res;
    try {
      res = await widget.rpc(fn, args);
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'message': e.toString()};
    }
    if (!mounted) return;
    setState(() => _busy = '');
    final msg = _s(res['message']);
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: res['ok'] == true ? Ds.c.success : Ds.c.danger,
        ),
      );
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_fnForTab.containsKey(widget.tabKey)) return const SizedBox.shrink();
    if (_loading) return const _Skeleton();

    final err = _s(_payload['error']);
    if (_payload['ok'] != true && err.isNotEmpty) {
      return _ErrorBlock(message: err, onRetry: _load);
    }

    final rows = _rows(_payload['rows']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Headline(payload: _payload),
        if (_rows(_payload['buckets']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _Buckets(buckets: _rows(_payload['buckets'])),
        ],
        SizedBox(height: Ds.space.x24),
        if (rows.isEmpty)
          _EmptyBlock(label: _s(_payload['empty_label']))
        else
          for (final r in rows) ...[
            _rowCard(r),
            SizedBox(height: Ds.space.x12),
          ],
        if (_s(_payload['note']).isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(
            _s(_payload['note']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
        ],
        SizedBox(height: Ds.space.x32),
      ],
    );
  }

  Widget _rowCard(Map<String, dynamic> r) {
    switch (widget.tabKey) {
      case 'receivables':
        return _CustomerCard(
          row: r,
          busy: _busy == _s(r['user_id']),
          onChase: () => _act(
            'admin_receivables_chase',
            {'p_user_id': r['user_id']},
            _s(r['user_id']),
          ),
          rpc: widget.rpc,
        );
      case 'claims':
        return _ClaimQueueCard(
          row: r,
          busy: _busy == _s(r['claim_id']),
          onAsk: () => _act(
            'admin_claim_ask_utr',
            {'p_claim_id': r['claim_id']},
            _s(r['claim_id']),
          ),
        );
      case 'unmatched':
        return _UnmatchedCard(
          row: r,
          busy: _busy == _s(r['claim_id']),
          noCandidateLabel: _s(_payload['no_candidate_label']),
          onAttach: (orderId) => _act(
            'admin_claim_attach',
            {'p_claim_id': r['claim_id'], 'p_order_id': orderId},
            _s(r['claim_id']),
          ),
        );
      case 'bills':
        return _BillCard(row: r);
      default:
        return const SizedBox.shrink();
    }
  }
}

// ── shared blocks ───────────────────────────────────────────────────────────

class _Headline extends StatelessWidget {
  const _Headline({required this.payload});
  final Map<String, dynamic> payload;

  @override
  Widget build(BuildContext context) {
    final headline = _s(payload['headline']);
    final sub = _s(payload['sub_headline']);
    final oldest = _s(payload['oldest_label']);
    final stalled = _s(payload['stalled_headline']);
    final utrGap = _s(payload['utr_gap_label']);
    final value = _s(payload['value_label']);
    if (headline.isEmpty) return const SizedBox.shrink();

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: Ds.t.title),
          if (sub.isNotEmpty || value.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(
              sub.isNotEmpty ? sub : value,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
          ],
          if (oldest.isNotEmpty || stalled.isNotEmpty || utrGap.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                if (stalled.isNotEmpty)
                  _Pill(label: stalled, tone: _s(payload['stalled_tone'])),
                if (oldest.isNotEmpty)
                  _Pill(label: oldest, tone: _s(payload['oldest_tone'])),
                if (utrGap.isNotEmpty) _Pill(label: utrGap, tone: 'bad'),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Buckets extends StatelessWidget {
  const _Buckets({required this.buckets});
  final List<Map<String, dynamic>> buckets;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final perRow = box.maxWidth >= 640 ? 4 : 2;
        final gap = Ds.space.x12;
        final w = (box.maxWidth - gap * (perRow - 1)) / perRow;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final b in buckets)
              SizedBox(
                width: w,
                child: _Card(
                  padding: EdgeInsets.all(Ds.space.x12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _s(b['label']),
                        style: Ds.t.caption.copyWith(
                          color: Ds.c.textSecondary,
                        ),
                      ),
                      SizedBox(height: Ds.space.x4),
                      Text(
                        _s(b['value_label']).isNotEmpty
                            ? _s(b['value_label'])
                            : _s(b['count_label']),
                        style: Ds.t.subtitle.copyWith(
                          color: moneyToneColor(_s(b['tone'])),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_s(b['value_label']).isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text(
                          _s(b['count_label']),
                          style: Ds.t.caption.copyWith(
                            color: Ds.c.textSecondary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ── the four cards ──────────────────────────────────────────────────────────

class _CustomerCard extends StatelessWidget {
  const _CustomerCard({
    required this.row,
    required this.busy,
    required this.onChase,
    required this.rpc,
  });
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onChase;
  final MoneyRpc rpc;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  _s(row['customer_name']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              SizedBox(width: Ds.space.x8),
              Text(
                _s(row['open_label']),
                textAlign: TextAlign.right,
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Pill(label: _s(row['age_label']), tone: _s(row['age_tone'])),
              _Pill(label: _s(row['order_count_label']), tone: 'muted'),
              _Pill(label: _s(row['bucket_label']), tone: 'muted'),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          Row(
            children: [
              Expanded(
                child: _SecondaryButton(
                  label: _s(row['open_orders_label']),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _ReceivableOrdersPage(
                        userId: _s(row['user_id']),
                        rpc: rpc,
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: _PrimaryButton(
                  label: _s(row['chase_label']),
                  busy: busy,
                  onTap: onChase,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReceivableOrdersPage extends StatefulWidget {
  const _ReceivableOrdersPage({required this.userId, required this.rpc});
  final String userId;
  final MoneyRpc rpc;

  @override
  State<_ReceivableOrdersPage> createState() => _ReceivableOrdersPageState();
}

class _ReceivableOrdersPageState extends State<_ReceivableOrdersPage> {
  Map<String, dynamic> _payload = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Map<String, dynamic> res;
    try {
      res = await widget.rpc('admin_receivables_orders', {
        'p_user_id': widget.userId,
      });
    } catch (e) {
      res = <String, dynamic>{'ok': false, 'error': e.toString()};
    }
    if (!mounted) return;
    setState(() {
      _payload = res;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows(_payload['rows']);
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_payload['customer_name']))),
      body: _loading
          ? const _Skeleton()
          : ListView(
              padding: EdgeInsets.all(Ds.space.x16),
              children: [
                if (_s(_payload['headline']).isNotEmpty)
                  _Card(
                    child: Text(
                      _s(_payload['headline']),
                      style: Ds.t.subtitle,
                    ),
                  ),
                SizedBox(height: Ds.space.x16),
                if (rows.isEmpty)
                  _EmptyBlock(label: _s(_payload['empty_label']))
                else
                  for (final r in rows) ...[
                    _Card(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _s(r['order_code']),
                                  style: Ds.t.body.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Text(
                                _s(r['open_label']),
                                textAlign: TextAlign.right,
                                style: Ds.t.body.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            _s(r['placed_label']),
                            style: Ds.t.caption.copyWith(
                              color: Ds.c.textSecondary,
                            ),
                          ),
                          SizedBox(height: Ds.space.x8),
                          Wrap(
                            spacing: Ds.space.x8,
                            runSpacing: Ds.space.x8,
                            children: [
                              _Pill(
                                label: _s(r['age_label']),
                                tone: _s(r['age_tone']),
                              ),
                              _Pill(label: _s(r['paid_note']), tone: 'muted'),
                            ],
                          ),
                        ],
                      ),
                    ),
                    SizedBox(height: Ds.space.x12),
                  ],
              ],
            ),
    );
  }
}

class _ClaimQueueCard extends StatelessWidget {
  const _ClaimQueueCard({
    required this.row,
    required this.busy,
    required this.onAsk,
  });
  final Map<String, dynamic> row;
  final bool busy;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final canAsk = row['can_ask_utr'] == true;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _s(row['customer_name']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                _s(row['amount_label']),
                textAlign: TextAlign.right,
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            _s(row['received_label']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Pill(label: _s(row['age_label']), tone: _s(row['age_tone'])),
              _Pill(label: _s(row['utr_label']), tone: _s(row['utr_tone'])),
              _Pill(label: _s(row['link_label']), tone: _s(row['link_tone'])),
            ],
          ),
          if (_s(row['utr_detail']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(
              _s(row['utr_detail']),
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
          ],
          if (canAsk) ...[
            SizedBox(height: Ds.space.x12),
            _PrimaryButton(
              label: _s(row['ask_utr_label']),
              busy: busy,
              onTap: onAsk,
            ),
          ],
        ],
      ),
    );
  }
}

class _UnmatchedCard extends StatelessWidget {
  const _UnmatchedCard({
    required this.row,
    required this.busy,
    required this.noCandidateLabel,
    required this.onAttach,
  });
  final Map<String, dynamic> row;
  final bool busy;
  final String noCandidateLabel;
  final ValueChanged<String> onAttach;

  @override
  Widget build(BuildContext context) {
    final candidates = _rows(row['candidates']);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _s(row['customer_name']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                _s(row['amount_label']),
                textAlign: TextAlign.right,
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            _s(row['note']),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Pill(label: _s(row['age_label']), tone: _s(row['age_tone'])),
              _Pill(label: _s(row['utr_label']), tone: _s(row['utr_tone'])),
            ],
          ),
          SizedBox(height: Ds.space.x12),
          if (candidates.isEmpty)
            Text(
              noCandidateLabel,
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            )
          else
            for (final cand in candidates) ...[
              _Card(
                padding: EdgeInsets.all(Ds.space.x12),
                filled: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _s(cand['order_code']),
                            style: Ds.t.body.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: Ds.space.x4),
                          Text(
                            [
                              _s(cand['placed_label']),
                              _s(cand['total_label']),
                              _s(cand['match_label']),
                            ].where((e) => e.isNotEmpty).join(' · '),
                            style: Ds.t.caption.copyWith(
                              color: Ds.c.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: Ds.space.x8),
                    _SecondaryButton(
                      label: _s(row['attach_label']),
                      busy: busy,
                      onTap: () => onAttach(_s(cand['order_id'])),
                    ),
                  ],
                ),
              ),
              SizedBox(height: Ds.space.x8),
            ],
        ],
      ),
    );
  }
}

class _BillCard extends StatelessWidget {
  const _BillCard({required this.row});
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _s(row['supplier_name']),
                  style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (_s(row['stalled_label']).isNotEmpty)
                _Pill(label: _s(row['stalled_label']), tone: 'bad'),
            ],
          ),
          SizedBox(height: Ds.space.x4),
          Text(
            [_s(row['file_name']), _s(row['received_label'])]
                .where((e) => e.isNotEmpty)
                .join(' · '),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              _Pill(label: _s(row['age_label']), tone: _s(row['age_tone'])),
              _Pill(label: _s(row['scan_label']), tone: _s(row['scan_tone'])),
            ],
          ),
        ],
      ),
    );
  }
}

// ── primitives ──────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  const _Card({required this.child, this.padding, this.filled = false});
  final Widget child;
  final EdgeInsets? padding;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: filled ? Ds.c.bg : Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: filled ? null : Ds.elevation.e1,
      ),
      child: child,
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.tone});
  final String label;
  final String tone;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Ds.space.x12,
        vertical: Ds.space.x4,
      ),
      decoration: BoxDecoration(
        color: moneyToneSoft(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(
        label,
        style: Ds.t.caption.copyWith(
          color: moneyToneColor(tone),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.onTap,
    this.busy = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget,
      child: FilledButton(
        onPressed: busy ? null : onTap,
        style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
        child: Text(label),
      ),
    );
  }
}

class _SecondaryButton extends StatelessWidget {
  const _SecondaryButton({
    required this.label,
    required this.onTap,
    this.busy = false,
  });
  final String label;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton(
        onPressed: busy ? null : onTap,
        child: Text(label),
      ),
    );
  }
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return _Card(
      child: Text(
        label,
        style: Ds.t.body.copyWith(color: Ds.c.textSecondary),
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message, style: Ds.t.body.copyWith(color: Ds.c.danger)),
          SizedBox(height: Ds.space.x12),
          _SecondaryButton(label: c('money.retry'), onTap: onRetry),
        ],
      ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.all(Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 4; i++) ...[
            Container(
              height: Ds.touch.listRowMinHeight,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
            ),
            SizedBox(height: Ds.space.x12),
          ],
        ],
      ),
    );
  }
}
