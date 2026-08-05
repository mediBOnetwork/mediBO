import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/utils/toast.dart';
import '../data/wa_template_api.dart';
import 'wa_template_actions.dart';
import 'wa_template_bits.dart';

/// A file the admin chose, reduced to the three things the upload needs.
///
/// Nothing here judges the file. Its size and type go to the backend as they
/// are — wa_template_set_header_media refuses with its own sentence if Meta
/// would not accept it.
class WaPickedFile {
  final String name;
  final Uint8List bytes;
  const WaPickedFile({required this.name, required this.bytes});
}

/// Create / edit a WhatsApp template.
///
/// The two things that decide whether this template is any good — the preview
/// text and the lint — are BOTH backend calls, refreshed on one debounce:
///
///   wa_template_preview(components)          -> the bubble, already rendered
///   wa_template_validate(components, cat)    -> errors[] and warnings[]
///
/// Nothing here validates with a regex, assembles preview text, or decides what
/// counts as an error. Save and Submit are disabled precisely when the backend
/// returned a non-empty errors[] — warnings never block, because Meta accepts
/// those templates.
///
/// The one structure this file does build is `components` itself. That is the
/// document the admin is composing, not a decision about it: the app collects
/// user input and sends it back for the backend to judge.
class WaTemplateEditorScreen extends StatefulWidget {
  /// The whole wa_templates_screen() payload — starters, tokens, categories,
  /// languages, button_spec and copy all come from it.
  final Map<String, dynamic> screen;

  /// Null for a new template. Otherwise the row being edited.
  final Map<String, dynamic>? template;

  /// Used by "Fix & resubmit" and "Restore into editor" to seed a draft from a
  /// specific set of components rather than the template's current ones.
  final List<dynamic>? initialComponents;

  const WaTemplateEditorScreen({
    super.key,
    required this.screen,
    this.template,
    this.initialComponents,
  });

  /// Debounce before the preview/lint round-trip. Exposed so a widget test can
  /// drive it without waiting real time.
  @visibleForTesting
  static Duration debounce = const Duration(milliseconds: 400);

  /// Debounce before the duplicate check. Longer than the lint debounce because
  /// wa_template_similar scans every other template.
  @visibleForTesting
  static Duration similarDebounce = const Duration(milliseconds: 600);

  /// How often, and for how long, the media-header and policy-review jobs are
  /// polled. Both stop at the deadline rather than hanging on a job that never
  /// finishes.
  @visibleForTesting
  static Duration pollInterval = const Duration(seconds: 2);
  @visibleForTesting
  static Duration pollTimeout = const Duration(seconds: 30);

  /// Test seam for the OS file dialog, same idea as WaTemplateApi.rpcTransport:
  /// a widget test can hand a file in without a picker or a filesystem.
  @visibleForTesting
  static Future<WaPickedFile?> Function(List<String> extensions)? filePicker;

  @override
  State<WaTemplateEditorScreen> createState() => _WaTemplateEditorScreenState();
}

class _WaTemplateEditorScreenState extends State<WaTemplateEditorScreen> {
  final _name = TextEditingController();
  final _header = TextEditingController();
  final _body = TextEditingController();
  final _footer = TextEditingController();

  String _language = '';
  String _category = '';

  /// Which backend token feeds each {{n}}, in order. token_map[0] -> {{1}}.
  final List<String> _tokenMap = [];

  /// The example value shown to Meta for each {{n}}, in the same order.
  final List<TextEditingController> _examples = [];

  final List<Map<String, dynamic>> _buttons = [];
  final List<TextEditingController> _buttonText = [];
  final List<TextEditingController> _buttonValue = [];

  Timer? _debounce;
  Map<String, dynamic>? _preview;
  List<dynamic> _errors = const [];
  List<dynamic> _warnings = const [];
  bool _checking = false;
  bool _busy = false;

  /// The saved row's id. Starts empty for a new template and is filled in by
  /// the first successful save — every gate below reads the SAVED row, so none
  /// of them has an answer before there is one.
  String _id = '';

  /// wa_template_submit_blockers(). Null means "not asked yet", which is NOT
  /// the same as "may not submit" — see [_gateBlocks].
  Map<String, dynamic>? _gate;

  Map<String, dynamic>? _mediaSpec;
  Map<String, dynamic>? _headerStatus;
  String _headerFormat = 'TEXT';

  /// Whether the saved row's header format has been adopted from
  /// wa_template_header_status yet. After the first load the picker owns it.
  bool _headerSeeded = false;
  bool _uploading = false;

  /// The backend's own refusal sentence from the last upload attempt, printed
  /// verbatim. Empty when there is nothing to say.
  String _uploadMessage = '';
  Timer? _headerPoll;

  Timer? _similarDebounce;
  Map<String, dynamic>? _similar;

  Map<String, dynamic>? _policy;
  bool _policyBusy = false;
  Timer? _policyPoll;

  // ── payload accessors ──────────────────────────────────────────────────────

  WaCopy get _copy =>
      WaCopy((widget.screen['copy'] as Map?)?.cast<String, dynamic>() ?? const {});
  List<dynamic> get _starters =>
      (widget.screen['starters'] as List?) ?? const [];
  List<dynamic> get _tokens => (widget.screen['tokens'] as List?) ?? const [];
  List<dynamic> get _categories =>
      (widget.screen['categories'] as List?) ?? const [];
  List<dynamic> get _languages =>
      (widget.screen['languages'] as List?) ?? const [];
  Map<String, dynamic> get _buttonSpec =>
      (widget.screen['button_spec'] as Map?)?.cast<String, dynamic>() ??
      const {};
  List<dynamic> get _buttonTypes =>
      (_buttonSpec['types'] as List?) ?? const [];

