import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// CHANGE #176 — the Loyalty control panel.
///
/// Every number in the loyalty engine is a row in a config table, and this
/// screen is the only thing that writes them. There are no hardcoded amounts,
/// windows or rates anywhere in the app: Om edits a tier threshold here, the
/// engine reads it on the next call, and the customer's status changes with no
/// rebuild and no deploy.
///
/// Each write RPC returns the FULL config back, so the screen never patches its
/// own local copy — it replaces state with what the backend now says is true.
class LoyaltyAdminScreen extends StatefulWidget {
  const LoyaltyAdminScreen({super.key});

  @override
  State<LoyaltyAdminScreen> createState() => _LoyaltyAdminScreenState();
}

class _LoyaltyAdminScreenState extends State<LoyaltyAdminScreen> {
  Map<String, dynamic>? _cfg;
  bool _loading = true;
  bool _error = false;

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
      final raw = await Supabase.instance.client.rpc('loyalty_config_get');
      if (mounted) {
        setState(() {
          _cfg = _asMap(raw);
          _loading = false;
        });
      }
      RenderLog.write('loyalty_admin',
          'tiers:${_list('tiers').length} slabs:${_list('slabs').length} steps:${_list('streak_steps').length}');
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = true;
          _loading = false;
        });
      }
    }
  }

  static Map<String, dynamic> _asMap(Object? raw) => raw is Map
      ? Map<String, dynamic>.from(raw)
      : (raw is List && raw.isNotEmpty
          ? Map<String, dynamic>.from(raw.first as Map)
          : <String, dynamic>{});

  List<Map<String, dynamic>> _list(String k) {
    final raw = _cfg?[k];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Every mutation goes through here: call, replace state with the returned
  /// config, tell the user. One place to get right.
  Future<void> _write(String fn, Map<String, dynamic> params) async {
    try {
      final raw = await Supabase.instance.client.rpc(fn, params: params);
      if (!mounted) return;
      setState(() => _cfg = _asMap(raw));
      showToast(context, fn);
    } catch (e) {
      if (mounted) showToast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
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
        title: Text((_cfg?['title'] ?? '').toString(), style: Ds.t.title),
        centerTitle: false,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, thickness: 1, color: Ds.c.divider),
        ),
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
          child: CircularProgressIndicator(color: Ds.c.brand, strokeWidth: 2.5));
    }
    if (_error || _cfg == null) {
      return Center(
        child: TextButton(
          onPressed: _load,
          child: Text('Retry', style: Ds.t.body.copyWith(color: Ds.c.brand)),
        ),
      );
    }
    return RefreshIndicator(
      color: Ds.c.brand,
      onRefresh: _load,
      child: ListView(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x16),
        children: [
          _programsCard(),
          _pointsCard(),
          _tiersCard(),
          _slabsCard(),
          _streakCard(),
          _referralCard(),
          SizedBox(height: Ds.space.x32),
        ],
      ),
    );
  }

  Widget _card({required String title, String? note, required List<Widget> children}) {
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
          if (note != null) ...[
            SizedBox(height: Ds.space.x4),
            Text(note, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
          ],
          SizedBox(height: Ds.space.x12),
          ...children,
        ],
      ),
    );
  }

  // ── master on/off per programme ──────────────────────────────────────────
  Widget _programsCard() {
    final programs = _list('programs');
    final summary = _asMap(_cfg?['summary']);
    return _card(
      title: 'Programmes',
      note: '${summary['on'] ?? 0} on · ${summary['tiers'] ?? 0} tiers · '
          '${summary['slabs'] ?? 0} slabs · ${summary['steps'] ?? 0} streak steps',
      children: [
        for (final p in programs)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            activeThumbColor: Ds.c.brand,
            title: Text((p['label'] ?? p['key']).toString(), style: Ds.t.body),
            subtitle: Text(
              p['active_now'] == true ? 'Running now' : 'Off',
              style: Ds.t.caption.copyWith(color: Ds.c.textSecondary),
            ),
            value: p['enabled'] == true,
            onChanged: (v) => _write('loyalty_program_set', {
              'p': {'key': p['key'], 'enabled': v}
            }),
          ),
      ],
    );
  }

  // ── points earn / redeem rates ───────────────────────────────────────────
  Widget _pointsCard() {
    final points = _list('programs').firstWhere(
      (p) => p['key'] == 'points',
      orElse: () => <String, dynamic>{},
    );
    final cfg = _asMap(points['config']);
    return _card(
      title: 'Points',
      note: 'Earn rate is points per ₹1 spent. Redeem value is ₹ per point.',
      children: [
        _numRow('Points per ₹1', cfg['earn_per_inr'], (v) {
          _write('loyalty_program_set', {
            'p': {'key': 'points', 'config': {'earn_per_inr': v}}
          });
        }),
        _numRow('₹ per point', cfg['inr_per_point'], (v) {
          _write('loyalty_program_set', {
            'p': {'key': 'points', 'config': {'inr_per_point': v}}
          });
        }),
        _numRow('Minimum points to redeem', cfg['min_redeem_points'], (v) {
          _write('loyalty_program_set', {
            'p': {'key': 'points', 'config': {'min_redeem_points': v}}
          });
        }),
      ],
    );
  }

  Widget _numRow(String label, Object? value, void Function(num) onSave) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Ds.t.body)),
          SizedBox(width: Ds.space.x12),
          SizedBox(
            width: Ds.space.x48 * 2,
            child: TextFormField(
              initialValue: (value ?? 0).toString(),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              textAlign: TextAlign.right,
              style: Ds.t.body,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                    horizontal: Ds.space.x8, vertical: Ds.space.x8),
                filled: true,
                fillColor: Ds.c.bg,
                border: OutlineInputBorder(
                    borderRadius: Ds.r.rButton,
                    borderSide: BorderSide(color: Ds.c.divider)),
              ),
              onFieldSubmitted: (s) {
                final n = num.tryParse(s.trim());
                if (n != null) onSave(n);
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── tiers ────────────────────────────────────────────────────────────────
  Widget _tiersCard() {
    final tiers = _list('tiers');
    return _card(
      title: 'Tiers',
      note: 'A customer sits in the highest tier whose threshold they meet.',
      children: [
        for (final t in tiers)
          _ruleRow(
            title: (t['name'] ?? '').toString(),
            detail: '${t['threshold_kind']} ≥ ${t['threshold_value']} '
                'in ${t['window_days']}d · ${t['benefit_kind']} ${t['benefit_value']}',
            enabled: t['enabled'] == true,
            onToggle: (v) => _write('loyalty_tier_upsert', {
              'p': {'id': t['id'], 'enabled': v}
            }),
            onEdit: () => _editSheet(
              title: 'Tier',
              fields: {
                'name': t['name'],
                'threshold_value': t['threshold_value'],
                'window_days': t['window_days'],
                'benefit_value': t['benefit_value'],
              },
              onSave: (vals) => _write('loyalty_tier_upsert', {
                'p': {'id': t['id'], ...vals}
              }),
            ),
            onDelete: () =>
                _write('loyalty_tier_delete', {'p_id': t['id']}),
          ),
        _addButton('Add tier', () => _editSheet(
              title: 'New tier',
              fields: const {
                'name': '',
                'threshold_value': 0,
                'window_days': 90,
                'benefit_value': 0,
              },
              onSave: (vals) => _write('loyalty_tier_upsert', {'p': vals}),
            )),
      ],
    );
  }

  // ── volume slabs ─────────────────────────────────────────────────────────
  Widget _slabsCard() {
    final slabs = _list('slabs');
    return _card(
      title: 'Volume targets',
      note: 'Buy ₹X inside the window, get the reward.',
      children: [
        for (final s in slabs)
          _ruleRow(
            title: (s['name'] ?? '').toString(),
            detail: '≥ ₹${s['threshold_amount']} in ${s['window_days']}d '
                '· ${s['reward_kind']} ${s['reward_value']}',
            enabled: s['enabled'] == true,
            onToggle: (v) => _write('loyalty_slab_upsert', {
              'p': {'id': s['id'], 'enabled': v}
            }),
            onEdit: () => _editSheet(
              title: 'Target',
              fields: {
                'name': s['name'],
                'threshold_amount': s['threshold_amount'],
                'window_days': s['window_days'],
                'reward_value': s['reward_value'],
              },
              onSave: (vals) => _write('loyalty_slab_upsert', {
                'p': {'id': s['id'], ...vals}
              }),
            ),
            onDelete: () => _write('loyalty_slab_delete', {'p_id': s['id']}),
          ),
        _addButton('Add target', () => _editSheet(
              title: 'New target',
              fields: const {
                'name': '',
                'threshold_amount': 0,
                'window_days': 30,
                'reward_value': 0,
              },
              onSave: (vals) => _write('loyalty_slab_upsert', {'p': vals}),
            )),
      ],
    );
  }

  // ── streak ladder ────────────────────────────────────────────────────────
  Widget _streakCard() {
    final steps = _list('streak_steps');
    return _card(
      title: 'Streak ladder',
      note: 'Order inside every window to climb; missing one resets.',
      children: [
        for (final s in steps)
          _ruleRow(
            title: 'Step ${s['step_no']}',
            detail: 'every ${s['interval_days']}d '
                '· ${s['reward_kind']} ${s['reward_value']}',
            enabled: s['enabled'] == true,
            onToggle: (v) => _write('loyalty_streak_upsert', {
              'p': {'step_no': s['step_no'], 'enabled': v}
            }),
            onEdit: () => _editSheet(
              title: 'Streak step',
              fields: {
                'step_no': s['step_no'],
                'interval_days': s['interval_days'],
                'reward_value': s['reward_value'],
              },
              onSave: (vals) => _write('loyalty_streak_upsert', {'p': vals}),
            ),
            onDelete: () => _write('loyalty_streak_delete', {'p_id': s['id']}),
          ),
        _addButton('Add step', () => _editSheet(
              title: 'New streak step',
              fields: const {
                'step_no': 1,
                'interval_days': 30,
                'reward_value': 0,
              },
              onSave: (vals) => _write('loyalty_streak_upsert', {'p': vals}),
            )),
      ],
    );
  }

  // ── referral ─────────────────────────────────────────────────────────────
  Widget _referralCard() {
    final r = _asMap(_cfg?['referral']);
    return _card(
      title: 'Referrals',
      note: 'Both sides are credited on the referee\'s first qualifying order.',
      children: [
        _numRow('Referrer reward', r['referrer_reward_value'], (v) {
          _write('loyalty_referral_set', {
            'p': {'referrer_reward_value': v}
          });
        }),
        _numRow('Referee reward', r['referee_reward_value'], (v) {
          _write('loyalty_referral_set', {
            'p': {'referee_reward_value': v}
          });
        }),
        _numRow('Minimum first order ₹', r['min_first_order_amount'], (v) {
          _write('loyalty_referral_set', {
            'p': {'min_first_order_amount': v}
          });
        }),
      ],
    );
  }

  // ── shared row / add / edit sheet ────────────────────────────────────────
  Widget _ruleRow({
    required String title,
    required String detail,
    required bool enabled,
    required void Function(bool) onToggle,
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Ds.t.body),
                SizedBox(height: Ds.space.x4),
                Text(detail,
                    style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onToggle, activeThumbColor: Ds.c.brand),
          IconButton(
            icon: Icon(Icons.edit_outlined, size: 20, color: Ds.c.brand),
            onPressed: onEdit,
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 20, color: Ds.c.danger),
            onPressed: onDelete,
          ),
        ],
      ),
    );
  }

  Widget _addButton(String label, VoidCallback onTap) {
    return SizedBox(
      width: double.infinity,
      height: Ds.space.x48,
      child: OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(Icons.add, size: 20, color: Ds.c.brand),
        label: Text(label, style: Ds.t.body.copyWith(color: Ds.c.brand)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Ds.c.brand),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
      ),
    );
  }

  /// A generic editor: one text field per key. Values come back typed the way
  /// they went in (number stays a number) so the RPC's ::numeric casts hold.
  Future<void> _editSheet({
    required String title,
    required Map<String, Object?> fields,
    required void Function(Map<String, Object?>) onSave,
  }) async {
    final ctrls = <String, TextEditingController>{
      for (final e in fields.entries)
        e.key: TextEditingController(text: (e.value ?? '').toString()),
    };
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
          Ds.space.x16,
          Ds.space.x16,
          Ds.space.x16,
          MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            for (final e in fields.entries) ...[
              Text(e.key, style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
              SizedBox(height: Ds.space.x4),
              TextField(
                controller: ctrls[e.key],
                keyboardType: e.value is num
                    ? const TextInputType.numberWithOptions(decimal: true)
                    : TextInputType.text,
                style: Ds.t.body,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12, vertical: Ds.space.x12),
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(
                      borderRadius: Ds.r.rButton,
                      borderSide: BorderSide(color: Ds.c.divider)),
                ),
              ),
              SizedBox(height: Ds.space.x12),
            ],
            SizedBox(
              width: double.infinity,
              height: Ds.space.x48,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                onPressed: () {
                  final out = <String, Object?>{};
                  for (final e in fields.entries) {
                    final raw = ctrls[e.key]!.text.trim();
                    out[e.key] = e.value is num ? (num.tryParse(raw) ?? 0) : raw;
                  }
                  Navigator.of(ctx).pop();
                  onSave(out);
                },
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
    for (final ctl in ctrls.values) {
      ctl.dispose();
    }
  }
}
