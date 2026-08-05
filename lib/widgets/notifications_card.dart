import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/widgets/animations.dart';
import 'package:pharma_b2b/features/whatsapp/data/wa_template_api.dart';
import 'package:pharma_b2b/features/whatsapp/ui/wa_template_editor_screen.dart';

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
        messenger?.showSnackBar(const SnackBar(content: Text("Couldn't update, try again")));
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
            ? 'Enter a valid 10-digit number'
            : "Couldn't add — try again");
        return;
      }
      RenderLog.write('c506_allowlist_added', '$_audience:${m['phone10']}');
      _allowlistPhoneCtl.clear();
      _allowlistLabelCtl.clear();
      await _loadAllowlist();
    } catch (_) {
      if (mounted) setState(() => _allowlistError = "Couldn't add — try again");
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
        messenger?.showSnackBar(const SnackBar(content: Text("Couldn't remove, try again")));
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
        const Text(
          'ALLOWED TEST NUMBERS',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
            color: Color(0xFF6B7280),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Numbers here always receive these notifications, even when a toggle '
          'above is off. For testing during build.',
          style: TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
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
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Text('None yet.', style: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF))),
          )
        else
          Column(children: entries.map((e) {
            final busy = _allowlistRemoving.contains(e.phone10);
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Expanded(
                  child: Text(
                    (e.label != null && e.label!.isNotEmpty) ? '${e.label} — ${e.phone10}' : e.phone10,
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
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Phone number',
                hintStyle: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 3,
            child: TextField(
              controller: _allowlistLabelCtl,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Label (optional)',
                hintStyle: TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                border: OutlineInputBorder(),
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
                  tooltip: 'Add',
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
                const Text(
                  'NOTIFICATIONS',
                  style: TextStyle(
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
              _ChatBackdrop(child: _DeliveredBubble(preview: current)),
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
                _ChatBackdrop(
                  child: _DeliveredBubble(
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
class _ChatBackdrop extends StatelessWidget {
  final Widget child;
  const _ChatBackdrop({required this.child});

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
class _DeliveredBubble extends StatelessWidget {
  final Map<String, dynamic> preview;
  const _DeliveredBubble({required this.preview});

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
      return WaTemplateApi.signedUrl(bucket, path);
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