  bool get _isNew => widget.template == null;
  String get _metaId => (widget.template?['meta_id'] ?? '').toString();
  bool get _nameLocked => _metaId.isNotEmpty;
  bool get _blocked => _errors.isNotEmpty;

  // ── the submit gate ────────────────────────────────────────────────────────
  //
  // Every one of these is an explicit `== false` / `== true` against a backend
  // field. An absent answer never blocks: before the RPC has replied, or when
  // there is no saved row to ask about, the editor behaves exactly as it did
  // before the gate existed. Blocking on a missing field would grey Submit out
  // for a reason nobody could read — the very bug this screen is fixing.

  bool get _gateBlocks => _gate?['can_submit'] == false;
  bool get _dupBlocks => _similar?['blocking'] == true;
  bool get _submitBlocked => _blocked || _gateBlocks || _dupBlocks;

  /// Why Submit is off, in the backend's words. Rendered under the button.
  List<String> get _submitReasons {
    final why = (_gate?['why_label'] ?? '').toString();
    final dup = (_similar?['summary'] ?? '').toString();
    return [
      if (_gateBlocks && why.isNotEmpty) why,
      if (_dupBlocks && dup.isNotEmpty) dup,
    ];
  }

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _language = (t?['language'] ?? '').toString();
    if (_language.isEmpty && _languages.isNotEmpty) {
      _language = ((_languages.first as Map)['key'] ?? '').toString();
    }
    _category = (t?['category'] ?? '').toString();
    if (_category.isEmpty && _categories.isNotEmpty) {
      _category = ((_categories.first as Map)['key'] ?? '').toString();
    }
    _name.text = (t?['name'] ?? '').toString();

    final seed = widget.initialComponents ??
        (t?['components'] as List?) ??
        const <dynamic>[];
    final map = (t?['token_map'] as List?) ?? const <dynamic>[];
    _loadComponents(seed, map);

    for (final c in [_name, _header, _body, _footer]) {
      c.addListener(_schedule);
    }
    // The duplicate check depends only on the body, so it runs on its own,
    // slower debounce rather than riding the lint round-trip.
    _body.addListener(_scheduleSimilar);
    if (seed.isNotEmpty) _schedule();

