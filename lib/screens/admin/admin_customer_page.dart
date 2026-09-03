// CHANGE #810 — the customer page.
//
// Eight tabs, and this file decides NOTHING about any of them. The tab list
// comes from `admin_customer_tab` via admin_customer_page(); each tab names its
// own RPC; each RPC answers with `blocks[]` and this file owns exactly one
// renderer per block kind:
//
//   kv | tiles | chips | list | table | timeline | note
//
// An unknown kind is skipped in silence, so a block invented in SQL tomorrow
// cannot crash a build shipped today. Every string on screen — labels, rupees,
// percentages, chip colours, confirm copy, toast wording — arrives in the
// payload. There is no Dart fallback text anywhere in this file, deliberately:
// substituting one would put a second, staler answer next to the backend's.
//
// mediBO does not deal in credit, so nothing here renders a limit, a
// utilisation bar or a "credit blocked" state; what a customer owes is an
// unpaid bill and the Bills & Payments tab prints it as one.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/backend_chip.dart';

/// Opens the customer page for [customerId] as a full route. [initialTab] is a
/// tab_key from the backend registry; anything the registry does not offer is
/// ignored and the payload's own default_tab wins.
///
/// Resolves to 'deleted' when the page deleted the customer (so the list can
/// reload), or null.
Future<String?> openAdminCustomerPage(BuildContext context, String customerId,
    {String initialTab = ''}) {
  return Navigator.of(context).push<String>(MaterialPageRoute(
    builder: (_) =>
        AdminCustomerPage(customerId: customerId, initialTab: initialTab),
  ));
}

class AdminCustomerPage extends StatefulWidget {
  final String customerId;
  final String initialTab;

  /// Test seam. Null in production -> the real RPCs. The protected suite sets
  /// this to serve fixture payloads so the block renderers can be proven
  /// without Supabase.
  static Future<Object?> Function(String rpc, Map<String, dynamic> params)?
      rpcOverride;

  /// Test seam for the "Customer 360" menu entry, which is a route this page
  /// does not own.
  static void Function(BuildContext context, String customerId)? open360;

  const AdminCustomerPage(
      {super.key, required this.customerId, this.initialTab = ''});

  @override
  State<AdminCustomerPage> createState() => _AdminCustomerPageState();
}

class _AdminCustomerPageState extends State<AdminCustomerPage> {
  // Resolved lazily: with `rpcOverride` set (the protected suite) Supabase is
  // never initialised, and an eager field initializer would throw at
  // createState() before a single widget was built.
  SupabaseClient get _sb => Supabase.instance.client;

  Map<String, dynamic>? _page;
  Map<String, dynamic>? _tab;
  String _tabKey = '';
  bool _loadingPage = true;
  bool _loadingTab = false;
  String _error = '';

  /// Per-tab filter arguments a CHIPS block asked us to send back, keyed by
  /// tab. The backend names both the parameter and the value; we only carry it.
  final Map<String, Map<String, dynamic>> _tabArgs = {};

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  Map<String, dynamic> _asMap(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  List<Map<String, dynamic>> _asList(Object? v) => v is List
      ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];

  String _s(Object? v) => v == null ? '' : v.toString();

  Future<Object?> _rpc(String name, Map<String, dynamic> params) {
    final over = AdminCustomerPage.rpcOverride;
    if (over != null) return over(name, params);
    return _sb.rpc(name, params: params);
  }

  Future<void> _loadPage() async {
    setState(() {
      _loadingPage = true;
      _error = '';
    });
    try {
      final res = await _rpc(
          'admin_customer_page', {'p_customer_id': widget.customerId});
      final m = _asMap(res);
      if (m['ok'] != true) {
        setState(() {
          _loadingPage = false;
          _error = _s(m['message']);
        });
        return;
      }
      final tabs = _asList(m['tabs']);
      final wanted = widget.initialTab;
      final offered = tabs.any((t) => _s(t['key']) == wanted);
      setState(() {
        _page = m;
        _loadingPage = false;
        _tabKey = offered
            ? wanted
            : (_s(m['default_tab']).isNotEmpty
                ? _s(m['default_tab'])
                : (tabs.isEmpty ? '' : _s(tabs.first['key'])));
      });
      RenderLog.write('c810_customer_page', '${tabs.length}');
      await _loadTab();
    } catch (e) {
      setState(() {
        _loadingPage = false;
        _error = e.toString();
      });
    }
  }

