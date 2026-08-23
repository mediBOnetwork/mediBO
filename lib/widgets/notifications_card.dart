import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/services/ui_copy.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/animations.dart';
import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';
import 'package:pharma_b2b/design_tokens.dart';
import 'package:pharma_b2b/screens/admin/notify_cost_screen.dart';

// CHANGE #498: Dashboard "Notifications" box — per-action WhatsApp toggles.
// CHANGE #499: collapsible (default collapsed) + fully dynamic row rendering.
//
// Every question this box answers now comes from ONE RPC, notification_matrix():
// which user types exist (audiences), which actions each has, whether a template
// exists for it and its status, and whether the admin may edit/preview/generate
// it. The client renders that payload — it decides nothing about a user type, a
// label, or a template's state. Tabs, labels, tones and tooltips are all the
// backend's. Writes still go through set_notification_setting (unchanged).

class _NotifRow {
  final String audience;
  final String audienceLabel;
  final int audienceSort;
  final String actionKey;
  final String label;
  bool enabled;
  final int sort;
  final String templateId;
  final String templateName;
  final String templateStatus;
  final String templateLabel;
  final String templateTone;
  final bool canEdit;
  final bool canPreview;
  final bool canGenerate;
  final String editLabel;
  final bool hasPendingChange;
  final bool autoManage;

  _NotifRow.fromMap(Map<String, dynamic> m)
      : audience = (m['audience'] ?? '').toString(),
        audienceLabel = (m['audience_label'] ?? '').toString(),
        audienceSort = (m['audience_sort'] as num?)?.toInt() ?? 0,
        actionKey = (m['action_key'] ?? '').toString(),
        label = (m['label'] ?? '').toString(),
        enabled = m['enabled'] == true,
        sort = (m['sort'] as num?)?.toInt() ?? 0,
        templateId = (m['template_id'] ?? '').toString(),
        templateName = (m['template_name'] ?? '').toString(),
        templateStatus = (m['template_status'] ?? '').toString(),
        templateLabel = (m['template_label'] ?? '').toString(),
        templateTone = (m['template_tone'] ?? '').toString(),
        canEdit = m['can_edit'] == true,
        canPreview = m['can_preview'] == true,
        canGenerate = m['can_generate'] == true,
        editLabel = (m['edit_label'] ?? '').toString(),
        hasPendingChange = m['has_pending_change'] == true,
        autoManage = m['auto_manage'] == true;
}

// CHANGE #506: build-time test numbers — a number on this list always
// receives that audience's notifications even when the toggle above is off.
class _AllowlistEntry {
  final String audience;
  final String phone10;
  final String? label;

  _AllowlistEntry({required this.audience, required this.phone10, this.label});
}

/// In-memory cache so re-opening/rebuilding the Dashboard doesn't re-fetch.
List<_NotifRow>? _cachedRows;
List<Map<String, dynamic>>? _cachedAudiences;
String? _cachedNote;
List<_AllowlistEntry>? _cachedAllowlist;
Map<String, dynamic>? _cachedEmail;

class NotificationsCard extends StatefulWidget {
  const NotificationsCard({super.key});

  /// Test seam: how EDIT opens the template editor. Null in production, where it
  /// fetches the templates-screen payload, finds the row and pushes
  /// WaTemplateEditorScreen — the same route the WhatsApp Templates screen uses.
  /// A test sets this to capture the template_id without building the editor.
  @visibleForTesting
  static Future<void> Function(BuildContext context, String templateId)?
      openEditorOverride;

  /// Test seam for the RPC transport, same idea as WaTemplateApi.rpcTransport: a
  /// widget test feeds payloads in without a network or a Supabase client.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcOverride;

  /// Clears the in-memory caches so each test starts from a clean fetch.
  @visibleForTesting
  static void debugResetCache() {
    _cachedRows = null;
    _cachedAudiences = null;
    _cachedNote = null;
    _cachedAllowlist = null;
    _cachedEmail = null;
  }

  @override
  State<NotificationsCard> createState() => _NotificationsCardState();
}

class _NotificationsCardState extends State<NotificationsCard> {
  static const _green = Color(0xFF1B7A43);
  static const _border = Color(0xFFE5E7EB);

  List<_NotifRow>? _rows;
  List<Map<String, dynamic>> _audiences = const [];
  String _note = '';
  bool _loading = true;
  String _audience = '';
  final Set<String> _busyKeys = {};
  bool _expanded = false;

  // cmd #299: email-channel state. One payload (notif_email_admin) carries the
  // config line, the mode options and one row per event; this card only draws
  // it and posts the toggle back.
  Map<String, dynamic>? _email;
  bool _emailLoading = true;
  final Set<String> _emailBusy = {};

