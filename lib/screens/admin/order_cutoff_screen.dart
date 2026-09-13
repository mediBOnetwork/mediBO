// CMD #1934 — Admin ▸ Order cut-off.
//
// The rule itself was built by CMD #1847: order_cutoff_run, order_cutoff_tick()
// on the cron dispatcher, the customer Edit/Cancel gate, the restoration
// window that holds the inquiry, the per-order actions and the audit line
// written on every cancel, hold and restore. None of it had a door — it lived
// inside the "New-order alerts" screen, so nothing in nav, search or the
// dashboard ever said "order cut-off", and the audit was never shown at all.
//
// This is that door, and it is ONE read: order_cutoff_screen() returns the
// rule's knobs, the orders on the clock, the never-auto-cancel pharmacies and
// the audit, already worded. This file words nothing, formats nothing and
// decides nothing — a button exists because the payload sent its flag, and
// every sentence on screen is a string the backend chose.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'order_alerts_screen.dart' show CutoffClockCard;

/// CMD #1934 — every decision this screen makes, with no Flutter and no
/// Supabase in sight, so the protected test can pin them on the Dart VM.
///
/// There are fewer decisions here than it looks: the point of the class is
/// that the answers are LOOKUPS. The rows render in the order the payload
/// lists them, the words are the payload's words, and a section is empty
/// because the backend sent an empty list — never because Dart filtered,
/// sorted or re-derived anything.
class OrderCutoffView {
  final Map<String, dynamic> payload;
  const OrderCutoffView(this.payload);

  String str(String key) => '${payload[key] ?? ''}';

  /// The section headings the backend named. An unknown key is '' rather than
  /// a Dart fallback word.
  String section(String key) =>
      '${((payload['sections'] as Map?) ?? const {})[key] ?? ''}';

  Map<String, dynamic> block(String key) =>
      ((payload[key] as Map?) ?? const {}).cast<String, dynamic>();

