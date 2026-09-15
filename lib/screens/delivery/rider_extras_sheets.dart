import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// CMD #407 — the rider's half of the delivery programme, in one file:
///   • today's incentive progress, on the home panel
///   • the training modules the assignment gate blocks on
///   • the vehicle and its fuel / maintenance log
///
/// Nothing here is computed. The progress bar's fraction, every rupee, every
/// target, every status word and every refusal message arrives finished from
/// `my_incentive_progress()`, `my_training()`, `sop_module_open()`,
/// `sop_quiz_submit()` and `my_vehicles()`.
typedef RiderRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

Future<Map<String, dynamic>> _liveRpc(
    String fn, Map<String, dynamic> params) async {
  final res = await Supabase.instance.client.rpc(fn, params: params);
  return Map<String, dynamic>.from(res as Map);
}

String _s(Object? v) => v == null ? '' : '$v';

List<Map<String, dynamic>> _rows(Object? v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

Color _tone(Object? t) {
  switch ('$t') {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color _toneSoft(Object? t) {
  switch ('$t') {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}

/// ── Today's targets ────────────────────────────────────────────────────────
///
/// `has:false` renders NOTHING — an empty incentive block on a rider's home is
/// noise, and the backend is the one that decides there is nothing to show.
class RiderIncentiveProgress extends StatelessWidget {
  /// `my_incentive_progress()` verbatim.
  final Map<String, dynamic> data;

  const RiderIncentiveProgress({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = _rows(data['rows']);
    RenderLog.write('c407_rider_incentive_rows', rows.length);
    if (data['has'] != true || rows.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x16),
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
              Expanded(child: Text(_s(data['title']), style: Ds.t.subtitle)),
              SizedBox(width: Ds.space.x8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_s(data['earned_today_label']), style: Ds.t.bodyStrong),
                  Text(_s(data['earned_caption']), style: Ds.t.caption),
                ],
              ),
            ],
          ),
          for (final r in rows) _ProgressRow(row: r),
        ],
      ),
    );
  }
}

class _ProgressRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _ProgressRow({required this.row});

  @override
  Widget build(BuildContext context) {
    // The fraction is the BACKEND's `progress`; this widget never divides.
    final p = row['progress'] is num
        ? (row['progress'] as num).toDouble().clamp(0.0, 1.0)
        : 0.0;
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(row['label']), style: Ds.t.body)),
              SizedBox(width: Ds.space.x8),
              _Pill(label: _s(row['status_label']), tone: row['tone']),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          ClipRRect(
            borderRadius: BorderRadius.circular(Ds.r.chip),
            child: LinearProgressIndicator(
              value: p,
              minHeight: Ds.space.x8,
              backgroundColor: Ds.c.bg,
              valueColor: AlwaysStoppedAnimation<Color>(_tone(row['tone'])),
            ),
          ),
          SizedBox(height: Ds.space.x4),
          Row(
            children: [
              Expanded(
                child: Text(
                    '${_s(row['value_label'])} / ${_s(row['target_label'])}',
                    style: Ds.t.caption),
              ),
              Text(_s(row['bonus_label']), style: Ds.t.caption),
            ],
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Object? tone;
  final VoidCallback? onTap;
  const _Pill({required this.label, this.tone, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    final pill = Container(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        color: _toneSoft(tone),
        borderRadius: BorderRadius.circular(Ds.r.chip),
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: _tone(tone))),
    );
    if (onTap == null) return pill;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Ds.r.chip),
      child: pill,
    );
  }
}

/// The two entry points a rider needs on their home, side by side.
class RiderExtrasButtons extends StatelessWidget {
  /// Labels are the backend's: `my_training().title` and `my_vehicles().title`
  /// arrive on the home payload's own `extras` block.
  final String trainingLabel;
  final String vehicleLabel;
  final RiderRpc? rpc;