  // CHANGE #506: allow-list state.
  List<_AllowlistEntry>? _allowlist;
  bool _allowlistLoading = true;
  bool _allowlistAdding = false;
  String? _allowlistError;
  final Set<String> _allowlistRemoving = {};
  final TextEditingController _allowlistPhoneCtl = TextEditingController();
  final TextEditingController _allowlistLabelCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    RenderLog.write('c499_notif_collapsed_default', 'true');
    if (_cachedRows != null) {
      _rows = _cachedRows;
      _audiences = _cachedAudiences ?? const [];
      _note = _cachedNote ?? '';
      _audience = _firstAudience();
      _loading = false;
      RenderLog.write('c498_notif_box_rendered', 'cached:${_rows!.length}');
    } else {
      _load();
    }
    if (_cachedAllowlist != null) {
      _allowlist = _cachedAllowlist;
      _allowlistLoading = false;
    } else {
      _loadAllowlist();
    }
    if (_cachedEmail != null) {
      _email = _cachedEmail;
      _emailLoading = false;
    } else {
      _loadEmail();
    }
  }

  @override
  void dispose() {
    _allowlistPhoneCtl.dispose();
    _allowlistLabelCtl.dispose();
    super.dispose();
  }

  Future<dynamic> _rpc(String fn, [Map<String, dynamic>? params]) {
    final o = NotificationsCard.rpcOverride;
    if (o != null) return o(fn, params);
    return params == null
        ? Supabase.instance.client.rpc(fn)
        : Supabase.instance.client.rpc(fn, params: params);
  }

  String _firstAudience() {
    if (_audience.isNotEmpty &&
        _audiences.any((a) => a['value'] == _audience)) {
      return _audience;
    }
    return _audiences.isNotEmpty
        ? (_audiences.first['value'] ?? '').toString()
        : '';
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      RenderLog.write('c499_notif_expanded_ontap', 'true');
      final rows = _rows ?? const <_NotifRow>[];
      RenderLog.write('c499_notif_rows_count', '${rows.length}');
      RenderLog.write('notif_matrix_audiences', '${_audiences.length}');
    }
  }

  Future<void> _load() async {
    try {
      final res =
          await _rpc('notification_matrix');
      final m =
          res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
      final audiences = [
        for (final a in (m['audiences'] as List?) ?? const [])
          if (a is Map) Map<String, dynamic>.from(a),
      ]..sort((a, b) => ((a['sort'] as num?)?.toInt() ?? 0)
          .compareTo((b['sort'] as num?)?.toInt() ?? 0));
      // Rows arrive already ordered (audience_sort, then sort). Never re-sort.
      final rows = [
        for (final r in (m['rows'] as List?) ?? const [])
          if (r is Map) _NotifRow.fromMap(Map<String, dynamic>.from(r)),
      ];
      _cachedRows = rows;
      _cachedAudiences = audiences;
      _cachedNote = (m['note'] ?? '').toString();
      if (mounted) {
        setState(() {
          _rows = rows;
          _audiences = audiences;
          _note = (m['note'] ?? '').toString();
          _audience = _firstAudience();
          _loading = false;
        });
        RenderLog.write('c498_notif_box_rendered', 'loaded:${rows.length}');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _toggle(_NotifRow row, bool value) async {
    final prev = row.enabled;
    setState(() {
      row.enabled = value;
      _busyKeys.add(row.actionKey);
    });
    try {
      final ok = await _rpc('set_notification_setting', {
        'p_audience': row.audience,
        'p_action_key': row.actionKey,
        'p_enabled': value,
      }) as bool? ?? false;
      if (!ok) throw Exception('rpc returned false');
      RenderLog.write('c498_notif_toggle_saved', '${row.audience}:${row.actionKey}:$value');
      if (!value) {
        try { RenderLog.write('c508_gate_blocked', '${row.audience}:${row.actionKey}'); } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        setState(() => row.enabled = prev);
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(SnackBar(content: Text(c('notifications.snack_update_failed'))));
      }
    } finally {
      if (mounted) setState(() => _busyKeys.remove(row.actionKey));
    }
  }

  void _showMessage(String? message) {
    final msg = (message ?? '').trim();
    if (msg.isEmpty || !mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── edit ───────────────────────────────────────────────────────────────────

  /// EDIT. A row with no template yet (can_generate) mints one first, then opens
  /// the editor on the returned id. Everything shown is the backend's: the
  /// generate message, the editor's own screen. On return the matrix is
  /// re-fetched so the row's template_label reflects the edit.
  Future<void> _edit(_NotifRow row) async {
    var templateId = row.templateId;
    if (row.canGenerate) {
      try {
        final res = await _rpc('notification_generate_template', {
          'p_audience': row.audience,
          'p_action_key': row.actionKey,
        });
        final m =
            res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
        if (m['ok'] != true) {
          _showMessage((m['message'] ?? '').toString());
          return; // an error changes nothing else
        }
        _showMessage((m['message'] ?? '').toString());
        templateId = (m['template_id'] ?? '').toString();
      } catch (_) {
        return;
      }
    }
    if (templateId.isEmpty || !mounted) return;
    await _openEditor(templateId);
    if (mounted) await _load(); // re-fetch so template_label updates
  }

  Future<void> _openEditor(String templateId) async {
    final override = NotificationsCard.openEditorOverride;
    if (override != null) {
      await override(context, templateId);
      return;
    }
    // The same route the WhatsApp Templates screen uses: the editor renders a
    // template ROW out of the wa_templates_screen() payload, so we fetch that
    // payload and hand it the matching row.
    Map<String, dynamic> screen = const {};
    Map<String, dynamic>? tpl;
    try {
      screen = await WaTemplateApi.screen();
      for (final t in (screen['templates'] as List?) ?? const []) {
        if (t is Map && (t['id'] ?? '').toString() == templateId) {
          tpl = Map<String, dynamic>.from(t);
          break;
        }
      }
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => WaTemplateEditorScreen(
          screen: screen,
          template: tpl ?? {'id': templateId},
        ),
      ),
    );
  }

  // ── preview ──────────────────────────────────────────────────────────────────

  /// PREVIEW as a bottom sheet — the delivered message, not a new screen.
  Future<void> _preview(_NotifRow row) async {
    try {
      final res =
          await _rpc('wa_template_preview_pair', {'p_template_id': row.templateId});
      final m =
          res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
      if (!mounted) return;
      if (m['error'] != null) {
        _showMessage((m['message'] ?? '').toString());
        return;
      }
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.white,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => _PreviewSheet(
          pair: m,
          summary: row.templateLabel,
          summaryTone: row.templateTone,
        ),
      );
    } catch (_) {}
  }

  // ── allow-list (unchanged) ───────────────────────────────────────────────────

  Future<void> _loadAllowlist() async {
    try {
      final res = await _rpc('get_notification_allowlist');
      final list = (res as List).map((r) {
        final m = Map<String, dynamic>.from(r as Map);
        return _AllowlistEntry(
          audience: m['audience'] as String? ?? '',
          phone10: m['phone10'] as String? ?? '',
          label: m['label'] as String?,
        );
      }).toList();
      _cachedAllowlist = list;
      if (mounted) setState(() { _allowlist = list; _allowlistLoading = false; });
    } catch (_) {
      if (mounted) setState(() => _allowlistLoading = false);
    }
  }

  Future<void> _addAllowlistEntry() async {
    final phone = _allowlistPhoneCtl.text.trim();
    if (phone.isEmpty) return;
    final label = _allowlistLabelCtl.text.trim();
    setState(() { _allowlistAdding = true; _allowlistError = null; });
    try {
      final res = await _rpc('add_notification_allowlist', {
        'p_audience': _audience,
        'p_phone': phone,
        'p_label': label.isEmpty ? null : label,
      });
      final m = res is Map ? Map<String, dynamic>.from(res) : const <String, dynamic>{};
      if (m['ok'] != true) {
        final err = m['error'] as String?;
        setState(() => _allowlistError = err == 'need_10_digits'
            ? c('notifications.allowlist_error_bad_phone')
            : c('notifications.allowlist_error_add_failed'));
        return;
      }
      RenderLog.write('c506_allowlist_added', '$_audience:${m['phone10']}');
      _allowlistPhoneCtl.clear();
      _allowlistLabelCtl.clear();
      await _loadAllowlist();
    } catch (_) {
      if (mounted) {
        setState(() =>
            _allowlistError = c('notifications.allowlist_error_add_failed'));
      }
    } finally {
      if (mounted) setState(() => _allowlistAdding = false);
    }
  }

  Future<void> _removeAllowlistEntry(_AllowlistEntry entry) async {
    setState(() => _allowlistRemoving.add(entry.phone10));
    try {
      await _rpc('remove_notification_allowlist', {
        'p_audience': entry.audience,
        'p_phone': entry.phone10,
      });
      RenderLog.write('c506_allowlist_removed', '${entry.audience}:${entry.phone10}');
      await _loadAllowlist();
    } catch (_) {
      if (mounted) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        messenger?.showSnackBar(SnackBar(content: Text(c('notifications.snack_remove_failed'))));
      }
    } finally {
      if (mounted) setState(() => _allowlistRemoving.remove(entry.phone10));
    }
  }

  // ── tabs, rows ───────────────────────────────────────────────────────────────

  Widget _segButton(String label, String value) {
    final selected = _audience == value;
    return GestureDetector(
      onTap: () => setState(() => _audience = value),
      child: Container(
        margin: const EdgeInsets.only(right: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? _green : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }

  Widget _miniIcon(IconData icon, String tooltip, VoidCallback onTap) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 18, color: _green),
        tooltip: tooltip.isEmpty ? null : tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        visualDensity: VisualDensity.compact,
        splashRadius: 18,
      ),
    );
  }

  Widget _row(_NotifRow row) {
    final busy = _busyKeys.contains(row.actionKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  row.label,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF111827),
                  ),
                ),
                if (row.templateLabel.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      row.templateLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: _toneColor(row.templateTone),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // Edit + preview sit immediately LEFT of the switch, compact enough
          // that the row is no taller than the switch alone.
          if (row.canEdit)
            _miniIcon(Icons.edit_outlined, row.editLabel, () => _edit(row)),
          if (row.canPreview)
            _miniIcon(Icons.visibility_outlined, row.templateLabel,
                () => _preview(row)),
          const SizedBox(width: 2),
          busy
              ? const SizedBox(
                  width: 34,
                  height: 20,
                  child: Center(
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              : Switch(
                  value: row.enabled,
                  activeColor: _green,
                  onChanged: (v) => _toggle(row, v),
                ),
        ],
      ),
    );
  }

  Widget _skeleton() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(4, (i) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                SkeletonBox(width: 160 - (i * 12.0), height: 12),
                const Spacer(),
                const SkeletonBox(width: 34, height: 18, radius: 10),
              ],
            ),
          )),
    );
  }

  Widget _expandedBody() {
    final rows = _rows ?? const <_NotifRow>[];
    final visible = rows.where((r) => r.audience == _audience).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: Color(0xFFE5E7EB)),
        ),
        // One tab per user type the backend knows about — never a hardcoded
        // Customer/Supplier pair. Ordered by the backend's sort, captioned with
        // its label.
        if (_audiences.isNotEmpty)
          Container(
            padding: const EdgeInsets.fromLTRB(3, 3, 0, 0),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Wrap(
              children: [
                for (final a in _audiences)
                  _segButton((a['label'] ?? '').toString(),
                      (a['value'] ?? '').toString()),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (_loading)
          _skeleton()
        else if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              _note,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          )
        else
          Column(children: visible.map(_row).toList()),
        _buildAllowlistSection(),
        _buildEmailSection(),
      ],
    );
  }

  // CHANGE #506: build-time test numbers, scoped to the currently selected
  // audience tab — a number here always receives that audience's
  // notifications even when a toggle above is off.
  Widget _buildAllowlistSection() {
    final entries = (_allowlist ?? const <_AllowlistEntry>[])
        .where((a) => a.audience == _audience)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Divider(height: 1, color: Color(0xFFE5E7EB)),
        ),
        Text(
          c('notifications.allowlist_heading'),
          style: const TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          c('notifications.allowlist_note'),
          style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
        ),
        const SizedBox(height: 8),
        if (_allowlistLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              width: 14, height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(c('notifications.allowlist_empty'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          )
        else
          Column(children: entries.map((e) {
            final busy = _allowlistRemoving.contains(e.phone10);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(
                  child: Text(
                    (e.label != null && e.label!.isNotEmpty)
                        ? cf('notifications.allowlist_entry_labelled',
                            {'label': e.label!, 'phone': e.phone10})
                        : e.phone10,
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                busy
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: Center(child: SizedBox(width: 12, height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                      )
                    : IconButton(
                        onPressed: () => _removeAllowlistEntry(e),
                        icon: const Icon(Icons.close, size: 16, color: Color(0xFF9CA3AF)),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                        visualDensity: VisualDensity.compact,
                      ),
              ]),
            );
          }).toList()),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            flex: 3,
            child: TextField(
              controller: _allowlistPhoneCtl,
              decoration: InputDecoration(
                isDense: true,
                hintText: c('notifications.allowlist_hint_phone'),
                hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _allowlistLabelCtl,
              decoration: InputDecoration(
                isDense: true,
                hintText: c('notifications.allowlist_hint_label'),
                hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: const OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 6),
          _allowlistAdding
              ? const SizedBox(
                  width: 32, height: 32,
                  child: Center(child: SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))),
                )
              : IconButton(
                  onPressed: _addAllowlistEntry,
                  icon: const Icon(Icons.add_circle, size: 26, color: _green),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: c('notifications.allowlist_tooltip_add'),
                ),
        ]),
        if (_allowlistError != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(_allowlistError!,
                style: const TextStyle(fontSize: 11.5, color: Color(0xFFDC2626), fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }



  // ─────────────────────────────── cmd #299: the email channel ──────────────
  // Email is the third channel: push, then WhatsApp, then email as the fallback
  // and the permanent record. Every word below — the section copy, the mode
  // names, the per-event status chip — arrives in notif_email_admin(); this
  // card decides nothing except which audience tab is showing.

  Future<void> _loadEmail() async {
    try {
      final res = await _rpc('notif_email_admin');
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      _cachedEmail = m;
      if (!mounted) return;
      setState(() {
        _email = m;
        _emailLoading = false;
      });
      RenderLog.write(
          'c299_email_rows', '${(m['rows'] as List?)?.length ?? 0}');
    } catch (_) {
      if (mounted) setState(() => _emailLoading = false);
    }
  }

  List<Map<String, dynamic>> _emailRowsForAudience() {
    final all = (_email?['rows'] as List?) ?? const [];
    return [
      for (final r in all)
        if (r is Map && (r['audience'] ?? '').toString() == _audience)
          Map<String, dynamic>.from(r),
    ];
  }

  Future<void> _setEmailRoute(
      Map<String, dynamic> row, {bool? enabled, String? mode}) async {
    final key = (row['event_key'] ?? '').toString();
    setState(() => _emailBusy.add(key));
    try {
      final res = await _rpc('notif_email_route_set', {
        'p_event_key': key,
        if (enabled != null) 'p_enabled': enabled,
        if (mode != null) 'p_mode': mode,
      });
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      if (m['ok'] != true) throw Exception((m['message'] ?? '').toString());
      RenderLog.write('c299_email_toggle', '$key:${enabled ?? mode}');
      await _loadEmail();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(c('notif_email.update_failed'))));
      }
    } finally {
      if (mounted) setState(() => _emailBusy.remove(key));
    }
  }

  Widget _buildEmailSection() {
    final cfg = _email?['config'] is Map
        ? Map<String, dynamic>.from(_email!['config'] as Map)
        : const <String, dynamic>{};
    final rows = _emailRowsForAudience();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(vertical: Ds.space.x12),
          child: Divider(height: 1, color: Ds.c.divider),
        ),
        Text(
          (_email?['title'] ?? c('notif_email.section_title')).toString(),
          style: Ds.t.bodyStrong,
        ),
        SizedBox(height: Ds.space.x4),
        Text((_email?['subtitle'] ?? '').toString(), style: Ds.t.caption),
        if (cfg.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Text(
            '${cfg['from_label'] ?? ''}: ${cfg['from_display'] ?? ''}',
            style: Ds.t.caption,
          ),
        ],
        SizedBox(height: Ds.space.x12),
        // Two doors out of this card: the money view, and the person view.
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            _linkChip(Icons.currency_rupee, c('notif_email.cost_link'), () {
              RenderLog.write('c299_cost_opened', 'true');
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const NotifyCostScreen()));
            }),
            _linkChip(Icons.person_off_outlined, c('notif_email.optouts_link'),
                _openOptOuts),
          ],
        ),
        SizedBox(height: Ds.space.x12),
        if (_emailLoading)
          _skeleton()
        else if (rows.isEmpty)
          Text((_email?['empty_text'] ?? '').toString(), style: Ds.t.caption)
        else
          Column(children: rows.map(_emailRow).toList()),
      ],
    );
  }

  Widget _linkChip(IconData icon, String label, VoidCallback onTap) =>
      InkWell(
        onTap: onTap,
        borderRadius: Ds.r.rChip,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x12, vertical: Ds.space.x8),
          decoration: BoxDecoration(
            color: Ds.c.brandSoft,
            borderRadius: Ds.r.rChip,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: Ds.space.x16, color: Ds.c.brand),
              SizedBox(width: Ds.space.x8),
              Text(label, style: Ds.t.caption.copyWith(color: Ds.c.brand)),
            ],
          ),
        ),
      );

  Widget _emailRow(Map<String, dynamic> row) {
    final key = (row['event_key'] ?? '').toString();
    final busy = _emailBusy.contains(key);
    final on = row['email_enabled'] == true;
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text((row['label'] ?? '').toString(), style: Ds.t.caption),
                Text(
                  on
                      ? '${row['mode_label'] ?? ''} · ${row['status_label'] ?? ''}'
                      : (row['status_label'] ?? '').toString(),
                  style: Ds.t.caption
                      .copyWith(color: _toneColor((row['status_tone'] ?? '').toString())),
                ),
              ],
            ),
          ),
          SizedBox(width: Ds.space.x8),
          _miniIcon(Icons.mail_outline, c('notif_email.edit'),
              () => _openEmailTemplate(row)),
          if (busy)
            SizedBox(
              width: Ds.space.x32,
              height: Ds.space.x24,
              child: const Center(
                child: SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            )
          else
            Switch(
              value: on,
              activeColor: _green,
              onChanged: (v) => _setEmailRoute(row, enabled: v),
            ),
        ],
      ),
    );
  }


  void _openEmailTemplate(Map<String, dynamic> row) {
    RenderLog.write('c299_email_editor', (row['event_key'] ?? '').toString());
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _EmailTemplateSheet(
        row: row,
        languages: [
          for (final l in (_email?['language_options'] as List?) ?? const [])
            if (l is Map) Map<String, dynamic>.from(l),
        ],
        rpc: _rpc,
        onSaved: _loadEmail,
      ),
    );
  }

  void _openOptOuts() {
    RenderLog.write('c299_optouts_opened', 'true');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (_) => _OptOutSheet(rpc: _rpc),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 20),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleExpanded,
            child: Row(
              children: [
                const Icon(Icons.notifications_none, size: 16, color: Color(0xFF374151)),
                const SizedBox(width: 7),
                Text(
                  c('notifications.card_title'),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: Color(0xFF374151),
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            alignment: Alignment.topCenter,
            child: _expanded ? _expandedBody() : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// Tone → text colour, the design-system muted palette. The tone KEY is the
/// backend's; only its colour is resolved here, the same way every screen does.
Color _toneColor(String tone) {
  switch (tone) {
    case 'good':
      return const Color(0xFF065F46);
    case 'warn':
      return const Color(0xFF92400E);
    case 'bad':
      return const Color(0xFF991B1B);
    case 'info':
      return const Color(0xFF1E40AF);
    default:
      return const Color(0xFF6B7280);
  }
}

// ── preview sheet ──────────────────────────────────────────────────────────────

/// The preview bottom sheet: the template summary line, then the CURRENT wording
/// as a delivered WhatsApp bubble, and — while Meta reviews a change — the
/// PREVIOUS wording still going out, beneath it. Every label is the backend's.
class _PreviewSheet extends StatelessWidget {
  final Map<String, dynamic> pair;
  final String summary;
  final String summaryTone;
  const _PreviewSheet({
    required this.pair,
    required this.summary,
    required this.summaryTone,
  });

  @override
  Widget build(BuildContext context) {
    final current =
        (pair['current'] as Map?)?.cast<String, dynamic>() ?? const {};
    final currentLabel = (pair['current_label'] ?? '').toString();
    final currentTone = (pair['current_tone'] ?? '').toString();
    final hasPrevious = pair['has_previous'] == true;
    final previousLabel = (pair['previous_label'] ?? '').toString();
    final previousAt = (pair['previous_at'] ?? '').toString();
    final previousBody = (pair['previous_body'] ?? '').toString();
    final previousPlain = (pair['previous_plain'] ?? '').toString();
    final previousSegments = (pair['previous_segments'] as List?) ?? const [];

    return SafeArea(
      top: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              if (summary.isNotEmpty)
                Text(
                  summary,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _toneColor(summaryTone),
                  ),
                ),
              const SizedBox(height: 14),
              if (currentLabel.isNotEmpty) ...[
                Text(
                  currentLabel,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _toneColor(currentTone),
                  ),
                ),
                const SizedBox(height: 6),
              ],
              WaChatBackdrop(child: WaDeliveredBubble(preview: current)),
              if (hasPrevious) ...[
                const SizedBox(height: 18),
                if (previousLabel.isNotEmpty)
                  Text(
                    previousLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF6B7280),
                    ),
                  ),
                if (previousAt.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      previousAt,
                      style: const TextStyle(
                          fontSize: 11, color: Color(0xFF9CA3AF)),
                    ),
                  ),
                const SizedBox(height: 6),
                WaChatBackdrop(
                  child: WaDeliveredBubble(
                    // Shaped like a preview payload so one bubble paints both:
                    // previous_segments are the styled runs, previous_plain the
                    // marker-stripped fallback, previous_body the last resort.
                    preview: {
                      'body_segments': previousSegments,
                      'body_plain': previousPlain,
                      'body_rendered': previousBody,
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Plain chat-style backdrop so the bubble reads as a phone screen.
class WaChatBackdrop extends StatelessWidget {
  final Widget child;
  const WaChatBackdrop({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        color: Color(0xFFECE5DD),
        borderRadius: BorderRadius.all(Radius.circular(12)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: child,
        ),
      ),
    );
  }
}

/// A delivered WhatsApp message: the media header flush at the top, then the
/// body (with example values already substituted), then the footer, with the
/// buttons rendered as full-width tiles BELOW the bubble — the same reading a
/// pharmacy gets. Reads a wa_template_preview-shaped payload.
///
/// Public because the WhatsApp Templates list reuses this exact bubble for its
/// own row-level preview: one delivered-message widget, two callers, so the two
/// previews cannot drift. It paints whatever payload it is handed and never
/// looks at a template's status — DRAFT, PENDING, REJECTED and APPROVED all
/// render the same bubble; status only ever decides the LABEL above it.
class WaDeliveredBubble extends StatelessWidget {
  final Map<String, dynamic> preview;
  const WaDeliveredBubble({super.key, required this.preview});

  @override
  Widget build(BuildContext context) {
    final rawHeader = preview['header'];
    final header = rawHeader is Map ? rawHeader.cast<String, dynamic>() : null;
    final format = (header?['format'] ?? '').toString().toUpperCase();
    final textHeader =
        format == 'TEXT' ? (header?['text'] ?? '').toString() : '';
    // WhatsApp renders *bold*, _italic_ and ~strike~; the customer never sees a
    // literal marker. The backend already split the message into styled
    // segments, so the bubble paints them and never parses asterisks. body_plain
    // is the marker-stripped fallback, body_rendered the last resort.
    final bodySegments = (preview['body_segments'] as List?) ?? const [];
    final bodyPlain = (preview['body_plain'] ?? '').toString();
    final body = bodyPlain.isNotEmpty
        ? bodyPlain
        : (preview['body_rendered'] ?? preview['body'] ?? '').toString();
    final footerSegments = (preview['footer_segments'] as List?) ?? const [];
    final footer = (preview['footer'] ?? '').toString();
    final showMedia = header != null && format.isNotEmpty && format != 'TEXT';
    final buttons = [
      for (final b in (preview['buttons'] as List?) ?? const [])
        if (b is Map) b.cast<String, dynamic>(),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          key: const Key('notif_preview_bubble'),
          decoration: BoxDecoration(
            color: const Color(0xFFE7F8D8),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showMedia) _BubbleMedia(header: header),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (textHeader.isNotEmpty) ...[
                      Text(
                        textHeader,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF111827)),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (bodySegments.isNotEmpty)
                      _segmentText(
                        bodySegments,
                        const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                            color: Color(0xFF111827)),
                      )
                    else
                      Text(
                        body,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            height: 1.35,
                            color: Color(0xFF111827)),
                      ),
                    if (footerSegments.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      _segmentText(
                        footerSegments,
                        const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: Color(0xFF6B7280)),
                      ),
                    ] else if (footer.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        footer,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: Color(0xFF6B7280)),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 6),
          _BubbleButtons(buttons: buttons),
        ],
      ],
    );
  }

  /// Paints already-split segments: one TextSpan each, bold / italic / strike
  /// exactly as the backend flagged them. No markup is parsed here — the split
  /// happened server-side, so a `*` never reaches the customer as a `*`.
  Widget _segmentText(List<dynamic> segments, TextStyle base) => Text.rich(
        TextSpan(
          children: [
            for (final s in segments)
              if (s is Map)
                TextSpan(
                  text: (s['text'] ?? '').toString(),
                  style: base.copyWith(
                    fontWeight: s['bold'] == true ? FontWeight.bold : null,
                    fontStyle: s['italic'] == true ? FontStyle.italic : null,
                    decoration: s['strike'] == true
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
          ],
        ),
        style: base,
      );
}

/// The media header inside the bubble: a private-bucket sample is signed from
/// the bucket and path the backend named; an approved image uses media_url as
/// is. A PDF or video is a file tile.
class _BubbleMedia extends StatefulWidget {
  final Map<String, dynamic> header;
  const _BubbleMedia({required this.header});

  @override
  State<_BubbleMedia> createState() => _BubbleMediaState();
}

class _BubbleMediaState extends State<_BubbleMedia> {
  late final Future<String?> _url;

  @override
  void initState() {
    super.initState();
    _url = _resolve(widget.header);
  }

  Future<String?> _resolve(Map<String, dynamic> h) async {
    final mediaUrl = (h['media_url'] ?? '').toString();
    if (mediaUrl.isNotEmpty) return mediaUrl;
    final bucket = (h['storage_bucket'] ?? '').toString();
    final path = (h['storage_path'] ?? '').toString();
    if (bucket.isNotEmpty && path.isNotEmpty) {
      // Resized render — signing the full-res original fails to decode on mobile
      // (renders fine on web). The bubble media box is small; 1080 is ample.
      return WaTemplateApi.signedUrl(bucket, path, renderWidth: 1080);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.header;
    const topRadius = BorderRadius.only(
        topLeft: Radius.circular(12), topRight: Radius.circular(12));
    if (h['is_image'] == true) {
      return FutureBuilder<String?>(
        future: _url,
        builder: (context, snap) {
          final url = (snap.data ?? '').toString();
          if (url.isEmpty) return _fileTile(h);
          return ClipRRect(
            borderRadius: topRadius,
            child: Image.network(
              url,
              width: double.infinity,
              height: 160,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => _fileTile(h),
            ),
          );
        },
      );
    }
    return _fileTile(h);
  }

  Widget _fileTile(Map<String, dynamic> h) {
    final label = (h['file_label'] ?? '').toString();
    final icon = h['is_pdf'] == true
        ? Icons.picture_as_pdf_outlined
        : h['is_video'] == true
            ? Icons.videocam_outlined
            : Icons.image_outlined;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.only(
            topLeft: Radius.circular(12), topRight: Radius.circular(12)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: const Color(0xFF1B7A43)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827)),
            ),
          ),
        ],
      ),
    );
  }
}