  Map<String, dynamic>? _tabDef(String key) {
    for (final t in _asList(_page?['tabs'])) {
      if (_s(t['key']) == key) return t;
    }
    return null;
  }

  Future<void> _loadTab() async {
    final def = _tabDef(_tabKey);
    final rpc = _s(def?['rpc']);
    if (rpc.isEmpty) {
      setState(() => _tab = null);
      return;
    }
    setState(() => _loadingTab = true);
    try {
      final params = <String, dynamic>{'p_customer_id': widget.customerId}
        ..addAll(_tabArgs[_tabKey] ?? const {});
      final res = await _rpc(rpc, params);
      if (!mounted) return;
      setState(() {
        _tab = _asMap(res);
        _loadingTab = false;
      });
      RenderLog.write(
          'c810_customer_tab_$_tabKey', '${_asList(_asMap(res)['blocks']).length}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _tab = null;
        _loadingTab = false;
        _error = e.toString();
      });
    }
  }

  void _selectTab(String key) {
    if (key == _tabKey) return;
    setState(() {
      _tabKey = key;
      _tab = null;
    });
    _loadTab();
  }

  // ── Tones. The backend names a tone; the token layer owns the colour. ─────
  Color _toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      case 'brand':
        return Ds.c.brand;
      case 'muted':
        return Ds.c.textSecondary;
      default:
        return Ds.c.text;
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
      case 'info':
        return Ds.c.infoSoft;
      case 'brand':
        return Ds.c.brandSoft;
      default:
        return Ds.c.bg;
    }
  }

  // ── Actions carried in the payload ───────────────────────────────────────
  Future<void> _runAction(Map<String, dynamic> action) async {
    // A plain link (a map deep-link on an address, say) opens and returns.
    final url = _s(action['url']);
    if (url.isNotEmpty && _s(action['rpc']).isEmpty) {
      await _openUrl(url);
      return;
    }

    final rpc = _s(action['rpc']);
    if (rpc.isEmpty) return;

    final params = Map<String, dynamic>.from(_asMap(action['args']));

    // A confirm gates the call, and carries its own copy.
    final confirm = _asMap(action['confirm']);
    if (confirm.isNotEmpty) {
      final answer = await _confirmAction(confirm);
      if (answer == null) return;
      final reasonArg = _s(confirm['reason_arg']);
      if (reasonArg.isNotEmpty) params[reasonArg] = answer;
    }

    // A prompt asks for one extra argument the backend named.
    final prompt = _asMap(action['prompt']);
    if (prompt.isNotEmpty) {
      final value = await _askText(
        title: _s(prompt['title']),
        hint: _s(prompt['hint']),
        okLabel: _s(prompt['ok']),
        cancelLabel: _s(prompt['cancel']),
        multiline: prompt['multiline'] == true,
      );
      if (value == null) return;
      params[_s(prompt['arg'])] = value;
    }

    try {
      final res = await _rpc(rpc, params);
      final m = _asMap(res);
      if (!mounted) return;
      final msg = _s(m['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: m['ok'] != true);
      await _loadTab();
      await _loadPage();
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
    }
  }

  /// Runs the edge-function call a payload asked for. A failure is never fatal:
  /// the database write it follows has already landed.
  Future<void> _invokeEdge(Map<String, dynamic> post) async {
    final name = _s(post['function']);
    if (name.isEmpty || AdminCustomerPage.rpcOverride != null) return;
    try {
      await _sb.functions.invoke(name, body: _asMap(post['body']));
    } catch (_) {}
  }

  Future<void> _openUrl(String url) async {
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<String?> _askText({
    required String title,
    required String hint,
    required String okLabel,
    required String cancelLabel,
    String initial = '',
    bool multiline = false,
  }) async {
    final ctl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
        title: Text(title, style: Ds.t.subtitle),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: multiline ? 5 : 1,
          style: Ds.t.body,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: Ds.t.caption,
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(cancelLabel, style: Ds.t.body),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
            onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
            child: Text(okLabel),
          ),
        ],
      ),
    );
  }

  /// Returns null on cancel, the typed reason when the backend asked for one,
  /// and an empty string for a plain confirm. Every word is the payload's.
  Future<String?> _confirmAction(Map<String, dynamic> confirm) async {
    final needsReason = confirm['needs_reason'] == true;
    final ctl = TextEditingController();
    var error = '';
    return showDialog<String>(
      context: context,
      builder: (dctx) => StatefulBuilder(
        builder: (dctx2, setLocal) => AlertDialog(
          backgroundColor: Ds.c.surface,
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
          title: Text(_s(confirm['title']), style: Ds.t.subtitle),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_s(confirm['body']), style: Ds.t.body),
            if (needsReason) ...[
              SizedBox(height: Ds.space.x16),
              TextField(
                controller: ctl,
                autofocus: true,
                style: Ds.t.body,
                decoration: InputDecoration(
                  hintText: _s(confirm['reason_hint']),
                  hintStyle: Ds.t.caption,
                  errorText: error.isEmpty ? null : error,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
            ],
          ]),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx2),
              child: Text(_s(confirm['cancel']), style: Ds.t.body),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Ds.c.danger),
              onPressed: () {
                final v = ctl.text.trim();
                if (needsReason && v.isEmpty) {
                  setLocal(() => error = _s(confirm['reason_error']));
                  return;
                }
                Navigator.pop(dctx2, v);
              },
              child: Text(_s(confirm['ok'])),
            ),
          ],
        ),
      ),
    );
  }

  // ── Block renderers ──────────────────────────────────────────────────────
  Widget _blockTitle(String text) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x12),
      child: Text(text, style: Ds.t.subtitle),
    );
  }

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  Widget _kvBlock(Map<String, dynamic> b) {
    final rows = _asList(b['rows']);
    final chip = backendChipOf(b, 'chip');
    return _card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: _blockTitle(_s(b['title']))),
          if (backendChipVisible(chip)) BackendChip(chip: chip),
        ]),
        for (final r in rows)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(
                width: Ds.space.x48 * 3,
                child: Text(_s(r['label']), style: Ds.t.caption),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Text(
                  _s(r['value']),
                  style: r['muted'] == true ? Ds.t.bodySecondary : Ds.t.body,
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _tilesBlock(Map<String, dynamic> b) {
    final tiles = _asList(b['tiles']);
    if (tiles.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      Wrap(
        spacing: Ds.space.x12,
        runSpacing: Ds.space.x12,
        children: [
          for (final t in tiles)
            Container(
              constraints: BoxConstraints(minWidth: Ds.space.x48 * 3),
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_s(t['label']), style: Ds.t.caption),
                  SizedBox(height: Ds.space.x4),
                  Text(
                    _s(t['value']),
                    style: Ds.t.subtitle
                        .copyWith(color: _toneColor(_s(t['tone']))),
                  ),
                ],
              ),
            ),
        ],
      ),
    ]);
  }

  Widget _chipsBlock(Map<String, dynamic> b) {
    final chips = _asList(b['chips']);
    if (chips.isEmpty) return const SizedBox.shrink();
    final arg = _s(b['arg']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final c in chips) ...[
            _FilterChipButton(
              label: _s(c['label']),
              count: c['count'] is num ? (c['count'] as num).toInt() : null,
              active: c['active'] == true,
              onTap: arg.isEmpty
                  ? null
                  : () {
                      final args = Map<String, dynamic>.from(
                          _tabArgs[_tabKey] ?? const {});
                      args[arg] = c.containsKey('value') ? c['value'] : c['key'];
                      _tabArgs[_tabKey] = args;
                      _loadTab();
                    },
            ),
            SizedBox(width: Ds.space.x8),
          ],
        ]),
      ),
    ]);
  }

  Widget _listBlock(Map<String, dynamic> b) {
    final items = _asList(b['items']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      if (items.isEmpty)
        _card(child: Text(_s(b['empty']), style: Ds.t.bodySecondary))
      else
        _card(
          child: Column(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
              _listRow(items[i]),
            ],
          ]),
        ),
    ]);
  }

  Widget _listRow(Map<String, dynamic> it) {
    final actions = _asList(it['actions']);
    final chip = backendChipOf(it, 'chip');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_s(it['title']), style: Ds.t.bodyStrong),
                if (_s(it['subtitle']).isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(_s(it['subtitle']), style: Ds.t.caption),
                ],
                if (_s(it['meta']).isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(_s(it['meta']), style: Ds.t.caption),
                ],
              ],
            ),
          ),
          SizedBox(width: Ds.space.x12),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (_s(it['trailing']).isNotEmpty)
              Text(
                _s(it['trailing']),
                style: Ds.t.bodyStrong
                    .copyWith(color: _toneColor(_s(it['trailing_tone']))),
              ),
            if (backendChipVisible(chip)) ...[
              SizedBox(height: Ds.space.x4),
              BackendChip(chip: chip),
            ],
          ]),
        ]),
        if (actions.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final a in actions)
                _ActionButton(
                  label: _s(a['label']),
                  color: _toneColor(_s(a['tone'])),
                  soft: _toneSoft(_s(a['tone'])),
                  onTap: () => _runAction(a),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _tableBlock(Map<String, dynamic> b) {
    final cols = _asList(b['columns']);
    final rows = b['rows'];
    if (cols.isEmpty || rows is! List) return const SizedBox.shrink();
    if (rows.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _blockTitle(_s(b['title'])),
        _card(child: Text(_s(b['empty']), style: Ds.t.bodySecondary)),
      ]);
    }
    TextAlign align(String a) =>
        a == 'right' ? TextAlign.right : TextAlign.left;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      _card(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: Ds.touch.listRowMinHeight,
            dataRowMinHeight: Ds.touch.minTarget,
            dataRowMaxHeight: Ds.touch.listRowMinHeight,
            dividerThickness: 1,
            columns: [
              for (final c in cols)
                DataColumn(
                  label: Text(_s(c['label']), style: Ds.t.caption),
                  numeric: _s(c['align']) == 'right',
                ),
            ],
            rows: [
              for (final r in rows.whereType<List>())
                DataRow(cells: [
                  for (var i = 0; i < cols.length; i++)
                    DataCell(Text(
                      i < r.length ? _s(_asMap(r[i])['text']) : '',
                      style: Ds.t.body,
                      textAlign: align(_s(cols[i]['align'])),
                    )),
                ]),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget _timelineBlock(Map<String, dynamic> b) {
    final items = _asList(b['items']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      if (items.isEmpty)
        _card(child: Text(_s(b['empty']), style: Ds.t.bodySecondary))
      else
        _card(
          child: Column(children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
              _timelineRow(items[i]),
            ],
          ]),
        ),
    ]);
  }

  Widget _timelineRow(Map<String, dynamic> it) {
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: Ds.space.x8,
        height: Ds.space.x8,
        margin: EdgeInsets.only(top: Ds.space.x8, right: Ds.space.x12),
        decoration: BoxDecoration(
          color: _toneColor(_s(it['tone'])),
          shape: BoxShape.circle,
        ),
      ),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_s(it['title']), style: Ds.t.bodyStrong),
          if (_s(it['subtitle']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(it['subtitle']), style: Ds.t.caption),
          ],
        ]),
      ),
      SizedBox(width: Ds.space.x12),
      Text(_s(it['when']), style: Ds.t.caption),
    ]);
  }

  Widget _block(Map<String, dynamic> b) {
    switch (_s(b['kind'])) {
      case 'kv':
        return _kvBlock(b);
      case 'tiles':
        return _tilesBlock(b);
      case 'chips':
        return _chipsBlock(b);
      case 'list':
        return _listBlock(b);
      case 'table':
        return _tableBlock(b);
      case 'timeline':
        return _timelineBlock(b);
      case 'note':
        return _card(child: Text(_s(b['text']), style: Ds.t.bodySecondary));
      default:
        // Forward compatibility: a kind this build has never heard of renders
        // zero pixels rather than throwing.
        return const SizedBox.shrink();
    }
  }

  // ── Chrome ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        elevation: 0,
        title: Text(_s(page?['title']), style: Ds.t.subtitle),
        leading:
            BackButton(color: Ds.c.text, onPressed: () => Navigator.pop(context)),
        actions: [if (page != null) _pageMenu(page)],
      ),
      body: _loadingPage
          ? const Center(child: CircularProgressIndicator())
          : (page == null
              ? Center(child: Text(_error, style: Ds.t.bodySecondary))
              : Column(children: [
                  _header(page),
                  _tabBar(page),
                  Expanded(child: _tabBody(page)),
                ])),
    );
  }

  Widget _header(Map<String, dynamic> page) {
    final chips = _asList(page['chips']);
    final contacts = _asList(page['contacts']);
    final churn = _asMap(page['churn']);
    return Container(
      width: double.infinity,
      color: Ds.c.surface,
      padding:
          EdgeInsets.fromLTRB(Ds.space.x16, 0, Ds.space.x16, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_s(page['subtitle']).isNotEmpty)
          Text(_s(page['subtitle']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          for (final c in chips)
            if (backendChipVisible(c)) BackendChip(chip: c),
          _PlainChip(label: _s(page['code_label'])),
          _PlainChip(label: _s(page['city_label'])),
          _PlainChip(label: _s(page['zone_label'])),
          _PlainChip(label: _s(page['term_label'])),
        ]),
        SizedBox(height: Ds.space.x12),
        _approvalControl(_asMap(page['status'])),
        if (contacts.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
            for (final c in contacts)
              _ActionButton(
                label: _s(c['label']),
                color: Ds.c.brand,
                soft: Ds.c.brandSoft,
                onTap: () => _openUrl(_s(c['url'])),
              ),
          ]),
        ],
        // The churn flag, with the one-tap nudge the backend attached to it.
        if (churn['has'] == true) ...[
          SizedBox(height: Ds.space.x12),
          Container(
            width: double.infinity,
            padding: EdgeInsets.all(Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.warningSoft,
              borderRadius: Ds.r.rButton,
            ),
            child: Row(children: [
              Expanded(
                child: Text(_s(churn['label']),
                    style: Ds.t.body.copyWith(color: Ds.c.warning)),
              ),
              if (_asMap(churn['nudge'])['has'] == true) ...[
                SizedBox(width: Ds.space.x8),
                _ActionButton(
                  label: _s(_asMap(churn['nudge'])['label']),
                  color: Ds.c.brand,
                  soft: Ds.c.surface,
                  onTap: () => _runAction(_asMap(churn['nudge'])),
                ),
              ],
            ]),
          ),
        ],
      ]),
    );
  }

  /// The approval dropdown. Its entries are ACTIONS the backend named — not a
  /// status list this screen invented — and each says for itself whether a
  /// reason must be collected before the call goes out.
  Widget _approvalControl(Map<String, dynamic> st) {
    if (st.isEmpty) return const SizedBox.shrink();
    final options = _asList(st['options']);
    if (options.isEmpty) return const SizedBox.shrink();
    return Row(children: [
      Text(_s(st['label']), style: Ds.t.caption),
      SizedBox(width: Ds.space.x8),
      Expanded(
        child: Text(_s(st['value']), style: Ds.t.body),
      ),
      PopupMenuButton<int>(
        icon: Icon(Icons.arrow_drop_down_circle_outlined, color: Ds.c.brand),
        tooltip: '',
        onSelected: (i) => _runApproval(st, options[i]),
        itemBuilder: (_) => [
          for (var i = 0; i < options.length; i++)
            PopupMenuItem<int>(
              value: i,
              child: Text(_s(options[i]['label']), style: Ds.t.body),
            ),
        ],
      ),
    ]);
  }

  Future<void> _runApproval(
      Map<String, dynamic> st, Map<String, dynamic> option) async {
    final params = Map<String, dynamic>.from(_asMap(st['args']))
      ..[_s(st['arg'])] = option['value'];
    if (option['needs_reason'] == true) {
      final prompt = _asMap(st['reason_prompt']);
      final reason = await _askText(
        title: _s(prompt['title']),
        hint: _s(prompt['hint']),
        okLabel: _s(prompt['ok']),
        cancelLabel: _s(prompt['cancel']),
        multiline: true,
      );
      if (reason == null || reason.isEmpty) return;
      params[_s(st['reason_arg'])] = reason;
    }
    try {
      final res = _asMap(await _rpc(_s(st['rpc']), params));
      if (!mounted) return;
      final msg = _s(res['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      await _loadPage();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// The page ⋮. Every entry is the backend's; this switch only routes the
  /// four that open a sheet this file owns.
  Widget _pageMenu(Map<String, dynamic> page) {
    final items = _asList(page['menu']);
    if (items.isEmpty) return const SizedBox.shrink();
    return PopupMenuButton<int>(
      icon: Icon(Icons.more_vert, color: Ds.c.text),
      tooltip: '',
      onSelected: (i) => _runPageMenu(items[i]),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem<int>(
            value: i,
            child: Text(
              _s(items[i]['label']),
              style: _s(items[i]['tone']) == 'danger'
                  ? Ds.t.body.copyWith(color: Ds.c.danger)
                  : Ds.t.body,
            ),
          ),
      ],
    );
  }

  Future<void> _runPageMenu(Map<String, dynamic> item) async {
    final key = _s(item['key']);
    final confirm = item['confirm'];
    String? reason;

    if (confirm is Map) {
      reason = await _confirmAction(confirm.cast<String, dynamic>());
      if (reason == null) return;
    }

    switch (key) {
      case 'edit':
        await _openEditForm(_asMap(_page?['edit']));
        break;
      case 'zone':
        await _openZoneSheet(_asMap(_page?['zone_set']));
        break;
      case 'note':
        await _openNoteSheet(_asMap(_page?['note_add']));
        break;
      case 'merge':
        await _openMergeSheet(_asMap(_page?['merge']));
        break;
      case 'c360':
        final open = AdminCustomerPage.open360;
        if (open != null && mounted) open(context, widget.customerId);
        break;
      case 'whatsapp':
        await _openUrl(_s(item['url']));
        break;
      case 'block':
      case 'unblock':
      case 'delete':
      case 'restore':
        await _lifecycle(key, reason ?? '');
        break;
    }
  }

  Future<void> _lifecycle(String action, String reason) async {
    try {
      final res = _asMap(await _rpc('admin_customer_action_reason', {
        'p_customer_id': widget.customerId,
        'p_action': action,
        'p_reason': reason,
      }));
      if (!mounted) return;
      final msg = _s(res['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      // PARITY: deleting a customer also revokes the login. The backend names
      // the edge function and its body — this screen has never known that a
      // customer HAS an auth user, only that the payload asked for a call.
      final post = _asMap(res['post_action']);
      if (res['ok'] == true && post.isNotEmpty) {
        await _invokeEdge(post);
      }
      if (res['ok'] == true && action == 'delete') {
        if (!mounted) return;
        Navigator.pop(context, 'deleted');
        return;
      }
      await _loadPage();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// The Edit form is DATA: the backend names every field, its label and its
  /// kind, and validates the patch it gets back against its own allow-list.
  Future<void> _openEditForm(Map<String, dynamic> edit) async {
    if (edit.isEmpty) return;
    Map<String, dynamic> form;
    try {
      form = _asMap(await _rpc(_s(edit['form_rpc']), _asMap(edit['args'])));
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
      return;
    }
    if (!mounted || form['ok'] != true) return;

    final fields = _asList(form['fields']);
    final ctrls = <String, TextEditingController>{
      for (final f in fields)
        _s(f['col']): TextEditingController(text: _s(f['value'])),
    };

    final patch = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(sctx).viewInsets.bottom),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.85,
          builder: (_, scroll) => Column(children: [
            Padding(
              padding: EdgeInsets.all(Ds.space.x16),
              child: Row(children: [
                Expanded(child: Text(_s(form['title']), style: Ds.t.subtitle)),
                TextButton(
                  onPressed: () => Navigator.pop(sctx),
                  child: Text(_s(form['cancel_label']), style: Ds.t.body),
                ),
                SizedBox(width: Ds.space.x8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                  onPressed: () => Navigator.pop(sctx, <String, dynamic>{
                    for (final f in fields)
                      _s(f['col']): ctrls[_s(f['col'])]!.text,
                  }),
                  child: Text(_s(form['save_label'])),
                ),
              ]),
            ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: EdgeInsets.fromLTRB(
                    Ds.space.x16, 0, Ds.space.x16, Ds.space.x24),
                children: [
                  for (final f in fields) ...[
                    TextField(
                      controller: ctrls[_s(f['col'])],
                      style: Ds.t.body,
                      decoration: InputDecoration(
                        labelText: _s(f['label']),
                        labelStyle: Ds.t.caption,
                        filled: true,
                        fillColor: Ds.c.bg,
                        isDense: true,
                        border:
                            OutlineInputBorder(borderRadius: Ds.r.rButton),
                      ),
                    ),
                    SizedBox(height: Ds.space.x12),
                  ],
                ],
              ),
            ),
          ]),
        ),
      ),
    );

    for (final c in ctrls.values) {
      c.dispose();
    }
    if (patch == null || !mounted) return;

    try {
      final params = Map<String, dynamic>.from(_asMap(edit['args']))
        ..[_s(edit['arg'])] = patch;
      final res = _asMap(await _rpc(_s(edit['save_rpc']), params));
      if (!mounted) return;
      final msg = _s(res['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      if (res['ok'] == true) {
        await _loadPage();
        await _loadTab();
      }
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// Set zone — the options are the zones table's, the RPC is the one the rest
  /// of the admin uses.
  Future<void> _openZoneSheet(Map<String, dynamic> z) async {
    if (z.isEmpty) return;
    final options = _asList(z['options']);
    if (options.isEmpty) return;
    final picked = await showModalBottomSheet<Object?>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Text(_s(z['title']), style: Ds.t.subtitle),
          ),
          for (final o in options)
            ListTile(
              title: Text(_s(o['label']), style: Ds.t.body),
              trailing: _s(o['value']) == _s(z['value'])
                  ? Icon(Icons.check, color: Ds.c.brand)
                  : null,
              onTap: () => Navigator.pop(sctx, o['value']),
            ),
          SizedBox(height: Ds.space.x8),
        ]),
      ),
    );
    if (picked == null || !mounted) return;
    try {
      final params = Map<String, dynamic>.from(_asMap(z['args']))
        ..[_s(z['arg'])] = picked;
      final res = _asMap(await _rpc(_s(z['rpc']), params));
      if (!mounted) return;
      final msg = _s(res['message']).isEmpty
          ? _s(z['saved_label'])
          : _s(res['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      await _loadPage();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// A note, with an optional reminder date that puts it on the follow-ups
  /// inbox the Customers list counts.
  Future<void> _openNoteSheet(Map<String, dynamic> n) async {
    if (n.isEmpty) return;
    final ctl = TextEditingController();
    DateTime? remind;
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => StatefulBuilder(
        builder: (sheetCtx, setLocal) => Padding(
          padding:
              EdgeInsets.only(bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(child: Text(_s(n['title']), style: Ds.t.subtitle)),
                TextButton(
                  onPressed: () => Navigator.pop(sheetCtx, false),
                  child: Text(_s(n['cancel']), style: Ds.t.body),
                ),
              ]),
              SizedBox(height: Ds.space.x12),
              TextField(
                controller: ctl,
                autofocus: true,
                maxLines: 4,
                style: Ds.t.body,
                decoration: InputDecoration(
                  hintText: _s(n['hint']),
                  hintStyle: Ds.t.caption,
                  filled: true,
                  fillColor: Ds.c.bg,
                  border: OutlineInputBorder(borderRadius: Ds.r.rButton),
                ),
              ),
              SizedBox(height: Ds.space.x12),
              Row(children: [
                Expanded(
                  child: Text(
                    remind == null
                        ? ''
                        : '${remind!.year}-${remind!.month.toString().padLeft(2, '0')}-${remind!.day.toString().padLeft(2, '0')}',
                    style: Ds.t.caption,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.event, color: Ds.c.brand),
                  onPressed: () async {
                    final now = DateTime.now();
                    final d = await showDatePicker(
                      context: sheetCtx,
                      initialDate: now,
                      firstDate: now.subtract(const Duration(days: 1)),
                      lastDate: now.add(const Duration(days: 365)),
                    );
                    if (d != null) setLocal(() => remind = d);
                  },
                ),
                SizedBox(width: Ds.space.x8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
                  onPressed: () => Navigator.pop(sheetCtx, true),
                  child: Text(_s(n['ok'])),
                ),
              ]),
              SizedBox(height: Ds.space.x8),
            ]),
          ),
        ),
      ),
    );
    final body = ctl.text.trim();
    ctl.dispose();
    if (saved != true || !mounted) return;
    try {
      final params = Map<String, dynamic>.from(_asMap(n['args']))
        ..[_s(n['arg'])] = body;
      if (remind != null) {
        params[_s(n['date_arg'])] =
            '${remind!.year}-${remind!.month.toString().padLeft(2, '0')}-${remind!.day.toString().padLeft(2, '0')}';
      }
      final res = _asMap(await _rpc(_s(n['rpc']), params));
      if (!mounted) return;
      final msg = _s(res['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: res['ok'] != true);
      if (res['ok'] == true) await _loadTab();
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    }
  }

  /// Merge duplicates: the backend finds them (same phone, GSTIN or drug
  /// licence), says WHY each one matched, and each row carries its own confirm
  /// and its own apply RPC. Nothing about the match is decided here.
  Future<void> _openMergeSheet(Map<String, dynamic> m) async {
    if (m.isEmpty) return;
    Map<String, dynamic> preview;
    try {
      preview = _asMap(await _rpc(_s(m['rpc']), _asMap(m['args'])));
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
      return;
    }
    if (!mounted || preview['ok'] != true) return;
    final items = _asList(preview['items']);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (sctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_s(preview['title']), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x8),
              Text(_s(preview['intro']), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              if (items.isEmpty)
                Text(_s(preview['empty']), style: Ds.t.bodySecondary)
              else
                for (final it in items) ...[
                  _listRow(it),
                  SizedBox(height: Ds.space.x12),
                ],
              SizedBox(height: Ds.space.x8),
            ],
          ),
        ),
      ),
    );
    if (mounted) await _loadPage();
  }

  Widget _tabBar(Map<String, dynamic> page) {
    final tabs = _asList(page['tabs']);
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border(bottom: BorderSide(color: Ds.c.divider)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        child: Row(children: [
          for (final t in tabs)
            _TabButton(
              label: _s(t['label']),
              active: _s(t['key']) == _tabKey,
              onTap: () => _selectTab(_s(t['key'])),
            ),
        ]),
      ),
    );
  }

  Widget _tabBody(Map<String, dynamic> page) {
    if (_loadingTab) return const Center(child: CircularProgressIndicator());
    final tab = _tab;
    if (tab == null) {
      return Center(
          child: Text(_error.isEmpty ? _s(page['empty_label']) : _error,
              style: Ds.t.bodySecondary));
    }
    if (tab['ok'] != true) {
      return Center(child: Text(_s(tab['message']), style: Ds.t.bodySecondary));
    }
    final blocks = _asList(tab['blocks']);
    if (blocks.isEmpty) {
      return Center(
          child: Text(_s(page['empty_label']), style: Ds.t.bodySecondary));
    }
    return RefreshIndicator(
      onRefresh: _loadTab,
      child: ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: blocks.length + (tab['has_more'] == true ? 1 : 0),
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x24),
        itemBuilder: (_, i) {
          if (i < blocks.length) return _block(blocks[i]);
          return _moreButton(tab);
        },
      ),
    );
  }

  Widget _moreButton(Map<String, dynamic> tab) {
    if (tab['has_more'] != true) return const SizedBox.shrink();
    return Center(
      child: _ActionButton(
        label: _s(tab['more_label']),
        color: Ds.c.brand,
        soft: Ds.c.brandSoft,
        onTap: () {
          final args = Map<String, dynamic>.from(_tabArgs[_tabKey] ?? const {});
          final limit = tab['limit'] is num ? (tab['limit'] as num).toInt() : 25;
          args['p_limit'] = limit + 25;
          _tabArgs[_tabKey] = args;
          _loadTab();
        },
      ),
    );
  }
}

// ── Small shared pieces ────────────────────────────────────────────────────

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _TabButton(
      {required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? Ds.c.brand : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: active
              ? Ds.t.bodyStrong.copyWith(color: Ds.c.brand)
              : Ds.t.bodySecondary,
        ),
      ),
    );
  }
}

class _PlainChip extends StatelessWidget {
  final String label;
  const _PlainChip({required this.label});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.c.bg,
        borderRadius: Ds.r.rChip,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

class _FilterChipButton extends StatelessWidget {
  final String label;
  final int? count;
  final bool active;
  final VoidCallback? onTap;
  const _FilterChipButton(
      {required this.label, this.count, required this.active, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
        decoration: BoxDecoration(
          color: active ? Ds.c.brandSoft : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: active ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(
          count == null ? label : '$label  $count',
          style: active
              ? Ds.t.caption.copyWith(color: Ds.c.brand)
              : Ds.t.caption,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color soft;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.label,
      required this.color,
      required this.soft,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rButton,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        decoration: BoxDecoration(
          color: soft,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: color),
        ),
        child: Text(label, style: Ds.t.caption.copyWith(color: color)),
      ),
    );
  }
}