    _id = (t?['id'] ?? '').toString();
    _loadMediaSpec();
    _refreshGate();
    _refreshHeaderStatus();
    _refreshPolicy();
    if (_body.text.trim().isNotEmpty) _scheduleSimilar();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _similarDebounce?.cancel();
    _headerPoll?.cancel();
    _policyPoll?.cancel();
    for (final c in [_name, _header, _body, _footer]) {
      c.dispose();
    }
    for (final c in [..._examples, ..._buttonText, ..._buttonValue]) {
      c.dispose();
    }
    super.dispose();
  }

  // ── components <-> form ────────────────────────────────────────────────────

  /// Unpacks a components array into the form fields. Used on open and when a
  /// starter is chosen.
  void _loadComponents(List<dynamic> components, List<dynamic> tokenMap) {
    _header.text = '';
    _headerFormat = 'TEXT';
    _body.text = '';
    _footer.text = '';
    for (final c in [..._examples, ..._buttonText, ..._buttonValue]) {
      c.dispose();
    }
    _examples.clear();
    _buttons.clear();
    _buttonText.clear();
    _buttonValue.clear();
    _tokenMap
      ..clear()
      ..addAll(tokenMap.map((e) => e.toString()));

    for (final raw in components) {
      if (raw is! Map) continue;
      final c = raw.cast<String, dynamic>();
      switch ((c['type'] ?? '').toString().toUpperCase()) {
        case 'HEADER':
          _header.text = (c['text'] ?? '').toString();
          // A header with no format is a text header — that is Meta's own
          // default, mirrored by wa_template_header_status's coalesce.
          _headerFormat =
              (c['format'] ?? 'TEXT').toString().toUpperCase();
          break;
        case 'BODY':
          _body.text = (c['text'] ?? '').toString();
          final ex = (c['example'] as Map?)?['body_text'];
          final row = (ex is List && ex.isNotEmpty) ? ex.first : null;
          if (row is List) {
            for (final v in row) {
              _examples.add(TextEditingController(text: v.toString()));
            }
          }
          break;
        case 'FOOTER':
          _footer.text = (c['text'] ?? '').toString();
          break;
        case 'BUTTONS':
          for (final b in (c['buttons'] as List?) ?? const []) {
            if (b is! Map) continue;
            final m = b.cast<String, dynamic>();
            _buttons.add({'type': (m['type'] ?? '').toString()});
            _buttonText
                .add(TextEditingController(text: (m['text'] ?? '').toString()));
            _buttonValue.add(TextEditingController(
                text: (m['url'] ?? m['phone_number'] ?? '').toString()));
          }
          break;
      }
    }
    // A starter may declare more bindings than it has example values, or the
    // other way round. Keep the two lists the same length so {{n}} and its
    // example never drift apart.
    while (_examples.length < _tokenMap.length) {
      _examples.add(TextEditingController(text: _exampleFor(_tokenMap[_examples.length])));
    }
  }

  String _exampleFor(String tokenKey) {
    for (final t in _tokens) {
      if (t is Map && (t['key'] ?? '').toString() == tokenKey) {
        return (t['example'] ?? '').toString();
      }
    }
    return '';
  }

  /// The components array as it currently stands in the form. This is what is
  /// sent to validate / preview / save — one shape, three destinations, so the
  /// lint and the bubble can never describe a different template than the save.
  List<Map<String, dynamic>> _componentsNow() {
    final list = <Map<String, dynamic>>[];
    if (_headerFormat != 'TEXT') {
      // A media header carries no text — the sample file IS the header. The
      // handle Meta issues for it lives on the row, put there by
      // wa_template_set_header_media, so it is never sent from here.
      list.add({'type': 'HEADER', 'format': _headerFormat});
    } else if (_header.text.trim().isNotEmpty) {
      list.add({'type': 'HEADER', 'format': 'TEXT', 'text': _header.text});
    }
    final body = <String, dynamic>{'type': 'BODY', 'text': _body.text};
    if (_examples.isNotEmpty) {
      body['example'] = {
        'body_text': [_examples.map((c) => c.text).toList()],
      };
    }
    list.add(body);
    if (_footer.text.trim().isNotEmpty) {
      list.add({'type': 'FOOTER', 'text': _footer.text});
    }
    if (_buttons.isNotEmpty) {
      final buttons = <Map<String, dynamic>>[];
      for (var i = 0; i < _buttons.length; i++) {
        final type = (_buttons[i]['type'] ?? '').toString();
        final b = <String, dynamic>{'type': type, 'text': _buttonText[i].text};
        if (type == 'URL') {
          b['url'] = _buttonValue[i].text;
          final ex = _attributionExample(type);
          if (ex.isNotEmpty) b['example'] = [ex];
        } else if (type == 'PHONE_NUMBER') {
          b['phone_number'] = _buttonValue[i].text;
        }
        buttons.add(b);
      }
      list.add({'type': 'BUTTONS', 'buttons': buttons});
    }
    return list;
  }

  Map<String, dynamic>? _typeSpec(String key) {
    for (final t in _buttonTypes) {
      if (t is Map && (t['key'] ?? '').toString() == key) {
        return t.cast<String, dynamic>();
      }
    }
    return null;
  }

  String _attributionExample(String key) {
    final ex = _typeSpec(key)?['attribution_example'];
    if (ex is List && ex.isNotEmpty) return ex.first.toString();
    return '';
  }

  int _countOfType(String key) =>
      _buttons.where((b) => (b['type'] ?? '') == key).length;

  // ── debounced backend round-trip ───────────────────────────────────────────

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(WaTemplateEditorScreen.debounce, _refresh);
  }

  Future<void> _refresh() async {
    final components = _componentsNow();
    if (mounted) setState(() => _checking = true);
    try {
      // Both answers come from the backend, for the same components.
      final results = await Future.wait([
        WaTemplateApi.validate(components, _category),
        WaTemplateApi.preview(components),
      ]);
      if (!mounted) return;
      setState(() {
        _errors = (results[0]['errors'] as List?) ?? const [];
        _warnings = (results[0]['warnings'] as List?) ?? const [];
        _preview = results[1];
        _checking = false;
      });
      try {
        RenderLog.write('wa_tpl_lint', 'e:${_errors.length} w:${_warnings.length}');
        RenderLog.write('wa_tpl_preview_ok', 1);
      } catch (_) {}
    } catch (_) {
      if (mounted) setState(() => _checking = false);
    }
  }

  // ── submit gate ────────────────────────────────────────────────────────────
  //
  // Each of these refuses to change anything when the RPC sends an error
  // envelope. A refusal must not blank a section that was showing a good
  // answer a moment ago.

  Future<void> _refreshGate() async {
    if (_id.isEmpty) return;
    try {
      final res = await WaTemplateApi.submitBlockers(_id);
      if (!mounted || WaTemplateApi.isError(res, 'can_submit')) return;
      setState(() => _gate = res);
      try {
        RenderLog.write('wa_tpl_gate', 'can:${res['can_submit']} n:${res['count']}');
      } catch (_) {}
    } catch (_) {}
  }

  // ── media header ───────────────────────────────────────────────────────────

  Future<void> _loadMediaSpec() async {
    try {
      final res = await WaTemplateApi.mediaSpec();
      if (!mounted || WaTemplateApi.isError(res, 'formats')) return;
      setState(() => _mediaSpec = res);
    } catch (_) {}
  }

  Future<void> _refreshHeaderStatus() async {
    if (_id.isEmpty) return;
    try {
      final res = await WaTemplateApi.headerStatus(_id);
      // 'header_format' is the required field, NOT the absence of 'error':
      // this payload carries its own nullable `error` (the upload's failure
      // text) inside a perfectly healthy response.
      if (!mounted || WaTemplateApi.isError(res, 'header_format')) return;
      setState(() {
        _headerStatus = res;
        // The saved row's header format is the BACKEND's answer, so it is
        // taken from here rather than inferred from the components the editor
        // happens to be holding. Adopted once, on first load: after that the
        // admin's choice in the picker is the live one.
        if (!_headerSeeded) {
          _headerSeeded = true;
          _headerFormat =
              (res['header_format'] ?? _headerFormat).toString().toUpperCase();
        }
      });
    } catch (_) {}
  }

  /// Meta issues the sample handle asynchronously, so the row is polled until
  /// it stops saying 'pending' or the deadline passes — never forever.
  void _startHeaderPoll() {
    _headerPoll?.cancel();
    var waited = Duration.zero;
    _headerPoll = Timer.periodic(WaTemplateEditorScreen.pollInterval, (t) async {
      waited += WaTemplateEditorScreen.pollInterval;
      await _refreshHeaderStatus();
      final status = (_headerStatus?['status'] ?? '').toString();
      if (status != 'pending' || waited >= WaTemplateEditorScreen.pollTimeout) {
        t.cancel();
        await _refreshGate();
      }
    });
  }

  /// The extensions come from the format's own `accepts`, so the dialog offers
  /// what Meta accepts. Nothing is rejected here: an oversized or wrong-typed
  /// file is uploaded and refused by the RPC, in the RPC's own words.
  Future<void> _pickAndUpload(Map<String, dynamic> format) async {
    if (_id.isEmpty) return;
    final exts = [
      for (final e in (format['accepts'] ?? '').toString().split(','))
        if (e.trim().isNotEmpty) e.trim().toLowerCase(),
    ];
    final pick = WaTemplateEditorScreen.filePicker ?? _pickFromDevice;
    final picked = await pick(exts);
    if (picked == null || !mounted) return;

    setState(() {
      _uploading = true;
      _uploadMessage = '';
    });
    try {
      final ext = picked.name.contains('.')
          ? picked.name.split('.').last.toLowerCase()
          : '';
      final mime = _mimeFor(ext);
      final path =
          'whatsapp/tpl_${_id}_${DateTime.now().millisecondsSinceEpoch}.$ext';
      await WaTemplateApi.uploadMedia(
          path: path, bytes: picked.bytes, mime: mime);
      final res = await WaTemplateApi.setHeaderMedia(
        id: _id,
        storagePath: path,
        mime: mime,
        bytes: picked.bytes.length,
      );
      if (!mounted) return;
      setState(() {
        _uploading = false;
        // Accepted or refused, the sentence shown is the backend's.
        _uploadMessage = WaTemplateApi.errorMessage(res);
      });
      if (res['ok'] == true) {
        await _refreshHeaderStatus();
        _startHeaderPoll();
      }
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// A file name is not a MIME type, and the browser hands over only the name.
  /// These are the extensions wa_template_media_spec itself lists; anything
  /// else goes up as generic binary for the RPC to refuse. This decides
  /// nothing about whether the file is allowed.
  static String _mimeFor(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      case 'mp4':
        return 'video/mp4';
      case '3gp':
        return 'video/3gpp';
      default:
        return 'application/octet-stream';
    }
  }

  static Future<WaPickedFile?> _pickFromDevice(List<String> extensions) async {
    final res = await FilePicker.pickFiles(
      type: extensions.isEmpty ? FileType.any : FileType.custom,
      allowedExtensions: extensions.isEmpty ? null : extensions,
      withData: true,
    );
    final file = (res?.files.isNotEmpty ?? false) ? res!.files.first : null;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;
    return WaPickedFile(name: file.name, bytes: bytes);
  }

  // ── duplicate check ────────────────────────────────────────────────────────

  void _scheduleSimilar() {
    _similarDebounce?.cancel();
    _similarDebounce =
        Timer(WaTemplateEditorScreen.similarDebounce, _refreshSimilar);
  }

  Future<void> _refreshSimilar() async {
    try {
      final res = await WaTemplateApi.similar(
          _body.text, _id.isEmpty ? null : _id);
      if (!mounted || WaTemplateApi.isError(res, 'summary')) return;
      setState(() => _similar = res);
    } catch (_) {}
  }

  // ── AI policy review ───────────────────────────────────────────────────────

  Future<void> _refreshPolicy() async {
    if (_id.isEmpty) return;
    try {
      final res = await WaTemplateApi.policyReviewLatest(_id);
      // Same trap as the header: a healthy verdict carries a null `error`.
      if (!mounted || WaTemplateApi.isError(res, 'status')) return;
      setState(() => _policy = res);
    } catch (_) {}
  }

  Future<void> _startPolicyReview() async {
    if (_id.isEmpty) return;
    setState(() => _policyBusy = true);
    try {
      final res = await WaTemplateApi.policyReviewStart(_id);
      if (!mounted) return;
      if (res['ok'] != true) {
        final msg = WaTemplateApi.errorMessage(res);
        if (msg.isNotEmpty) showToast(context, msg, isError: true);
        setState(() => _policyBusy = false);
        return;
      }
      await _refreshPolicy();
      _startPolicyPoll();
    } catch (_) {
      if (mounted) setState(() => _policyBusy = false);
    }
  }

  void _startPolicyPoll() {
    _policyPoll?.cancel();
    var waited = Duration.zero;
    _policyPoll = Timer.periodic(WaTemplateEditorScreen.pollInterval, (t) async {
      waited += WaTemplateEditorScreen.pollInterval;
      await _refreshPolicy();
      final status = (_policy?['status'] ?? '').toString();
      if (status != 'pending' || waited >= WaTemplateEditorScreen.pollTimeout) {
        t.cancel();
        if (mounted) setState(() => _policyBusy = false);
      }
    });
  }

  // ── starters / tokens ──────────────────────────────────────────────────────

  void _applyStarter(Map<String, dynamic> s) {
    setState(() {
      _name.text = (s['name'] ?? '').toString();
      _category = (s['category'] ?? '').toString();
      _loadComponents(
        (s['components'] as List?) ?? const [],
        (s['token_map'] as List?) ?? const [],
      );
    });
    _schedule();
  }

  /// Appends the next {{n}} and records which backend value feeds it.
  ///
  /// The index comes from how many bindings are already recorded — the body
  /// text is never parsed to work it out. If the admin deletes a {{n}} by hand
  /// the backend lint says so ("Placeholders must run in order"); that verdict
  /// is not second-guessed here.
  void _insertToken(Map<String, dynamic> token) {
    final key = (token['key'] ?? '').toString();
    final n = _tokenMap.length + 1;
    setState(() {
      _tokenMap.add(key);
      _examples.add(TextEditingController(text: (token['example'] ?? '').toString()));
      final sel = _body.selection;
      final text = _body.text;
      final at = (sel.isValid && sel.start >= 0 && sel.start <= text.length)
          ? sel.start
          : text.length;
      final inserted = '{{$n}}';
      _body.text = text.substring(0, at) + inserted + text.substring(at);
      _body.selection =
          TextSelection.collapsed(offset: at + inserted.length);
    });
    _schedule();
  }

  // ── save / submit ──────────────────────────────────────────────────────────

  Future<void> _save({bool thenSubmit = false}) async {
    setState(() => _busy = true);
    try {
      final res = await WaTemplateApi.save(
        id: widget.template?['id']?.toString(),
        name: _name.text,
        language: _language,
        category: _category,
        components: _componentsNow(),
      );
      if (!mounted) return;

      if (res['ok'] != true) {
        final err = (res['error'] ?? '').toString();
        if (err == 'invalid') {
          // Backend's own issue list, verbatim, in the same red block the lint
          // uses.
          setState(() => _errors = (res['issues'] as List?) ?? const []);
        } else {
          final msg = (res['message'] ?? '').toString();
          showToast(context, msg.isEmpty ? _copy['generic_error'] : msg,
              isError: true);
        }
        setState(() => _busy = false);
        return;
      }

      final saved = (res['template'] as Map?)?.cast<String, dynamic>();
      // A new template only has an id from here on, which is also the first
      // moment the gate has a row to read.
      if (saved != null) _id = (saved['id'] ?? '').toString();
      await _refreshGate();
      if (!mounted) return;

      if (thenSubmit && saved != null) {
        final id = (saved['id'] ?? '').toString();
        final sub = await WaTemplateApi.submit(id);
        if (!mounted) return;
        if (sub['status'] == 'ok') {
          showToast(context, _copy['submit_ok']);
        } else {
          // Meta's own wording — shown exactly as Meta phrased it.
          final meta = (sub['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
          final title = (meta['title'] ?? '').toString();
          final message = (meta['message'] ?? '').toString();
          final shown = [title, message].where((s) => s.isNotEmpty).join(' — ');
          showToast(context, shown.isEmpty ? _copy['generic_error'] : shown,
              isError: true);
          setState(() => _busy = false);
          return;
        }
      } else {
        showToast(context, _copy['saved']);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      showToast(context, _copy['generic_error'], isError: true);
      setState(() => _busy = false);
    }
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new,
              size: 20, color: Color(0xFF1B7A43)),
          onPressed: () => Navigator.of(context).pop(false),
        ),
        title: Text(
          _isNew ? copy['editor_new_title'] : copy['editor_edit_title'],
          style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: Color(0xFF111827)),
        ),
      ),
      bottomNavigationBar: _ActionBar(
        copy: copy,
        blocked: _blocked,
        submitBlocked: _submitBlocked,
        reasons: _submitReasons,
        busy: _busy,
        onSave: () => _save(),
        onSubmit: () => _save(thenSubmit: true),
        onWhyBlocked: () => waSubmitBlockersSheet(context, _gate, _similar),
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 900;
          final form = _buildForm(copy);
          final preview = _buildPreview(copy);
          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: form,
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: preview,
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [form, const SizedBox(height: 24), preview],
            ),
          );
        },
      ),
    );
  }

  Widget _buildForm(WaCopy copy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── starters (new templates only) ───────────────────────────────
        if (_isNew && _starters.isNotEmpty) ...[
          _SectionTitle(copy['starters_title']),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final s in _starters)
                if (s is Map)
                  _StarterChip(
                    label: (s['label'] ?? '').toString(),
                    note: (s['note'] ?? '').toString(),
                    onTap: () => _applyStarter(s.cast<String, dynamic>()),
                  ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        // ── name / language / category ──────────────────────────────────
        _Field(
          label: copy['name_label'],
          hint: copy['name_hint'],
          controller: _name,
          enabled: !_nameLocked,
        ),
        if (_nameLocked)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              copy['name_locked_note'],
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ),
        const SizedBox(height: 16),
        _Dropdown(
          label: copy['language_label'],
          value: _language,
          enabled: !_nameLocked,
          items: _languages,
          onChanged: (v) {
            setState(() => _language = v);
            _schedule();
          },
        ),
        const SizedBox(height: 16),
        _Dropdown(
          label: copy['category_label'],
          value: _category,
          items: _categories,
          onChanged: (v) {
            setState(() => _category = v);
            _schedule();
          },
        ),
        // The category note carries the cost / opt-in wording. It matters, so
        // it is rendered rather than tucked into a tooltip.
        ..._categoryNote(),

        const SizedBox(height: 24),

        // ── header / body / footer ──────────────────────────────────────
        _buildHeaderSection(copy),
        const SizedBox(height: 16),
        _Field(label: copy['body_label'], controller: _body, maxLines: 6),

        const SizedBox(height: 12),
        _SectionTitle(copy['tokens_title']),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _tokens)
              if (t is Map)
                _TokenChip(
                  label: (t['label'] ?? '').toString(),
                  example: (t['example'] ?? '').toString(),
                  onTap: () => _insertToken(t.cast<String, dynamic>()),
                ),
          ],
        ),

        if (_examples.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionTitle(copy['examples_title']),
          const SizedBox(height: 8),
          for (var i = 0; i < _examples.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Field(
                label: '{{${i + 1}}}'
                    '${i < _tokenMap.length ? '  ·  ${_tokenMap[i]}' : ''}',
                controller: _examples[i],
                onChanged: (_) => _schedule(),
              ),
            ),
        ],

        const SizedBox(height: 16),
        _Field(
            label: copy['footer_label'], controller: _footer, maxLines: 1),

        const SizedBox(height: 24),
        _buildButtons(copy),
      ],
    );
  }

  // ── header section ─────────────────────────────────────────────────────────

  Map<String, dynamic>? _formatSpec(String value) {
    for (final f in (_mediaSpec?['formats'] as List?) ?? const []) {
      if (f is Map && (f['value'] ?? '').toString().toUpperCase() == value) {
        return f.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// The format picker plus whichever header the chosen format needs. The list
  /// of formats, their labels, what they accept and how big they may be all
  /// come from wa_template_media_spec — none of it is written here.
  Widget _buildHeaderSection(WaCopy copy) {
    final formats = (_mediaSpec?['formats'] as List?) ?? const [];
    final blockedReason = (_mediaSpec?['blocked_reason'] ?? '').toString();
    final rules = [
      for (final r in (_mediaSpec?['rules'] as List?) ?? const [])
        if (r.toString().isNotEmpty) r.toString(),
    ];
    final isText = _headerFormat == 'TEXT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (blockedReason.isNotEmpty) ...[
          WaBanner(body: blockedReason, tone: 'muted'),
          const SizedBox(height: 8),
        ],
        if (formats.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in formats)
                if (f is Map)
                  Builder(builder: (_) {
                    final m = f.cast<String, dynamic>();
                    final value = (m['value'] ?? '').toString().toUpperCase();
                    // blocked_reason turns the MEDIA formats off. Text is
                    // always available — it needs nothing from Meta.
                    final off = blockedReason.isNotEmpty && value != 'TEXT';
                    return _FormatChoice(
                      label: (m['label'] ?? '').toString(),
                      selected: value == _headerFormat,
                      enabled: !off,
                      onTap: () {
                        setState(() => _headerFormat = value);
                        _schedule();
                        if (value != 'TEXT') _refreshHeaderStatus();
                      },
                    );
                  }),
            ],
          ),
          const SizedBox(height: 12),
        ],
        if (isText)
          _Field(label: copy['header_label'], controller: _header, maxLines: 1)
        else ...[
          _buildMediaHeader(),
          if (rules.isNotEmpty) ...[
            const SizedBox(height: 12),
            WaBanner(tone: 'muted', lines: rules),
          ],
        ],
      ],
    );
  }

  /// The sample file's state, exactly as wa_template_header_status describes
  /// it. `expired` or a `blocker` repaints it in the bad tone — that override
  /// is the one place this widget insists, because a stale sample looks fine
  /// until Meta rejects the submission.
  Widget _buildMediaHeader() {
    final h = _headerStatus;
    final expired = h?['expired'] == true;
    final blocker = (h?['blocker'] ?? '').toString();
    final bad = expired || blocker.isNotEmpty;
    final format = _formatSpec(_headerFormat);

    final lines = [
      for (final s in [
        blocker,
        (h?['error'] ?? '').toString(),
        (h?['file_label'] ?? '').toString(),
        (h?['size_label'] ?? '').toString(),
        (h?['expires_label'] ?? '').toString(),
      ])
        if (s.isNotEmpty) s,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WaBanner(
          title: (h?['status_label'] ?? '').toString(),
          tone: bad ? 'bad' : h?['tone'],
          lines: lines,
          action: _uploading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    // Nothing can be uploaded against a row that does not
                    // exist yet, so the action waits for the first save.
                    onPressed: (format == null || _id.isEmpty)
                        ? null
                        : () => _pickAndUpload(format),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B7A43),
                      side: const BorderSide(color: Color(0xFF1B7A43)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Re-upload'),
                  ),
                ),
        ),
        if (_uploadMessage.isNotEmpty) ...[
          const SizedBox(height: 8),
          WaBanner(body: _uploadMessage, tone: 'muted'),
        ],
      ],
    );
  }

  List<Widget> _categoryNote() {
    for (final c in _categories) {
      if (c is Map && (c['key'] ?? '').toString() == _category) {
        final note = (c['note'] ?? '').toString();
        if (note.isEmpty) return const [];
        return [
          const SizedBox(height: 6),
          Text(note,
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        ];
      }
    }
    return const [];
  }

  Widget _buildButtons(WaCopy copy) {
    final totalMax = (_buttonSpec['total_max'] as num?)?.toInt() ?? 0;
    final textMax = (_buttonSpec['text_max'] as num?)?.toInt();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(copy['buttons_title']),
        const SizedBox(height: 8),
        for (var i = 0; i < _buttons.length; i++)
          _ButtonRow(
            index: i,
            type: (_buttons[i]['type'] ?? '').toString(),
            spec: _typeSpec((_buttons[i]['type'] ?? '').toString()),
            copy: copy,
            textController: _buttonText[i],
            valueController: _buttonValue[i],
            textMax: textMax,
            onChanged: _schedule,
            onTrackingLink: () {
              final url =
                  (_typeSpec('URL')?['attribution_url'] ?? '').toString();
              _buttonValue[i].text = url;
              _schedule();
            },
            onRemove: () {
              setState(() {
                _buttons.removeAt(i);
                _buttonText.removeAt(i).dispose();
                _buttonValue.removeAt(i).dispose();
              });
              _schedule();
            },
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in _buttonTypes)
              if (t is Map)
                Builder(builder: (_) {
                  final key = (t['key'] ?? '').toString();
                  final max = (t['max'] as num?)?.toInt() ?? 0;
                  // The limits are the backend's numbers, not ours.
                  final full = _countOfType(key) >= max ||
                      (totalMax > 0 && _buttons.length >= totalMax);
                  return OutlinedButton.icon(
                    onPressed: full
                        ? null
                        : () {
                            setState(() {
                              _buttons.add({'type': key});
                              _buttonText.add(TextEditingController());
                              _buttonValue.add(TextEditingController());
                            });
                            _schedule();
                          },
                    icon: const Icon(Icons.add, size: 16),
                    label: Text((t['label'] ?? '').toString()),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B7A43),
                      side: const BorderSide(color: Color(0xFF1B7A43)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                  );
                }),
          ],
        ),
      ],
    );
  }

  Widget _buildPreview(WaCopy copy) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _SectionTitle(copy['preview_title']),
            const SizedBox(width: 8),
            if (_checking)
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Color(0xFF6B7280)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_preview == null)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              WaSkeleton(height: 16, width: 200),
              SizedBox(height: 8),
              WaSkeleton(height: 16),
              SizedBox(height: 8),
              WaSkeleton(height: 16, width: 160),
            ],
          )
        else
          WaPreviewBubble(preview: _preview!),

        // ── lint, verbatim ─────────────────────────────────────────────
        if (_errors.isNotEmpty) ...[
          const SizedBox(height: 16),
          WaBanner(
            title: copy['errors_title'],
            tone: 'red',
            lines: _errors.map((e) => e.toString()).toList(),
          ),
        ],
        if (_warnings.isNotEmpty) ...[
          const SizedBox(height: 12),
          WaBanner(
            title: copy['warnings_title'],
            tone: 'yellow',
            lines: _warnings.map((e) => e.toString()).toList(),
          ),
        ],

        // ── duplicate check ────────────────────────────────────────────
        ..._buildDuplicate(),

        // ── AI policy review ───────────────────────────────────────────
        const SizedBox(height: 16),
        _buildPolicy(),
      ],
    );
  }

  /// wa_template_similar's own summary, in its own tone, over its own rows.
  /// The percentages, the wording and the verdict about what counts as too
  /// close are all the backend's — this only prints them.
  List<Widget> _buildDuplicate() {
    final s = _similar;
    if (s == null) return const [];
    final summary = (s['summary'] ?? '').toString();
    final rows = (s['rows'] as List?) ?? const [];
    if (summary.isEmpty && rows.isEmpty) return const [];
    return [
      const SizedBox(height: 12),
      WaBanner(body: summary, tone: s['tone']),
      if (rows.isNotEmpty) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final r in rows)
              if (r is Map)
                WaChip(
                  label: (r['label'] ?? '').toString(),
                  tone: r['tone'],
                ),
          ],
        ),
      ],
    ];
  }

  /// The pre-submit review. Everything shown is the verdict's own wording;
  /// "Use this wording" appears only when the backend actually supplied a
  /// rewrite, never as an empty gesture.
  Widget _buildPolicy() {
    final p = _policy;
    final verdict = (p?['verdict'] as Map?)?.cast<String, dynamic>();
    final suggested = (verdict?['suggested_body'] ?? '').toString();
    final label = (p?['label'] ?? '').toString();

    final detail = [
      for (final s in [
        (verdict?['verdict_label'] ?? '').toString(),
        (verdict?['category_advice'] ?? '').toString(),
        (verdict?['likely_rejection_reason'] ?? '').toString(),
      ])
        if (s.isNotEmpty) s,
    ];
    final issues = (verdict?['issues'] as List?) ?? const [];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed:
                (_id.isEmpty || _policyBusy) ? null : _startPolicyReview,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF1B7A43),
              side: const BorderSide(color: Color(0xFF1B7A43)),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('Check before submitting'),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: WaChip(label: label, tone: p?['tone']),
          ),
        ],
        if (detail.isNotEmpty) ...[
          const SizedBox(height: 8),
          WaBanner(tone: p?['tone'], lines: detail),
        ],
        if (issues.isNotEmpty) ...[
          const SizedBox(height: 12),
          WaIssueList(issues: issues),
        ],
        if (suggested.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: () {
                _body.text = suggested;
                _schedule();
                _scheduleSimilar();
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text('Use this wording'),
            ),
          ),
        ],
      ],
    );
  }
}

