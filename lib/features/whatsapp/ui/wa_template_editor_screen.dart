import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:pharma_b2b/utils/render_log.dart';
import 'package:pharma_b2b/utils/toast.dart';
import '../data/wa_template_api.dart';
import 'wa_template_actions.dart';
import 'wa_template_bits.dart';
import 'wa_token_picker.dart';

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

  /// Debounce before wa_body_renumber. Deleting a variable out of the middle
  /// leaves a hole Meta rejects, so the body is re-checked as the admin types
  /// rather than only at save time.
  @visibleForTesting
  static Duration renumberDebounce = const Duration(milliseconds: 400);

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
  /// Seam for the tests. `mime` is the selected format's own mime list, so the
  /// dialog can filter on what Meta accepts rather than on a guess made here.
  static Future<WaPickedFile?> Function(List<String> extensions, String mime)?
      filePicker;

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

  /// Which value feeds each numbered variable: the key at index 0 is what
  /// {{1}} in the body means.
  ///
  /// This is the single source of truth for the mapping, and it is never
  /// derived from the body text. wa_body_insert_token and wa_body_renumber
  /// both return a map alongside the body they produced; whatever they hand
  /// back is stored here verbatim and passed to wa_template_save unchanged.
  /// Rebuilding it in Dart is what let the app and the backend disagree about
  /// which value fed {{2}}.
  List<String> _tokenKeys = const [];

  /// The example value shown to Meta, held per VALUE rather than per {{n}}.
  /// Renumbering then cannot separate a value from its example.
  final Map<String, TextEditingController> _exampleByKey = {};

  final List<Map<String, dynamic>> _buttons = [];
  final List<TextEditingController> _buttonText = [];
  final List<TextEditingController> _buttonValue = [];

  Timer? _debounce;
  Map<String, dynamic>? _preview;

  /// wa_template_preview(p_template_id) — the SAVED row's preview, carrying the
  /// media header (the sample file, keyed to the row) plus body_rendered,
  /// rendered_note and char_count. Refreshed on open and after every save, not
  /// on every keystroke: the sample lives on the row, so it cannot change while
  /// the admin edits unsaved text. Null until there is a saved row to ask
  /// about; the live components preview drives the bubble until then.
  Map<String, dynamic>? _tplPreview;

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

  /// The detached upload's job id, held from an unsaved-template upload until
  /// the next save claims it (passed as p_media_job). Empty once claimed, and
  /// unused once the template exists — that path uses set_header_media instead.
  String _mediaJobId = '';

  /// wa_media_job_status for the detached upload. Same fields the banner already
  /// reads from wa_template_header_status, so the unsaved and saved cases share
  /// one block.
  Map<String, dynamic>? _mediaJobStatus;
  Timer? _mediaJobPoll;

  Timer? _similarDebounce;
  Map<String, dynamic>? _similar;

  Timer? _renumberDebounce;

  /// True while a backend-supplied body is being written into the field.
  /// Writing to the controller re-fires its own listeners, and without this the
  /// renumber that produced the text would immediately schedule another one.
  bool _applyingBody = false;

  Map<String, dynamic>? _policy;
  bool _policyBusy = false;
  bool _policyApplying = false;
  Timer? _policyPoll;

  // ── payload accessors ──────────────────────────────────────────────────────

  WaCopy get _copy =>
      WaCopy((widget.screen['copy'] as Map?)?.cast<String, dynamic>() ?? const {});
  List<dynamic> get _starters =>
      (widget.screen['starters'] as List?) ?? const [];
  // screen['tokens'] is deliberately NOT read. It was wa_template_tokens()'s
  // fixed list of nine; WaTokenPicker loads the live set instead.
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
    // Editing the body by hand can delete a variable and leave a hole in the
    // numbering, so every edit is put back to wa_body_renumber.
    _body.addListener(_scheduleRenumber);
    if (seed.isNotEmpty) _schedule();

    _id = (t?['id'] ?? '').toString();
    _loadMediaSpec();
    _refreshGate();
    _refreshHeaderStatus();
    _refreshBubblePreview();
    _refreshPolicy();
    if (_body.text.trim().isNotEmpty) _scheduleSimilar();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _similarDebounce?.cancel();
    _renumberDebounce?.cancel();
    _headerPoll?.cancel();
    _mediaJobPoll?.cancel();
    _policyPoll?.cancel();
    for (final c in [_name, _header, _body, _footer]) {
      c.dispose();
    }
    for (final c in [
      ..._exampleByKey.values,
      ..._buttonText,
      ..._buttonValue
    ]) {
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
    for (final c in [
      ..._exampleByKey.values,
      ..._buttonText,
      ..._buttonValue
    ]) {
      c.dispose();
    }
    _exampleByKey.clear();
    _buttons.clear();
    _buttonText.clear();
    _buttonValue.clear();
    // The saved row's own map, adopted as-is. A stored body is ALREADY numbered
    // — that is the only form Meta accepts — so there is nothing to convert and
    // nothing to re-derive: token_map[i] is what {{i+1}} means, and it stays
    // that way until an RPC returns a different one.
    _tokenKeys = [for (final k in tokenMap) k.toString()];
    List<String> examples = const [];

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
            examples = row.map((v) => v.toString()).toList();
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

    // examples[i] belongs to {{i+1}}, which token_map[i] names — the same
    // index in both, which is why the example follows the VALUE and survives a
    // later renumber.
    for (var i = 0; i < _tokenKeys.length; i++) {
      _exampleByKey.putIfAbsent(
        _tokenKeys[i],
        () => TextEditingController(
            text: i < examples.length ? examples[i] : ''),
      );
    }
    _ensureExamples();
  }

  /// Gives every key in the map an example field to type into. It creates
  /// controllers and nothing else — the map itself is never touched here.
  void _ensureExamples() {
    for (final k in _tokenKeys) {
      _exampleByKey.putIfAbsent(k, () => TextEditingController());
    }
  }

  /// Writes a body the BACKEND produced into the field, with its map and its
  /// caret. The three always move together: a body without its map is exactly
  /// the disagreement this screen exists to prevent.
  void _applyBody(Map<String, dynamic> res, {int? caret}) {
    final body = (res['body'] ?? '').toString();
    final map = (res['token_map'] as List?) ?? const [];
    _applyingBody = true;
    try {
      _body.text = body;
      // Clamped only to stay inside the string — an offset past the end is a
      // Flutter assertion, not a decision about where the caret belongs.
      final at = (caret ?? body.length).clamp(0, body.length);
      _body.selection = TextSelection.collapsed(offset: at);
      _tokenKeys = [for (final k in map) k.toString()];
      _ensureExamples();
    } finally {
      _applyingBody = false;
    }
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
    if (_tokenKeys.isNotEmpty) {
      body['example'] = {
        'body_text': [
          _tokenKeys.map((k) => _exampleByKey[k]?.text ?? '').toList(),
        ],
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
    _ensureExamples();
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
    // Before there is a row, the draft preview is the only one that reflects
    // the edit just made — refresh it on this same debounce. A saved template
    // keeps its open/save/upload cadence, since its bubble mirrors the row.
    if (_id.isEmpty) await _refreshBubblePreview();
  }

  /// The bubble's preview payload — the media header (the uploaded sample) and
  /// body_rendered, everything it needs to read like a delivered message. One
  /// shape, two sources: a SAVED row is fetched by id (wa_template_preview); an
  /// UNSAVED one is built from the components in the editor, the token map, and
  /// the detached upload job (wa_preview_draft), so the picture shows before
  /// there is a row. Adopts only a real payload — body_rendered is never null on
  /// success, so its absence marks an error envelope and a good bubble is never
  /// blanked.
  Future<void> _refreshBubblePreview() async {
    try {
      final res = _id.isEmpty
          ? await WaTemplateApi.previewDraft(
              _componentsNow(),
              _tokenKeys,
              _mediaJobId.isEmpty ? null : _mediaJobId,
            )
          : await WaTemplateApi.templatePreview(_id);
      if (!mounted || res['body_rendered'] == null) return;
      setState(() => _tplPreview = res);
    } catch (_) {}
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

  /// Re-fetched whenever the id changes — the spec's can_upload, upload_label
  /// and blocked_reason are answers ABOUT this template, not global constants,
  /// so a spec fetched while the template was unsaved is stale the moment it
  /// saves.
  Future<void> _loadMediaSpec() async {
    try {
      final res = await WaTemplateApi.mediaSpec(_id);
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
        await _refreshBubblePreview();
      }
    });
  }

  /// The extensions and the mime filter both come from the format's own spec,
  /// so the dialog offers exactly what Meta accepts.
  ///
  /// Works whether or not the template has been saved. An UNSAVED template
  /// uploads to a detached job (wa_media_upload_detached) whose handle the next
  /// save claims; a SAVED template attaches the sample directly, exactly as
  /// before. The two only differ in the storage path and the RPC — everything
  /// the user sees is the backend's.
  ///
  /// Size is the one thing checked before the bytes move: a 100 MB video has
  /// to travel to storage before the RPC can refuse it, and paying for that
  /// upload only to be told no is the wrong order. The refusal is still the
  /// BACKEND's sentence — both RPCs return their `too_big` message from p_bytes
  /// before they read the file, so asking first is free. Nothing else is judged
  /// here: a wrong-typed file goes up and the RPC refuses it in its own words.
  Future<void> _pickAndUpload(Map<String, dynamic> format) async {
    final exts = [
      for (final e in (format['accepts'] ?? '').toString().split(','))
        if (e.trim().isNotEmpty) e.trim().toLowerCase(),
    ];
    final pick = WaTemplateEditorScreen.filePicker ?? _pickFromDevice;
    final picked = await pick(exts, (format['mime'] ?? '').toString());
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
      final millis = DateTime.now().millisecondsSinceEpoch;
      final detached = _id.isEmpty;
      final path = detached
          ? 'whatsapp/tpl_new_$millis.$ext'
          : 'whatsapp/tpl_${_id}_$millis.$ext';

      final maxMb = num.tryParse((format['max_mb'] ?? '').toString());
      final tooBig =
          maxMb != null && picked.bytes.length > maxMb * 1024 * 1024;
      if (tooBig) {
        final refusal = detached
            ? await WaTemplateApi.mediaUploadDetached(
                storagePath: path, mime: mime, bytes: picked.bytes.length)
            : await WaTemplateApi.setHeaderMedia(
                id: _id,
                storagePath: path,
                mime: mime,
                bytes: picked.bytes.length,
              );
        if (!mounted) return;
        setState(() {
          _uploading = false;
          _uploadMessage = WaTemplateApi.errorMessage(refusal);
        });
        return;
      }

      await WaTemplateApi.uploadMedia(
          path: path, bytes: picked.bytes, mime: mime);
      final res = detached
          ? await WaTemplateApi.mediaUploadDetached(
              storagePath: path, mime: mime, bytes: picked.bytes.length)
          : await WaTemplateApi.setHeaderMedia(
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
        if (detached) {
          // Hold the job id for the next save to claim, and poll the job for
          // the same status block the attached case shows.
          setState(() => _mediaJobId = (res['job_id'] ?? '').toString());
          await _refreshMediaJobStatus();
          // The draft preview now has a media job — refresh so the bubble shows
          // the picture as soon as the handle resolves.
          await _refreshBubblePreview();
          _startMediaJobPoll();
        } else {
          await _refreshHeaderStatus();
          await _refreshBubblePreview();
          _startHeaderPoll();
        }
      }
    } catch (_) {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// The detached job's state, fetched by job id. Refuses to change anything on
  /// an error envelope, exactly like the attached header status.
  Future<void> _refreshMediaJobStatus() async {
    if (_mediaJobId.isEmpty) return;
    try {
      final res = await WaTemplateApi.mediaJobStatus(_mediaJobId);
      if (!mounted || WaTemplateApi.isError(res, 'status')) return;
      setState(() => _mediaJobStatus = res);
    } catch (_) {}
  }

  /// Meta issues the sample handle asynchronously, so the job is polled until
  /// it is ready (or no longer pending) or the deadline passes — never forever.
  void _startMediaJobPoll() {
    _mediaJobPoll?.cancel();
    var waited = Duration.zero;
    _mediaJobPoll =
        Timer.periodic(WaTemplateEditorScreen.pollInterval, (t) async {
      waited += WaTemplateEditorScreen.pollInterval;
      await _refreshMediaJobStatus();
      final ready = _mediaJobStatus?['ready'] == true;
      final status = (_mediaJobStatus?['status'] ?? '').toString();
      if (ready ||
          status != 'pending' ||
          waited >= WaTemplateEditorScreen.pollTimeout) {
        t.cancel();
        // The handle has resolved — re-render the draft bubble with the picture.
        if (ready) await _refreshBubblePreview();
      }
    });
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

  static Future<WaPickedFile?> _pickFromDevice(
      List<String> extensions, String mime) async {
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

  /// One tap applies the review's suggested rewrite. wa_policy_apply changes the
  /// SAVED row and re-lints it server-side, then returns the new body — this
  /// method only writes that body into the field and re-runs the existing lint,
  /// preview and duplicate checks. It composes no wording of its own, and on any
  /// refusal it changes nothing and shows the backend's sentence.
  Future<void> _applyPolicy() async {
    if (_id.isEmpty) return;
    setState(() => _policyApplying = true);
    try {
      final res = await WaTemplateApi.policyApply(_id);
      if (!mounted) return;
      if (res['ok'] != true) {
        final msg = WaTemplateApi.errorMessage(res);
        if (msg.isNotEmpty) showToast(context, msg, isError: true);
        setState(() => _policyApplying = false);
        return;
      }
      // The rewrite is already applied and linted on the row; the field takes
      // the body it returned, verbatim. Setting the text fires the body's own
      // listeners, so the lint, preview and duplicate checks re-run on their
      // usual debounce.
      _body.text = (res['body'] ?? _body.text).toString();
      final msg = (res['message'] ?? '').toString();
      if (msg.isNotEmpty) showToast(context, msg);
      setState(() => _policyApplying = false);
      // The saved-row preview changed too, so the bubble is refreshed from it.
      await _refreshBubblePreview();
    } catch (_) {
      if (mounted) setState(() => _policyApplying = false);
    }
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

  /// Asks the backend to put value [key] into the body at the caret.
  ///
  /// Every part of this is wa_body_insert_token's answer: which number the
  /// value gets, whether it REUSES the number the value already has further up
  /// the message, the resulting body, and where the caret lands after it. This
  /// method computes none of it — no arithmetic, no scan of the text for {{n}},
  /// no map building.
  ///
  /// It also does not build the placeholder. Inserting a value's own
  /// `insert_as` was the bug: that string was named ({{customer_name}}), Meta
  /// accepts numbered variables only, and a named one is literal text — the
  /// pharmacy received the characters "{{customer_name}}".
  Future<void> _insertToken(String key) async {
    if (key.isEmpty) return;

    final text = _body.text;
    final sel = _body.selection;
    final cursor = (sel.isValid && sel.start >= 0 && sel.start <= text.length)
        ? sel.start
        : text.length;

    Map<String, dynamic> res;
    try {
      res = await WaTemplateApi.bodyInsertToken(
        body: text,
        cursor: cursor,
        key: key,
        tokenMap: _tokenKeys,
      );
    } catch (_) {
      return;
    }
    if (!mounted) return;

    // A refusal inserts NOTHING and says why in the backend's own sentence.
    // Half an insert — text placed but the map not updated — would be the
    // disagreement itself.
    if (WaTemplateApi.isError(res, 'body')) {
      final msg = WaTemplateApi.errorMessage(res);
      if (msg.isNotEmpty) showToast(context, msg, isError: true);
      return;
    }

    setState(() {
      _applyBody(res, caret: (res['cursor'] as num?)?.toInt());

      // The example Meta is shown, seeded from the backend's own sample of what
      // this variable will really contain. Anything the admin already typed for
      // this value wins.
      final preview = (res['preview_value'] ?? '').toString();
      final existing = _exampleByKey[key];
      if (existing == null) {
        _exampleByKey[key] = TextEditingController(text: preview);
      } else if (existing.text.isEmpty && preview.isNotEmpty) {
        existing.text = preview;
      }
    });

    // A brief hint of what the variable just inserted will actually say, in the
    // backend's words — printed verbatim, never composed here.
    final preview = (res['preview_value'] ?? '').toString();
    if (preview.isNotEmpty) showToast(context, preview);

    _schedule();
  }

  // ── renumbering ────────────────────────────────────────────────────────────
  //
  // Deleting {{1}} out of the middle of a sentence leaves {{2}},{{3}} behind,
  // and Meta rejects a template whose numbering has a hole. Closing that gap
  // means renaming the remaining variables AND rebuilding the map that says
  // what they mean — one operation, done in one place, by wa_body_renumber.

  void _scheduleRenumber() {
    // The body that a renumber or an insert just wrote is already correct;
    // re-checking it would only bounce between the two.
    if (_applyingBody) return;
    _renumberDebounce?.cancel();
    _renumberDebounce =
        Timer(WaTemplateEditorScreen.renumberDebounce, _renumber);
  }

  /// Puts the current body and map through wa_body_renumber and adopts the
  /// result when it says the numbering actually moved.
  Future<void> _renumber() async {
    _renumberDebounce?.cancel();
    final before = _body.text;
    Map<String, dynamic> res;
    try {
      res = await WaTemplateApi.bodyRenumber(before, _tokenKeys);
    } catch (_) {
      return;
    }
    if (!mounted || WaTemplateApi.isError(res, 'body')) return;
    if (res['changed'] != true) return;
    // The admin may have typed on since the round-trip started. Rewriting the
    // field would throw that away, so a stale answer is dropped and the next
    // keystroke's renumber will carry the correction instead.
    if (_body.text != before) return;

    // The caret is held where it was rather than jumping to the end — the
    // admin is mid-sentence. clamp() in _applyBody keeps it inside the string.
    final caret = _body.selection.isValid ? _body.selection.start : null;
    setState(() => _applyBody(res, caret: caret));
    _schedule();
  }

  // ── save / submit ──────────────────────────────────────────────────────────

  Future<void> _save({bool thenSubmit = false}) async {
    setState(() => _busy = true);
    try {
      // Immediately before the save, whatever the debounce has or has not had
      // time to do: a template whose numbering has a hole is rejected by Meta,
      // and saving one is how it would reach them.
      await _renumber();
      if (!mounted) return;
      _ensureExamples();
      // _id, not widget.template — after the first save of a NEW template the
      // widget's map still has no id, so reading it there would send null a
      // second time and create a duplicate. Save-and-continue makes that
      // second save an ordinary thing to do.
      final saveId =
          _id.isEmpty ? (widget.template?['id'])?.toString() : _id;
      final res = await WaTemplateApi.save(
        id: saveId,
        name: _name.text,
        language: _language,
        category: _category,
        components: _componentsNow(),
        tokenMap: _tokenKeys,
        // Claim the detached upload, when there is one. The backend writes the
        // HEADER from the job's handle and format.
        mediaJob: _mediaJobId.isEmpty ? null : _mediaJobId,
      );
      if (!mounted) return;

      if (res['ok'] != true) {
        final err = (res['error'] ?? '').toString();
        if (err == 'invalid') {
          // Backend's own issue list, verbatim, in the same red block the lint
          // uses.
          setState(() => _errors = (res['issues'] as List?) ?? const []);
        } else {
          // media_not_ready included: show the backend's sentence and leave the
          // job id in place so the user can simply save again once it settles.
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
      // The save has claimed the detached job — drop it so a second save does
      // not try to claim it again, and let the attached header path take over.
      if (_mediaJobId.isNotEmpty) {
        _mediaJobPoll?.cancel();
        _mediaJobId = '';
        _mediaJobStatus = null;
      }
      await _refreshGate();
      if (!mounted) return;
      // The bubble now has a row to render — re-ask so the sample and the
      // rendered body reflect what was just saved.
      await _refreshBubblePreview();
      if (!mounted) return;
      // The spec's can_upload/blocked_reason are answers about THIS id, so a
      // save that mints one makes the previous answer stale.
      await _loadMediaSpec();
      if (!mounted) return;
      // A save that claimed a detached upload now carries a handle on the row —
      // read it so a still-open editor shows the attached header and Re-upload.
      await _refreshHeaderStatus();
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
        WaTokenPicker(onInsert: _insertToken),

        if (_tokenKeys.isNotEmpty) ...[
          const SizedBox(height: 16),
          _SectionTitle(copy['examples_title']),
          const SizedBox(height: 8),
          for (var i = 0; i < _tokenKeys.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _Field(
                label: '{{${i + 1}}}  ·  ${_tokenKeys[i]}',
                controller: _exampleByKey[_tokenKeys[i]]!,
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
    final rules = [
      for (final r in (_mediaSpec?['rules'] as List?) ?? const [])
        if (r.toString().isNotEmpty) r.toString(),
    ];
    final isText = _headerFormat == 'TEXT';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                    // Every format stays selectable even when the sample
                    // cannot be uploaded yet. Choosing one is how the admin
                    // reaches the reason and the Save that clears it — greying
                    // the choice out is what hid the explanation before.
                    return _FormatChoice(
                      label: (m['label'] ?? '').toString(),
                      selected: value == _headerFormat,
                      enabled: true,
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
    // Before the template exists the banner reads the DETACHED upload job; once
    // saved it reads the row's header status. Both speak the same vocabulary
    // (status_label, tone, file_label, size_label, expires_label), so one block
    // serves both.
    final h = _id.isEmpty ? _mediaJobStatus : _headerStatus;
    // expired / blocker / has_sample are attached-only answers about a saved row.
    final expired = _headerStatus?['expired'] == true;
    final blocker = (_headerStatus?['blocker'] ?? '').toString();
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

    // can_upload is now true on an unsaved template too — the backend dropped
    // the save-first restriction, so the picker is offered saved or not.
    final canUpload = _mediaSpec?['can_upload'] == true;
    final uploadLabel = (_mediaSpec?['upload_label'] ?? '').toString();
    final blockedReason = (_mediaSpec?['blocked_reason'] ?? '').toString();
    // Re-upload is a SECOND way to do what the primary button already does, so
    // it appears only once there is something to replace.
    final hasSample = _headerStatus?['has_sample'] == true;
    final showReupload = hasSample || expired;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The uploaded sample itself, so the admin can SEE what will sit on top
        // of the message — the labels below still come from the status banner.
        ..._buildSampleView(),
        WaBanner(
          title: (h?['status_label'] ?? '').toString(),
          tone: bad ? 'bad' : h?['tone'],
          lines: lines,
          action: _uploading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ONE primary control, always present, always captioned by
                    // the backend. Disabled still says what it is for.
                    if (uploadLabel.isNotEmpty)
                      ElevatedButton(
                        onPressed: (!canUpload || format == null)
                            ? null
                            : () => _pickAndUpload(format),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1B7A43),
                          foregroundColor: Colors.white,
                          disabledBackgroundColor: const Color(0xFFD1D5DB),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(uploadLabel),
                      ),
                    // The reason sits directly beneath the control it explains.
                    // The backend no longer sends one for an unsaved template.
                    if (!canUpload && blockedReason.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      WaBanner(body: blockedReason, tone: 'warn'),
                    ],
                    if (showReupload) ...[
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: (!canUpload || format == null)
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
                    ],
                  ],
                ),
        ),
        if (_uploadMessage.isNotEmpty) ...[
          const SizedBox(height: 8),
          WaBanner(body: _uploadMessage, tone: 'muted'),
        ],
      ],
    );
  }

  /// The uploaded sample, viewable, inside the header block. The file location
  /// comes from the STATUS the block already reads — wa_media_job_status for a
  /// detached upload, wa_template_header_status for a saved row — both of which
  /// now carry is_image / storage_bucket / storage_path / file_label. Shown only
  /// once the sample is ready and there is a file: an image as a tappable
  /// thumbnail, a PDF or video as a tappable file tile.
  List<Widget> _buildSampleView() {
    final raw = _id.isEmpty ? _mediaJobStatus : _headerStatus;
    if (raw == null) return const [];
    final header = raw.cast<String, dynamic>();
    final ready = header['ready'] == true || header['has_sample'] == true;
    final hasFile = (header['media_url'] ?? '').toString().isNotEmpty ||
        (header['storage_path'] ?? '').toString().isNotEmpty;
    if (!ready || !hasFile) return const [];
    return [
      _SampleView(
        key: ValueKey('sample-${header['storage_path'] ?? header['media_url']}'),
        header: header,
      ),
      const SizedBox(height: 12),
    ];
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
        ..._buildBubble(),

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

  /// The message bubble. The saved-row preview (with its media header and
  /// body_rendered) wins when it is loaded; until there is a saved row, the
  /// live components preview keeps the bubble updating as the admin types.
  /// rendered_note and char_count sit under the bubble — both the backend's.
  List<Widget> _buildBubble() {
    final source = _tplPreview ?? _preview;
    if (source == null) {
      return const [
        WaSkeleton(height: 16, width: 200),
        SizedBox(height: 8),
        WaSkeleton(height: 16),
        SizedBox(height: 8),
        WaSkeleton(height: 16, width: 160),
      ];
    }
    final note = (_tplPreview?['rendered_note'] ?? '').toString();
    final charCount = (_tplPreview?['char_count'] ?? '').toString();
    final buttons = [
      for (final b in (source['buttons'] as List?) ?? const [])
        if (b is Map) b.cast<String, dynamic>(),
    ];
    return [
      // A plain chat-style backdrop, so the message reads like a phone screen
      // rather than a form field.
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: const BoxDecoration(
          color: Color(0xFFECE5DD),
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        child: LayoutBuilder(
          builder: (context, box) {
            // WhatsApp holds an incoming bubble to ~85% of the width, left
            // aligned; the button tiles below it share that width.
            final maxW = box.maxWidth * 0.85;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: maxW),
                  child: _MediaBubble(preview: source),
                ),
                // Quick-reply and link buttons are NOT part of the bubble — in
                // WhatsApp they arrive as their own full-width tiles beneath it.
                if (buttons.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxW),
                    child: _BubbleButtons(buttons: buttons),
                  ),
                ],
              ],
            );
          },
        ),
      ),
      if (note.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          note,
          style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
        ),
      ],
      if (charCount.isNotEmpty && charCount != '0') ...[
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            charCount,
            style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)),
          ),
        ),
      ],
    ];
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
        // One-tap apply. The caption is the review's own apply_all_label when it
        // sent one; the single Dart literal "Use this wording" is the fallback.
        // Applying goes through wa_policy_apply — it changes the saved row and
        // re-lints server-side — never a local edit that could disagree with it.
        if (suggested.isNotEmpty) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed:
                  (_id.isEmpty || _policyApplying) ? null : _applyPolicy,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF1B7A43),
                side: const BorderSide(color: Color(0xFF1B7A43)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              child: Text(
                (verdict?['apply_all_label'] ?? '').toString().isNotEmpty
                    ? (verdict!['apply_all_label']).toString()
                    : 'Use this wording',
              ),
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

// ── message preview: media header + bubble ───────────────────────────────────
//
// The sample file lives in a PRIVATE bucket, so a public URL 403s. The URL is
// signed here from the bucket and path the backend named — never guessed — and
// re-signed on every open (the widgets are rebuilt with a fresh key when the
// payload changes), never cached, because signed URLs expire. When media_url is
// set the file is public (Meta approved it) and used directly.

/// The viewable link for the sample: the public CDN link when Meta has issued
/// one, otherwise a fresh signed link for the private file. Null when signing
/// fails or there is nothing to sign — the caller then shows the file label
/// instead of a broken image.
Future<String?> _resolveSampleUrl(Map<String, dynamic> header) async {
  final mediaUrl = (header['media_url'] ?? '').toString();
  if (mediaUrl.isNotEmpty) return mediaUrl;
  final bucket = (header['storage_bucket'] ?? '').toString();
  final path = (header['storage_path'] ?? '').toString();
  if (bucket.isNotEmpty && path.isNotEmpty) {
    return WaTemplateApi.signedUrl(bucket, path);
  }
  return null;
}

/// The icon for the sample's kind. The backend's is_pdf / is_video booleans
/// decide it — nothing here parses a file name or a mime type.
IconData _sampleIcon(Map<String, dynamic> header) {
  if (header['is_pdf'] == true) return Icons.picture_as_pdf_outlined;
  if (header['is_video'] == true) return Icons.videocam_outlined;
  return Icons.image_outlined;
}

/// Opens the sample image full size — the same URL the thumbnail resolved.
void _openFullSizeImage(BuildContext context, String url) {
  showDialog<void>(
    context: context,
    builder: (_) => Dialog(
      key: const Key('wa_sample_fullscreen'),
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      child: InteractiveViewer(
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const SizedBox(
            height: 200,
            child: Icon(Icons.broken_image_outlined,
                size: 40, color: Color(0xFF9CA3AF)),
          ),
        ),
      ),
    ),
  );
}

