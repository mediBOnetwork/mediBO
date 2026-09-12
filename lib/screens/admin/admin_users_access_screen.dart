// CHANGE #653 — "Users & access": the ONE screen that edits the matrix every
// other screen is drawn from.
//
// One list for admins and partners. Open a login and you get the nav as rows,
// two toggles per row: View and Write. Write implies View, and turning View
// off turns Write off with it — both of those decisions are made in
// `access_matrix_set()`, and this screen re-renders whatever the RPC hands
// back rather than predicting it.
//
// Nothing here is worded in Dart. Titles, role labels, zone labels, the two
// toggle captions, the "N screens on" summary, the hints and the saved toast
// all arrive from access_users_list() / access_matrix_get().

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/ui_copy.dart';
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

class AdminUsersAccessScreen extends StatefulWidget {
  const AdminUsersAccessScreen({super.key});

  @override
  State<AdminUsersAccessScreen> createState() => _AdminUsersAccessScreenState();
}

class _AdminUsersAccessScreenState extends State<AdminUsersAccessScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final raw = await Supabase.instance.client.rpc('access_users_list');
      final map = raw is List
          ? (raw.isEmpty ? <String, dynamic>{} : (raw.first as Map).cast<String, dynamic>())
          : (raw as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _payload = map;
        _loading = false;
        _error = map['ok'] == true ? '' : (map['message'] ?? '').toString();
      });
      RenderLog.write('c653_users_access_rows',
          ((map['users'] as List?) ?? const []).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    final users = ((p['users'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text((p['title'] ?? '').toString(), style: Ds.t.title),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _AccessSkeleton()
          : _error.isNotEmpty
              ? _AccessMessage(message: _error, onRetry: _load)
              : users.isEmpty
                  ? _AccessMessage(
                      message: (p['empty_hint'] ?? '').toString(),
                      title: (p['empty_title'] ?? '').toString(),
                      onRetry: _load)
                  : ListView.separated(
                      padding: EdgeInsets.all(Ds.space.x16),
                      itemCount: users.length + 1,
                      separatorBuilder: (_, __) =>
                          SizedBox(height: Ds.space.x12),
                      itemBuilder: (_, i) {
                        if (i == 0) {
                          return Padding(
                            padding: EdgeInsets.only(bottom: Ds.space.x4),
                            child: Text((p['subtitle'] ?? '').toString(),
                                style: Ds.t.caption),
                          );
                        }
                        return _UserCard(
                          row: users[i - 1],
                          onOpen: _openMatrix,
                        );
                      },
                    ),
    );
  }

  Future<void> _openMatrix(Map<String, dynamic> row) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _AccessMatrixScreen(
          kind: (row['kind'] ?? '').toString(),
          id: (row['id'] ?? '').toString(),
          name: (row['name'] ?? '').toString(),
        ),
      ),
    );
    if (mounted) _load();
  }
}

/// One login (or one partner business) in the list.
class _UserCard extends StatelessWidget {
  const _UserCard({required this.row, required this.onOpen});

  final Map<String, dynamic> row;
  final ValueChanged<Map<String, dynamic>> onOpen;

  @override
  Widget build(BuildContext context) {
    String s(String k) => (row[k] ?? '').toString();
    return Material(
      color: Ds.c.surface,
      borderRadius: Ds.r.rCard,
      child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: () => onOpen(row),
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s('name'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(s('role_label'), style: Ds.t.caption),
                    SizedBox(height: Ds.space.x4),
                    Wrap(
                      spacing: Ds.space.x8,
                      runSpacing: Ds.space.x4,
                      children: [
                        _Pill(text: s('granted_label')),
                        _Pill(text: s('zone_label')),
                      ],
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: Ds.c.textSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
          color: Ds.c.brandSoft, borderRadius: Ds.r.rChip),
      child: Text(text, style: Ds.t.caption),
    );
  }
}

/// The nav as rows, two toggles per row, for ONE subject.
class _AccessMatrixScreen extends StatefulWidget {
  const _AccessMatrixScreen(
      {required this.kind, required this.id, required this.name});