// ── small building blocks ────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xFF6B7280)),
      );
}

class _Field extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final bool enabled;
  final int maxLines;
  final int? maxLength;
  final ValueChanged<String>? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.enabled = true,
    this.maxLines = 1,
    this.maxLength,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF6B7280))),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            enabled: enabled,
            maxLines: maxLines,
            maxLength: maxLength,
            onChanged: onChanged,
            style: const TextStyle(fontSize: 15, color: Color(0xFF111827)),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
              filled: true,
              fillColor: enabled ? const Color(0xFFF5F6F8) : const Color(0xFFEDEFF2),
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: Color(0xFF1B7A43)),
              ),
            ),
          ),
        ],
      );
}

class _Dropdown extends StatelessWidget {
  final String label;
  final String value;
  final List<dynamic> items;
  final ValueChanged<String> onChanged;
  final bool enabled;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final keys = [
      for (final i in items)
        if (i is Map) (i['key'] ?? '').toString(),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF6B7280))),
        const SizedBox(height: 6),
        Container(
          height: 48,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: enabled ? const Color(0xFFF5F6F8) : const Color(0xFFEDEFF2),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: keys.contains(value) ? value : null,
              isExpanded: true,
              onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
              items: [
                for (final i in items)
                  if (i is Map)
                    DropdownMenuItem(
                      value: (i['key'] ?? '').toString(),
                      child: Text(
                        (i['label'] ?? '').toString(),
                        style: const TextStyle(
                            fontSize: 15, color: Color(0xFF111827)),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One option in the header-format picker. `label` is the backend's.
class _FormatChoice extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _FormatChoice({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = !enabled
        ? const Color(0xFF9CA3AF)
        : selected
            ? Colors.white
            : const Color(0xFF1B7A43);
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: !enabled
              ? const Color(0xFFF3F4F6)
              : selected
                  ? const Color(0xFF1B7A43)
                  : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: enabled
                  ? const Color(0xFF1B7A43)
                  : const Color(0xFFE5E7EB)),
        ),
        child: Text(
          label,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w500, color: fg),
        ),
      ),
    );
  }
}