/// The button tiles BELOW the bubble: one full-width tile per row, never side
/// by side, a hairline between. Text and kind_label are the backend's.
class _BubbleButtons extends StatelessWidget {
  final List<Map<String, dynamic>> buttons;
  const _BubbleButtons({required this.buttons});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('notif_preview_buttons'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0)
              const Divider(
                  height: 1, thickness: 0.5, color: Color(0xFFE5E7EB)),
            _tile(buttons[i]),
          ],
        ],
      ),
    );
  }

  Widget _tile(Map<String, dynamic> b) {
    final text = (b['text'] ?? '').toString();
    final kindLabel = (b['kind_label'] ?? '').toString();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFF1E40AF)),
          ),
          if (kindLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              kindLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)),
            ),
          ],
        ],
      ),
    );
  }
}


/// cmd #299 — edit one event's email template in one language at a time.
/// Subject and body are stored on the SAME row the WhatsApp template uses, and
/// the tokens offered are that route's own variable_map, so the two channels can
/// never drift apart.
class _EmailTemplateSheet extends StatefulWidget {
  const _EmailTemplateSheet({
    required this.row,
    required this.languages,
    required this.rpc,
    required this.onSaved,
  });

  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> languages;
  final Future<dynamic> Function(String fn, [Map<String, dynamic>? params]) rpc;
  final Future<void> Function() onSaved;

