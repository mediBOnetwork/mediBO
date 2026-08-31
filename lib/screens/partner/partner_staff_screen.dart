// CHANGE #399 (1/3) — the partner manages its OWN staff.
//
// Until now a partner login could only be created by the office. This screen
// hands that to the partner, with one hard rule the BACKEND enforces and this
// screen merely obeys: the access options offered for a staff member are the
// ones partner_staff_console() sent, and it only ever sends options at or below
// what the signed-in partner holds itself. There is no client-side idea of
// "what a partner may grant" to get out of step with the server's.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';
import 'partner_console_screen.dart';

class PartnerStaffScreen extends StatefulWidget {
  const PartnerStaffScreen({super.key});

  @override
  State<PartnerStaffScreen> createState() => _PartnerStaffScreenState();
}

class _PartnerStaffScreenState extends State<PartnerStaffScreen> {
  Map<String, dynamic>? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final res = await Supabase.instance.client.rpc('partner_staff_console');
      final map = Map<String, dynamic>.from(res as Map);
      RenderLog.write('partner_staff',
          'ok=${map['ok']} users=${(map['users'] as List?)?.length ?? 0} '
          'write=${map['can_write']}');
      if (!mounted) return;
      setState(() { _d = map; _loading = false; });
    } catch (_) {
      // The console RPC never answered. The screen falls to its error state,
      // whose words come from ui_copy — cached at boot, so they survive the
      // very outage that produced them.
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  /// Every write goes through here: call, print the backend's own message with
  /// the backend's own tone, reload. The screen never decides what happened.
  Future<void> _call(String fn, Map<String, dynamic> params) async {
    try {
      final res = await Supabase.instance.client.rpc(fn, params: params);
      final map = Map<String, dynamic>.from(res as Map);
      if (!mounted) return;
      final msg = (map['message'] as String?) ?? '';
      if (msg.isNotEmpty) {
        showToast(context, msg, isError: map['ok'] != true);
      }
      await _load();
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  Future<void> _addSheet() async {
    final d = _d;
    if (d == null) return;
    final idCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: Ds.space.x16,
          right: Ds.space.x16,
          top: Ds.space.x24,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + Ds.space.x24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text((d['add_label'] as String?) ?? '', style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x16),
            TextField(
              controller: idCtrl,
              autofocus: true,
              decoration: InputDecoration(
                  hintText: (d['add_hint'] as String?) ?? ''),
            ),
            SizedBox(height: Ds.space.x12),
            TextField(
              controller: nameCtrl,
              decoration: InputDecoration(
                  hintText: (d['name_hint'] as String?) ?? ''),
            ),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text((d['save_label'] as String?) ?? ''),
              ),
            ),
            SizedBox(height: Ds.space.x8),
            SizedBox(
              height: Ds.touch.minTarget,
              child: TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text((d['cancel_label'] as String?) ?? ''),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    await _call('partner_staff_add', {
      'p_identity': idCtrl.text.trim(),
      'p_name': nameCtrl.text.trim().isEmpty ? null : nameCtrl.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        foregroundColor: Ds.c.text,
        elevation: 0,
        title: Text((d?['title'] as String?) ?? '', style: Ds.t.title),
      ),
      floatingActionButton: (d != null && d['can_write'] == true)
          ? FloatingActionButton.extended(
              backgroundColor: Ds.c.brand,
              onPressed: _addSheet,
              icon: const Icon(Icons.person_add_alt),
              label: Text((d['add_label'] as String?) ?? ''),
            )
          : null,
      body: _loading
          ? const PartnerSkeleton()
          : (d == null || d['ok'] != true)
              ? PartnerNotice(
                  title: (d?['message'] as String?) == null
                      ? c('partner.error_title')
                      : '',
                  text: (d?['message'] as String?) ??
                      c('partner.error_message'),
                  onRetry: _load,
                  retryLabel: c('partner.retry_label'),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: PartnerStaffView(
                    payload: d,
                    onRemove: (id) =>
                        _call('partner_staff_remove', {'p_id': id}),
                    onAccessSet: (uid, featureKey, access) =>
                        _call('partner_staff_access_set', {
                          'p_user_id': uid,
                          'p_feature_key': featureKey,
                          'p_access': access,
                        }),
                  ),
                ),
    );
  }
}


/// The rendered staff list, split out from the screen so a protected test can
/// pump a payload with no Supabase, no network and no timers. It renders only
/// what the payload contains: the access options offered for a staff member are
/// the ones the BACKEND sent, so a partner can never be shown — let alone
/// send — a grant it does not itself hold.
class PartnerStaffView extends StatelessWidget {
  const PartnerStaffView({
    super.key,
    required this.payload,
    required this.onRemove,
    required this.onAccessSet,
  });

  final Map<String, dynamic> payload;
  final void Function(Object id) onRemove;
  final void Function(Object userId, String featureKey, String access) onAccessSet;

  @override
  Widget build(BuildContext context) {
    final d = payload;
    final users = (d['users'] as List? ?? const []);
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        Text((d['subtitle'] as String?) ?? '', style: Ds.t.bodySecondary),
        if (((d['readonly_text'] as String?) ?? '').isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          PartnerChip(text: d['readonly_text'] as String, tone: 'warning'),
        ],
        SizedBox(height: Ds.space.x24),
        if (users.isEmpty)
          PartnerNotice(text: (d['empty_text'] as String?) ?? '')
        else
          for (final u in users)
            _userCard(d, Map<String, dynamic>.from(u as Map)),
      ],
    );
  }

  Widget _userCard(Map<String, dynamic> d, Map<String, dynamic> u) {
    final perms = (u['permissions'] as List? ?? const []);
    return PartnerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((u['display_name'] as String?) ?? '', style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text((u['identity'] as String?) ?? '', style: Ds.t.caption),
                  ],
                ),
              ),
              PartnerChip(
                  text: (u['status_label'] as String?) ?? '',
                  tone: u['status_tone'] as String?),
            ],
          ),
          if (((u['self_label'] as String?) ?? '').isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            PartnerChip(text: u['self_label'] as String, tone: 'info'),
          ],
          if (perms.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            Text((d['perm_title'] as String?) ?? '', style: Ds.t.caption),
            SizedBox(height: Ds.space.x8),
            for (final p in perms)
              _permRow(u, Map<String, dynamic>.from(p as Map),
                  enabled: u['can_edit'] == true),
            SizedBox(height: Ds.space.x8),
            Text((d['perm_note'] as String?) ?? '', style: Ds.t.caption),
          ],
          if (u['can_remove'] == true) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: () => onRemove(u['id'] as Object),
                style: OutlinedButton.styleFrom(foregroundColor: Ds.c.danger),
                child: Text((d['remove_label'] as String?) ?? ''),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The options come from the payload. A feature the partner holds 'read' on
  /// simply never arrives with a 'write' option, so the subset rule is visible
  /// in the UI and enforced again on the server.
  Widget _permRow(Map<String, dynamic> u, Map<String, dynamic> p,
      {required bool enabled}) {
    final options = (p['options'] as List? ?? const [])
        .map((o) => Map<String, dynamic>.from(o as Map))
        .toList();
    final selected = options.firstWhere(
      (o) => o['selected'] == true,
      orElse: () => options.isEmpty ? <String, dynamic>{} : options.first,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Row(
        children: [
          Expanded(child: Text((p['label'] as String?) ?? '', style: Ds.t.body)),
          SizedBox(width: Ds.space.x12),
          DropdownButton<String>(
            value: selected['value'] as String?,
            underline: const SizedBox.shrink(),
            style: Ds.t.body,
            onChanged: !enabled
                ? null
                : (v) {
                    if (v == null) return;
                    onAccessSet(u['id'] as Object,
                        (p['feature_key'] as String?) ?? '', v);
                  },
            items: [
              for (final o in options)
                DropdownMenuItem<String>(
                  value: o['value'] as String?,
                  child: Text((o['label'] as String?) ?? ''),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