  final String kind;
  final String id;
  final String name;

  @override
  State<_AccessMatrixScreen> createState() => _AccessMatrixScreenState();
}

class _AccessMatrixScreenState extends State<_AccessMatrixScreen> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String _error = '';
  final Set<String> _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final raw = await Supabase.instance.client.rpc('access_matrix_get',
          params: {'p_kind': widget.kind, 'p_id': widget.id});
      final map = raw is List
          ? (raw.isEmpty ? <String, dynamic>{} : (raw.first as Map).cast<String, dynamic>())
          : (raw as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _payload = map;
        _loading = false;
        _error = map['ok'] == true ? '' : (map['message'] ?? '').toString();
      });
      RenderLog.write('c653_matrix_groups',
          ((map['groups'] as List?) ?? const []).length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// One toggle. The backend decides what the pair becomes (write implies
  /// view; view off clears write) and this screen renders its answer.
  Future<void> _set(String featureKey, bool canView, bool canWrite) async {
    if (_saving.contains(featureKey)) return;
    setState(() => _saving.add(featureKey));
    try {
      final raw = await Supabase.instance.client.rpc('access_matrix_set', params: {
        'p_kind': widget.kind,
        'p_id': widget.id,
        'p_feature_key': featureKey,
        'p_can_view': canView,
        'p_can_write': canWrite,
      });
      final map = raw is List
          ? (raw.isEmpty ? <String, dynamic>{} : (raw.first as Map).cast<String, dynamic>())
          : (raw as Map).cast<String, dynamic>();
      if (!mounted) return;
      if (map['ok'] != true) {
        showToast(context, (map['message'] ?? '').toString(), isError: true);
      } else {
        _applyAnswer(featureKey, map['can_view'] == true, map['can_write'] == true);
        final msg = (map['message'] ?? '').toString();
        if (msg.isNotEmpty) showToast(context, msg);
      }
    } catch (e) {
      if (mounted) showToast(context, '$e', isError: true);
    } finally {
      if (mounted) setState(() => _saving.remove(featureKey));
    }
  }

  /// Write the RPC's OWN answer back into the rendered payload — never the
  /// value that was tapped. A partner staff row clamped by the partner's own
  /// grant comes back different from what was asked for, and that is the
  /// value the row must show.
  void _applyAnswer(String featureKey, bool canView, bool canWrite) {
    final p = _payload;
    if (p == null) return;
    final groups = (p['groups'] as List?) ?? const [];
    for (final g in groups.whereType<Map>()) {
      for (final f in ((g['features'] as List?) ?? const []).whereType<Map>()) {
        if ((f['feature_key'] ?? '').toString() == featureKey) {
          f['can_view'] = canView;
          f['can_write'] = canWrite;
        }
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = _payload ?? const <String, dynamic>{};
    final user = (p['user'] as Map?)?.cast<String, dynamic>() ?? const {};
    final groups = ((p['groups'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList(growable: false);
    final viewLabel = (p['view_label'] ?? '').toString();
    final writeLabel = (p['write_label'] ?? '').toString();
    final ceilingHint = (p['ceiling_hint'] ?? '').toString();
    final lockedHint = (p['locked_hint'] ?? '').toString();

    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(
            (user['name'] ?? widget.name).toString(), style: Ds.t.title),
        backgroundColor: Ds.c.surface,
        elevation: 0,
      ),
      body: _loading
          ? const _AccessSkeleton()
          : _error.isNotEmpty
              ? _AccessMessage(message: _error, onRetry: _load)
              : ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: [
                    Text((user['role_label'] ?? '').toString(),
                        style: Ds.t.caption),
                    if (ceilingHint.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(ceilingHint, style: Ds.t.caption),
                    ],
                    if (lockedHint.isNotEmpty &&
                        groups.isNotEmpty &&
                        _firstLocked(groups)) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(lockedHint, style: Ds.t.caption),
                    ],
                    SizedBox(height: Ds.space.x24),
                    for (final g in groups) ...[
                      Text((g['label'] ?? '').toString(),
                          style: Ds.t.subtitle),
                      SizedBox(height: Ds.space.x8),
                      Container(
                        decoration: BoxDecoration(
                          color: Ds.c.surface,
                          borderRadius: Ds.r.rCard,
                          boxShadow: Ds.elevation.e1,
                        ),
                        child: Column(
                          children: [
                            for (final f in ((g['features'] as List?) ?? const [])
                                .whereType<Map>()
                                .map((e) => e.cast<String, dynamic>()))
                              _FeatureRow(
                                feature: f,
                                viewLabel: viewLabel,
                                writeLabel: writeLabel,
                                busy: _saving
                                    .contains((f['feature_key'] ?? '').toString()),
                                onChanged: _set,
                              ),
                          ],
                        ),
                      ),
                      SizedBox(height: Ds.space.x24),
                    ],
                  ],
                ),
    );
  }

  bool _firstLocked(List<Map<String, dynamic>> groups) {
    for (final g in groups) {
      for (final f in ((g['features'] as List?) ?? const []).whereType<Map>()) {
        if (f['locked'] == true) return true;
      }
    }
    return false;
  }
}

/// One feature, two toggles.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.feature,
    required this.viewLabel,
    required this.writeLabel,
    required this.busy,
    required this.onChanged,
  });

  final Map<String, dynamic> feature;
  final String viewLabel;
  final String writeLabel;
  final bool busy;
  final void Function(String featureKey, bool canView, bool canWrite) onChanged;

  @override
  Widget build(BuildContext context) {
    final key = (feature['feature_key'] ?? '').toString();
    final canView = feature['can_view'] == true;
    final canWrite = feature['can_write'] == true;
    final locked = feature['locked'] == true;

    return Container(
      constraints: BoxConstraints(minHeight: Ds.touch.listRowMinHeight),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Ds.c.divider, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text((feature['label'] ?? '').toString(), style: Ds.t.body),
                if ((feature['hint'] ?? '').toString().isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text((feature['hint'] ?? '').toString(), style: Ds.t.caption),
                ],
              ],
            ),
          ),
          _Toggle(
            label: viewLabel,
            value: canView,
            // Write implies View, so a row that is ON for write cannot have
            // View switched off on its own — the backend would send it back
            // unchanged. Turning View off sends write:false with it.
            enabled: !locked && !busy,
            onChanged: (v) => onChanged(key, v, v ? canWrite : false),
          ),
          SizedBox(width: Ds.space.x8),
          _Toggle(
            label: writeLabel,
            value: canWrite,
            enabled: !locked && !busy,
            onChanged: (v) => onChanged(key, v ? true : canView, v),
          ),
        ],
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: Ds.t.caption),
        SizedBox(
          height: Ds.touch.minTarget,
          child: Switch(
            value: value,
            onChanged: enabled ? onChanged : null,
            activeColor: Ds.c.brand,
          ),
        ),
      ],
    );
  }
}

/// Loading is a skeleton, not a bare spinner.
class _AccessSkeleton extends StatelessWidget {
  const _AccessSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.all(Ds.space.x16),
      itemCount: 6,
      separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
      itemBuilder: (_, __) => Container(
        height: Ds.space.x48 + Ds.space.x24,
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
        ),
      ),
    );
  }
}

/// An error or an empty state — the backend's copy, plus one way forward.
class _AccessMessage extends StatelessWidget {
  const _AccessMessage(
      {required this.message, required this.onRetry, this.title = ''});

  final String message;
  final String title;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty) ...[
              Text(title, style: Ds.t.subtitle, textAlign: TextAlign.center),
              SizedBox(height: Ds.space.x8),
            ],
            Text(message, style: Ds.t.caption, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x24),
            OutlinedButton(
                onPressed: onRetry,
                child: Text(c('users_access.retry'))),
          ],
        ),
      ),
    );
  }
}
