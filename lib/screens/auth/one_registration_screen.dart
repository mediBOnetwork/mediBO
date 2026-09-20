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

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../services/registration_bar.dart';
import '../../utils/render_log.dart';
import '../../widgets/customer_registration_form.dart';
import '../../widgets/registration_documents_section.dart';
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
      return _page(RegistrationDoneView(
          done: _map(_wiz['done']), onBrowse: _browse));
    }
    if (_wizardOn) return _page(_wizardStep());

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

  /// Phone first: full width with a 16 px gutter, capped on a wide screen.
  Widget _page(Widget child) => LayoutBuilder(builder: (context, box) {
        final pad = box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16;
        return SingleChildScrollView(
          controller: _scroll,
          padding: EdgeInsets.fromLTRB(pad, Ds.space.x16, pad, Ds.space.x32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: child,
            ),
          ),
        );
      });

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
    final chips = <String, List<String>>{
      for (final e in _map(_wiz['chips']).entries)
        if (e.value is List)
          e.key: (e.value as List).map((o) => o.toString()).toList(),
    };
    final continueLabel = _saving
        ? (last ? _s(_wiz, 'submitting_label') : _s(_wiz, 'saving_label'))
        : (last ? _s(_wiz, 'submit_label') : _s(_wiz, 'continue_label'));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RegistrationProgressBar(steps: steps, current: _step, onJump: _goTo),
        if (_step == 0 && imported['is'] == true && _s(imported, 'note').isNotEmpty)
          _note(_s(imported, 'note'), Ds.c.infoSoft),
        if (_step == 0 && _p['has_draft'] == true && _s(_p, 'draft_note').isNotEmpty)
          _note(_s(_p, 'draft_note'), Ds.c.bg),
        if (step['docs'] == true && pending['show'] == true && _s(pending, 'line').isNotEmpty)
          _note(_s(pending, 'line'), Ds.c.warningSoft),
        SizedBox(height: Ds.space.x16),
        Container(
          padding: EdgeInsets.all(Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            boxShadow: Ds.elevation.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_s(step, 'step_of'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x4),
              Text(_s(step, 'title'), style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x16),
              if (ctrl != null)
                CustomerRegistrationForm(
                  controller: ctrl,
                  onlyFields: fields,
                  chips: chips,
                ),
              if (step['docs'] == true)
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
            ],
          ),
        ),
        if (_message.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Text(_message, style: Ds.t.caption.copyWith(color: Ds.c.danger)),
        ],
        SizedBox(height: Ds.space.x24),
        Row(children: [
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
        ]),
      ],
    );
  }

  Widget _note(String text, Color bg) => Container(
        width: double.infinity,
        margin: EdgeInsets.only(top: Ds.space.x12),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rCard),
        child: Text(text, style: Ds.t.caption),
      );
}