/// The WhatsApp message bubble: the media header flush to the top edges, then
/// body_rendered, then the footer in smaller grey text, then the delivery time
/// in the bottom-right, with the small tail on the top-left. body_rendered
/// already has the example values substituted; body_raw ({{1}}) is deliberately
/// never read here. Buttons are NOT drawn inside — WhatsApp renders those as
/// their own tiles below the bubble (see _BubbleButtons).
class _MediaBubble extends StatelessWidget {
  final Map<String, dynamic> preview;
  const _MediaBubble({required this.preview});

  @override
  Widget build(BuildContext context) {
    final rawHeader = preview['header'];
    final header = rawHeader is Map ? rawHeader.cast<String, dynamic>() : null;
    final format = (header?['format'] ?? '').toString().toUpperCase();
    final textHeader =
        format == 'TEXT' ? (header?['text'] ?? '').toString() : '';
    final body = (preview['body_rendered'] ?? preview['body'] ?? '').toString();
    final footer = (preview['footer'] ?? '').toString();
    final showMedia = header != null && format.isNotEmpty && format != 'TEXT';
    // The device clock, stamped the way WhatsApp stamps a message. Display only
    // — chrome that mimics the app, never part of the template, which is why it
    // is the one value here not read from the backend.
    final time = TimeOfDay.now().format(context);

    const bubbleColor = Color(0xFFE7F8D8);
    final bubble = Container(
      key: const Key('wa_preview_bubble'),
      decoration: BoxDecoration(
        color: bubbleColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showMedia) _BubbleHeaderMedia(header: header),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
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
                Text(
                  body,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w400,
                      height: 1.35,
                      color: Color(0xFF111827)),
                ),
                // The footer sits directly under the body, smaller and grey.
                if (footer.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    footer,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                        color: Color(0xFF6B7280)),
                  ),
                ],
                const SizedBox(height: 4),
                // The timestamp, bottom-right, the way a delivered message reads.
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    time,
                    style: const TextStyle(
                        fontSize: 11, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // The little tail on the top-left corner an incoming WhatsApp bubble has.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        CustomPaint(
          size: const Size(7, 14),
          painter: _BubbleTailPainter(bubbleColor),
        ),
        Flexible(child: bubble),
      ],
    );
  }
}

