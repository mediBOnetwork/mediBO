// CMD #2129 — ONE Add customer flow for every staff entry point.
//
// Customers tab (manual, and the photo card that replaced "Import by file"),
// Today's visit, every plan (current and past), the lead list and a lead that
// came from a file import all open THIS screen. It is the Registration v3
// flow (#2135) — the same General · Location · Documents steps the customer
// fills — plus a staff-only Terms step and a Saved screen.
//
// It composes nothing. `addcust_open()` sends the step list, every caption,
// the terms options and the prefill (from the lead, the photo, or the
// customer being resumed); `addcust_number_check()` judges the WhatsApp
// number live; `addcust_save()` writes through the ONE door
// (admin_import_customer / lead_import_customer); `addcust_finish()` applies
// the terms, sends the invite and returns the Saved screen verbatim.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';
import '../../widgets/customer_registration_form.dart';
import '../../widgets/doc_viewer_screen.dart';
import '../../widgets/registration_licences_section.dart';
import '../../widgets/registration_location_step.dart';
import '../../widgets/registration_wizard.dart';
import '../customer_documents_screen.dart' show CustomerDocumentsTransport;
import 'admin_customer_page.dart' show openAdminCustomerPage;

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
List<Map<String, dynamic>> _l(dynamic v) =>
    ((v as List?) ?? const []).map(_m).toList();
String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

class AddCustomerFlow extends StatefulWidget {
  const AddCustomerFlow({
    super.key,
    this.leadId,
    this.customerId,
    this.prefill,
  });

  /// The lead (visit, plan, lead list, file-imported lead) this opened from.
  /// The backend pre-fills from it and the save links back to it.
  final int? leadId;

  /// A customer whose registration is unfinished — "Resume theirs".
  final String? customerId;

  /// Values already in hand (a photo read, a caller's own prefill). The
  /// backend merges them over the lead's.
  final Map<String, dynamic>? prefill;

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  /// Test seam for the photo read (the customer-import edge function).
  @visibleForTesting
  static Future<Map<String, dynamic>> Function(List<String> images)?
      extractTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  static Future<Map<String, dynamic>> extract(List<String> images) async {
    final t = extractTransport;
    if (t != null) return t(images);
    final res = await Supabase.instance.client.functions.invoke(
      'customer-import',
      body: {'mode': 'extract', 'images': images, 'mime_type': 'image/jpeg'},
    );
    return _m(res.data);
  }

  /// The one door. Returns true when a customer was saved.
  static Future<bool?> open(
    BuildContext context, {
    int? leadId,
    String? customerId,
    Map<String, dynamic>? prefill,
  }) {
    RenderLog.write('c2129_addcust_open',
        leadId != null ? 'lead' : (customerId != null ? 'resume' : 'manual'));
    return Navigator.of(context).push<bool>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => AddCustomerFlow(
          leadId: leadId, customerId: customerId, prefill: prefill),
    ));
  }

  @override
  State<AddCustomerFlow> createState() => _AddCustomerFlowState();
}

class _AddCustomerFlowState extends State<AddCustomerFlow> {
  final _scroll = ScrollController();

  Map<String, dynamic> _p = const {};
  CustomerFormController? _form;
  bool _loading = true;
  bool _failed = false;
  bool _saving = false;
  bool _reading = false;
  String _message = '';
  int _step = 0;
  // CMD #2141 (QA) — steps the backend saved with Continue this session; the
  // bar paints only these and the backend's own `complete` green.
  final Set<String> _okSteps = {};

  int? _leadId;
  String? _customerId;
  Map<String, dynamic>? _prefill;

  // Live number verdict.
  Map<String, dynamic> _num = const {};
  bool _numChecking = false;
  String _numFor = '';
  Timer? _numTimer;
  bool _fresh = false;

  // Fields the photo filled — they carry the backend's "✓ Read from photo".
  final Set<String> _readKeys = {};

  // Documents.
  Map<String, dynamic> _lic = const {};
  final Set<String> _skips = {};
  final Set<String> _docReading = {};
  final Map<String, String> _thumbUrls = {};
  String _busyDoc = '';

  // Terms, as chosen on screen (seeded from the backend's defaults).
  Map<String, dynamic> _terms = const {};
  String _payment = '';
  String _delivery = '';
  int? _zone;
  bool _invite = true;

  Map<String, dynamic>? _saved;

  /// CMD #2171 — the backend's own word for "saved, carry on", printed where
  /// the staff are rather than on a screen they did not ask for.
  String _savedNote = '';