  @override
  State<_EmailTemplateSheet> createState() => _EmailTemplateSheetState();
}

class _EmailTemplateSheetState extends State<_EmailTemplateSheet> {
  late final TextEditingController _subject;
  late final TextEditingController _body;
  String _lang = 'en';
  bool _saving = false;
  String _previewSubject = '';
  String _previewBody = '';

  @override
  void initState() {
    super.initState();
    _subject = TextEditingController();
    _body = TextEditingController();
    _fill();
  }

  void _fill() {
    final r = widget.row;
    _subject.text =
        (_lang == 'hi' ? r['subject_hi'] : r['subject'] ?? '').toString();
    _body.text = (_lang == 'hi' ? r['body_hi'] : r['body'] ?? '').toString();
  }

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.rpc('notif_email_template_save', {
        'p_event_key': (widget.row['event_key'] ?? '').toString(),
        'p_lang': _lang,
        'p_subject': _subject.text,
        'p_body': _body.text,
      });
      await widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(c('notif_email.update_failed'))));
      }
    }
  }

  Future<void> _preview() async {
    try {
      final res = await widget.rpc('notif_email_preview', {
        'p_event_key': (widget.row['event_key'] ?? '').toString(),
        'p_lang': _lang,
      });
      final m = res is Map
          ? Map<String, dynamic>.from(res)
          : const <String, dynamic>{};
      if (!mounted) return;
      setState(() {
        _previewSubject = (m['subject'] ?? m['message'] ?? '').toString();
        _previewBody = (m['body'] ?? '').toString();
      });
    } catch (_) {/* the preview is a courtesy; a failure must not block Save */}
  }

  @override
  Widget build(BuildContext context) {
    final vars = (widget.row['variables'] as List?) ?? const [];
    return Padding(
      padding: EdgeInsets.only(
        left: Ds.space.x16,
        right: Ds.space.x16,
        top: Ds.space.x16,
        bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text((widget.row['label'] ?? '').toString(), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              children: [
                for (final l in widget.languages)
                  ChoiceChip(
                    label: Text((l['label'] ?? '').toString(),
                        style: Ds.t.caption),
                    selected: _lang == (l['key'] ?? '').toString(),
                    onSelected: (_) {
                      setState(() {
                        _lang = (l['key'] ?? '').toString();
                        _previewSubject = '';
                        _previewBody = '';
                        _fill();
                      });
                    },
                  ),
              ],
            ),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: _subject,
              style: Ds.t.body,
              decoration: InputDecoration(labelText: c('notif_email.subject_hint')),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: _body,
              style: Ds.t.body,
              minLines: 5,
              maxLines: 12,
              decoration: InputDecoration(labelText: c('notif_email.body_hint')),
            ),
            if (vars.isNotEmpty) ...[
              SizedBox(height: Ds.space.x12),
              Text(c('notif_email.variables_hint'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              Wrap(
                spacing: Ds.space.x8,
                runSpacing: Ds.space.x4,
                children: [
                  for (final v in vars)
                    Text(v.toString(), style: Ds.t.caption),
                ],
              ),
            ],
            if (_previewSubject.isNotEmpty) ...[
              SizedBox(height: Ds.space.x16),
              Container(
                width: double.infinity,
                padding: EdgeInsets.all(Ds.space.x12),
                decoration: BoxDecoration(
                    color: Ds.c.bg, borderRadius: Ds.r.rCard),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_previewSubject, style: Ds.t.bodyStrong),
                    SizedBox(height: Ds.space.x4),
                    Text(_previewBody, style: Ds.t.caption),
                  ],
                ),
              ),
            ],
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _preview,
                    child: Text(c('notif_email.preview')),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: Text(c('notif_email.save')),
                  ),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x8),
          ],
        ),
      ),
    );
  }
}

