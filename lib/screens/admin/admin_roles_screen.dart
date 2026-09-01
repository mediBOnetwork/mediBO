// CHANGE #394 — Admin roles & access.
//
// Access used to be one boolean (`admins.is_super`) and nothing else: three
// admins with identical, total power over a money system. This screen is the
// Om-facing end of `admin_permissions` — the same feature_registry +
// permissions shape partners already had — reached from Manage Admins.
//
// Pure renderer, like every other surface here. The admins, the feature
// groups, the three access levels and their labels, the presets and their
// hints all arrive from `admin_roles_screen()`; the toast after a save is the
// backend's own string. Dart owns exactly one thing: which of the three
// backend-named tones a chip is painted with.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

typedef RolesRpc = Future<Map<String, dynamic>> Function(
    String fn, Map<String, dynamic> params);

class AdminRolesScreen extends StatefulWidget {
  const AdminRolesScreen({super.key, this.rpc});

  final RolesRpc? rpc;

  @override
  State<AdminRolesScreen> createState() => _AdminRolesScreenState();
}

class _AdminRolesScreenState extends State<AdminRolesScreen> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  String _selected = '';
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _call(
      String fn, Map<String, dynamic> params) async {
    if (widget.rpc != null) return widget.rpc!(fn, params);
    final res = await Supabase.instance.client.rpc(fn, params: params);
    return Map<String, dynamic>.from(res as Map);
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await _call('admin_roles_screen', const {});
      if (!mounted) return;
      final admins = List<Map<String, dynamic>>.from(
          (res['admins'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
      final editable = admins.where((a) => a['is_super'] != true).toList();
      setState(() {
        _data = res;
        _loading = false;
        _error = null;
        if (_selected.isEmpty && editable.isNotEmpty) {
          _selected = editable.first['email']?.toString() ?? '';
        }
      });
      RenderLog.write('admin_role_rows', editable.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _set(String email, String featureKey, String access) async {
    final busyKey = '$email|$featureKey';
    if (_busy.contains(busyKey)) return;
    setState(() => _busy.add(busyKey));
    try {
      final res = await _call('admin_perm_set', {
        'p_email': email,
        'p_feature_key': featureKey,
        'p_access': access,
      });
      if (!mounted) return;
      if (res['ok'] == true) {
        final toast = res['toast']?.toString() ?? '';
        if (toast.isNotEmpty) showToast(context, toast);
        await _load();
      } else {
        showToast(context, res['message']?.toString() ?? res['error']?.toString() ?? '',
            isError: true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
    if (mounted) setState(() => _busy.remove(busyKey));
  }

  Future<void> _applyPreset(String email, String presetKey) async {
    try {
      final res = await _call('admin_perm_apply_preset', {
        'p_email': email,
        'p_preset_key': presetKey,
      });
      if (!mounted) return;
      if (res['ok'] == true) {
        final toast = res['toast']?.toString() ?? '';
        if (toast.isNotEmpty) showToast(context, toast);
        await _load();
      } else {
        showToast(context, res['message']?.toString() ?? res['error']?.toString() ?? '',
            isError: true);
      }
    } catch (e) {
      if (mounted) showToast(context, e.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        surfaceTintColor: Ds.c.surface,
        elevation: 0,
        title: Text(d?['title']?.toString() ?? '', style: Ds.t.title),
      ),
      body: _body(d),
    );
  }

  Widget _body(Map<String, dynamic>? d) {
    if (_loading) return const _RolesSkeleton();
    if (_error != null) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(_error!, style: Ds.t.bodySecondary, textAlign: TextAlign.center),
        ),
      );
    }
    if (d == null) return const SizedBox.shrink();
    if (d['ok'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Text(d['message']?.toString() ?? '',
              style: Ds.t.bodySecondary, textAlign: TextAlign.center),
        ),
      );
    }

    final admins = List<Map<String, dynamic>>.from(
        (d['admins'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final editable = admins.where((a) => a['is_super'] != true).toList();
    final options = List<Map<String, dynamic>>.from(
        (d['access_options'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final presets = List<Map<String, dynamic>>.from(
        (d['presets'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
    final groups = List<Map<String, dynamic>>.from(
        (d['groups'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));

    final current = editable.firstWhere(
        (a) => (a['email']?.toString() ?? '') == _selected,
        orElse: () => const <String, dynamic>{});
    final access = Map<String, dynamic>.from(
        (current['access'] as Map?) ?? const <String, dynamic>{});

    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x32),
      children: [
        Text(d['subtitle']?.toString() ?? '', style: Ds.t.bodySecondary),
        SizedBox(height: Ds.space.x24),
        ...admins.map((a) => Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: _AdminTile(
                admin: a,
                selected: (a['email']?.toString() ?? '') == _selected,
                onTap: a['is_super'] == true
                    ? null
                    : () => setState(() => _selected = a['email']?.toString() ?? ''),
              ),
            )),
        if (editable.isEmpty) ...[
          SizedBox(height: Ds.space.x16),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d['empty_title']?.toString() ?? '', style: Ds.t.subtitle),
                SizedBox(height: Ds.space.x4),
                Text(d['empty_hint']?.toString() ?? '', style: Ds.t.bodySecondary),
              ],
            ),
          ),
        ],
        if (current.isNotEmpty) ...[
          SizedBox(height: Ds.space.x24),
          _Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(d['preset_label']?.toString() ?? '', style: Ds.t.subtitle),
                SizedBox(height: Ds.space.x4),
                Text(d['preset_hint']?.toString() ?? '', style: Ds.t.caption),
                SizedBox(height: Ds.space.x12),
                Wrap(
                  spacing: Ds.space.x8,
                  runSpacing: Ds.space.x8,
                  children: presets
                      .map((p) => SizedBox(
                            height: Ds.space.x48,
                            child: OutlinedButton(
                              onPressed: () => _applyPreset(
                                  _selected, p['preset_key']?.toString() ?? ''),
                              child: Text(
                                  '${p['label'] ?? ''} · ${p['count_label'] ?? ''}',
                                  style: Ds.t.caption),
                            ),
                          ))
                      .toList(),
                ),
              ],
            ),
          ),
          SizedBox(height: Ds.space.x24),
          ...groups.map((g) {
            final features = List<Map<String, dynamic>>.from(
                (g['features'] as List? ?? const []).map((e) => Map<String, dynamic>.from(e as Map)));
            return Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g['label']?.toString() ?? '', style: Ds.t.caption),
                  SizedBox(height: Ds.space.x8),
                  _Panel(
                    child: Column(
                      children: features
                          .map((f) => FeatureAccessRow(
                                feature: f,
                                access: access[f['feature_key']]?.toString() ?? 'none',
                                options: options,
                                onPick: (v) => _set(_selected,
                                    f['feature_key']?.toString() ?? '', v),
                              ))
                          .toList(),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}

/// One admin in the picker. The role line ("Super admin — full access" or
/// "12 granted") is composed by the backend, never counted in Dart.
class _AdminTile extends StatelessWidget {
  const _AdminTile({required this.admin, required this.selected, this.onTap});

  final Map<String, dynamic> admin;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Ds.c.brandSoft : Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: onTap,
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.space.x48),
          padding: EdgeInsets.all(Ds.space.x16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(admin['email']?.toString() ?? '', style: Ds.t.body),
                    SizedBox(height: Ds.space.x4),
                    Text(
                      [admin['role_label'], admin['zone_label']]
                          .map((e) => e?.toString() ?? '')
                          .where((e) => e.isNotEmpty)
                          .join(' · '),
                      style: Ds.t.caption,
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: Ds.c.brand, size: Ds.space.x24),
            ],
          ),
        ),
      ),
    );
  }
}

/// One feature, three states. The three labels and their tones are the
/// backend's `access_options`, in the backend's order — Dart never names them.
class FeatureAccessRow extends StatelessWidget {
  const FeatureAccessRow({
    super.key,
    required this.feature,
    required this.access,
    required this.options,
    required this.onPick,
  });

  final Map<String, dynamic> feature;
  final String access;
  final List<Map<String, dynamic>> options;
  final void Function(String value) onPick;

  @override
  Widget build(BuildContext context) {
    final hint = feature['hint']?.toString() ?? '';
    return Padding(
      padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(feature['label']?.toString() ?? '', style: Ds.t.body),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(hint, style: Ds.t.caption),
          ],
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            children: options.map((o) {
              final value = o['value']?.toString() ?? '';
              final on = value == access;
              return SizedBox(
                height: Ds.space.x48,
                child: InkWell(
                  borderRadius: Ds.r.rChip,
                  onTap: on ? null : () => onPick(value),
                  // Same reason as the audit filters: an alignment here would
                  // stretch each of the three levels across the whole row.
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
                    decoration: BoxDecoration(
                      color: on ? _toneColor(o['tone']?.toString() ?? '') : Ds.c.surface,
                      borderRadius: Ds.r.rChip,
                      border: Border.all(color: on ? Ds.c.brand : Ds.c.divider),
                    ),
                    child: Text(o['label']?.toString() ?? '', style: Ds.t.caption),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  static Color _toneColor(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.successSoft;
      case 'info':
        return Ds.c.infoSoft;
      case 'danger':
        return Ds.c.dangerSoft;
      case 'warning':
        return Ds.c.warningSoft;
      default:
        return Ds.c.bg;
    }
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: child,
    );
  }
}

class _RolesSkeleton extends StatelessWidget {
  const _RolesSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 4,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (_, __) => Container(
        height: Ds.space.x48 * 2,
        decoration: BoxDecoration(color: Ds.c.surface, borderRadius: Ds.r.rCard),
      ),
    );
  }
}