  List<Map<String, dynamic>> _list(Object? raw) => (raw as List? ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  /// The rule's knobs, in payload order. A field with no key is dropped
  /// because it cannot be saved; nothing else is filtered out here.
  List<Map<String, dynamic>> get fields =>
      _list(payload['fields']).where((f) => '${f['key'] ?? ''}'.isNotEmpty).toList();

  bool isSwitch(Map<String, dynamic> field) => field['type'] == 'bool';

  bool isMultiline(Map<String, dynamic> field) => field['multiline'] == true;

  List<Map<String, dynamic>> get clockItems => _list(block('clock')['items']);

  List<Map<String, dynamic>> get neverItems => _list(block('never')['items']);

  List<Map<String, dynamic>> get auditItems => _list(block('audit')['items']);

  /// The restoration-window banner shows only when the BACKEND says the window
  /// is open AND gave it a sentence — never on a clock Dart kept itself.
  bool get showWindowNote {
    final clock = block('clock');
    return clock['window_open'] == true &&
        '${clock['window_note'] ?? ''}'.isNotEmpty;
  }

  /// The "rule is off" banner is the backend's sentence or nothing at all.
  String get offNote => str('off_note');

  /// Marking a pharmacy reuses customer_credit_list(); a pharmacy already
  /// marked is not offered again.
  static List<Map<String, dynamic>> neverCandidates(Map<String, dynamic>? credit) =>
      (credit?['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((e) => e['never_auto_cancel'] != true)
          .toList();
}

class OrderCutoffScreen extends StatefulWidget {
  const OrderCutoffScreen({super.key});

  @override
  State<OrderCutoffScreen> createState() => _OrderCutoffScreenState();
}

class _OrderCutoffScreenState extends State<OrderCutoffScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final _fields = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  SupabaseClient get _db => Supabase.instance.client;

  Map<String, dynamic>? _asMap(Object? raw) {
    final m = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
    return m is Map ? Map<String, dynamic>.from(m) : null;
  }

  OrderCutoffView get _v => OrderCutoffView(_data ?? const {});

  String _s(String key) => _v.str(key);

  String _section(String key) => _v.section(key);

  Map<String, dynamic> _block(String key) => _v.block(key);

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = _asMap(await _db.rpc('order_cutoff_screen'));
      if (!mounted) return;
      for (final f in (d?['fields'] as List? ?? const [])) {
        if (f is! Map) continue;
        final key = '${f['key'] ?? ''}';
        if (key.isEmpty || f['type'] == 'bool') continue;
        (_fields[key] ??= TextEditingController()).text = '${f['value'] ?? ''}';
      }
      setState(() {
        _data = d;
        _loading = false;
      });
      final clock = ((d?['clock'] as Map?) ?? const {});
      RenderLog.write('c1934_cutoff_screen', '${(clock['items'] as List?)?.length ?? 0}');
      RenderLog.write('c1934_cutoff_fields', '${(d?['fields'] as List?)?.length ?? 0}');
      RenderLog.write('c1934_cutoff_audit',
          '${((d?['audit'] as Map?)?['items'] as List?)?.length ?? 0}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// The SAME setter the alerts screen uses. There is one writer for these
  /// values and this screen is not a second one.
  Future<void> _save(Map<String, dynamic> patch) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _db.rpc('order_alert_settings_set', params: {'p_patch': patch});
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, _s('saved_label'));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, '$e', isError: true);
    }
  }

  Future<void> _act(Map<String, dynamic> item, String action, int? minutes) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await _db.rpc('order_cutoff_action', params: {
        'p_order_id': item['order_id'],
        'p_action': action,
        'p_minutes': ?minutes,
      }));
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = '${res?['message'] ?? ''}';
      if (msg.isNotEmpty) showToast(context, msg, isError: res?['ok'] != true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, '$e', isError: true);
    }
  }

  Future<void> _neverSet(String customerId, bool never) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = _asMap(await _db.rpc('order_cutoff_never_set',
          params: {'p_customer_id': customerId, 'p_never': never}));
      if (!mounted) return;
      setState(() => _busy = false);
      final msg = '${res?['message'] ?? ''}';
      if (msg.isNotEmpty) showToast(context, msg, isError: res?['ok'] != true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, '$e', isError: true);
    }
  }

  /// Marking a pharmacy reuses customer_credit_list() — the same search the
  /// credit section already offers, so no second customer list exists.
  Future<void> _addNever() async {
    final never = _block('never');
    final ctrl = TextEditingController();
    List<Map<String, dynamic>> results = const [];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        Future<void> search() async {
          final res = _asMap(await _db.rpc('customer_credit_list',
              params: {'p_q': ctrl.text.trim(), 'p_limit': 20}));
          setSheet(() => results = OrderCutoffView.neverCandidates(res));
        }

        return Padding(
          padding: EdgeInsets.only(
            left: Ds.space.x16,
            right: Ds.space.x16,
            top: Ds.space.x24,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${never['add_label'] ?? ''}', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  onSubmitted: (_) => search(),
                  decoration: InputDecoration(labelText: '${never['search_label'] ?? ''}'),
                ),
              ),
              SizedBox(width: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton(
                  onPressed: search,
                  child: Text('${never['search_label'] ?? ''}'),
                ),
              ),
            ]),
            SizedBox(height: Ds.space.x16),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: Ds.space.x48 * 6),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final r in results)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${r['customer_name'] ?? ''}', style: Ds.t.body),
                      trailing: SizedBox(
                        height: Ds.touch.minTarget,
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            _neverSet('${r['customer_id']}', true);
                          },
                          child: Text('${never['add_label'] ?? ''}'),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ]),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s('title'), style: Ds.t.subtitle),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const _CutoffSkeleton()
          : _error != null
              ? _CutoffError(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Ds.space.x16),
                    children: [
                      if (_s('subtitle').isNotEmpty) ...[
                        Text(_s('subtitle'), style: Ds.t.bodySecondary),
                        SizedBox(height: Ds.space.x16),
                      ],
                      if (_s('off_note').isNotEmpty) ...[
                        _CutoffNote(text: _s('off_note'), tone: Ds.c.warningSoft),
                        SizedBox(height: Ds.space.x16),
                      ],
                      _CutoffHeading(label: _section('settings')),
                      ..._settingRows(),
                      SizedBox(height: Ds.space.x32),
                      _CutoffHeading(label: _section('clock')),
                      ..._clockRows(),
                      SizedBox(height: Ds.space.x32),
                      _CutoffHeading(label: _section('never')),
                      ..._neverRows(),
                      SizedBox(height: Ds.space.x32),
                      _CutoffHeading(label: _section('audit')),
                      ..._auditRows(),
                      SizedBox(height: Ds.space.x48),
                    ],
                  ),
                ),
    );
  }

  /// Rendered in the order the payload lists them — the backend owns which
  /// knobs belong to the cut-off and what each is called.
  List<Widget> _settingRows() {
    final out = <Widget>[];
    for (final f in _v.fields) {
      final key = '${f['key']}';
      final label = '${f['label'] ?? ''}';
      if (_v.isSwitch(f)) {
        out.add(SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(label, style: Ds.t.body),
          value: f['value'] == true,
          onChanged: _busy ? null : (v) => _save({key: v}),
        ));
      } else {
        final ctrl = _fields[key] ??= TextEditingController(text: '${f['value'] ?? ''}');
        out.add(Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: ctrl,
                minLines: _v.isMultiline(f) ? 2 : 1,
                maxLines: _v.isMultiline(f) ? 5 : 1,
                keyboardType: f['type'] == 'int'
                    ? TextInputType.number
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: label,
                  helperText: f['hint'] as String?,
                ),
              ),
            ),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _save({key: ctrl.text.trim()}),
                child: Text(_s('saved_label')),
              ),
            ),
          ]),
        ));
      }
    }
    return out;
  }

  /// The clock is order_cutoff_console()'s payload, drawn by the card the
  /// alerts screen already uses. Restore, +X min, Cancel now, Exempt — each
  /// appears only while the backend is still sending its flag.
  List<Widget> _clockRows() {
    final clock = _block('clock');
    final items = _v.clockItems;
    if (items.isEmpty) {
      return [
        _CutoffEmpty(
          title: '${clock['title'] ?? ''}',
          body: '${clock['empty_label'] ?? ''}',
        ),
      ];
    }
    final out = <Widget>[];
    if (_v.showWindowNote) {
      out.add(Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: _CutoffNote(text: '${clock['window_note']}', tone: Ds.c.warningSoft),
      ));
    }
    for (final m in items) {
      out.add(CutoffClockCard(
        item: m,
        busy: _busy,
        onAction: (action, minutes) => _act(m, action, minutes),
      ));
    }
    return out;
  }

  List<Widget> _neverRows() {
    final never = _block('never');
    final items = _v.neverItems;
    final out = <Widget>[
      if ('${never['hint'] ?? ''}'.isNotEmpty) ...[
        Text('${never['hint']}', style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
      ],
    ];
    if (items.isEmpty) {
      out.add(_CutoffEmpty(
        title: '${never['empty_label'] ?? ''}',
        body: '',
      ));
    } else {
      for (final m in items) {
        out.add(Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          child: Row(children: [
            Expanded(child: Text('${m['name'] ?? ''}', style: Ds.t.body)),
            SizedBox(width: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _neverSet('${m['customer_id']}', false),
                child: Text('${m['remove_label'] ?? ''}'),
              ),
            ),
          ]),
        ));
      }
    }
    if ('${never['add_label'] ?? ''}'.isNotEmpty) {
      out.add(SizedBox(height: Ds.space.x12));
      out.add(SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: OutlinedButton(
          onPressed: _busy ? null : _addNever,
          child: Text('${never['add_label']}'),
        ),
      ));
    }
    return out;
  }

  /// audit_log, already worded by the backend: who, what, why and when. The
  /// screen never composes a sentence of its own.
  List<Widget> _auditRows() {
    final audit = _block('audit');
    final items = _v.auditItems;
    if (items.isEmpty) {
      return [_CutoffEmpty(title: '${audit['empty_label'] ?? ''}', body: '')];
    }
    final out = <Widget>[
      if ('${audit['hint'] ?? ''}'.isNotEmpty) ...[
        Text('${audit['hint']}', style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
      ],
    ];
    for (final m in items) {
      out.add(Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x8),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(
              color: _auditTone('${m['tone'] ?? ''}'),
              borderRadius: Ds.r.rChip,
            ),
            child: Text('${m['action_label'] ?? ''}', style: Ds.t.caption),
          ),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${m['target_label'] ?? ''}', style: Ds.t.body),
              if ('${m['why_label'] ?? ''}'.isNotEmpty)
                Text('${m['why_label']}', style: Ds.t.caption),
              Text('${m['who_label'] ?? ''} · ${m['when_label'] ?? ''}',
                  style: Ds.t.caption),
            ]),
          ),
        ]),
      ));
    }
    return out;
  }

  /// The tone token the backend named. An unknown tone is neutral, never a
  /// throw and never a colour Dart picked on its own.
  static Color _auditTone(String tone) {
    switch (tone) {
      case 'danger':
        return Ds.c.dangerSoft;
      case 'warning':
        return Ds.c.warningSoft;
      case 'success':
        return Ds.c.successSoft;
      case 'info':
        return Ds.c.infoSoft;
      default:
        return Ds.c.bg;
    }
  }
}

