// CMD #2061 — ONE registration form.
//
// Registration used to be two screens: business details, then a separate
// document checklist. A shop that finished the first one was "registered"
// with no papers behind it, and the per-zone document rules (#2060) reached
// neither screen. This is the merged surface, and it is the SAME screen for
// both doors: a self-signup arrives with its login prefilled, an imported
// customer arrives with its whole row prefilled and fills only what is blank.
//
// It composes nothing. `customer_registration_payload()` carries the title,
// the subtitle, the imported note, the field schema, the prefill, the saved
// draft, the document block and every button caption. One Submit —
// `customer_registration_submit(values, skips)` — saves the profile, the
// uploads and the "I don't have this" answers together, and the sentence it
// prints afterwards is the backend's too.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../../design_tokens.dart';
import '../../services/registration_bar.dart';
import '../../utils/doc_capture.dart';
import '../../utils/doc_scan.dart';
import '../../utils/render_log.dart';
import '../../widgets/customer_registration_form.dart';
import '../../widgets/doc_upload_sheet.dart';
import '../../widgets/doc_viewer_screen.dart';
import '../../widgets/registration_documents_section.dart';
import '../../widgets/registration_licences_section.dart';
import '../../widgets/registration_location_step.dart';
import '../../widgets/registration_wizard.dart';
import '../customer_documents_screen.dart' show CustomerDocumentsTransport;

class OneRegistrationScreen extends StatefulWidget {
  const OneRegistrationScreen({
    super.key,
    this.onSaved,
    this.embedded = false,
  });

  /// Told once the profile has been saved. The cart sheet uses it to close
  /// onto the basket the person came back for.
  final VoidCallback? onSaved;

  /// True when a surface around this one already draws the title bar — the
  /// cart sheet does. It changes the chrome, never the form.
  final bool embedded;

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<OneRegistrationScreen> createState() => _OneRegistrationScreenState();
}

class _OneRegistrationScreenState extends State<OneRegistrationScreen> {
  final _scroll = ScrollController();
  final _docsKey = GlobalKey();

  Map<String, dynamic> _p = const {};
  CustomerFormController? _form;
  bool _loading = true;
  bool _failed = false;
  bool _saving = false;
  String _message = '';
  String _busyDoc = '';

  final Map<String, PickedDoc> _picked = {};
  final Set<String> _skips = {};

  // CMD #2128 — Step 3 · Licences. The block is a SECOND read, on its own
  // RPC, so the list refreshes after an upload or a removal without pulling
  // the whole registration payload down again.
  Map<String, dynamic> _lic = const {};
  final Map<String, String> _thumbUrls = {};
  final Map<String, int> _pages = {};
  bool _scanning = false;

  // CMD #2126 — the 3-step flow. Where the person is, whether the resume
  // point has been taken from the payload yet, and whether Submit landed.
  int _step = 0;
  bool _stepSeeded = false;
  bool _showDone = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _form?.dispose();
    super.dispose();
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : const {};

  String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  Map<String, dynamic> get _docs => _map(_p['documents']);

  /// CMD #2126 — the backend's flow block. Absent or disabled and this screen
  /// is the single form it always was.
  Map<String, dynamic> get _wiz => _map(_p['wizard']);
  List<Map<String, dynamic>> get _steps => wizardSteps(_wiz);
  bool get _wizardOn => _wiz['enabled'] == true && _steps.isNotEmpty;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final raw = await OneRegistrationScreen.rpc(
          'customer_registration_payload');
      final p = _map(raw is List && raw.isNotEmpty ? raw.first : raw);
      if (!mounted) return;

      final ctrl = _form ?? CustomerFormController(formContext: 'signup');
      final schema = _map(p['schema']);
      if (schema.isNotEmpty) ctrl.seed(schema);
      // Prefill first, then the draft: what the person typed last time wins
      // over what we knew about them.
      ctrl.applyMap(_map(p['prefill']));
      ctrl.applyMap(_map(p['draft']));

      setState(() {
        _p = p;
        _form = ctrl;
        _loading = false;
        // Resume on the step the backend saved with the draft — once. A
        // re-read after a save must never yank the person to another step.
        if (_wizardOn && !_stepSeeded) {
          _stepSeeded = true;
          _step = ((_wiz['resume_step'] as num?)?.toInt() ?? 0)
              .clamp(0, _steps.length - 1);
        }
      });
      if (_wizardOn) {
        RenderLog.write('c2126_reg_wizard',
            'steps=${_steps.length};step=$_step;done=${_showDone ? 1 : 0}');
      }