/// The button tiles WhatsApp shows BELOW the bubble: one full-width tile per
/// row, never side by side, each its text centred with the backend's kind_label
/// beneath, and a hairline divider between them. Every string is the backend's.
class _BubbleButtons extends StatelessWidget {
  final List<Map<String, dynamic>> buttons;
  const _BubbleButtons({required this.buttons});

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('wa_preview_buttons'),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1)),
        ],
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

/// The small triangular tail at the bubble's top-left, in the bubble's colour.
class _BubbleTailPainter extends CustomPainter {
  final Color color;
  const _BubbleTailPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(size.width, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BubbleTailPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The media header INSIDE the bubble. Fills the bubble width with rounded top
/// corners for an image; a file tile for a PDF or video; a neutral placeholder
/// box with the warn line when no sample has been uploaded yet.
class _BubbleHeaderMedia extends StatefulWidget {
  final Map<String, dynamic> header;
  const _BubbleHeaderMedia({required this.header});

  @override
  State<_BubbleHeaderMedia> createState() => _BubbleHeaderMediaState();
}

class _BubbleHeaderMediaState extends State<_BubbleHeaderMedia> {
  late final Future<String?> _url;

  @override
  void initState() {
    super.initState();
    _url = _resolveSampleUrl(widget.header);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.header;
    final missing = (h['missing_label'] ?? '').toString();
    if (missing.isNotEmpty) {
      final placeholder = (h['placeholder_label'] ?? '').toString();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 120,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFFF3F4F6),
              borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(12), topRight: Radius.circular(12)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_sampleIcon(h), size: 28, color: const Color(0xFF9CA3AF)),
                if (placeholder.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      placeholder,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 12, color: Color(0xFF6B7280)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(
              missing,
              style: TextStyle(fontSize: 12, color: WaTone.of('warn').fg),
            ),
          ),
        ],
      );
    }

    if (h['is_image'] == true) {
      return FutureBuilder<String?>(
        future: _url,
        builder: (context, snap) {
          final url = (snap.data ?? '').toString();
          if (url.isEmpty) {
            return _SampleFileTile(header: h, roundedTop: true);
          }
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openFullSizeImage(context, url),
            child: ClipRRect(
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12), topRight: Radius.circular(12)),
              child: Image.network(
                url,
                width: double.infinity,
                height: 180,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    _SampleFileTile(header: h, roundedTop: true),
              ),
            ),
          );
        },
      );
    }

    // PDF / video — a file tile carrying the backend's file_label.
    return _SampleFileTile(header: h, roundedTop: true);
  }
}

