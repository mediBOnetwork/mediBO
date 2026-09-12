import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../models/loyalty.dart';
import '../utils/render_log.dart';
import '../utils/toast.dart';

/// CHANGE #176 — the customer's Rewards screen.
///
/// One RPC (`loyalty_my_rewards`) returns the whole screen already decided:
/// which of the five programmes are running, the tier the customer is on, the
/// sentence describing the gap to the next one, ₹ already formatted by
/// inr_money, every heading. This widget computes NOTHING — it does not add up
/// points, does not decide a tier, does not pluralise, does not format a rupee.
/// If a programme is off the backend sends `{"on": false}` for it and the
/// section simply is not built, which is why turning one off in the admin panel
/// makes it disappear here with no client change.
class RewardsScreen extends StatefulWidget {
  const RewardsScreen({super.key});

  @override
  State<RewardsScreen> createState() => _RewardsScreenState();
}

class _RewardsScreenState extends State<RewardsScreen> {
  Map<String, dynamic>? _p;
  bool _loading = true;
  bool _error = false;
  bool _redeeming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final raw = await Supabase.instance.client.rpc('loyalty_my_rewards');
      final p = raw is Map
          ? Map<String, dynamic>.from(raw)
          : (raw is List && raw.isNotEmpty
              ? Map<String, dynamic>.from(raw.first as Map)
              : <String, dynamic>{});
      if (mounted) {
        setState(() {
          _p = p;
          _loading = false;
        });
      }
      RenderLog.write('rewards_screen',
          'any_on:${p['any_on']} tier:${_m(p, 'tier')['on']} pts:${_m(p, 'points')['on']}');
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  static Map<String, dynamic> _m(Map<String, dynamic>? p, String k) {
    final v = p?[k];
    return v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  }

  static String _s(Map<String, dynamic>? p, String k) => (p?[k] ?? '').toString();