      unawaited(_loadLicences());

      RenderLog.write(
          'c2061_one_form',
          'docs=${(_docs['rows'] as List?)?.length ?? 0}'
          ';pending=${_map(p['docs_pending'])['show'] == true ? 1 : 0}');

      // Resume lands on the papers that are still out, without a second route.
      // CMD #2087 — the cart's Place order gate opens this form with the
      // backend's own anchor in the route arguments ('documents' when a
      // starred paper is what is missing). Whoever sent us here says where to
      // land; the payload's own docs_pending still answers every other way in.
      if (_map(p['docs_pending'])['show'] == true ||
          _routeAnchor() == 'documents') {
        if (_wizardOn && !_showDone) {
          // In the flow the papers are a STEP, so resuming there is a jump.
          final i = _steps.indexWhere((s) => s['docs'] == true);
          if (i >= 0) setState(() => _step = i);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) => _toDocs());
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      RenderLog.write('c2061_one_form', 'error');
    }
  }

  /// CMD #2087 — the section the caller asked us to resume at, from the
  /// route's own arguments. Absent is absent: the form opens at the top.
  String _routeAnchor() {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map && args['anchor'] != null) return args['anchor'].toString();
    return '';
  }

  void _toDocs() {
    final ctx = _docsKey.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(ctx,
        duration: Ds.motion.standard, curve: Ds.motion.curve);
  }

  Future<void> _pick(Map<String, dynamic> row) async {
    final key = _s(row, 'key');
    final chosen =
        await CustomerDocumentsTransport.choose(row['camera_only'] == true);
    if (chosen == null || !mounted) return;
    setState(() {
      _picked[key] =
          PickedDoc(name: chosen.name, ext: chosen.ext, bytes: chosen.bytes);
      _skips.remove(key);
    });
  }

  // ── CMD #2128 · Step 3 · Licences ────────────────────────────────────────

  /// The list, its counter and every caption on it.
  Future<void> _loadLicences() async {
    try {
      final raw = await OneRegistrationScreen.rpc('custreg_licences_step');
      final b = _map(raw is List && raw.isNotEmpty ? raw.first : raw);
      if (!mounted || b['show'] != true) return;
      setState(() => _lic = b);
      RenderLog.write(
          'c2128_licences',
          'rows=${_licRows.length}'
          ';groups=${((b['groups'] as List?) ?? const []).length}'
          ';req=${b['required_done'] ?? 0}/${b['required_total'] ?? 0}');
      unawaited(_signThumbs());
    } catch (_) {
      // The step still renders the papers the payload already carried.
    }
  }

  List<Map<String, dynamic>> get _licRows => [
        for (final g in ((_lic['groups'] as List?) ?? const []))
          ...(((_map(g)['rows'] as List?) ?? const []).map(_map)),
      ];

  /// A private object needs a signed URL before it can be drawn. One per row,
  /// resolved once, and a failure simply leaves the tile blank.
  Future<void> _signThumbs() async {
    for (final row in _licRows) {
      final key = _s(row, 'key');
      final thumb = _map(row['thumb']);
      final path = _s(thumb, 'path');
      if (path.isEmpty || _thumbUrls.containsKey(key)) continue;
      try {
        final url = await CustomerDocumentsTransport.sign(
            _s(thumb, 'bucket').isEmpty ? 'kyc-docs' : _s(thumb, 'bucket'),
            path);
        if (!mounted) return;
        if (url.isNotEmpty) setState(() => _thumbUrls[key] = url);
      } catch (_) {
        // no thumbnail is a blank tile, never a broken screen
      }
    }
  }

  /// What this device can actually do. The sheet drops an option it cannot
  /// honour; it never invents one.
  Set<String> get _capabilities => {
        'files',
        if (!kIsWeb) 'scanner',
      };

  /// Tap an upload circle: the row's own sheet, then whichever way in was
  /// chosen. The file is held on the device and rides up with Submit, exactly
  /// as it did before — this only changes HOW it is chosen.
  Future<void> _pickForRow(Map<String, dynamic> row) async {
    final sheet = _map(row['sheet']);
    final choice = await showDocUploadSheet(context,
        sheet: sheet, capabilities: _capabilities);
    if (choice == null || !mounted) return;
    final key = _s(row, 'key');
    setState(() => _busyDoc = key);
    try {
      switch (choice) {
        case 'scan':
          await captureDocument(
            scan: () async => await scanDocuments(pageLimit: 1),
            cameraFallback: _shot,
            handlePage: (page) async =>
                _hold(key, page.name, page.bytes),
          );
        case 'camera':
          final shot = await _shot();
          if (shot != null) await _hold(key, shot.name, shot.bytes);
        case 'gallery':
          final shot = await _shot(gallery: true);
          if (shot != null) await _hold(key, shot.name, shot.bytes);
        default:
          final f = await CustomerDocumentsTransport.choose(false);
          if (f != null) await _hold(key, f.name, f.bytes);
      }
    } catch (_) {
      // A cancelled or refused picker is not an error the person must read.
    } finally {
      if (mounted) setState(() => _busyDoc = '');
    }
  }

  Future<CapturedPage?> _shot({bool gallery = false}) async {
    final x = await ImagePicker().pickImage(
        source: gallery ? ImageSource.gallery : ImageSource.camera,
        imageQuality: 85,
        maxWidth: 1800);
    if (x == null) return null;
    return (name: x.name, bytes: await x.readAsBytes());
  }

  /// Hold a chosen file against its row. The page count of a PDF is a fact
  /// about the file, measured here and sent up with it so the backend can
  /// print "2 pages" without ever opening it.
  Future<void> _hold(String key, String name, Uint8List bytes) async {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : 'jpg';
    var pages = 1;
    if (ext == 'pdf') {
      try {
        pages = PdfDocument(inputBytes: bytes).pages.count;
      } catch (_) {
        pages = 1;
      }
    }
    if (!mounted) return;
    setState(() {
      _picked[key] = PickedDoc(name: name, ext: ext, bytes: bytes);
      _pages[key] = pages;
      _skips.remove(key);
      _thumbUrls.remove(key);
    });
  }

  /// Tap a thumbnail: the paper opens INSIDE the app. Never a share sheet,
  /// never another viewer.
  Future<void> _viewDoc(Map<String, dynamic> row) async {
    final key = _s(row, 'key');
    final local = _picked[key];
    final choice = await showDocViewer(context,
        row: local == null
            ? row
            : ({
                ...row,
                'thumb': {
                  ..._map(row['thumb']),
                  'kind': local.ext == 'pdf' ? 'pdf' : 'image',
                  'pages': _pages[key] ?? 1,
                },
              }),
        url: _thumbUrls[key] ?? '',
        bytes: local?.bytes);
    if (!mounted || choice == null) return;
    switch (choice) {
      case DocViewerChoice.retake:
        await _pickForRow(row);
      case DocViewerChoice.remove:
        await _removeDoc(row);
      case DocViewerChoice.keep:
        break;
    }
  }

  Future<void> _removeDoc(Map<String, dynamic> row) async {
    final key = _s(row, 'key');
    if (_picked.containsKey(key)) {
      setState(() {
        _picked.remove(key);
        _pages.remove(key);
      });
      return;
    }
    setState(() => _busyDoc = key);
    try {
      final res =
          _map(await OneRegistrationScreen.rpc('custreg_doc_remove', {
        'p_kind': key,
      }));
      if (!mounted) return;
      final block = _map(res['block']);
      setState(() {
        _message = _s(res, 'message');
        _busyDoc = '';
        if (block.isNotEmpty) _lic = _lic.isEmpty ? block : {..._lic, ...block};
        _thumbUrls.remove(key);
      });
    } catch (_) {
      if (mounted) setState(() => _busyDoc = '');
    }
  }

  /// Scan a licence: one photo, and the backend reads the numbers off it. The
  /// model names nothing the person then sees — the review sheet's title, its
  /// line, its field labels and its buttons all come back from SQL.
  Future<void> _scanLicence() async {
    if (_scanning) return;
    final scan = _map(_lic['scan']);
    setState(() {
      _scanning = true;
      _message = '';
    });
    try {
      CapturedPage? page;
      await captureDocument(
        scan: () async => await scanDocuments(pageLimit: 1),
        cameraFallback: _shot,
        handlePage: (p) async => page = p,
      );
      if (page == null || !mounted) {
        setState(() => _scanning = false);
        return;
      }
      final res = await Supabase.instance.client.functions.invoke(
        'licence-ocr',
        body: {
          'image_base64': base64Encode(page!.bytes),
          'mime_type': page!.name.toLowerCase().endsWith('.png')
              ? 'image/png'
              : 'image/jpeg',
        },
      );
      final data = _map(res.data);
      final review = _map(await OneRegistrationScreen.rpc(
          'custreg_licence_scan_review', {'p_fields': _map(data['fields'])}));
      if (!mounted) return;
      setState(() => _scanning = false);
      if (review['ok'] != true) {
        setState(() => _message = _s(review, 'empty_label').isNotEmpty
            ? _s(review, 'empty_label')
            : _s(scan, 'none_label'));
        return;
      }
      final take = await _confirmScan(review);
      if (take != true || !mounted) return;
      final applied = _map(await OneRegistrationScreen.rpc(
          'custreg_licence_scan_apply', {'p_values': _map(review['values'])}));
      if (!mounted) return;
      final values = _map(applied['values']);
      if (values.isNotEmpty) _form?.applyMap(values);
      setState(() => _message = _s(applied, 'message'));
      RenderLog.write('c2128_lic_scan', 'fields=${values.length}');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _message = _s(scan, 'none_label');
      });
    }
  }

  /// The review sheet. Every word on it is in `review`.
  Future<bool?> _confirmScan(Map<String, dynamic> review) {
    final rows = ((review['rows'] as List?) ?? const []).map(_map).toList();
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x24, Ds.space.x16, Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(review, 'title'), style: Ds.t.title),
              SizedBox(height: Ds.space.x4),
              Text(_s(review, 'line'), style: Ds.t.bodySecondary),
              SizedBox(height: Ds.space.x16),
              for (final r in rows)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x12),
                  child: Row(children: [
                    Expanded(
                        child: Text(_s(r, 'label'), style: Ds.t.bodySecondary)),
                    SizedBox(width: Ds.space.x12),
                    Flexible(
                      child: Text(_s(r, 'value'),
                          textAlign: TextAlign.right, style: Ds.t.bodyStrong),
                    ),
                  ]),
                ),
              SizedBox(height: Ds.space.x8),
              Semantics(
                identifier: 'reg_lic_scan_confirm',
                button: true,
                child: SizedBox(
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    child: Text(_s(review, 'confirm_label')),
                  ),
                ),
              ),
              SizedBox(height: Ds.space.x8),
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: Text(_s(review, 'cancel_label')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toggleSkip(Map<String, dynamic> row) {
    final key = _s(row, 'key');
    setState(() {
      if (_skips.contains(key) || row['skipped'] == true) {
        _skips.remove(key);
      } else {
        _skips.add(key);
        _picked.remove(key);
      }
    });
  }

  /// One Submit: the profile, then whatever files were chosen, then the
  /// answers. A skipped starred paper never blocks it — the backend simply
  /// answers with "Docs pending" and the account waits for the paper.
  Future<void> _submit() async {
    final ctrl = _form;
    if (ctrl == null || _saving) return;
    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final res = _map(await OneRegistrationScreen.rpc(
          'customer_registration_submit', {
        'p_values': ctrl.payload(),
        'p_skips': _skips.toList(),
      }));
      if (res['ok'] != true) {
        if (!mounted) return;
        setState(() {
          _saving = false;
          _message = _s(res, 'message');
        });
        return;
      }

      // The row exists now, so the files that were held can land on it.
      final cid = _s(res, 'customer_id');
      for (final entry in _picked.entries) {
        await _upload(cid, entry.key, entry.value);
      }
      if (!mounted) return;

      final after = _map(res['payload']);
      setState(() {
        _saving = false;
        _picked.clear();
        _skips.clear();
        _message = _s(res, 'message');
        if (after.isNotEmpty) _p = after;
      });
      RenderLog.write('c2061_submit',
          res['docs_pending'] == true ? 'docs_pending' : 'complete');
      if (_wizardOn) _showDone = true;
      widget.onSaved?.call();
      // CMD #2112 — the bar in the bottom stack is the same ask as this form,
      // so it re-reads the backend the moment the form does. A registration
      // that just completed must not leave "Registration pending" on screen.
      unawaited(RegistrationBarDriver.instance.refresh());
      await _load();
      await _loadLicences();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = _s(_p, 'error_label');
      });
    }
  }

  /// CMD #2126 — Continue. The backend judges the step (its required fields)
  /// and AUTO-SAVES the draft with the step to come back to; the last step's
  /// Continue is Submit.
  Future<void> _continue() async {
    final ctrl = _form;
    if (ctrl == null || _saving) return;
    final steps = _steps;
    final key = (steps[_step]['key'] ?? '').toString();
    setState(() {
      _saving = true;
      _message = '';
    });
    try {
      final res = _map(await OneRegistrationScreen.rpc(
          'customer_registration_step_save',
          {'p_step': key, 'p_values': ctrl.payload()}));
      if (!mounted) return;
      if (res['ok'] != true) {
        setState(() {
          _saving = false;
          _message = _s(res, 'message');
        });
        return;
      }
      if (_step >= steps.length - 1) {
        setState(() => _saving = false);
        await _submit();
        return;
      }
      setState(() {
        _saving = false;
        _step = ((res['step_index'] as num?)?.toInt() ?? _step + 1)
            .clamp(0, steps.length - 1);
      });
      _toTop();
      RenderLog.write('c2126_reg_step', 'step=$_step');
      // The bar reads the same saved draft, so it re-reads after every step.
      unawaited(RegistrationBarDriver.instance.refresh());
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = _s(_p, 'error_label');
      });
    }
  }

  /// Back, or a tapped tick: save what is on screen and move — never blocks.
  Future<void> _goTo(int i) async {
    final ctrl = _form;
    if (ctrl == null || i == _step || i < 0 || i >= _steps.length) return;
    final from = (_steps[_step]['key'] ?? '').toString();
    final to = (_steps[i]['key'] ?? '').toString();
    setState(() {
      _step = i;
      _message = '';
    });
    _toTop();
    try {
      await OneRegistrationScreen.rpc('customer_registration_step_save',
          {'p_step': from, 'p_values': ctrl.payload(), 'p_goto': to});
    } catch (_) {
      // The next Continue saves again; nothing typed is lost on the device.
    }
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: Ds.motion.standard, curve: Ds.motion.curve);
  }

  void _browse() {
    // Leaving the flow: the bar in the bottom stack re-reads the backend so a
    // finished registration never leaves "Registration pending" on screen.
    unawaited(RegistrationBarDriver.instance.refresh());
    if (widget.embedded) {
      Navigator.of(context).maybePop();
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _upload(String customerId, String kind, PickedDoc doc) async {
    if (customerId.isEmpty) return;
    setState(() => _busyDoc = kind);
    try {
      final p = _map(await CustomerDocumentsTransport.call(
          'customer_doc_upload_path',
          {'p_customer_id': customerId, 'p_kind': kind, 'p_ext': doc.ext}));
      if (p['ok'] != true) return;
      final mime = switch (doc.ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };
      final stored = await CustomerDocumentsTransport.put(
          _s(p, 'bucket'), _s(p, 'path'), doc.bytes, mime);
      await CustomerDocumentsTransport.call('customer_doc_upload_register', {
        'p_customer_id': customerId,
        'p_kind': kind,
        'p_path': stored,
        'p_file_name': doc.name,
        'p_mime': mime,
        'p_bytes': doc.bytes.length,
        'p_pages': _pages[kind] ?? 1,
      });
    } catch (_) {
      // A file that would not go up is not a failed registration: the profile
      // is saved, the paper is simply still owed and the banner says so.
    } finally {
      if (mounted) setState(() => _busyDoc = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.embedded) return _body();
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(title: Text(_s(_p, 'title'))),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
          child: SizedBox(
        width: Ds.space.x24,
        height: Ds.space.x24,
        child: CircularProgressIndicator(color: Ds.c.brand),
      ));
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_s(_p, 'error_label'), style: Ds.t.body),
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                  onPressed: _load, child: Text(_s(_p, 'retry_label'))),
            ),
          ]),
        ),
      );
    }

    // CMD #2126 — the flow: Done after Submit (or when nothing is owed), the
    // current step otherwise.
    if (_wizardOn && (_showDone || _p['needs'] != true)) {
      return LayoutBuilder(builder: (context, box) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: RegistrationDoneView(
              done: _map(_wiz['done']),
              onBrowse: _browse,
              horizontalPadding:
                  box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16,
            ),
          ),
        );
      });
    }
    if (_wizardOn) return _wizardStep();

    // Nothing owed — the backend says so, and says what to print about it.
    if (_p['needs'] != true) {
      return Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_s(_p, 'done_title'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x8),
            Text(_s(_p, 'done_line'),
                style: Ds.t.caption, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x24),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(_s(_p, 'close_label')),
              ),
            ),
          ]),
        ),
      );
    }

    final ctrl = _form;
    final pending = _map(_p['docs_pending']);
    final imported = _map(_p['imported']);

    return LayoutBuilder(builder: (context, box) {
      // Phone first. The form stays full width on a phone and simply stops
      // growing on a wide screen; nothing here is a fixed pixel width.
      final pad = box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16;
      return SingleChildScrollView(
        controller: _scroll,
        padding: EdgeInsets.fromLTRB(pad, Ds.space.x16, pad, Ds.space.x32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_s(_p, 'subtitle').isNotEmpty)
                  Text(_s(_p, 'subtitle'), style: Ds.t.caption),
                if (imported['is'] == true && _s(imported, 'note').isNotEmpty)
                  _note(_s(imported, 'note'), Ds.c.infoSoft),
                if (pending['show'] == true && _s(pending, 'line').isNotEmpty)
                  _note(_s(pending, 'line'), Ds.c.warningSoft),
                if (_p['has_draft'] == true && _s(_p, 'draft_note').isNotEmpty)
                  _note(_s(_p, 'draft_note'), Ds.c.bg),
                SizedBox(height: Ds.space.x16),
                if (ctrl != null) CustomerRegistrationForm(controller: ctrl),
                Container(
                  key: _docsKey,
                  child: RegistrationDocumentsSection(
                    block: _docs,
                    picked: _picked,
                    skipped: _skips,
                    busyKey: _busyDoc,
                    onPick: _pick,
                    onSkipToggle: _toggleSkip,
                  ),
                ),
                if (_message.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x16),
                  Text(_message, style: Ds.t.caption),
                ],
                SizedBox(height: Ds.space.x24),
                SizedBox(
                  width: double.infinity,
                  height: Ds.touch.minTarget,
                  child: FilledButton(
                    onPressed: _saving ? null : _submit,
                    child: Text(_saving
                        ? _s(_p, 'submitting_label')
                        : _s(_p, 'submit_label')),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    });
  }

  /// CMD #2126 — one step, laid out as the approved design (Image A): the
  /// progress bar on a white band under the title bar, the step's title and
  /// subtitle, its fields with labels above them, and Back + Continue pinned
  /// to the bottom. Phone first: a 16 px gutter, capped width on a big screen.
  Widget _wizardStep() {
    final steps = _steps;
    final step = steps[_step];
    final ctrl = _form;
    final pending = _map(_p['docs_pending']);
    final imported = _map(_p['imported']);
    final last = _step >= steps.length - 1;
    final fields = ((step['fields'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final mapBlock = _map(step['map']);
    final chips = <String, List<String>>{
      for (final e in _map(_wiz['chips']).entries)
        if (e.value is List)
          e.key: (e.value as List).map((o) => o.toString()).toList(),
    };
    final notes = <String, String>{
      for (final e in _map(_wiz['field_notes']).entries)
        e.key: (e.value ?? '').toString(),
    };
    // CMD #2127 — a step may name its own primary button ("Confirm location");
    // absent, the flow's own Continue stands.
    final stepContinue = _s(step, 'continue_label');
    final continueLabel = _saving
        ? (last ? _s(_wiz, 'submitting_label') : _s(_wiz, 'saving_label'))
        : (last
            ? _s(_wiz, 'submit_label')
            : (stepContinue.isNotEmpty
                ? stepContinue
                : _s(_wiz, 'continue_label')));

    return LayoutBuilder(builder: (context, box) {
      final pad = box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16;
      Widget capped(Widget child) => Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: child,
            ),
          );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Ds.c.surface,
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x8, pad, Ds.space.x4),
            child: capped(RegistrationProgressBar(
                steps: steps, current: _step, onJump: _goTo)),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.fromLTRB(pad, Ds.space.x24, pad, Ds.space.x24),
              child: capped(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_s(step, 'title').isNotEmpty)
                    Text(_s(step, 'title'), style: Ds.t.title),
                  if (_s(step, 'subtitle').isNotEmpty) ...[
                    SizedBox(height: Ds.space.x4),
                    Text(_s(step, 'subtitle'), style: Ds.t.bodySecondary),
                  ],
                  if (_step == 0 && imported['is'] == true && _s(imported, 'note').isNotEmpty)
                    _note(_s(imported, 'note'), Ds.c.infoSoft),
                  if (_step == 0 && _p['has_draft'] == true && _s(_p, 'draft_note').isNotEmpty)
                    _note(_s(_p, 'draft_note'), Ds.c.surface),
                  if (step['docs'] == true && pending['show'] == true && _s(pending, 'line').isNotEmpty)
                    _note(_s(pending, 'line'), Ds.c.warningSoft),
                  SizedBox(height: Ds.space.x16),
                  // CMD #2127 — the location step is a MAP, not five boxes:
                  // the pin is the input and the address is the backend's
                  // answer to it, shown in a card with Edit. Every other step
                  // is the form it always was.
                  if (ctrl != null && mapBlock.isNotEmpty)
                    RegistrationLocationStep(
                      map: mapBlock,
                      values: ctrl.valuesForKeys(const [
                        'address', 'landmark', 'city', 'state',
                        'pincode', 'district', 'latitude', 'longitude',
                        'store_location_link',
                      ]),
                      rpc: (fn, params) =>
                          OneRegistrationScreen.rpc(fn, params),
                      onValues: (vals) {
                        ctrl.applyMap(vals);
                        final la = (vals['latitude'] ?? '').toString();
                        final ln = (vals['longitude'] ?? '').toString();
                        if (la.isNotEmpty && ln.isNotEmpty) {
                          ctrl.setPin(la, ln);
                        }
                      },
                    )
                  else if (ctrl != null)
                    CustomerRegistrationForm(
                      controller: ctrl,
                      onlyFields: fields,
                      chips: chips,
                      notes: notes,
                    ),
                  if (step['docs'] == true)
                    Container(
                      key: _docsKey,
                      // CMD #2128 — the Licences step is its own surface: the
                      // three groups, the live counter, thumbnails and the
                      // in-app viewer. Until that block has arrived the older
                      // flat list keeps the step usable.
                      child: _lic['show'] == true
                          ? RegistrationLicencesSection(
                              block: _lic,
                              picked: _picked,
                              skipped: _skips,
                              thumbUrls: _thumbUrls,
                              busyKey: _busyDoc,
                              scanning: _scanning,
                              onUpload: _pickForRow,
                              onView: _viewDoc,
                              onSkipToggle: _toggleSkip,
                              onScan: _scanLicence,
                            )
                          : RegistrationDocumentsSection(
                              block: _docs,
                              picked: _picked,
                              skipped: _skips,
                              busyKey: _busyDoc,
                              onPick: _pick,
                              onSkipToggle: _toggleSkip,
                            ),
                    ),
                  if (_message.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x12),
                    Text(_message, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
                  ],
                ],
              )),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x12, pad, Ds.space.x16),
            child: capped(Row(children: [
              if (_step > 0) ...[
                Expanded(
                  child: Semantics(
                    identifier: 'reg_back',
                    button: true,
                    child: SizedBox(
                      height: Ds.touch.minTarget,
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => _goTo(_step - 1),
                        child: Text(_s(_wiz, 'back_label')),
                      ),
                    ),
                  ),
                ),
                SizedBox(width: Ds.space.x12),
              ],
              Expanded(
                flex: 2,
                child: Semantics(
                  identifier: 'reg_primary',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: _saving ? null : _continue,
                      child: Text(continueLabel,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
            ])),
          ),
        ],
      );
    });
  }

  Widget _note(String text, Color bg) => Container(
        width: double.infinity,
        margin: EdgeInsets.only(top: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
        child: Text(text, style: Ds.t.caption),
      );
}