/// A file tile — icon, file_label and size_label — for a PDF or video sample,
/// or an image whose link could not be signed. Tappable when a URL is given.
class _SampleFileTile extends StatelessWidget {
  final Map<String, dynamic> header;
  final VoidCallback? onTap;
  final bool roundedTop;
  const _SampleFileTile({
    required this.header,
    this.onTap,
    this.roundedTop = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = (header['file_label'] ?? '').toString();
    final size = (header['size_label'] ?? '').toString();
    final radius = roundedTop
        ? const BorderRadius.only(
            topLeft: Radius.circular(12), topRight: Radius.circular(12))
        : BorderRadius.circular(10);
    final tile = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: radius,
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        children: [
          Icon(_sampleIcon(header), size: 22, color: const Color(0xFF1B7A43)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (label.isNotEmpty)
                  Text(
                    label,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF111827)),
                  ),
                if (size.isNotEmpty)
                  Text(
                    size,
                    style: const TextStyle(
                        fontSize: 12, color: Color(0xFF6B7280)),
                  ),
              ],
            ),
          ),
          if (onTap != null)
            const Icon(Icons.open_in_new, size: 16, color: Color(0xFF6B7280)),
        ],
      ),
    );
    if (onTap == null) return tile;
    return GestureDetector(
        behavior: HitTestBehavior.opaque, onTap: onTap, child: tile);
  }
}