class _CutoffHeading extends StatelessWidget {
  final String label;
  const _CutoffHeading({required this.label});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Text(label, style: Ds.t.title),
      );
}

class _CutoffNote extends StatelessWidget {
  final String text;
  final Color tone;
  const _CutoffNote({required this.text, required this.tone});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: tone, borderRadius: Ds.r.rCard),
        child: Text(text, style: Ds.t.body),
      );
}

class _CutoffEmpty extends StatelessWidget {
  final String title;
  final String body;
  const _CutoffEmpty({required this.title, required this.body});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (title.isNotEmpty) Text(title, style: Ds.t.body),
          if (body.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(body, style: Ds.t.caption),
          ],
        ]),
      );
}

class _CutoffSkeleton extends StatelessWidget {
  const _CutoffSkeleton();

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          for (var i = 0; i < 5; i++)
            Container(
              height: Ds.space.x48,
              margin: EdgeInsets.only(bottom: Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
            ),
        ],
      );
}

class _CutoffError extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _CutoffError({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(message, style: Ds.t.caption, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              // The icon, not a word: this screen has no copy of its own and
              // the payload that carries the copy is exactly what failed.
              child: OutlinedButton(onPressed: onRetry, child: const Icon(Icons.refresh)),
            ),
          ]),
        ),
      );
}