  /// CMD #2151 — true while a finger is on the Location map.
  final ValueNotifier<bool> _mapTouch = ValueNotifier<bool>(false);
  void _onMapTouch() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _mapTouch.addListener(_onMapTouch);
    _leadId = widget.leadId;
    _customerId = widget.customerId;
    _prefill = widget.prefill;
    _load();
  }

  @override
  void dispose() {
    _mapTouch.removeListener(_onMapTouch);
    _mapTouch.dispose();
    _numTimer?.cancel();
    _scroll.dispose();
    _form?.controllerFor('whatsapp_no').removeListener(_onNumber);
    _form?.dispose();
    super.dispose();
  }

  void _onFormChange() {
    if (mounted) setState(() {});
  }

  /// CMD #2141 — the SAME v4 General step the customer's own registration
  /// draws (Mr/Ms, required contacts, live checks).
  bool get _v4 => _s(_wiz, 'layout') == 'v4';

  Map<String, dynamic> get _wiz => _m(_p['wizard']);
  List<Map<String, dynamic>> get _steps => wizardSteps(_wiz);
  Map<String, dynamic> get _cur =>
      _steps.isEmpty ? const {} : _steps[_step.clamp(0, _steps.length - 1)];
  String get _stepKey => _s(_cur, 'key');
  bool get _isTerms => _cur['terms'] == true;
  bool get _isDocs => _cur['docs'] == true;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final p = _m(await AddCustomerFlow.rpc('addcust_open', {
        'p_lead_id': _leadId,
        'p_customer_id': _customerId,
        'p_prefill': _prefill,
      }));
      if (!mounted) return;
      if (p['ok'] != true) {
        setState(() {
          _p = p;
          _loading = false;
          _failed = true;
        });
        return;
      }
      _form?.controllerFor('whatsapp_no').removeListener(_onNumber);
      _form?.removeListener(_onFormChange);
      _form?.dispose();
      final ctrl = CustomerFormController(formContext: 'signup');
      // CMD #2141 — a live-check verdict repaints Continue.
      ctrl.addListener(_onFormChange);
      final schema = _m(p['schema']);
      if (schema.isNotEmpty) ctrl.seed(schema);
      ctrl.applyMap(_m(p['prefill']));
      ctrl.controllerFor('whatsapp_no').addListener(_onNumber);
      setState(() {
        _p = p;
        _form = ctrl;
        _loading = false;
        _step = 0;
        _saved = null;
        _num = const {};
        _numFor = '';
        _fresh = false;
        _readKeys.clear();
        _okSteps.clear();
        _skips.clear();
        _lic = const {};
        _seedTerms(_m(p['terms']));
      });
      RenderLog.write('c2129_addcust', 'steps=${_steps.length};step=0');
      _onNumber();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  void _seedTerms(Map<String, dynamic> t) {
    if (t.isEmpty) return;
    _terms = t;
    _payment = _s(_m(t['payment']), 'value');
    _delivery = _s(_m(t['delivery']), 'value');
    final z = _m(t['zone'])['value'];
    _zone = z is num ? z.toInt() : int.tryParse('${z ?? ''}');
    _invite = _m(t['invite'])['on'] != false;
  }

  // ── WhatsApp number, judged live ─────────────────────────────────────────

  void _onNumber() {
    final key = _s(_m(_p['number']), 'key');
    final v = (_form?.controllerFor(key.isEmpty ? 'whatsapp_no' : key).text ?? '')
        .trim();
    if (v == _numFor) return;
    _numFor = v;
    _numTimer?.cancel();
    if (v.isEmpty) {
      setState(() {
        _num = const {};
        _numChecking = false;
      });
      return;
    }
    setState(() {
      _numChecking = true;
      _fresh = false;
    });
    final ms = (_m(_p['number'])['debounce_ms'] as num?)?.toInt() ?? 500;
    _numTimer = Timer(Duration(milliseconds: ms), () => _checkNumber(v));
  }

  Future<void> _checkNumber(String v) async {
    try {
      final res = _m(await AddCustomerFlow.rpc('addcust_number_check',
          {'p_number': v, 'p_customer_id': _customerId}));
      if (!mounted || v != _numFor) return;
      // CMD #2171 (Om, APK 1.3.33) — the check judged the number AFTER
      // reducing it to its last ten digits, and it sends that back as
      // `value`. The box shows what was judged, so a picked "+448357881873"
      // reads 8357881873. Claiming _numFor first stops the new text starting
      // a second check of the same number.
      final cleaned = _s(res, 'value');
      if (cleaned.isNotEmpty && cleaned != v) {
        _numFor = cleaned;
        final key = _s(_m(_p['number']), 'key');
        _form?.controllerFor(key.isEmpty ? 'whatsapp_no' : key).text = cleaned;
      }
      setState(() {
        _num = res;
        _numChecking = false;
      });
      RenderLog.write('c2129_num', _s(res, 'state'));
    } catch (_) {
      if (!mounted) return;
      setState(() => _numChecking = false);
    }
  }

  Future<void> _numAction(Map<String, dynamic> a) async {
    final id = _s(a, 'customer_id');
    switch (_s(a, 'key')) {
      case 'open':
        if (id.isNotEmpty) await openAdminCustomerPage(context, id);
      case 'use_another':
        _form?.controllerFor('whatsapp_no').clear();
      case 'resume':
        _customerId = id;
        _prefill = null;
        await _load();
      case 'restore':
        await AddCustomerFlow.rpc('admin_customer_action',
            {'p_customer_id': id, 'p_action': 'restore'});
        if (!mounted) return;
        await openAdminCustomerPage(context, id);
        if (mounted) Navigator.of(context).maybePop(true);
      case 'fresh':
        setState(() => _fresh = true);
    }
  }

  // ── Photo read ───────────────────────────────────────────────────────────

  Future<void> _readPhoto() async {
    final ctrl = _form;
    if (ctrl == null || _reading) return;
    final shot = await CustomerDocumentsTransport.choose(true);
    if (shot == null || !mounted) return;
    setState(() {
      _reading = true;
      _message = '';
    });
    try {
      final m = await AddCustomerFlow.extract([base64Encode(shot.bytes)]);
      if (!mounted) return;
      if (m['error'] != null) throw StateError('${m['error']}');
      final known = ctrl.fields.map((f) => f['key'].toString()).toSet();
      final got = <String, dynamic>{
        for (final e in m.entries)
          if (known.contains(e.key) &&
              e.value != null &&
              e.value is! Map &&
              e.value is! List &&
              '${e.value}'.trim().isNotEmpty)
            e.key: e.value,
      };
      ctrl.applyMap(got);
      setState(() {
        _reading = false;
        _readKeys.addAll(got.keys);
      });
      RenderLog.write('c2129_photo_read', 'fields=${got.length}');
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _message = _s(_m(_p['photo']), 'failed_label');
      });
    }
  }

  // ── Steps ────────────────────────────────────────────────────────────────

  Map<String, dynamic> _values() => {
        ...?_form?.payload(),
        if (_fresh) '_fresh': true,
      };

  Future<Map<String, dynamic>?> _saveStep(String step) async {
    final res = _m(await AddCustomerFlow.rpc('addcust_save', {
      'p_values': _values(),
      'p_lead_id': _leadId,
      'p_customer_id': _customerId,
      'p_step': step,
    }));
    if (!mounted) return null;
    if (res['ok'] != true) {
      final n = _m(res['number']);
      setState(() {
        _message = _s(res, 'message');
        if (n.isNotEmpty) _num = n;
      });
      return null;
    }
    final cid = _s(res, 'customer_id');
    if (cid.isNotEmpty) _customerId = cid;
    final lic = _m(res['licences']);
    if (lic.isNotEmpty) _lic = lic;
    final t = _m(res['terms']);
    if (t.isNotEmpty) {
      final z = _m(t['zone'])['value'];
      _terms = t;
      if (_zone == null && z != null) {
        _zone = z is num ? z.toInt() : int.tryParse('$z');
      }
    }
    unawaited(_signThumbs());
    return res;
  }

  Future<void> _finish() async {
    final cid = _customerId;
    if (cid == null) return;
    final res = _m(await AddCustomerFlow.rpc('addcust_finish', {
      'p_customer_id': cid,
      'p_terms': {
        'payment_term': _payment,
        'delivery': _delivery,
        'zone_id': _zone,
        'invite': _invite,
      },
      'p_skips': _skips.toList(),
    }));
    if (!mounted) return;
    if (res['ok'] != true) {
      setState(() => _message = _s(res, 'message'));
      return;
    }
    setState(() => _saved = res);
    RenderLog.write('c2129_saved', 'checklist=${_l(res['checklist']).length}');
  }

  Future<void> _run(Future<void> Function() body) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _message = '';
      _savedNote = '';
    });
    try {
      await body();
    } catch (_) {
      if (mounted) setState(() => _message = _s(_p, 'error_label'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// CMD #2171 — the ONE number verdict decides whether this step may go on.
  /// `allow` is the backend's word (addcust_number_check); a blocked number
  /// prints its own amber line with the backend's buttons right above, so the
  /// disabled Continue is never unexplained.
  bool get _numBlocks =>
      _step == 0 &&
      !_fresh &&
      _num.isNotEmpty &&
      _num['allow'] == false;

  Future<void> _continue() => _run(() async {
        if (_isTerms) {
          await _finish();
          return;
        }
        if (_numBlocks) return;
        if (_v4 && !_isDocs && _m(_cur['map']).isEmpty) {
          final ctrl = _form;
          final fields = ((_cur['fields'] as List?) ?? const [])
              .map((e) => e.toString())
              .toList();
          if (ctrl != null && ctrl.missingAmong(fields).isNotEmpty) {
            ctrl.revealRequired();
            return;
          }
          if (ctrl?.checksBlock ?? false) return;
        }
        if (!_isDocs) {
          final res = await _saveStep(_stepKey);
          if (res == null) return;
          _okSteps.add(_stepKey);
        }
        if (!mounted) return;
        setState(() => _step = (_step + 1).clamp(0, _steps.length - 1));
        _toTop();
        RenderLog.write('c2129_addcust', 'steps=${_steps.length};step=$_step');
      });

  /// Save — name, WhatsApp and pin are enough; the rest can come later.
  ///
  /// CMD #2171 (Om, APK 1.3.33) — Save used to run addcust_finish, so tapping
  /// it on General threw the staff straight to the "Customer added" screen
  /// with the Location, Documents and Invite steps never seen. Save saves and
  /// stays; the backend answers with its own line and the step set is only
  /// finished by the last step.
  Future<void> _saveNow() => _run(() async {
        final res = await _saveStep('save');
        if (res == null || !mounted) return;
        setState(() => _savedNote = _s(_m(res['saved']), 'label'));
      });

  void _back() {
    if (_step == 0) return;
    setState(() {
      _step -= 1;
      _message = '';
    });
    _toTop();
  }

  void _toTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(0, duration: Ds.motion.standard, curve: Ds.motion.curve);
  }

  // ── Documents ────────────────────────────────────────────────────────────

  List<Map<String, dynamic>> get _licRows => [
        for (final g in _l(_lic['groups'])) ..._l(g['rows']),
      ];

  Future<void> _refreshLic() async {
    final cid = _customerId;
    if (cid == null) return;
    try {
      final b = _m(await AddCustomerFlow.rpc(
          'addcust_licences', {'p_customer_id': cid}));
      if (!mounted || b['ok'] != true) return;
      setState(() => _lic = b);
      unawaited(_signThumbs());
    } catch (_) {}
  }

  Future<void> _signThumbs() async {
    for (final row in _licRows) {
      final key = _s(row, 'key');
      final thumb = _m(row['thumb']);
      final path = _s(thumb, 'path');
      if (path.isEmpty || _thumbUrls.containsKey(key)) continue;
      try {
        final url = await CustomerDocumentsTransport.sign(
            _s(thumb, 'bucket').isEmpty ? 'kyc-docs' : _s(thumb, 'bucket'),
            path);
        if (!mounted) return;
        if (url.isNotEmpty) setState(() => _thumbUrls[key] = url);
      } catch (_) {}
    }
  }

  Future<void> _upload(Map<String, dynamic> row) async {
    final cid = _customerId;
    final key = _s(row, 'key');
    if (cid == null || key.isEmpty) return;
    final f = await CustomerDocumentsTransport.choose(row['camera_only'] == true);
    if (f == null || !mounted) return;
    setState(() {
      _busyDoc = key;
      _docReading.add(key);
      _skips.remove(key);
      _message = '';
    });
    try {
      final mime = switch (f.ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };
      final p = _m(await CustomerDocumentsTransport.call(
          'customer_doc_upload_path',
          {'p_customer_id': cid, 'p_kind': key, 'p_ext': f.ext}));
      if (p['ok'] != true) throw StateError('path');
      final stored = await CustomerDocumentsTransport.put(
          _s(p, 'bucket'), _s(p, 'path'), f.bytes, mime);
      await CustomerDocumentsTransport.call('customer_doc_upload_register', {
        'p_customer_id': cid,
        'p_kind': key,
        'p_path': stored,
        'p_file_name': f.name,
        'p_mime': mime,
        'p_bytes': f.bytes.length,
        'p_pages': 1,
      });
      if (row['reads'] == true) {
        Map<String, dynamic> fields = const {};
        try {
          // CMD #2141 — the OCR fix: read the stored paper by its path, never
          // re-send the photo as a multi-megabyte JSON body.
          final res = await Supabase.instance.client.functions.invoke(
            'licence-ocr',
            body: {
              'bucket': _s(p, 'bucket'),
              'path': stored,
              'mime_type': mime,
              'kind': key,
            },
          );
          fields = _m(_m(res.data)['fields']);
        } catch (_) {
          // An unread photo is still a saved photo.
        }
        await AddCustomerFlow.rpc('custreg_doc_read_save',
            {'p_kind': key, 'p_ocr': fields, 'p_owner': cid});
      }
      _thumbUrls.remove(key);
      await _refreshLic();
    } catch (_) {
      if (mounted) {
        setState(() => _message = _s(_lic, 'upload_failed_label'));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busyDoc = '';
          _docReading.remove(key);
        });
      }
    }
  }

  Future<void> _view(Map<String, dynamic> row) async {
    final key = _s(row, 'key');
    final choice = await showDocViewer(context,
        row: row, url: _thumbUrls[key] ?? '');
    if (!mounted || choice == null) return;
    if (choice == DocViewerChoice.retake) await _upload(row);
  }

  /// CMD #2141 (Om, 22 Sep) — the SAME edit sheet as registration: the photo
  /// (tap to zoom), the row's own fields with "✓ read" on what came off the
  /// photo, Retake and Save → custreg_doc_read_edit for this customer.
  Future<void> _editDoc(Map<String, dynamic> row) async {
    final cid = _customerId;
    final key = _s(row, 'key');
    final edit = _m(row['edit']);
    if (cid == null || edit.isEmpty) return _view(row);
    var retake = false;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => DocReadEditSheet(
        edit: edit,
        thumb: docEditThumb(row, _thumbUrls[key] ?? '', null),
        onViewPhoto: () => _view(row),
        onRetake: () {
          retake = true;
          Navigator.of(ctx).pop(false);
        },
        onConfirm: (values) async {
          try {
            final res = _m(await AddCustomerFlow.rpc('custreg_doc_read_edit',
                {'p_kind': key, 'p_values': values, 'p_owner': cid}));
            if (res['ok'] != true) return _s(res, 'message');
            await _refreshLic();
            RenderLog.write('c2141_addcust_doc_edit', key);
            return null;
          } catch (_) {
            return _s(_p, 'error_label');
          }
        },
      ),
    );
    if (retake && mounted) await _upload(row);
  }

  void _toggleSkip(Map<String, dynamic> row) {
    final key = _s(row, 'key');
    setState(() => _skips.contains(key) ? _skips.remove(key) : _skips.add(key));
  }

  Future<void> _scanFirst() async {
    final row = _licRows.firstWhere(
        (r) => _s(r, 'state') != 'uploaded' && r['reads'] == true,
        orElse: () => const {});
    if (row.isNotEmpty) await _upload(row);
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        backgroundColor: Ds.c.surface,
        automaticallyImplyLeading: false,
        title: Text(_s(_p, 'title'), style: Ds.t.title),
        actions: [
          Semantics(
            identifier: 'addcust_close',
            button: true,
            child: IconButton(
              tooltip: _s(_p, 'close_label'),
              icon: const Icon(Icons.close),
              onPressed: () =>
                  Navigator.of(context).maybePop(saved != null ? true : null),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? _skeleton()
            : _failed
                ? _error()
                : saved != null
                    ? _savedView(saved)
                    : _stepView(),
      ),
    );
  }

  Widget _skeleton() => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < 5; i++) ...[
              Container(
                height: i == 0 ? Ds.space.x48 + Ds.space.x24 : Ds.space.x48,
                decoration: BoxDecoration(
                  color: Ds.c.divider,
                  borderRadius: Ds.r.rCard,
                ),
              ),
              SizedBox(height: Ds.space.x16),
            ],
          ],
        ),
      );

  Widget _error() => Center(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (_s(_p, 'message').isNotEmpty)
              Text(_s(_p, 'message'),
                  style: Ds.t.bodySecondary, textAlign: TextAlign.center),
            SizedBox(height: Ds.space.x16),
            Semantics(
              identifier: 'addcust_retry',
              button: true,
              child: SizedBox(
                height: Ds.touch.minTarget,
                child: OutlinedButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: Text(_s(_p, 'retry_label')),
                ),
              ),
            ),
          ]),
        ),
      );

  Widget _capped(Widget child) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: child,
        ),
      );

  Widget _stepView() {
    final steps = _steps;
    if (steps.isEmpty) return _error();
    final ctrl = _form;
    final step = _cur;
    final last = _step >= steps.length - 1;
    final fields = ((step['fields'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();
    final mapBlock = _m(step['map']);
    final chips = <String, List<RegChip>>{
      for (final e in _m(_wiz['chips']).entries)
        if (e.value is List) e.key: RegChip.parse(e.value),
    };
    final readNote = _s(_m(_p['photo']), 'read_note');
    final notes = <String, String>{
      for (final k in _readKeys) k: readNote,
    };
    final link = _m(_p['link']);
    final save = _m(_p['save']);
    final stepContinue = _s(step, 'continue_label');
    final primary = _saving
        ? (last ? _s(_wiz, 'submitting_label') : _s(_wiz, 'saving_label'))
        : (last
            ? _s(_wiz, 'submit_label')
            : (stepContinue.isNotEmpty
                ? stepContinue
                : _s(_wiz, 'continue_label')));

    return LayoutBuilder(builder: (context, box) {
      final pad = box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Ds.c.surface,
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x8, pad, Ds.space.x4),
            child: _capped(RegistrationProgressBar(
              steps: [
                for (final st in steps)
                  _okSteps.contains(_s(st, 'key')) ? {...st, 'complete': true} : st,
              ],
              current: _step,
              currentComplete: _isDocs && _lic['show'] == true
                  ? _lic['required_complete'] == true
                  : null,
              onJump: (i) {
                if (i < _step) setState(() => _step = i);
              },
            )),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _scroll,
              // CMD #2151 — a finger on the map stops the page scrolling.
              physics: _mapTouch.value
                  ? const NeverScrollableScrollPhysics()
                  : null,
              padding: EdgeInsets.fromLTRB(pad, Ds.space.x24, pad, Ds.space.x24),
              child: _capped(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_step == 0 && link['show'] == true)
                    _note(_s(link, 'label'), Ds.c.infoSoft),
                  if (_step == 0 && _s(_p, 'note').isNotEmpty)
                    _note(_s(_p, 'note'), Ds.c.infoSoft),
                  if (_step == 0) ...[
                    if (_v4 && _s(step, 'title').isNotEmpty) ...[
                      Text(_s(step, 'title'), style: Ds.t.title),
                      SizedBox(height: Ds.space.x16),
                    ],
                    _photoCard(),
                    SizedBox(height: Ds.space.x16),
                  ] else ...[
                    if (_s(step, 'title').isNotEmpty)
                      Text(_s(step, 'title'), style: Ds.t.title),
                    if (_s(step, 'subtitle').isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(step, 'subtitle'), style: Ds.t.bodySecondary),
                    ],
                    SizedBox(height: Ds.space.x16),
                  ],
                  if (_isTerms)
                    _termsView()
                  else if (_isDocs)
                    _lic['show'] == true
                        ? RegistrationLicencesSection(
                            block: _lic,
                            picked: const {},
                            skipped: _skips,
                            thumbUrls: _thumbUrls,
                            busyKey: _busyDoc,
                            scanning: false,
                            onUpload: _upload,
                            onView: _view,
                            onSkipToggle: _toggleSkip,
                            onScan: _scanFirst,
                            onEdit: _editDoc,
                            reading: _docReading,
                          )
                        : const SizedBox.shrink()
                  else if (ctrl != null && mapBlock.isNotEmpty)
                    RegistrationLocationStep(
                      touchLock: _mapTouch,
                      map: mapBlock,
                      values: ctrl.valuesForKeys(const [
                        'address', 'landmark', 'city', 'state',
                        'pincode', 'district', 'latitude', 'longitude',
                        'store_location_link',
                      ]),
                      rpc: (fn, params) => AddCustomerFlow.rpc(fn, params),
                      onValues: (vals) {
                        ctrl.applyMap(vals);
                        final la = (vals['latitude'] ?? '').toString();
                        final ln = (vals['longitude'] ?? '').toString();
                        if (la.isNotEmpty && ln.isNotEmpty) ctrl.setPin(la, ln);
                      },
                    )
                  else if (ctrl != null)
                    CustomerRegistrationForm(
                      controller: ctrl,
                      onlyFields: fields,
                      chips: chips,
                      notes: notes,
                      below: {'whatsapp_no': _numberVerdict()},
                      v4: _v4 ? _wiz : const {},
                      checkRpc: (fn, params) => AddCustomerFlow.rpc(fn, params),
                      customerId: _customerId,
                    ),
                  if (_message.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x12),
                    Text(_message,
                        style: Ds.t.caption.copyWith(color: Ds.c.danger)),
                  ],
                  // CMD #2171 — Save answers here, on the step the staff are
                  // standing on. The sentence is addcust_save's own.
                  if (_savedNote.isNotEmpty) ...[
                    SizedBox(height: Ds.space.x12),
                    Semantics(
                      identifier: 'addcust_saved_note',
                      child: Text(_savedNote,
                          style: Ds.t.caption.copyWith(
                              color: Ds.c.brand,
                              fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              )),
            ),
          ),
          if (!_isTerms && _s(save, 'hint').isNotEmpty)
            Padding(
              padding: EdgeInsets.fromLTRB(pad, Ds.space.x8, pad, 0),
              child: Text(_s(save, 'hint'),
                  textAlign: TextAlign.center,
                  style: Ds.t.caption.copyWith(
                      color: Ds.c.brand, fontWeight: FontWeight.w600)),
            ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x12, pad, Ds.space.x16),
            child: _capped(Row(children: [
              Expanded(
                child: Semantics(
                  identifier: _step == 0 ? 'addcust_save' : 'addcust_back',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: _saving
                          ? null
                          : (_step == 0 ? _saveNow : _back),
                      child: Text(
                          _step == 0 ? _s(save, 'label') : _s(_wiz, 'back_label'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
              ),
              SizedBox(width: Ds.space.x12),
              Expanded(
                flex: 2,
                child: Semantics(
                  identifier: 'addcust_primary',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      // CMD #2171 — dead-or-alive, never both: the button is
                      // enabled exactly when the one number verdict allows it.
                      onPressed: (_saving || _numBlocks) ? null : _continue,
                      child: Text(primary,
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
        margin: EdgeInsets.only(bottom: Ds.space.x16),
        padding: EdgeInsets.all(Ds.space.x12),
        decoration: BoxDecoration(color: bg, borderRadius: Ds.r.rButton),
        child: Text(text, style: Ds.t.body),
      );

  /// "Photograph board or GST certificate" — the brand card from the design.
  Widget _photoCard() {
    final photo = _m(_p['photo']);
    return Semantics(
      identifier: 'addcust_photo',
      button: true,
      child: Material(
        color: Ds.c.brand,
        borderRadius: Ds.r.rCard,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: _reading ? null : _readPhoto,
          child: Padding(
            padding: EdgeInsets.all(Ds.space.x16),
            child: Row(children: [
              Container(
                width: Ds.space.x48,
                height: Ds.space.x48,
                decoration: BoxDecoration(
                  color: Ds.c.surface.withValues(alpha: 0.16),
                  borderRadius: Ds.r.rButton,
                ),
                alignment: Alignment.center,
                child: _reading
                    ? SizedBox(
                        width: Ds.space.x24,
                        height: Ds.space.x24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Ds.c.surface),
                      )
                    : Icon(Icons.photo_camera_outlined, color: Ds.c.surface),
              ),
              SizedBox(width: Ds.space.x16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_s(photo, 'title'),
                        style: Ds.t.bodyStrong.copyWith(color: Ds.c.surface)),
                    SizedBox(height: Ds.space.x4),
                    Text(
                        _reading
                            ? _s(photo, 'reading_label')
                            : _s(photo, 'line'),
                        style: Ds.t.caption.copyWith(color: Ds.c.surface)),
                  ],
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// The live verdict under the WhatsApp field: checking, new, taken,
  /// unfinished, another role, removed, wrong format — the backend's words
  /// and the backend's buttons.
  Widget _numberVerdict() {
    if (_numChecking) {
      return Row(children: [
        SizedBox(
          width: Ds.space.x12,
          height: Ds.space.x12,
          child: CircularProgressIndicator(strokeWidth: 2, color: Ds.c.brand),
        ),
        SizedBox(width: Ds.space.x8),
        Text(_s(_m(_p['number']), 'checking_label'), style: Ds.t.caption),
      ]);
    }
    if (_num.isEmpty || _fresh) return const SizedBox.shrink();
    final tone = _s(_num, 'tone');
    final actions = _l(_num['actions']);
    return Semantics(
      identifier: 'addcust_num_${_s(_num, 'state')}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(_num, 'label'),
              style: Ds.t.caption.copyWith(
                  color: licTone(tone), fontWeight: FontWeight.w600)),
          if (actions.isNotEmpty)
            Wrap(spacing: Ds.space.x8, children: [
              for (final a in actions)
                Semantics(
                  identifier: 'addcust_num_act_${_s(a, 'key')}',
                  button: true,
                  child: ConstrainedBox(
                    constraints:
                        BoxConstraints(minHeight: Ds.touch.minTarget),
                    child: TextButton(
                      onPressed: () => _numAction(a),
                      child: Text(_s(a, 'label')),
                    ),
                  ),
                ),
            ]),
        ],
      ),
    );
  }

  Widget _chipRow(List<Map<String, dynamic>> options, String value,
      ValueChanged<String> onPick, String idPrefix) {
    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x8,
      children: [
        for (final o in options)
          Semantics(
            identifier: '${idPrefix}_${_s(o, 'value')}',
            button: true,
            selected: _s(o, 'value') == value,
            child: ChoiceChip(
              label: Text(_s(o, 'label')),
              selected: _s(o, 'value') == value,
              showCheckmark: false,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (_) => onPick(_s(o, 'value')),
              selectedColor: Ds.c.brandSoft,
              backgroundColor: Ds.c.surface,
              labelStyle: Ds.t.body.copyWith(
                color: _s(o, 'value') == value ? Ds.c.brand : Ds.c.text,
                fontWeight:
                    _s(o, 'value') == value ? FontWeight.w600 : null,
              ),
              side: BorderSide(
                  color: _s(o, 'value') == value ? Ds.c.brand : Ds.c.divider),
              shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
            ),
          ),
      ],
    );
  }

  Widget _termsView() {
    final pay = _m(_terms['payment']);
    final del = _m(_terms['delivery']);
    final zone = _m(_terms['zone']);
    final slab = _m(_terms['slab']);
    final inv = _m(_terms['invite']);
    final zones = _l(zone['options']);
    final zoneLabel = zones
        .firstWhere((z) => '${z['value']}' == '${_zone ?? ''}',
            orElse: () => const {})['label'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // CMD #2151 — Invite step: payment term and delivery are drawn only
        // when the backend turns them on (addcust_rules); their defaults
        // still travel with Save.
        if (pay['show'] != false) ...[
          Text(_s(pay, 'label'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          _chipRow(_l(pay['options']), _payment,
              (v) => setState(() => _payment = v), 'addcust_pay'),
          SizedBox(height: Ds.space.x24),
        ],
        if (del['show'] != false) ...[
          Text(_s(del, 'label'), style: Ds.t.bodyStrong),
          SizedBox(height: Ds.space.x8),
          _chipRow(_l(del['options']), _delivery,
              (v) => setState(() => _delivery = v), 'addcust_deliv'),
          SizedBox(height: Ds.space.x24),
        ],
        Container(
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Column(children: [
            _termRow(
              _s(zone, 'label'),
              zone['locked'] == true || zones.length < 2
                  ? Text('${zoneLabel ?? ''}', style: Ds.t.bodyStrong)
                  : DropdownButtonHideUnderline(
                      child: DropdownButton<int>(
                        value: zones.any((z) => '${z['value']}' == '$_zone')
                            ? _zone
                            : null,
                        style: Ds.t.bodyStrong,
                        items: [
                          for (final z in zones)
                            DropdownMenuItem<int>(
                              value: (z['value'] as num).toInt(),
                              child: Text(_s(z, 'label')),
                            ),
                        ],
                        onChanged: (v) => setState(() => _zone = v),
                      ),
                    ),
            ),
            Divider(height: Ds.space.hairline, color: Ds.c.divider),
            _termRow(_s(slab, 'label'),
                Text(_s(slab, 'value_label'), style: Ds.t.bodyStrong)),
            Divider(height: Ds.space.hairline, color: Ds.c.divider),
            _termRow(
              _s(inv, 'label'),
              Semantics(
                identifier: 'addcust_invite',
                toggled: _invite,
                child: Switch(
                  value: _invite,
                  activeTrackColor: Ds.c.brand,
                  onChanged: (v) => setState(() => _invite = v),
                ),
              ),
            ),
          ]),
        ),
      ],
    );
  }

  Widget _termRow(String label, Widget value) => Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        child: Row(children: [
          Expanded(child: Text(label, style: Ds.t.bodySecondary)),
          SizedBox(width: Ds.space.x8),
          value,
        ]),
      );

  Widget _savedView(Map<String, dynamic> s) {
    final invite = _m(s['invite']);
    final rows = _l(s['checklist']);
    return LayoutBuilder(builder: (context, box) {
      final pad = box.maxWidth >= 600 ? Ds.space.x24 : Ds.space.x16;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(pad, Ds.space.x32, pad, Ds.space.x24),
              child: _capped(Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: Ds.space.x48 + Ds.space.x32,
                      height: Ds.space.x48 + Ds.space.x32,
                      decoration: BoxDecoration(
                          color: Ds.c.brandSoft, shape: BoxShape.circle),
                      alignment: Alignment.center,
                      child: Icon(Icons.check_rounded,
                          size: Ds.space.x48, color: Ds.c.brand),
                    ),
                  ),
                  SizedBox(height: Ds.space.x24),
                  Text(_s(s, 'title'),
                      style: Ds.t.title, textAlign: TextAlign.center),
                  SizedBox(height: Ds.space.x8),
                  Text(_s(s, 'line'),
                      style: Ds.t.bodySecondary, textAlign: TextAlign.center),
                  if (invite['show'] == true) ...[
                    SizedBox(height: Ds.space.x12),
                    Center(
                      child: Container(
                        padding: EdgeInsets.symmetric(
                            horizontal: Ds.space.x12, vertical: Ds.space.x4),
                        decoration: BoxDecoration(
                          color: licToneSoft(_s(invite, 'tone')),
                          borderRadius: Ds.r.rChip,
                        ),
                        child: Text(_s(invite, 'label'),
                            textAlign: TextAlign.center,
                            style: Ds.t.caption.copyWith(
                                color: licTone(_s(invite, 'tone')),
                                fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ],
                  SizedBox(height: Ds.space.x24),
                  Container(
                    decoration: BoxDecoration(
                      color: Ds.c.surface,
                      borderRadius: Ds.r.rCard,
                      border: Border.all(color: Ds.c.divider),
                    ),
                    child: Column(children: [
                      for (var i = 0; i < rows.length; i++) ...[
                        if (i > 0)
                          Divider(
                              height: Ds.space.hairline, color: Ds.c.divider),
                        _termRow(
                          _s(rows[i], 'label'),
                          Flexible(
                            child: Text(_s(rows[i], 'value'),
                                textAlign: TextAlign.right,
                                style: Ds.t.bodyStrong.copyWith(
                                    color: licTone(_s(rows[i], 'tone')))),
                          ),
                        ),
                      ],
                    ]),
                  ),
                  SizedBox(height: Ds.space.x16),
                  Text(_s(s, 'note'),
                      style: Ds.t.caption, textAlign: TextAlign.center),
                ],
              )),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(pad, Ds.space.x12, pad, Ds.space.x16),
            child: _capped(Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  identifier: 'addcust_open_customer',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: OutlinedButton(
                      onPressed: () async {
                        final id = _s(s, 'customer_id');
                        final nav = Navigator.of(context);
                        if (id.isNotEmpty) {
                          await openAdminCustomerPage(context, id);
                        }
                        if (mounted) nav.maybePop(true);
                      },
                      child: Text(_s(s, 'open_label')),
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x12),
                Semantics(
                  identifier: 'addcust_add_another',
                  button: true,
                  child: SizedBox(
                    height: Ds.touch.minTarget,
                    child: FilledButton(
                      onPressed: () {
                        _leadId = null;
                        _customerId = null;
                        _prefill = null;
                        _load();
                      },
                      child: Text(_s(s, 'another_label')),
                    ),
                  ),
                ),
              ],
            )),
          ),
        ],
      );
    });
  }
}