/// The uploaded sample in the media-header SECTION: a tappable thumbnail for an
/// image, a tappable file tile for a PDF or video. Expired samples add the
/// backend's expires_label in the bad tone.
class _SampleView extends StatefulWidget {
  final Map<String, dynamic> header;
  const _SampleView({super.key, required this.header});

  @override
  State<_SampleView> createState() => _SampleViewState();
}

class _SampleViewState extends State<_SampleView> {
  late final Future<String?> _url;

  @override
  void initState() {
    super.initState();
    _url = _resolveSampleUrl(widget.header);
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.header;
    final expired = h['expired'] == true;
    final expiresLabel = (h['expires_label'] ?? '').toString();

    Widget viewer;
    if (h['is_image'] == true) {
      viewer = FutureBuilder<String?>(
        future: _url,
        builder: (context, snap) {
          final url = (snap.data ?? '').toString();
          if (url.isEmpty) return _SampleFileTile(header: h);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => _openFullSizeImage(context, url),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                url,
                width: 140,
                height: 140,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => _SampleFileTile(header: h),
              ),
            ),
          );
        },
      );
    } else {
      viewer = FutureBuilder<String?>(
        future: _url,
        builder: (context, snap) {
          final url = (snap.data ?? '').toString();
          return _SampleFileTile(
            header: h,
            onTap: url.isEmpty ? null : () => _open(url),
          );
        },
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Align(alignment: Alignment.centerLeft, child: viewer),
        if (expired && expiresLabel.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            expiresLabel,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: WaTone.of('bad').fg),
          ),
        ],
      ],
    );
  }
}
