// CMD #1935 — Step 2 of registration: the document checklist.
//
// This screen knows the NAME of one RPC and nothing else. Which documents are
// collected, what they are called, which of them are required, which offer an
// "I don't have this" way out, what each card's chip says, and whether the
// step is finished are all decided in `kyc_doc_checklist()` and read from the
// payload. Adding a document, or making one mandatory, is a row in
// customer_doc_types — it never reaches this file.
//
// It is also never the ROOT of the navigation stack: the flow is pushed on top
// of Home (CMD #1935 fixes the blank screen that closing the old root left
// behind), so Close is a pop and always lands somewhere.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../services/registration_payload.dart';
import '../../widgets/customer_surface_widgets.dart';

class CustomerDocsScreen extends StatefulWidget {
  const CustomerDocsScreen({super.key});

  /// Test seam — the same shape every public screen uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  /// Test seam for the storage put. Returns the stored path.
  @visibleForTesting
  static Future<String> Function(
      String bucket, String path, Uint8List bytes, String mime)? uploadTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  static Future<String> upload(
      String bucket, String path, Uint8List bytes, String mime) async {
    final t = uploadTransport;
    if (t != null) return t(bucket, path, bytes, mime);
    await Supabase.instance.client.storage.from(bucket).uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(contentType: mime, upsert: true),
        );
    return path;
  }

  @override
  State<CustomerDocsScreen> createState() => _CustomerDocsScreenState();
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

String _s(Map<String, dynamic>? m, String k) => (m?[k] ?? '').toString();

bool _b(Map<String, dynamic>? m, String k) => m?[k] == true;

class _CustomerDocsScreenState extends State<CustomerDocsScreen> {
  bool _loading = true;
  String _busyKey = '';
  Map<String, dynamic> _payload = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = _asMap(await CustomerDocsScreen.rpc('kyc_doc_checklist'));
      if (!mounted) return;
      setState(() {
        _payload = r ?? const {};
        _loading = false;
      });
      RenderLog.write('c1935_doc_items', _items.length);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      RenderLog.write('c1935_doc_items', 0);
    }
  }

  List<Map<String, dynamic>> get _items {
    final raw = _payload['items'];
    if (raw is! List) return const [];
    return raw.map(_asMap).whereType<Map<String, dynamic>>().toList();
  }

  void _toast(String msg) {
    if (msg.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _pickAndUpload(Map<String, dynamic> item) async {
    final key = _s(item, 'key');
    setState(() => _busyKey = key);
    try {
      final picked =
          await FilePicker.pickFiles(withData: true, allowMultiple: false);
      final f = picked?.files.isNotEmpty == true ? picked!.files.first : null;
      final bytes = f?.bytes;
      if (bytes == null) {
        if (mounted) setState(() => _busyKey = '');
        return;
      }
      final bucket = _s(_payload, 'bucket');
      final prefix = _s(_payload, 'upload_prefix');
      if (bucket.isEmpty || prefix.isEmpty) {
        if (mounted) setState(() => _busyKey = '');
        return;
      }
      final ext = (f!.extension ?? 'jpg').toLowerCase();
      final mime = ext == 'pdf'
          ? 'application/pdf'
          : ext == 'png'
              ? 'image/png'
              : 'image/jpeg';
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final path = await CustomerDocsScreen.upload(
          bucket, '$prefix/${key}_$stamp.$ext', bytes, mime);

      final res = _asMap(await CustomerDocsScreen.rpc('kyc_upload_register', {
        'p_kind': key,
        'p_path': path,
        'p_file_name': f.name,
        'p_mime': mime,
        'p_bytes': bytes.length,
      }));
      if (!mounted) return;
      setState(() => _busyKey = '');
      _toast(_s(res, 'message'));
      await _load();
    } catch (_) {
      if (mounted) setState(() => _busyKey = '');
    }
  }

  Future<void> _setSkip(Map<String, dynamic> item, bool skip) async {
    final key = _s(item, 'key');
    setState(() => _busyKey = key);
    try {
      final res = _asMap(await CustomerDocsScreen.rpc(
          'kyc_doc_skip', {'p_key': key, 'p_skip': skip}));
      if (!mounted) return;
      setState(() {
        _busyKey = '';
        final next = _asMap(res?['checklist']);
        if (next != null) _payload = next;
      });
      _toast(_s(res, 'message'));
    } catch (_) {
      if (mounted) setState(() => _busyKey = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = _s(_payload, 'title');
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(title),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: _s(_payload, 'close_label'),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.of(context)
                  .pushNamedAndRemoveUntil('/', (r) => false);
            }
          },
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const _ChecklistSkeleton()
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: EdgeInsets.all(Ds.space.x16),
                  children: _sections(),
                ),
              ),
      ),
    );
  }

  List<Widget> _sections() {
    if (!_b(_payload, 'ok')) {
      return [
        SizedBox(height: Ds.space.x32),
        Text(_s(_payload, 'message'), style: Ds.t.body, textAlign: TextAlign.center),
      ];
    }
    final items = _items;
    return [
      _StepHeader(
        step: _s(_payload, 'step_label'),
        line: _s(_payload, 'subtitle'),
      ),
      // CMD #2059 — the same strip the banner and the details form print, so
      // the checklist says where it sits and step 1 stays one tap away.
      if (RegistrationSurface.steps.isNotEmpty) ...[
        SizedBox(height: Ds.space.x12),
        RegistrationStepStrip(
          step: RegistrationSurface.step,
          steps: RegistrationSurface.steps,
          onOpen: (r) => Navigator.of(context).pushNamed(r),
        ),
      ],
      SizedBox(height: Ds.space.x16),
      _Summary(
        title: _s(_payload, 'summary_title'),
        line: _s(_payload, 'summary_line'),
        tone: _s(_payload, 'summary_tone'),
      ),
      SizedBox(height: Ds.space.x24),
      if (items.isEmpty)
        Text(_s(_payload, 'empty_line'), style: Ds.t.bodySecondary)
      else
        for (final it in items) ...[
          _DocCard(
            item: it,
            busy: _busyKey == _s(it, 'key'),
            onUpload: () => _pickAndUpload(it),
            onSkip: (v) => _setSkip(it, v),
          ),
          SizedBox(height: Ds.space.x12),
        ],
      SizedBox(height: Ds.space.x32),
    ];
  }
}

