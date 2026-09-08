// CHANGE #298 — Admin > Push notifications.
//
// Two jobs: hold the Firebase project values that turn push on at all, and
// carry the per-event push toggle the spec asks for. Everything printed here —
// the page title, each section heading, the Save caption, every event label —
// arrives from push_admin_screen(); this file words nothing.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';

class AdminPushScreen extends StatefulWidget {
  const AdminPushScreen({super.key});

  @override
  State<AdminPushScreen> createState() => _AdminPushScreenState();
}

class _AdminPushScreenState extends State<AdminPushScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  final _fields = <String, TextEditingController>{};
  static const _configKeys = <String>[
    'project_id', 'sender_id', 'api_key', 'app_id',
    'web_api_key', 'web_app_id', 'vapid_key', 'android_package',
  ];

  @override
  void initState() {
    super.initState();
    for (final k in _configKeys) {
      _fields[k] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await Supabase.instance.client.rpc('push_admin_screen');
      if (!mounted) return;
      final map = Map<String, dynamic>.from(res as Map);
      final cfg = Map<String, dynamic>.from(map['config'] as Map? ?? {});
      for (final k in _configKeys) {
        _fields[k]!.text = (cfg[k] as String?) ?? '';
      }
      setState(() {
        _data = map;
        _loading = false;
      });
      RenderLog.write('c298_push_admin',
          ((map['events'] as List?) ?? const []).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveConfig({required bool enabled}) async {
    final patch = <String, dynamic>{'enabled': enabled};
    for (final k in _configKeys) {
      patch[k] = _fields[k]!.text.trim();
    }
    try {
      await Supabase.instance.client
          .rpc('push_config_set', params: {'p_patch': patch});
      await _load();
      if (!mounted) return;
      _toast(UiCopy.t('push_admin.saved'));
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString());
    }
  }

  Future<void> _toggleEvent(String eventKey, bool on) async {
    try {
      final res = await Supabase.instance.client.rpc('notif_event_push_set',
          params: {'p_event_key': eventKey, 'p_enabled': on});
      await _load();
      if (!mounted) return;
      final msg = (res is Map ? res['message'] as String? : null) ?? '';
      if (msg.isNotEmpty) _toast(msg);
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString());
    }
  }

  void _toast(String m) {
    if (m.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(d?['title'] as String? ?? '')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _Message(text: _error!, onRetry: _load)
              : (d?['ok'] as bool? ?? false)
                  ? _content(d!)
                  : _Message(
                      text: d?['message'] as String? ?? '', onRetry: _load),
    );
  }

  Widget _content(Map<String, dynamic> d) {
    final cfg = Map<String, dynamic>.from(d['config'] as Map? ?? {});
    final events = (d['events'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final devices = Map<String, dynamic>.from(d['devices'] as Map? ?? {});
    final canEdit = (d['can_edit_config'] as bool?) ?? false;
    final live = (cfg['enabled'] as bool?) ?? false;

    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [
        _Section(title: d['config_title'] as String? ?? ''),
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((cfg['setup_note'] as String? ?? '').isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(Ds.space.x12),
                  decoration: BoxDecoration(
                    color: Ds.c.warningSoft,
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(cfg['setup_note'] as String, style: Ds.t.caption),
                ),
                SizedBox(height: Ds.space.x16),
              ],
              for (final k in _configKeys) ...[
                TextField(
                  controller: _fields[k],
                  enabled: canEdit,
                  decoration: InputDecoration(labelText: k),
                ),
                SizedBox(height: Ds.space.x12),
              ],
              SizedBox(height: Ds.space.x4),
              SizedBox(
                width: double.infinity,
                height: Ds.touch.minTarget,
                child: FilledButton(
                  onPressed: canEdit ? () => _saveConfig(enabled: true) : null,
                  child: Text(d['save_label'] as String? ?? ''),
                ),
              ),
              if (live) ...[
                SizedBox(height: Ds.space.x8),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: OutlinedButton(
                    onPressed:
                        canEdit ? () => _saveConfig(enabled: false) : null,
                    child: Text(UiCopy.t('push_admin.turn_off')),
                  ),
                ),
              ],
            ],
          ),
        ),
        SizedBox(height: Ds.space.x24),
        _Section(title: d['devices_title'] as String? ?? ''),
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${devices['active'] ?? 0}', style: Ds.t.title),
              Text('${devices['total'] ?? 0}', style: Ds.t.caption),
            ],
          ),
        ),
        SizedBox(height: Ds.space.x24),
        _Section(title: d['events_title'] as String? ?? ''),
        for (final e in events)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x16, vertical: Ds.space.x8),
              constraints:
                  BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(e['label'] as String? ?? '', style: Ds.t.body),
                        SizedBox(height: Ds.space.x4),
                        Text(e['push_body'] as String? ?? '',
                            style: Ds.t.caption,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  Switch(
                    value: (e['push_enabled'] as bool?) ?? false,
                    onChanged: ((e['ready'] as bool?) ?? false)
                        ? (v) => _toggleEvent(e['event_key'] as String, v)
                        : null,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(bottom: Ds.space.x12),
        child: Text(title, style: Ds.t.title),
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.text, required this.onRetry});
  final String text;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(text, textAlign: TextAlign.center, style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              TextButton(
                  onPressed: onRetry,
                  child: Text(UiCopy.t('notif_inbox.retry'))),
            ],
          ),
        ),
      );
}
