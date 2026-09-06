// CHANGE #840 — My Account: the customer's own page.
//
// It is the CUSTOMER SIDE of #810's page, off the same registry table. The tab
// list comes from `admin_customer_tab` rows whose audience contains
// 'customer', through my_account_page(); each tab names its own RPC; each RPC
// answers with `blocks[]` and this file owns exactly one renderer per kind:
//
//   kv | tiles | chips | list | table | timeline | note      (shared with #810)
//   nav | embed | toggles | select | actions | calendar      (this page's own)
//
// An unknown kind renders zero pixels rather than throwing, so a block
// invented in SQL tomorrow cannot crash a build shipped today. There is no
// Dart display string anywhere in this file — not a label, not an empty state,
// not a toast, not a month name. `embed` is the one exception in spirit and
// not in fact: the backend names an existing widget by key and decides where
// it sits; Dart only knows which class that key means, exactly as
// `customerMenuScreen` knows which screen a route_key means.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/backend_chip.dart';
import '../kyc/kyc_panel.dart';
import 'profile_account_menu.dart' show customerMenuScreen;
import 'profile_edit_screen.dart' show CustomerProfileForm;

class MyAccountScreen extends StatefulWidget {
  /// A tab_key from the backend registry. Anything the registry does not offer
  /// is ignored and the payload's own default_tab wins.
  final String initialTab;

  /// CMD #1815 — a block's own `section` key, so a link can land on the part
  /// of a tab it was about. The KYC chip asks for 'kyc' and the customer
  /// arrives at Licence & documents rather than at the top of a long tab. A
  /// section this payload does not carry scrolls nowhere, in silence.
  final String initialSection;

  /// Test seam. Null in production -> the real RPCs. The protected suite serves
  /// fixture payloads through this so the renderers can be proven without
  /// Supabase.
  static Future<Object?> Function(String rpc, Map<String, dynamic> params)?
      rpcOverride;

  /// Test seam for opening a stored document, which this page does not own.
  static Future<void> Function(String bucket, String path)? openDoc;

  /// CHANGE #850 — the page RPC is a parameter, not a literal. The customer's
  /// own page keeps `my_account_page`; the supplier's My Account passes
  /// `supplier_account_page` and gets the same renderer, because both answer in
  /// the same block grammar. Nothing else about this file knows which one it is.
  final String pageRpc;

  /// The RenderLog key prefix, so the two pages prove themselves separately.
  final String logPrefix;

  /// A `nav` block names a route_key; this turns one into a screen. Null keeps
  /// the customer menu's own resolver.
  final Widget? Function(String route)? navResolver;

  const MyAccountScreen({
    super.key,
    this.initialTab = '',
    this.initialSection = '',
    this.pageRpc = 'my_account_page',
    this.logPrefix = 'c840_account',
    this.navResolver,
  });