class _StarterChip extends StatelessWidget {
  final String label;
  final String note;
  final VoidCallback onTap;
  const _StarterChip(
      {required this.label, required this.note, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF1B7A43)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1B7A43))),
              if (note.isNotEmpty)
                Text(note,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
            ],
          ),
        ),
      );
}

class _TokenChip extends StatelessWidget {
  final String label;
  final String example;
  final VoidCallback onTap;
  const _TokenChip(
      {required this.label, required this.example, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFEFF6FF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.add, size: 13, color: Color(0xFF1E40AF)),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF1E40AF))),
              if (example.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(example,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280))),
              ],
            ],
          ),
        ),
      );
}

class _ButtonRow extends StatelessWidget {
  final int index;
  final String type;
  final Map<String, dynamic>? spec;
  final WaCopy copy;
  final TextEditingController textController;
  final TextEditingController valueController;
  final int? textMax;
  final VoidCallback onChanged;
  final VoidCallback onTrackingLink;
  final VoidCallback onRemove;

  const _ButtonRow({
    required this.index,
    required this.type,
    required this.spec,
    required this.copy,
    required this.textController,
    required this.valueController,
    required this.textMax,
    required this.onChanged,
    required this.onTrackingLink,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final note = (spec?['note'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  (spec?['label'] ?? type).toString(),
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF111827)),
                ),
              ),
              IconButton(
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 18),
                color: const Color(0xFF6B7280),
                tooltip: copy['remove'],
              ),
            ],
          ),
          if (note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(note,
                  style: const TextStyle(
                      fontSize: 12, color: Color(0xFF6B7280))),
            ),
          _Field(
            label: copy['button_text_label'],
            controller: textController,
            maxLength: textMax,
            onChanged: (_) => onChanged(),
          ),
          if (type == 'URL') ...[
            const SizedBox(height: 8),
            _Field(
              label: copy['button_url_label'],
              controller: valueController,
              onChanged: (_) => onChanged(),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onTrackingLink,
                icon: const Icon(Icons.link, size: 16),
                label: Text(copy['use_tracking_link']),
                style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF1B7A43)),
              ),
            ),
          ],
          if (type == 'PHONE_NUMBER') ...[
            const SizedBox(height: 8),
            _Field(
              label: copy['button_phone_label'],
              controller: valueController,
              onChanged: (_) => onChanged(),
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  final WaCopy copy;

  /// The lint's verdict — still what Save obeys.
  final bool blocked;

  /// The lint OR the submit gate OR the duplicate check. Only Submit obeys
  /// this: a draft that Meta would reject is still worth saving.
  final bool submitBlocked;

  /// Why Submit is off, in the backend's words. Empty when it is on.
  final List<String> reasons;

  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onSubmit;
  final VoidCallback onWhyBlocked;

  const _ActionBar({
    required this.copy,
    required this.blocked,
    required this.submitBlocked,
    required this.reasons,
    required this.busy,
    required this.onSave,
    required this.onSubmit,
    required this.onWhyBlocked,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton(
                    // Disabled precisely while the backend reports errors.
                    onPressed: (blocked || busy) ? null : onSave,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B7A43),
                      side: const BorderSide(color: Color(0xFF1B7A43)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(copy['save']),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                // A disabled button that simply does nothing is the bug this
                // screen is fixing. It stays disabled — but the tap is caught
                // above it and answers the only question worth asking: why?
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: (submitBlocked && !busy) ? onWhyBlocked : null,
                  child: IgnorePointer(
                    ignoring: submitBlocked && !busy,
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: (submitBlocked || busy) ? null : onSubmit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B7A43),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFD1D5DB),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text(copy['submit']),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          // The reason, directly under the button that is off, in the warn
          // tone. Printed exactly as the backend worded it.
          for (final reason in reasons)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                reason,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: WaTone.of('warn').fg),
              ),
            ),
            ],
          ),
        ),
      );
}