  const RiderExtrasButtons({
    super.key,
    required this.trainingLabel,
    required this.vehicleLabel,
    this.rpc,
  });

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c407_rider_extras_buttons', 2);
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Row(
        children: [
          Expanded(
            child: _Pill(
              label: trainingLabel,
              tone: 'info',
              onTap: () => showRiderTraining(context, rpc: rpc),
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: _Pill(
              label: vehicleLabel,
              tone: 'success',
              onTap: () => showRiderVehicles(context, rpc: rpc),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showRiderTraining(BuildContext context, {RiderRpc? rpc}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
    builder: (_) => RiderTrainingSheet(rpc: rpc),
  );
}

Future<void> showRiderVehicles(BuildContext context, {RiderRpc? rpc}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
    builder: (_) => RiderVehicleSheet(rpc: rpc),
  );
}

/// ── Training ───────────────────────────────────────────────────────────────
class RiderTrainingSheet extends StatefulWidget {
  final RiderRpc? rpc;
  const RiderTrainingSheet({super.key, this.rpc});

  @override
  State<RiderTrainingSheet> createState() => _RiderTrainingSheetState();
}

class _RiderTrainingSheetState extends State<RiderTrainingSheet> {
  Map<String, dynamic>? _home;
  Map<String, dynamic>? _module;
  final Map<String, int> _answers = {};
  Map<String, dynamic>? _result;
  bool _loading = true;

  RiderRpc get _rpc => widget.rpc ?? _liveRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _rpc('my_training', const {});
      if (!mounted) return;
      setState(() {
        _home = res;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String moduleId) async {
    setState(() => _loading = true);
    try {
      final res = await _rpc('sop_module_open', {'p_module_id': moduleId});
      if (!mounted) return;
      setState(() {
        _module = res['ok'] == true ? res : null;
        _result = res['ok'] == true ? null : res;
        _answers.clear();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final m = _module;
    if (m == null) return;
    setState(() => _loading = true);
    try {
      final res = await _rpc('sop_quiz_submit', {
        'p_module_id': _s(m['module_id']),
        'p_answers': _answers.entries
            .map((e) => {'question_id': e.key, 'choice': e.value})
            .toList(),
      });
      if (!mounted) return;
      setState(() {
        _result = res;
        _module = null;
        _loading = false;
      });
      await _load();
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = _home;
    final m = _module;
    RenderLog.write('c407_rider_training_open', 1);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: _loading
            ? Padding(
                padding: EdgeInsets.all(Ds.space.x32),
                child: const Center(child: CircularProgressIndicator()))
            : m != null
                ? _quiz(m)
                : _list(h),
      ),
    );
  }

  Widget _list(Map<String, dynamic>? h) {
    final rows = _rows(h?['modules']);
    RenderLog.write('c407_rider_training_modules', rows.length);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(h?['title']), style: Ds.t.title),
        if (_result != null) SizedBox(height: Ds.space.x8),
        if (_result != null)
          _Pill(label: _s(_result?['message']), tone: _result?['tone']),
        SizedBox(height: Ds.space.x16),
        if (rows.isEmpty)
          Text(_s(h?['empty_note']), style: Ds.t.bodySecondary)
        else
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final r in rows)
                  Padding(
                    padding: EdgeInsets.only(bottom: Ds.space.x12),
                    child: InkWell(
                      onTap: () => _open(_s(r['module_id'])),
                      borderRadius: Ds.r.rCard,
                      child: Padding(
                        padding: EdgeInsets.all(Ds.space.x12),
                        child: Row(
                          children: [
                            Expanded(
                                child:
                                    Text(_s(r['title']), style: Ds.t.body)),
                            SizedBox(width: Ds.space.x8),
                            _Pill(
                                label: _s(r['status_label']), tone: r['tone']),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _quiz(Map<String, dynamic> m) {
    final qs = _rows(m['questions']);
    RenderLog.write('c407_rider_quiz_questions', qs.length);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_s(m['title']), style: Ds.t.title),
        SizedBox(height: Ds.space.x12),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              Text(_s(m['body']), style: Ds.t.body),
              SizedBox(height: Ds.space.x24),
              Text(_s(m['quiz_heading']), style: Ds.t.subtitle),
              for (final q in qs) _question(q),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x16),
        SizedBox(
          width: double.infinity,
          height: Ds.touch.minTarget,
          child: FilledButton(
            onPressed: _answers.length == qs.length ? _submit : null,
            child: Text(_s(m['submit_label'])),
          ),
        ),
      ],
    );
  }

  Widget _question(Map<String, dynamic> q) {
    final id = _s(q['question_id']);
    final opts = q['options'] is List ? (q['options'] as List) : const [];
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(q['prompt']), style: Ds.t.bodyStrong),
          for (var i = 0; i < opts.length; i++)
            InkWell(
              onTap: () => setState(() => _answers[id] = i),
              child: Container(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Icon(
                      _answers[id] == i
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: _answers[id] == i
                          ? Ds.c.brand
                          : Ds.c.textSecondary,
                    ),
                    SizedBox(width: Ds.space.x12),
                    Expanded(
                        child: Text(_s(opts[i]), style: Ds.t.body)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// ── Vehicle & fuel ─────────────────────────────────────────────────────────
class RiderVehicleSheet extends StatefulWidget {
  final RiderRpc? rpc;
  const RiderVehicleSheet({super.key, this.rpc});

  @override
  State<RiderVehicleSheet> createState() => _RiderVehicleSheetState();
}

class _RiderVehicleSheetState extends State<RiderVehicleSheet> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _kind;
  String? _vehicleId;
  final _amount = TextEditingController();
  final _odo = TextEditingController();
  final _reg = TextEditingController();

  RiderRpc get _rpc => widget.rpc ?? _liveRpc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    _odo.dispose();
    _reg.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _rpc('my_vehicles', const {});
      if (!mounted) return;
      setState(() {
        _data = res;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(Map<String, dynamic> res) {
    final m = _s(res['message']);
    if (m.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _saveVehicle() async {
    final res = await _rpc('vehicle_save', {
      'p_patch': {'reg_number': _reg.text, 'vehicle_type': ''}
    });
    _toast(res);
    _reg.clear();
    await _load();
  }

  Future<void> _addExpense() async {
    final res = await _rpc('vehicle_expense_add', {
      'p_patch': {
        'kind': _kind,
        'amount': _amount.text,
        'odometer_km': _odo.text,
        'vehicle_id': _vehicleId,
      }
    });
    _toast(res);
    _amount.clear();
    _odo.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final vehicles = _rows(d?['vehicles']);
    final expenses = _rows(d?['expenses']);
    final kinds = _rows(d?['kinds']);
    RenderLog.write('c407_rider_vehicles', vehicles.length);
    RenderLog.write('c407_rider_expenses', expenses.length);

    if (_loading) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (d?['has'] != true) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Text(_s(d?['empty_note']), style: Ds.t.bodySecondary),
      );
    }

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(_s(d?['title']), style: Ds.t.title)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(_s(d?['total_value']), style: Ds.t.bodyStrong),
                    Text(_s(d?['total_label']), style: Ds.t.caption),
                  ],
                ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  Text(_s(d?['vehicles_heading']), style: Ds.t.subtitle),
                  if (vehicles.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: Ds.space.x8),
                      child: Text(_s(d?['empty_vehicles']),
                          style: Ds.t.bodySecondary),
                    ),
                  for (final v in vehicles)
                    Padding(
                      padding: EdgeInsets.only(top: Ds.space.x8),
                      child: Row(
                        children: [
                          Expanded(
                              child: Text(_s(v['reg_number']),
                                  style: Ds.t.body)),
                          Text(_s(v['type_label']), style: Ds.t.caption),
                        ],
                      ),
                    ),
                  SizedBox(height: Ds.space.x12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _reg,
                          decoration: InputDecoration(
                              labelText: _s(d?['add_vehicle_label'])),
                        ),
                      ),
                      SizedBox(width: Ds.space.x8),
                      SizedBox(
                        height: Ds.touch.minTarget,
                        child: OutlinedButton(
                          onPressed: _saveVehicle,
                          child: Text(_s(d?['add_vehicle_label'])),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Ds.space.x24),
                  Text(_s(d?['expenses_heading']), style: Ds.t.subtitle),
                  Wrap(
                    spacing: Ds.space.x8,
                    children: [
                      for (final k in kinds)
                        _Pill(
                          label: _s(k['label']),
                          tone: _kind == _s(k['slug']) ? 'success' : null,
                          onTap: () =>
                              setState(() => _kind = _s(k['slug'])),
                        ),
                    ],
                  ),
                  SizedBox(height: Ds.space.x8),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _amount,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: '₹'),
                        ),
                      ),
                      SizedBox(width: Ds.space.x8),
                      Expanded(
                        child: TextField(
                          controller: _odo,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'km'),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Ds.space.x12),
                  SizedBox(
                    width: double.infinity,
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: _kind == null ? null : _addExpense,
                      child: Text(_s(d?['add_expense_label'])),
                    ),
                  ),
                  if (expenses.isEmpty)
                    Padding(
                      padding: EdgeInsets.only(top: Ds.space.x16),
                      child: Text(_s(d?['empty_expenses']),
                          style: Ds.t.bodySecondary),
                    ),
                  for (final e in expenses)
                    Padding(
                      padding: EdgeInsets.only(top: Ds.space.x12),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(_s(e['kind_label']), style: Ds.t.body),
                                Text(
                                    '${_s(e['date_label'])}  ${_s(e['vehicle_label'])}  ${_s(e['odometer_label'])}',
                                    style: Ds.t.caption),
                              ],
                            ),
                          ),
                          Text(_s(e['amount_label']), style: Ds.t.bodyStrong),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