  @override
  State<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends State<MyAccountScreen> {
  SupabaseClient get _sb => Supabase.instance.client;

  Map<String, dynamic>? _page;
  Map<String, dynamic>? _tab;
  String _tabKey = '';
  bool _loadingPage = true;
  bool _loadingTab = false;
  String _error = '';

  /// Per-tab arguments a chips / calendar block asked us to send back, keyed by
  /// tab. The backend names both the parameter and the value; we only carry it.
  final Map<String, Map<String, dynamic>> _tabArgs = {};

  @override
  void initState() {
    super.initState();
    _wantSection = widget.initialSection;
    _loadPage();
  }

  Map<String, dynamic> _asMap(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : <String, dynamic>{};

  List<Map<String, dynamic>> _asList(Object? v) => v is List
      ? v.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];

  String _s(Object? v) => v == null ? '' : v.toString();

  Future<Object?> _rpc(String name, Map<String, dynamic> params) {
    final over = MyAccountScreen.rpcOverride;
    if (over != null) return over(name, params);
    return _sb.rpc(name, params: params);
  }

  Future<void> _loadPage() async {
    setState(() {
      _loadingPage = true;
      _error = '';
    });
    try {
      final m = _asMap(await _rpc(widget.pageRpc, const {}));
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
      RenderLog.write('${widget.logPrefix}_page', '${tabs.length}');
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
    final rpc = _s(_tabDef(_tabKey)?['rpc']);
    if (rpc.isEmpty) {
      setState(() => _tab = null);
      return;
    }
    setState(() => _loadingTab = true);
    try {
      final res =
          await _rpc(rpc, Map<String, dynamic>.from(_tabArgs[_tabKey] ?? const {}));
      if (!mounted) return;
      setState(() {
        _tab = _asMap(res);
        _loadingTab = false;
      });
      RenderLog.write('${widget.logPrefix}_tab_$_tabKey',
          '${_asList(_asMap(res)['blocks']).length}');
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

  void _setArg(String arg, Object? value) {
    if (arg.isEmpty) return;
    final args = Map<String, dynamic>.from(_tabArgs[_tabKey] ?? const {});
    args[arg] = value;
    _tabArgs[_tabKey] = args;
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

  // ── Actions ──────────────────────────────────────────────────────────────
  /// Runs one action the payload described. `kind` decides the shape:
  /// 'rpc' calls and shows the backend's message; 'doc' calls, polls on the
  /// backend's own poll_ms and opens the file at the backend's own bucket+path.
  Future<void> _runAction(Map<String, dynamic> a) async {
    final rpc = _s(a['rpc']);
    if (rpc.isEmpty) return;
    final params = Map<String, dynamic>.from(_asMap(a['args']));

    final prompt = _asMap(a['prompt']);
    if (prompt.isNotEmpty) {
      final value = await _askText(prompt);
      if (value == null) return;
      params[_s(prompt['arg'])] = value;
    }

    try {
      var m = _asMap(await _rpc(rpc, params));
      if (!mounted) return;

      if (_s(a['kind']) == 'doc' && m['ok'] == true) {
        m = await _pollDoc(a, m);
        if (!mounted) return;
        if (_s(m['status']) == 'ready') {
          await _openDoc(_s(m['bucket']), _s(m['path']));
        }
      }

      if (!mounted) return;
      final msg = _s(m['message']);
      if (msg.isNotEmpty) showToast(context, msg, isError: m['ok'] != true);
      await _loadTab();
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
    }
  }

  /// The wait is the backend's: it names the polling RPC, the argument and the
  /// interval, and it says when the document is ready. This never invents a
  /// timeout of its own beyond refusing to poll forever.
  Future<Map<String, dynamic>> _pollDoc(
      Map<String, dynamic> a, Map<String, dynamic> first) async {
    final pollRpc = _s(a['poll_rpc']);
    final pollArg = _s(a['poll_arg']);
    final id = first['statement_id'];
    if (pollRpc.isEmpty || pollArg.isEmpty || id == null) return first;

    var m = first;
    for (var i = 0; i < 20 && _s(m['status']) == 'building'; i++) {
      final ms = m['poll_ms'] is num ? (m['poll_ms'] as num).toInt() : 1500;
      await Future<void>.delayed(Duration(milliseconds: ms));
      if (!mounted) return m;
      m = _asMap(await _rpc(pollRpc, {pollArg: id}));
    }
    return m;
  }

  Future<void> _openDoc(String bucket, String path) async {
    if (bucket.isEmpty || path.isEmpty) return;
    final over = MyAccountScreen.openDoc;
    if (over != null) return over(bucket, path);
    try {
      final url = await _sb.storage.from(bucket).createSignedUrl(path, 300);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString(), isError: true);
    }
  }

  Future<String?> _askText(Map<String, dynamic> prompt) {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
        title: Text(_s(prompt['title']), style: Ds.t.subtitle),
        content: TextField(
          controller: ctl,
          autofocus: true,
          style: Ds.t.body,
          decoration: InputDecoration(
            hintText: _s(prompt['hint']),
            hintStyle: Ds.t.caption,
            filled: true,
            fillColor: Ds.c.bg,
            border: OutlineInputBorder(borderRadius: Ds.r.rButton),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(_s(prompt['cancel']), style: Ds.t.body),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Ds.c.brand),
            onPressed: () => Navigator.pop(dctx, ctl.text.trim()),
            child: Text(_s(prompt['ok'])),
          ),
        ],
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
                  : () => _setArg(
                      arg, c.containsKey('value') ? c['value'] : c['key']),
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
    final chip = backendChipOf(it, 'chip');
    final actions = _asList(it['actions']);
    final row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_s(it['title']), style: Ds.t.bodyStrong),
          if (_s(it['subtitle']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(it['subtitle']), style: Ds.t.caption),
          ],
          if (_s(it['meta']).isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(_s(it['meta']), style: Ds.t.caption),
          ],
        ]),
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
    ]);
    // CHANGE #850 — a row may carry its own buttons. Each is one RPC the
    // payload described, exactly like the `actions` block; a row that sent
    // none draws none, so the customer's page is unchanged.
    if (actions.isEmpty) return row;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      row,
      SizedBox(height: Ds.space.x8),
      Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final a in actions)
            if (a['enabled'] != false)
              _ActionButton(
                label: _s(a['label']),
                color: _toneColor(_s(a['tone'])),
                soft: _toneSoft(_s(a['tone'])),
                selected: a['selected'] == true,
                onTap: () => _runAction(a),
              ),
        ],
      ),
    ]);
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

  /// A row that opens a screen this app already ships. The backend decides
  /// which screens belong on the account page and in what order; a route_key
  /// this build has never heard of resolves to nothing and is skipped in
  /// silence, so a registry row that ships before its screen cannot break the
  /// page.
  Widget? _navScreen(String route) =>
      (widget.navResolver ?? customerMenuScreen)(route);

  Widget _navBlock(Map<String, dynamic> b) {
    final items = _asList(b['items'])
        .where((e) => _navScreen(_s(e['route'])) != null)
        .toList();
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      _card(
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
            InkWell(
              onTap: () {
                final screen = _navScreen(_s(items[i]['route']));
                if (screen == null) return;
                Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => screen));
              },
              child: Container(
                constraints:
                    BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
                alignment: Alignment.centerLeft,
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_s(items[i]['label']), style: Ds.t.bodyStrong),
                        if (_s(items[i]['caption']).isNotEmpty) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(_s(items[i]['caption']), style: Ds.t.caption),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Ds.c.textSecondary),
                ]),
              ),
            ),
          ],
        ]),
      ),
    ]);
  }

  /// An existing widget the backend placed here by key.
  Widget _embedBlock(Map<String, dynamic> b) {
    switch (_s(b['widget'])) {
      case 'kyc_panel':
        return const KycPanel();
      // CMD #1815 — THE profile editor, embedded where the backend put it.
      // There is no separate Edit profile screen any more.
      case 'profile_form':
        return CustomerProfileForm(onSaved: _loadTab);
      default:
        return const SizedBox.shrink();
    }
  }

  /// A switch list. Every switch is one RPC call the payload described: the
  /// backend names the function, the fixed arguments and the argument the new
  /// value goes in. Dart decides nothing about what a switch means.
  Widget _togglesBlock(Map<String, dynamic> b) {
    final items = _asList(b['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    final rpc = _s(b['rpc']);
    final valueArg = _s(b['value_arg']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      if (_s(b['note']).isNotEmpty) ...[
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Text(_s(b['note']), style: Ds.t.caption),
        ),
      ],
      _card(
        child: Column(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) Divider(height: Ds.space.x24, color: Ds.c.divider),
            Row(children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(items[i]['label']), style: Ds.t.body),
                    if (_s(items[i]['caption']).isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(items[i]['caption']), style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Switch(
                value: items[i]['on'] == true,
                activeThumbColor: Ds.c.brand,
                onChanged: rpc.isEmpty || valueArg.isEmpty
                    ? null
                    : (v) => _runAction({
                          'kind': 'rpc',
                          'rpc': rpc,
                          'args': {
                            ..._asMap(items[i]['args']),
                            valueArg: v,
                          },
                        }),
              ),
            ]),
          ],
        ]),
      ),
    ]);
  }

  /// A single-choice list — the message language today. The options, their
  /// order and which one is current all arrive in the payload.
  Widget _selectBlock(Map<String, dynamic> b) {
    final options = _asList(b['options']);
    if (options.isEmpty) return const SizedBox.shrink();
    final rpc = _s(b['rpc']);
    final arg = _s(b['arg']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final o in options)
            _FilterChipButton(
              label: _s(o['label']),
              active: o['active'] == true,
              onTap: rpc.isEmpty || arg.isEmpty
                  ? null
                  : () => _runAction({
                        'kind': 'rpc',
                        'rpc': rpc,
                        'args': {arg: o['value']},
                      }),
            ),
        ],
      ),
    ]);
  }

  /// A row of buttons the payload described, with the current value above them
  /// when it sent one (the quiet-hours window, for instance).
  Widget _actionsBlock(Map<String, dynamic> b) {
    final items = _asList(b['items']);
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      if (_s(b['note']).isNotEmpty) ...[
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x12),
          child: Text(_s(b['note']), style: Ds.t.caption),
        ),
      ],
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_s(b['value']).isNotEmpty) ...[
            Text(_s(b['value']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
          ],
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final a in items)
                if (a['enabled'] != false)
                  _ActionButton(
                    label: _s(a['label']),
                    color: _toneColor(_s(a['tone'])),
                    soft: _toneSoft(_s(a['tone'])),
                    onTap: () => _runAction(a),
                  ),
            ],
          ),
        ]),
      ),
    ]);
  }

  /// The order calendar. The GRID is the payload's: leading blanks, day
  /// numbers, counts and per-cell tone all arrive computed, so the month, the
  /// week start and which day is "next expected" are never worked out here.
  Widget _calendarBlock(Map<String, dynamic> b) {
    final cells = _asList(b['cells']);
    if (cells.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _blockTitle(_s(b['title'])),
        _card(child: Text(_s(b['empty']), style: Ds.t.bodySecondary)),
      ]);
    }
    final weekdays = (b['weekdays'] is List)
        ? (b['weekdays'] as List).map(_s).toList()
        : const <String>[];
    final dayArg = _s(b['day_arg']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _blockTitle(_s(b['title'])),
      _card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_s(b['month_label']).isNotEmpty) ...[
            Text(_s(b['month_label']), style: Ds.t.bodyStrong),
            SizedBox(height: Ds.space.x12),
          ],
          if (weekdays.isNotEmpty)
            Row(
              children: [
                for (final w in weekdays)
                  Expanded(
                    child: Text(w,
                        style: Ds.t.caption, textAlign: TextAlign.center),
                  ),
              ],
            ),
          SizedBox(height: Ds.space.x8),
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: Ds.space.x4,
            crossAxisSpacing: Ds.space.x4,
            children: [
              for (final c in cells)
                _CalendarCell(
                  label: _s(c['label']),
                  has: c['has'] == true,
                  color: _toneColor(_s(c['tone'])),
                  soft: _toneSoft(_s(c['tone'])),
                  onTap: (dayArg.isEmpty || _s(c['value']).isEmpty)
                      ? null
                      : () => _setArg(dayArg, c['value']),
                ),
            ],
          ),
        ]),
      ),
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
      case 'nav':
        return _navBlock(b);
      case 'embed':
        return _embedBlock(b);
      case 'toggles':
        return _togglesBlock(b);
      case 'select':
        return _selectBlock(b);
      case 'actions':
        return _actionsBlock(b);
      case 'calendar':
        return _calendarBlock(b);
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
        title: Text(_s(page?['title']), style: Ds.t.subtitle),
      ),
      body: _loadingPage
          ? const Center(child: CircularProgressIndicator())
          : page == null
              ? Center(child: Text(_error, style: Ds.t.bodySecondary))
              : Column(children: [
                  _header(page),
                  _tabBar(page),
                  Expanded(child: _tabBody(page)),
                ]),
    );
  }

  Widget _header(Map<String, dynamic> page) {
    final chips = _asList(page['chips']);
    return Container(
      width: double.infinity,
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_s(page['subtitle']).isNotEmpty)
          Text(_s(page['subtitle']), style: Ds.t.caption),
        if (chips.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final c in chips)
                if (backendChipVisible(c)) BackendChip(chip: c),
            ],
          ),
        ],
      ]),
    );
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

  /// CMD #1815 — the section a link asked to land on, cleared the moment it
  /// has been shown once so a pull-to-refresh does not yank the customer back.
  /// The payload owns the anchor: a block carries its own `section` key and
  /// this only finds it. A section this build is handed but the payload never
  /// sent scrolls nowhere rather than throwing.
  String _wantSection = '';
  final GlobalKey _sectionKey = GlobalKey();

  void _scheduleSectionScroll(List<Map<String, dynamic>> blocks) {
    if (_wantSection.isEmpty) return;
    if (!blocks.any((b) => _s(b['section']) == _wantSection)) {
      _wantSection = '';
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _sectionKey.currentContext;
      _wantSection = '';
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(ctx,
          duration: const Duration(milliseconds: 250), alignment: 0.05);
      RenderLog.write('${widget.logPrefix}_section', _tabKey);
    });
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
    _scheduleSectionScroll(blocks);
    return RefreshIndicator(
      onRefresh: _loadTab,
      child: ListView.separated(
        padding: EdgeInsets.all(Ds.space.x16),
        itemCount: blocks.length + (tab['has_more'] == true ? 1 : 0),
        separatorBuilder: (_, _) => SizedBox(height: Ds.space.x24),
        itemBuilder: (_, i) {
          if (i >= blocks.length) return _moreButton(tab);
          final section = _s(blocks[i]['section']);
          if (section.isEmpty || section != _wantSection) return _block(blocks[i]);
          return KeyedSubtree(key: _sectionKey, child: _block(blocks[i]));
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
          final limit = tab['limit'] is num ? (tab['limit'] as num).toInt() : 25;
          _setArg('p_limit', limit + 25);
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
          style:
              active ? Ds.t.caption.copyWith(color: Ds.c.brand) : Ds.t.caption,
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color soft;

  /// CHANGE #850 — whether this is the state the row is ALREADY in. It is the
  /// payload's own flag, never inferred here from the label or the args.
  final bool selected;
  final VoidCallback onTap;
  const _ActionButton(
      {required this.label,
      required this.color,
      required this.soft,
      required this.onTap,
      this.selected = false});

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
          color: selected ? color : soft,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: color),
        ),
        child: Text(label,
            style: Ds.t.caption
                .copyWith(color: selected ? Ds.c.surface : color)),
      ),
    );
  }
}

class _CalendarCell extends StatelessWidget {
  final String label;
  final bool has;
  final Color color;
  final Color soft;
  final VoidCallback? onTap;
  const _CalendarCell({
    required this.label,
    required this.has,
    required this.color,
    required this.soft,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: has ? soft : Ds.c.bg,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: has ? color : Ds.c.divider),
        ),
        child: Text(
          label,
          style: has
              ? Ds.t.caption.copyWith(color: color)
              : Ds.t.caption,
        ),
      ),
    );
  }
}