/// "Step 2 of 2" plus the one line under it — both backend strings.
class _StepHeader extends StatelessWidget {
  final String step;
  final String line;
  const _StepHeader({required this.step, required this.line});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(step, style: Ds.t.caption),
        SizedBox(height: Ds.space.x4),
        Text(line, style: Ds.t.bodySecondary),
      ],
    );
  }
}

Color _toneBg(String tone) => switch (tone) {
      'success' => Ds.c.successSoft,
      'danger' => Ds.c.dangerSoft,
      'warning' => Ds.c.warningSoft,
      'info' => Ds.c.infoSoft,
      _ => Ds.c.bg,
    };

Color _toneFg(String tone) => switch (tone) {
      'success' => Ds.c.success,
      'danger' => Ds.c.danger,
      'warning' => Ds.c.warning,
      'info' => Ds.c.info,
      _ => Ds.c.textSecondary,
    };

/// The progress line. It says nothing of its own: which sentence, and which
/// tone it is painted in, both arrive on the payload.
class _Summary extends StatelessWidget {
  final String title;
  final String line;
  final String tone;
  const _Summary({required this.title, required this.line, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (title.isEmpty && line.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: _toneBg(tone),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title.isNotEmpty) ...[
            Text(title, style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x4),
          ],
          if (line.isNotEmpty)
            Text(line, style: Ds.t.body.copyWith(color: _toneFg(tone))),
        ],
      ),
    );
  }
}

/// One document. Every string on it is the payload's; the only decision this
/// widget makes is which of the backend's own fields to paint where.
class _DocCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool busy;
  final VoidCallback onUpload;
  final ValueChanged<bool> onSkip;

  const _DocCard({
    required this.item,
    required this.busy,
    required this.onUpload,
    required this.onSkip,
  });

  @override
  Widget build(BuildContext context) {
    final skipped = _b(item, 'skipped');
    final canSkip = _b(item, 'can_skip');
    final retake = _s(item, 'retake_reason');
    final hint = _s(item, 'hint');
    final number = _s(item, 'number');
    final cameraNote = _s(item, 'camera_only_note');

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(item, 'label'), style: Ds.t.subtitle),
                    SizedBox(height: Ds.space.x4),
                    Text(_s(item, 'requirement_label'), style: Ds.t.caption),
                  ],
                ),
              ),
              SizedBox(width: Ds.space.x8),
              _Chip(
                label: _s(item, 'status_label'),
                tone: _s(item, 'status_tone'),
              ),
            ],
          ),
          if (hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(hint, style: Ds.t.caption),
          ],
          if (cameraNote.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(cameraNote, style: Ds.t.caption),
          ],
          if (number.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(number, style: Ds.t.bodyStrong),
          ],
          if (retake.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              width: double.infinity,
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                color: Ds.c.warningSoft,
                borderRadius: Ds.r.rButton,
              ),
              child: Text(retake,
                  style: Ds.t.body.copyWith(color: Ds.c.warning)),
            ),
          ],
          SizedBox(height: Ds.space.x12),
          SizedBox(
            width: double.infinity,
            height: Ds.touch.minTarget,
            child: busy
                ? const Center(child: CircularProgressIndicator())
                : (skipped
                    ? OutlinedButton(
                        onPressed: onUpload,
                        child: Text(_s(item, 'action_label')),
                      )
                    : FilledButton(
                        onPressed: onUpload,
                        child: Text(retake.isNotEmpty
                            ? _s(item, 'retake_label')
                            : _s(item, 'action_label')),
                      )),
          ),
          // "I don't have this" exists only where the BACKEND offered it. A
          // required document has no checkbox at all — not a disabled one.
          if (canSkip) ...[
            SizedBox(height: Ds.space.x4),
            SizedBox(
              height: Ds.touch.minTarget,
              child: InkWell(
                onTap: busy ? null : () => onSkip(!skipped),
                child: Row(
                  children: [
                    Checkbox(
                      value: skipped,
                      onChanged: busy ? null : (v) => onSkip(v == true),
                    ),
                    Expanded(
                      child: Text(_s(item, 'skip_label'), style: Ds.t.body),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final String tone;
  const _Chip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: _toneBg(tone),
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption.copyWith(color: _toneFg(tone))),
    );
  }
}

/// A skeleton, not a bare spinner — the checklist's own shape while the RPC
/// answers.
class _ChecklistSkeleton extends StatelessWidget {
  const _ChecklistSkeleton();

  @override
  Widget build(BuildContext context) {
    Widget block() => Container(
          margin: EdgeInsets.only(bottom: Ds.space.x12),
          height: Ds.space.x48 + Ds.space.x48,
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
          ),
        );
    return ListView(
      padding: EdgeInsets.all(Ds.space.x16),
      children: [block(), block(), block()],
    );
  }
}