  static List<Map<String, dynamic>> _list(Map<String, dynamic> p, String k) {
    final raw = p[k];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// The backend decides whether redeeming is allowed (`can_redeem`) and what
  /// to say when it refuses; this only relays the answer.
  Future<void> _redeem() async {
    if (_redeeming) return;
    final points = _m(_p, 'points');
    final bal = (points['balance'] as num?)?.toDouble() ?? 0;
    setState(() => _redeeming = true);
    try {
      final raw = await Supabase.instance.client
          .rpc('loyalty_redeem', params: {'p_points': bal});
      final r = raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
      if (!mounted) return;
      if (r['ok'] == true) {
        showToast(context, _s(r, 'credit_label'));
        await _load();
      } else {
        showToast(context, _s(r, 'message'));
      }
    } catch (_) {
      // swallowed: a failed redeem leaves the balance untouched server-side
    } finally {
      if (mounted) setState(() => _redeeming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 20, color: Ds.c.brand),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(_s(p, 'title'), style: Ds.t.title),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Ds.c.divider),
        ),
      ),
      body: _body(p),
    );
  }

  Widget _body(Map<String, dynamic>? p) {
    if (_loading) {
      return Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2.5));
    }
    if (_error || p == null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 48, color: Ds.c.textSecondary),
              SizedBox(height: Ds.space.x16),
              TextButton(
                onPressed: _load,
                child: Text(_s(p, 'off_title'),
                    style: Ds.t.body.copyWith(color: Ds.c.brand)),
              ),
            ],
          ),
        ),
      );
    }

    // Nothing switched on yet — the backend supplies the whole empty state.
    if (p['any_on'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.card_giftcard_outlined,
                  size: 56, color: Ds.c.textSecondary),
              SizedBox(height: Ds.space.x16),
              Text(_s(p, 'off_title'),
                  style: Ds.t.subtitle, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x8),
              Text(_s(p, 'off_note'),
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    // Which sections exist is RewardsView's single decision — the same pure
    // class test/protected/loyalty_test.dart holds down. A programme Om
    // switched off arrives as {"on": false} and is simply not in this list.
    final view = RewardsView(p);

    return RefreshIndicator(
      color: Ds.c.brand,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x16),
        children: [
          for (final s in view.sections) _sectionCard(s),
          SizedBox(height: Ds.space.x24),
        ],
      ),
    );
  }

  Widget _sectionCard(RewardsSection s) {
    switch (s.key) {
      case 'tier':
        return _tierCard(s.data);
      case 'points':
        return _pointsCard(s.data);
      case 'targets':
        return _targetsCard(s.data);
      case 'streak':
        return _streakCard(s.data);
      case 'referral':
        return _referralCard(s.data);
    }
    // Forward compatibility: a programme this build has never heard of is
    // skipped rather than crashing the screen.
    return const SizedBox.shrink();
  }

  Widget _shell({required String title, required List<Widget> children}) {
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Ds.t.subtitle),
          SizedBox(height: Ds.space.x12),
          ...children,
        ],
      ),
    );
  }

  Widget _bar(double pct) {
    return ClipRRect(
      borderRadius: Ds.r.rChip,
      child: LinearProgressIndicator(
        value: pct.clamp(0, 1),
        minHeight: Ds.space.x8,
        backgroundColor: Ds.c.divider,
        valueColor: AlwaysStoppedAnimation<Color>(Ds.c.brand),
      ),
    );
  }

  Widget _tierCard(Map<String, dynamic> t) {
    final pct = (t['progress_pct'] as num?)?.toDouble() ?? 0;
    return _shell(title: _s(t, 'title'), children: [
      Row(
        children: [
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x4),
            decoration: BoxDecoration(
                color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
            child: Text(_s(t, 'current_label'),
                style: Ds.t.body.copyWith(color: Ds.c.brand)),
          ),
        ],
      ),
      SizedBox(height: Ds.space.x12),
      _bar(pct),
      SizedBox(height: Ds.space.x8),
      Text(_s(t, 'progress_label'),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
    ]);
  }

  Widget _pointsCard(Map<String, dynamic> pt) {
    return _shell(title: _s(pt, 'title'), children: [
      Text(_s(pt, 'balance_label'), style: Ds.t.display),
      SizedBox(height: Ds.space.x4),
      Text(_s(pt, 'worth_label'),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      if (_s(pt, 'min_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(pt, 'min_label'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      ],
      SizedBox(height: Ds.space.x12),
      SizedBox(
        width: double.infinity,
        height: Ds.space.x48,
        child: FilledButton(
          onPressed: (pt['can_redeem'] == true && !_redeeming) ? _redeem : null,
          style: FilledButton.styleFrom(
            backgroundColor: Ds.c.brand,
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
          ),
          child: Text(_s(pt, 'redeem_label')),
        ),
      ),
    ]);
  }

  Widget _targetsCard(Map<String, dynamic> tg) {
    final items = _list(tg, 'items');
    return _shell(title: _s(tg, 'title'), children: [
      for (final it in items) ...[
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(_s(it, 'name'), style: Ds.t.body)),
            Text(_s(it, 'reward_label'),
                style: Ds.t.body.copyWith(color: Ds.c.brand)),
          ],
        ),
        SizedBox(height: Ds.space.x8),
        _bar((it['progress_pct'] as num?)?.toDouble() ?? 0),
        SizedBox(height: Ds.space.x4),
        Text(_s(it, 'progress_label'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
        SizedBox(height: Ds.space.x16),
      ],
    ]);
  }

  Widget _streakCard(Map<String, dynamic> st) {
    return _shell(title: _s(st, 'title'), children: [
      Text(_s(st, 'count_label'), style: Ds.t.display),
      if (_s(st, 'next_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x4),
        Text(_s(st, 'next_label'),
            style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      ],
      if (_s(st, 'next_reward_label').isNotEmpty) ...[
        SizedBox(height: Ds.space.x8),
        Text(_s(st, 'next_reward_label'),
            style: Ds.t.body.copyWith(color: Ds.c.brand)),
      ],
    ]);
  }

  Widget _referralCard(Map<String, dynamic> rf) {
    return _shell(title: _s(rf, 'title'), children: [
      Text(_s(rf, 'code_label'),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
      SizedBox(height: Ds.space.x4),
      Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(
            color: Ds.c.brandSoft, borderRadius: Ds.r.rButton),
        child: Text(_s(rf, 'code'),
            style: Ds.t.subtitle.copyWith(color: Ds.c.brand)),
      ),
      SizedBox(height: Ds.space.x8),
      Text(_s(rf, 'note'),
          style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
    ]);
  }
}