/// cmd #299 — per-user opt-outs. A person can silence any event on any single
/// channel; their language rides along, because one resolver feeds push,
/// WhatsApp and email alike.
class _OptOutSheet extends StatefulWidget {
  const _OptOutSheet({required this.rpc});

  final Future<dynamic> Function(String fn, [Map<String, dynamic>? params]) rpc;

  @override
  State<_OptOutSheet> createState() => _OptOutSheetState();
}

class _OptOutSheetState extends State<_OptOutSheet> {
  final TextEditingController _search = TextEditingController();
  Map<String, dynamic>? _list;
  Map<String, dynamic>? _detail;
  bool _loading = true;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await widget.rpc(
          'notif_optout_users', {'p_search': _search.text});
      if (!mounted) return;
      setState(() {
        _list = res is Map ? Map<String, dynamic>.from(res) : null;
        _loading = false;
      });
      RenderLog.write(
          'c299_optout_users', '${(_list?['users'] as List?)?.length ?? 0}');
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(String userId) async {
    setState(() => _loading = true);
    try {
      final res = await widget.rpc('notif_optout_detail', {'p_user_id': userId});
      if (!mounted) return;
      setState(() {
        _detail = res is Map ? Map<String, dynamic>.from(res) : null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _set(String actionKey, String channel, bool enabled) async {
    final id = '$actionKey:$channel';
    setState(() => _busy.add(id));
    try {
      await widget.rpc('notif_optout_set', {
        'p_user_id': (_detail?['user_id'] ?? '').toString(),
        'p_action_key': actionKey,
        'p_channel': channel,
        'p_enabled': enabled,
      });
      RenderLog.write('c299_optout_set', '$id:$enabled');
      await _open((_detail?['user_id'] ?? '').toString());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(content: Text(c('notif_email.update_failed'))));
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x16,
          bottom: MediaQuery.of(context).viewInsets.bottom + Ds.space.x16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: _detail != null ? _detailView() : _listView(),
        ),
      );

  Widget _listView() {
    final users = (_list?['users'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text((_list?['title'] ?? '').toString(), style: Ds.t.subtitle),
        SizedBox(height: Ds.space.x4),
        Text((_list?['subtitle'] ?? '').toString(), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        TextField(
          controller: _search,
          style: Ds.t.body,
          onSubmitted: (_) => _load(),
          decoration: InputDecoration(
            labelText: c('notif_email.search_hint'),
            suffixIcon: IconButton(
                icon: const Icon(Icons.search), onPressed: _load),
          ),
        ),
        SizedBox(height: Ds.space.x12),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : users.isEmpty
                  ? Text((_list?['empty_text'] ?? '').toString(),
                      style: Ds.t.caption)
                  : ListView.builder(
                      itemCount: users.length,
                      itemBuilder: (_, i) {
                        final u = Map<String, dynamic>.from(users[i] as Map);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text((u['name'] ?? '').toString(),
                              style: Ds.t.body),
                          subtitle: Text(
                            [
                              (u['contact'] ?? '').toString(),
                              (u['language_label'] ?? '').toString(),
                              (u['optout_label'] ?? '').toString(),
                            ].where((t) => t.isNotEmpty).join('  ·  '),
                            style: Ds.t.caption,
                          ),
                          onTap: () => _open((u['user_id'] ?? '').toString()),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _detailView() {
    final events = (_detail?['events'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _detail = null),
            ),
            Expanded(
              child: Text((_detail?['name'] ?? '').toString(),
                  style: Ds.t.subtitle, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        Text(
          '${_detail?['language_heading'] ?? ''}: ${_detail?['language_label'] ?? ''}',
          style: Ds.t.caption,
        ),
        SizedBox(height: Ds.space.x12),
        Text((_detail?['events_heading'] ?? '').toString(), style: Ds.t.caption),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : events.isEmpty
                  ? Text((_detail?['empty_text'] ?? '').toString(),
                      style: Ds.t.caption)
                  : ListView.builder(
                      itemCount: events.length,
                      itemBuilder: (_, i) {
                        final e = Map<String, dynamic>.from(events[i] as Map);
                        final channels =
                            (e['channels'] as List?) ?? const [];
                        return Padding(
                          padding:
                              EdgeInsets.symmetric(vertical: Ds.space.x8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text((e['label'] ?? '').toString(),
                                  style: Ds.t.body),
                              Wrap(
                                spacing: Ds.space.x8,
                                children: [
                                  for (final ch in channels)
                                    if (ch is Map)
                                      _channelChip(
                                          (e['action_key'] ?? '').toString(),
                                          Map<String, dynamic>.from(ch)),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _channelChip(String actionKey, Map<String, dynamic> ch) {
    final key = (ch['key'] ?? '').toString();
    final on = ch['enabled'] == true;
    final busy = _busy.contains('$actionKey:$key');
    return FilterChip(
      label: Text((ch['label'] ?? '').toString(), style: Ds.t.caption),
      selected: on,
      onSelected: busy ? null : (v) => _set(actionKey, key, v),
    );
  }
}
