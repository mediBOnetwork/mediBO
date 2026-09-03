// CHANGE #753 — the supplier page.
//
// Seven tabs, and this file decides NOTHING about any of them. The tab list
// comes from `admin_supplier_tab` via admin_supplier_page(); each tab names its
// own RPC; each RPC answers with `blocks[]` and this file owns exactly one
// renderer per block kind:
//
//   kv | tiles | chips | list | table | timeline | buttons | note
//
// An unknown kind is skipped in silence, so a block invented in SQL tomorrow
// cannot crash a build shipped today. Every string on screen — labels, rupees,
// percentages, chip colours, confirm copy, toast wording — arrives in the
// payload. There is no Dart fallback text anywhere in this file, deliberately:
// substituting one would put a second, staler answer next to the backend's.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/download_bytes.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import '../../widgets/backend_chip.dart';

/// Opens the supplier page for [supplierId] as a full route. [initialTab] is a
/// tab_key from the backend registry; anything the registry does not offer is
/// ignored and the payload's own default_tab wins.
Future<void> openAdminSupplierPage(BuildContext context, String supplierId,
    {String initialTab = ''}) {
  return Navigator.of(context).push(MaterialPageRoute(
    builder: (_) =>
        AdminSupplierPage(supplierId: supplierId, initialTab: initialTab),
  ));
}

class AdminSupplierPage extends StatefulWidget {
  final String supplierId;
  final String initialTab;

  /// Test seam. Null in production -> the real RPCs. The protected suite sets
  /// this to serve fixture payloads so the block renderers can be proven
  /// without Supabase.
  static Future<Object?> Function(String rpc, Map<String, dynamic> params)?
      rpcOverride;

  const AdminSupplierPage(
      {super.key, required this.supplierId, this.initialTab = ''});

  @override
  State<AdminSupplierPage> createState() => _AdminSupplierPageState();
}

class _AdminSupplierPageState extends State<AdminSupplierPage> {
  // Resolved lazily: with `rpcOverride` set (the protected suite) Supabase is
  // never initialised, and an eager field initializer would throw at
  // createState() before a single widget was built.
  SupabaseClient get _sb => Supabase.instance.client;

  Map<String, dynamic>? _page;
  String _tabKey = '';
  bool _loadingPage = true;
  bool _loadingTab = false;
  String _error = '';

  Map<String, dynamic>? _tab;

  /// Per-tab filter arguments the CHIPS block asked us to send back, keyed by
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
    final over = AdminSupplierPage.rpcOverride;
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
          'admin_supplier_page', {'p_supplier_id': widget.supplierId});
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
      RenderLog.write('c753_supplier_page', '${tabs.length}');
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
      final params = <String, dynamic>{'p_supplier_id': widget.supplierId}
        ..addAll(_tabArgs[_tabKey] ?? const {});
      final res = await _rpc(rpc, params);
      if (!mounted) return;
      setState(() {
        _tab = _asMap(res);
        _loadingTab = false;
      });
      RenderLog.write('c753_supplier_tab_$_tabKey',
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
    final rpc = _s(action['rpc']);
    if (rpc.isEmpty) return;

    final params = Map<String, dynamic>.from(_asMap(action['args']));

    // A prompt asks for one extra argument the backend named.
    final prompt = _asMap(action['prompt']);
    if (prompt.isNotEmpty) {
      final value = await _askText(
        title: _s(prompt['title']),
        hint: _s(prompt['hint']),
        okLabel: _s(prompt['ok']),
        cancelLabel: _s(prompt['cancel']),
      );
      if (value == null) return;
      params[_s(prompt['arg'])] = value;
    }

    try {
      final res = await _rpc(rpc, params);
      final m = _asMap(res);
      if (action['export'] == true) {
        final content = _s(m['content']);
        downloadBytes(utf8.encode(content), _s(m['file_name']), _s(m['mime']));
        return;
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

  Future<String?> _askText({
    required String title,
    required String hint,
    required String okLabel,
    required String cancelLabel,
  }) async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: Ds.c.surface,
        shape: RoundedRectangleBorder(borderRadius: Ds.r.rCard),
        title: Text(title, style: Ds.t.subtitle),
        content: TextField(
          controller: ctl,
          autofocus: true,
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

  void _followLink(Map<String, dynamic> link) {
    final copy = _s(link['copy']);
    if (copy.isNotEmpty) {
      Clipboard.setData(ClipboardData(text: copy));
      final toast = _s(link['toast']);
      if (toast.isNotEmpty) showToast(context, toast);
    }
    final tab = _s(link['tab']);
    if (tab.isNotEmpty && _tabDef(tab) != null) _selectTab(tab);
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
      Wrap(
        spacing: Ds.space.x8,
        runSpacing: Ds.space.x8,
        children: [
          for (final c in chips)
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
        ],
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
    final link = _asMap(it['link']);
    final body = Column(
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
                  selected: a['selected'] == true,
                  onTap: () => _runAction(a),
                ),
            ],
          ),
        ],
      ],
    );
    if (link.isEmpty) return body;
    return InkWell(
      onTap: () => _followLink(link),
      borderRadius: Ds.r.rButton,
      child: body,
    );
  }

  Widget _tableBlock(Map<String, dynamic> b) {
    final cols = _asList(b['columns']);
    final rows = b['rows'];
    if (cols.isEmpty || rows is! List) return const SizedBox.shrink();
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
    final link = _asMap(it['link']);
    final row = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
    if (link.isEmpty) return row;
    return InkWell(
      onTap: () => _followLink(link),
      borderRadius: Ds.r.rButton,
      child: row,
    );
  }

  Widget _buttonsBlock(Map<String, dynamic> b) {
    final buttons = _asList(b['buttons']);
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final btn in buttons)
          _ActionButton(
            label: _s(btn['label']),
            color: _toneColor(_s(btn['tone'])),
            soft: _toneSoft(_s(btn['tone'])),
            selected: false,
            onTap: () => _runAction(btn),
          ),
      ],
    );
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
      case 'buttons':
        return _buttonsBlock(b);
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
        leading: BackButton(color: Ds.c.text, onPressed: () => Navigator.pop(context)),
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
    return Container(
      width: double.infinity,
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, 0, Ds.space.x16, Ds.space.x12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_s(page['subtitle']).isNotEmpty)
          Text(_s(page['subtitle']), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
          for (final c in chips)
            if (backendChipVisible(c)) BackendChip(chip: c),
          _PlainChip(label: _s(page['spn_label'])),
          _PlainChip(label: _s(page['zone_label'])),
        ]),
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

  Widget _tabBody(Map<String, dynamic> page) {
    if (_loadingTab) return const Center(child: CircularProgressIndicator());
    final tab = _tab;
    if (tab == null) {
      return Center(
          child: Text(_error.isEmpty ? _s(page['empty_label']) : _error,
              style: Ds.t.bodySecondary));
    }
    if (tab['ok'] != true) {
      return Center(
          child: Text(_s(tab['message']), style: Ds.t.bodySecondary));
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
        itemCount: blocks.length + (_s(tab['more_label']).isEmpty ? 0 : 1),
        separatorBuilder: (_, __) => SizedBox(height: Ds.space.x24),
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
        selected: false,
        onTap: () {
          final args = Map<String, dynamic>.from(_tabArgs[_tabKey] ?? const {});
          final limit = tab['limit'] is num ? (tab['limit'] as num).toInt() : 50;
          args['p_limit'] = limit + 50;
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
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? Ds.c.brand : Ds.c.surface,
              width: Ds.space.x4 / 2,
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
    if (label.trim().isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x8, vertical: Ds.space.x4),
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
  const _FilterChipButton({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final text = count == null ? label : '$label  $count';
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rChip,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: active ? Ds.c.brandSoft : Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: active ? Ds.c.brand : Ds.c.divider),
        ),
        child: Text(
          text,
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
  final bool selected;
  final VoidCallback onTap;
  const _ActionButton({
    required this.label,
    required this.color,
    required this.soft,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: Ds.r.rButton,
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        alignment: Alignment.center,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: selected ? soft : Ds.c.surface,
          borderRadius: Ds.r.rButton,
          border: Border.all(color: selected ? color : Ds.c.divider),
        ),
        child: Text(label, style: Ds.t.caption.copyWith(color: color)),
      ),
    );
  }
}
