// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:pharma_b2b/utils/toast.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart' as xmlp;

import '../../config/api_keys.dart';
import '../../utils/render_log.dart';
import '../../models/product.dart';
import '../../supabase_config.dart';
import '../../util.dart';

// ─── Enums ───────────────────────────────────────────────────────────────────

enum _ImpStep { idle, parsing, geminiCols, mapping, matching, reviewing, writing, done }

/// CHANGE #623 — steps of the second import ("Import barcode"). Kept separate
/// from _ImpStep so the medicine import flow above is untouched.
enum _BcStep { none, setup, busy, mapping, previewing, done }

enum _MsStatus { matched, partial, unrecognized, manuallyMatched }

// ─── Match row ────────────────────────────────────────────────────────────────

class _MRow {
  final String lineItem;
  _MsStatus status;
  final List<Product> candidates;
  int selectedIndex;
  bool isHidden;
  _MsStatus? _preHideStatus;
  final Map<String, String> extraData;

  _MRow({
    required this.lineItem,
    required this.status,
    required this.candidates,
    this.selectedIndex = 0,
    this.isHidden = false,
    _MsStatus? preHideStatus,
    Map<String, String>? extraData,
  })  : _preHideStatus = preHideStatus,
        extraData = extraData ?? {};

  Product? get selectedProduct =>
      candidates.isEmpty ? null : candidates[selectedIndex];

  bool get isApproved =>
      status == _MsStatus.matched || status == _MsStatus.manuallyMatched;

  void hide() {
    if (!isHidden) { _preHideStatus = status; isHidden = true; }
  }

  void unhide() {
    if (isHidden) {
      if (_preHideStatus != null) status = _preHideStatus!;
      _preHideStatus = null;
      isHidden = false;
    }
  }
}

// ─── Import column ────────────────────────────────────────────────────────────

class _ImpCol {
  final int fileIndex;
  final String header;
  final List<String> samples;
  String mappedTo;
  String newColName;
  String newColType;

  _ImpCol({
    required this.fileIndex,
    required this.header,
    required this.samples,
    required this.mappedTo,
    this.newColName = '',
    this.newColType = 'text',
  });
}

// ─── Constants ────────────────────────────────────────────────────────────────

const _kMedCols = [
  // CHANGE #623 — 'barcode' is mappable here too (Part A3). If the admin maps
  // it, it rides along in the row payload the medicine import already writes;
  // nothing else about that flow changed.
  'product_name', 'salt_composition', 'marketer', 'mrp', 'barcode',
  'pack_qty', 'pack_size', 'pack_type', 'therapeutic_class',
  'rx_required', 'status', 'uses', 'benefits', 'side_effects',
  'storage', 'chemical_class', 'action_class',
  'product_introduction', 'product_highlight',
];

/// CHANGE #623 — the only two things a barcode sheet has to carry. product_id
/// is optional; the backend prefers it over the name when present.
const _kBcCols = ['product_name', 'barcode', 'product_id'];

const _kTh = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF),
  letterSpacing: 0.5,
);

// ─── Screen ───────────────────────────────────────────────────────────────────

class AdminAddMedicineScreen extends StatefulWidget {
  final Uint8List? preloadedBytes;
  final String? preloadedFileName;
  final VoidCallback? onImportComplete;

  const AdminAddMedicineScreen({
    super.key,
    this.preloadedBytes,
    this.preloadedFileName,
    this.onImportComplete,
  });
  @override
  State<AdminAddMedicineScreen> createState() => _AdminAddMedicineScreenState();
}

class _AdminAddMedicineScreenState extends State<AdminAddMedicineScreen> {
  _ImpStep _step = _ImpStep.idle;
  String _statusMsg = '';

  // Stage 1
  List<_ImpCol> _cols = [];
  List<List<String>> _rawRows = [];
  final Map<int, TextEditingController> _newColCtrls = {};

  // Stage 2
  List<_MRow> _rows = [];
  int _matchProgress = 0;
  int _matchTotal = 0;
  bool _isRetrying = false;
  double _retryProgress = 0.0;
  int _expandedRow = -1;

  // Done
  int _updatedCount = 0;
  int _insertedCount = 0;
  int _skippedCount = 0;

  // ── CHANGE #623 — barcode import state ─────────────────────────────────────
  // Every label, count and colour shown by this flow comes out of the RPC
  // payloads below (_bcTargets / _bcPreview / _bcApply). Nothing here derives
  // a verdict, a total or a colour from the rows itself.
  _BcStep _bcStep = _BcStep.none;
  String _bcMode = 'item';                 // 'item' | 'order' → p_mode
  DateTime _bcDate = DateTime.now();       // only sent in 'order' mode
  String _bcStatusMsg = '';
  Map<String, dynamic>? _bcTargets;        // barcode_import_targets payload
  bool _bcTargetsLoading = false;
  List<_ImpCol> _bcCols = [];
  List<List<String>> _bcRawRows = [];
  List<Map<String, dynamic>> _bcRows = []; // the exact array sent to both RPCs
  Map<String, dynamic>? _bcPreview;        // barcode_import_preview payload
  Map<String, dynamic>? _bcApply;          // barcode_import_apply payload

  @override
  void initState() {
    super.initState();
    if (widget.preloadedBytes != null && widget.preloadedFileName != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _startFromBytes(widget.preloadedBytes!, widget.preloadedFileName!),
      );
    }
  }

  @override
  void dispose() {
    for (final c in _newColCtrls.values) c.dispose();
    super.dispose();
  }

  // ── File helpers ─────────────────────────────────────────────────────────────

  Future<String> _readAsText(html.File f) async {
    final r = html.FileReader();
    r.readAsText(f);
    await r.onLoad.first;
    return (r.result as String).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  Future<Uint8List> _readBytes(html.File f) async {
    final r = html.FileReader();
    r.readAsDataUrl(f);
    await r.onLoad.first;
    return base64Decode((r.result as String).split(',').last);
  }

  Future<String> _pdfText(Uint8List bytes) async {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final t = PdfTextExtractor(doc).extractText();
      doc.dispose();
      return t;
    } catch (_) { return ''; }
  }

  Future<String> _xlsxText(html.File f) async => _xlsxBytesText(await _readBytes(f));

  String _xlsxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open Excel file.'); }
    ArchiveFile? find(String p) {
      final lo = p.toLowerCase();
      for (final x in archive) { if (x.name.toLowerCase() == lo) return x; }
      return null;
    }
    final ss = <String>[];
    final ssf = find('xl/sharedStrings.xml');
    if (ssf != null) {
      try {
        final doc = xmlp.XmlDocument.parse(utf8.decode(ssf.content as List<int>));
        for (final si in doc.findAllElements('si')) {
          ss.add(si.findAllElements('t').map((t) => t.innerText).join());
        }
      } catch (_) {}
    }
    ArchiveFile? shf;
    for (int n = 1; n <= 10; n++) { shf = find('xl/worksheets/sheet$n.xml'); if (shf != null) break; }
    if (shf == null) throw Exception('No worksheet found in Excel file.');
    final wsDoc = xmlp.XmlDocument.parse(utf8.decode(shf.content as List<int>));
    String? rc(xmlp.XmlElement cell) {
      final t = cell.getAttribute('t');
      if (t == 'inlineStr') return cell.findAllElements('t').map((e) => e.innerText).join();
      if (t == 's') {
        final v = cell.findElements('v').firstOrNull?.innerText;
        if (v == null) return null;
        final idx = int.tryParse(v);
        if (idx == null || idx >= ss.length) return null;
        return ss[idx];
      }
      return cell.findElements('v').firstOrNull?.innerText;
    }
    final sb = StringBuffer();
    for (final row in wsDoc.findAllElements('row')) {
      final cells = <String, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final col = ref.replaceAll(RegExp(r'[0-9]'), '');
        if (col.isNotEmpty) cells[col] = rc(cell) ?? '';
      }
      if (cells.isEmpty) continue;
      final cols = cells.keys.toList()..sort();
      sb.writeln(cols.map((c) => cells[c]!).join('\t'));
    }
    return sb.toString();
  }

  Future<String> _odsText(html.File f) async => _odsBytesText(await _readBytes(f));

  String _odsBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open ODS file.'); }
    ArchiveFile? cf;
    for (final x in archive) { if (x.name.toLowerCase() == 'content.xml') { cf = x; break; } }
    if (cf == null) throw Exception('Not a valid ODS file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(cf.content as List<int>));
    String ct(xmlp.XmlElement cell) {
      final ps = cell.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p');
      return ps.isNotEmpty ? ps.map((e) => e.innerText).join(' ').trim() : '';
    }
    final sb = StringBuffer();
    for (final tbl in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table')) {
      for (final row in tbl.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'table-row')) {
        final cells = row.descendants.whereType<xmlp.XmlElement>()
            .where((e) => e.localName == 'table-cell' || e.localName == 'covered-table-cell').toList();
        if (cells.isEmpty) continue;
        sb.writeln(cells.map(ct).join('\t'));
      }
    }
    return sb.toString();
  }

  Future<String> _docxText(html.File f) async => _docxBytesText(await _readBytes(f));

  String _docxBytesText(Uint8List bytes) {
    Archive archive;
    try { archive = ZipDecoder().decodeBytes(bytes); }
    catch (_) { throw Exception('Could not open DOCX file.'); }
    ArchiveFile? df;
    for (final x in archive) { if (x.name.toLowerCase() == 'word/document.xml') { df = x; break; } }
    if (df == null) throw Exception('Not a valid DOCX file.');
    final doc = xmlp.XmlDocument.parse(utf8.decode(df.content as List<int>));
    final sb = StringBuffer();
    for (final p in doc.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 'p')) {
      final t = p.descendants.whereType<xmlp.XmlElement>().where((e) => e.localName == 't').map((e) => e.innerText).join();
      if (t.trim().isNotEmpty) sb.writeln(t);
    }
    return sb.toString();
  }

  // ── Parse any file to a 2-D table ────────────────────────────────────────────

  Future<({List<String> headers, List<List<String>> rows})> _parseFile(html.File f) async {
    final ext = f.name.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv': case 'tsv': case 'txt':
        return _textToTable(await _readAsText(f));
      case 'xlsx': case 'xls':
        return _textToTable(await _xlsxText(f));
      case 'ods':
        return _textToTable(await _odsText(f));
      case 'docx':
        return _textToTable(await _docxText(f));
      case 'pdf':
        final bytes = await _readBytes(f);
        final local = await _pdfText(bytes);
        if (local.trim().length > 20) return _textToTable(local);
        return _geminiTable(false, '', base64Encode(bytes), 'application/pdf');
      case 'jpg': case 'jpeg':
        return _geminiTable(true, 'image/jpeg', base64Encode(await _readBytes(f)), '');
      case 'png':
        return _geminiTable(true, 'image/png', base64Encode(await _readBytes(f)), '');
      case 'webp':
        return _geminiTable(true, 'image/webp', base64Encode(await _readBytes(f)), '');
      case 'heic': case 'heif':
        return _geminiTable(true, 'image/heic', base64Encode(await _readBytes(f)), '');
      case 'gif':
        return _geminiTable(true, 'image/gif', base64Encode(await _readBytes(f)), '');
      default:
        return _textToTable(await _readAsText(f));
    }
  }

  Future<({List<String> headers, List<List<String>> rows})> _parseBytesFile(Uint8List bytes, String fileName) async {
    final ext = fileName.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv': case 'tsv': case 'txt':
        final text = utf8.decode(bytes, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        return _textToTable(text);
      case 'xlsx': case 'xls':
        return _textToTable(_xlsxBytesText(bytes));
      case 'ods':
        return _textToTable(_odsBytesText(bytes));
      case 'docx':
        return _textToTable(_docxBytesText(bytes));
      case 'pdf':
        final local = await _pdfText(bytes);
        if (local.trim().length > 20) return _textToTable(local);
        return _geminiTable(false, '', base64Encode(bytes), 'application/pdf');
      case 'jpg': case 'jpeg':
        return _geminiTable(true, 'image/jpeg', base64Encode(bytes), '');
      case 'png':
        return _geminiTable(true, 'image/png', base64Encode(bytes), '');
      case 'webp':
        return _geminiTable(true, 'image/webp', base64Encode(bytes), '');
      case 'heic': case 'heif':
        return _geminiTable(true, 'image/heic', base64Encode(bytes), '');
      case 'gif':
        return _geminiTable(true, 'image/gif', base64Encode(bytes), '');
      default:
        final text = utf8.decode(bytes, allowMalformed: true).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        return _textToTable(text);
    }
  }

  Future<void> _startFromBytes(Uint8List bytes, String fileName) async {
    setState(() { _step = _ImpStep.parsing; _statusMsg = 'Reading file…'; });
    try {
      final table = await _parseBytesFile(bytes, fileName);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file');
      setState(() { _step = _ImpStep.geminiCols; _statusMsg = 'Mapping columns with Gemini…'; });
      final cols = await _geminiMapCols(table.headers, table.rows);
      for (final c in _newColCtrls.values) c.dispose();
      _newColCtrls.clear();
      setState(() {
        _rawRows = table.rows;
        _cols = cols;
        for (final c in _cols) _newColCtrls[c.fileIndex] = TextEditingController();
        _step = _ImpStep.mapping;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _step = _ImpStep.idle; });
      showToast(context, e.toString().replaceFirst('Exception: ', ''), duration: const Duration(seconds: 6));
    }
  }

  ({List<String> headers, List<List<String>> rows}) _textToTable(String text) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return (headers: [], rows: []);
    final sep = lines.first.contains('\t') ? '\t' : ',';
    var allRows = lines.map((l) =>
        l.split(sep).map((c) => c.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), '')).toList()
    ).toList();
    if (allRows.isEmpty) return (headers: [], rows: []);
    final maxCols = allRows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    allRows = allRows.map((r) {
      if (r.length < maxCols) return [...r, ...List.filled(maxCols - r.length, '')];
      return r;
    }).toList();
    final first = allRows[0];
    final isHdr = first.every((c) => double.tryParse(c.replaceAll(RegExp(r'[₹,\s]'), '')) == null);
    if (isHdr && allRows.length > 1) return (headers: first, rows: allRows.sublist(1));
    return (headers: List.filled(maxCols, ''), rows: allRows);
  }

  static const _ocrEdgeFn =
      'https://swojhmarmaijkshsbeih.supabase.co/functions/v1/gemini-ocr';

  Future<({List<String> headers, List<List<String>> rows})> _geminiTable(
      bool isImage, String mime, String b64, String pdfMime) async {
    final prompt =
        'Extract the tabular data from this file. '
        'Return ONLY a JSON object (no markdown fences):\n'
        '{"headers":["col1","col2"],"rows":[["v1","v2"],...]}\n'
        'Use empty string "" for missing headers. '
        'Include all data rows. Keep currency symbols (₹) in values as-is.';

    final resp = await http.post(
      Uri.parse(_ocrEdgeFn),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'image_base64': b64,
        'mime_type': isImage ? mime : pdfMime,
        'prompt': prompt,
      }),
    ).timeout(const Duration(seconds: 60));
    if (resp.statusCode != 200) throw Exception('OCR API error (HTTP ${resp.statusCode})');
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final txt = data['text'] as String? ?? '';
    if (txt.isEmpty) throw Exception('Empty response from OCR service');
    final jm = RegExp(r'\{[\s\S]*\}').firstMatch(txt);
    if (jm == null) throw Exception('Could not parse table structure from file');
    final dec = jsonDecode(jm.group(0)!) as Map<String, dynamic>;
    final headers = (dec['headers'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final rows = (dec['rows'] as List<dynamic>?)
        ?.map((r) => (r as List<dynamic>).map((e) => e.toString()).toList()).toList() ?? [];
    return (headers: headers, rows: rows);
  }

  // ── Gemini column mapping ─────────────────────────────────────────────────────

  Future<List<_ImpCol>> _geminiMapCols(List<String> headers, List<List<String>> dataRows) =>
      _geminiMapColsWith(headers, dataRows,
          'Database fields:\n'
          '- product_name: medicine name (e.g. "Augmentin 625 Duo", "Pan 40mg")\n'
          '- salt_composition: active ingredients (e.g. "Amoxicillin 500mg")\n'
          '- marketer: brand/company (e.g. "GSK", "Abbott")\n'
          '- mrp: price in ₹ (e.g. "₹159.28", "206.25")\n'
          '- barcode: barcode / EAN / UPC / GTIN printed on the pack (a long digit run, usually 8-14 digits)\n'
          '- pack_qty: pack description (e.g. "10 tablets in 1 strip", "30ml")\n'
          '- pack_size: pack code (e.g. "10\'T", "30ml")\n'
          '- pack_type: packaging (e.g. "Strip", "Bottle")\n'
          '- therapeutic_class: category (e.g. "ANTIBIOTICS")\n'
          '- rx_required: prescription? ("Rx" or empty)\n'
          '- status: availability (e.g. "Available")\n'
          '- uses, benefits, side_effects, storage, chemical_class, action_class\n'
          '- ignore: skip this column\n\n'
          'Infer from BOTH header AND sample values. '
          'Numbers with ₹ or decimals like "159.28" → mrp. '
          'Values like "10\'T","30ml","500mg" → pack_qty or pack_size. '
          'Digit-only values 8-14 characters long → barcode. '
          'Date-like values → ignore. Serial/index numbers → ignore.\n\n');

  /// CHANGE #623 — barcode import maps the SAME way, through the SAME Gemini
  /// step; only the field list it is allowed to choose from differs.
  Future<List<_ImpCol>> _geminiMapColsBarcode(List<String> headers, List<List<String>> dataRows) =>
      _geminiMapColsWith(headers, dataRows,
          'Database fields:\n'
          '- product_name: medicine name (e.g. "Augmentin 625 Duo", "Pan 40mg")\n'
          '- barcode: barcode / EAN / UPC / GTIN printed on the pack (a long digit run, usually 8-14 digits)\n'
          '- product_id: our own numeric catalogue id — ONLY if the sheet clearly carries one\n'
          '- ignore: skip this column\n\n'
          'Infer from BOTH header AND sample values. '
          'Digit-only values 8-14 characters long → barcode. '
          'Short running numbers (1,2,3…) → ignore, NOT product_id. '
          'Text containing mg/ml/tablet/cap → product_name. '
          'Date-like values → ignore.\n\n');

  Future<List<_ImpCol>> _geminiMapColsWith(
      List<String> headers, List<List<String>> dataRows, String fieldSpec) async {
    final entries = <Map<String, dynamic>>[];
    for (int i = 0; i < headers.length; i++) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.trim().isNotEmpty).take(5).toList();
      entries.add({'index': i, 'header': headers[i], 'samples': samples});
    }
    final prompt =
        'Map each spreadsheet column to the correct pharmaceutical database field.\n\n'
        '$fieldSpec'
        'Columns:\n${jsonEncode(entries)}\n\n'
        'Return ONLY a JSON array (no markdown): '
        '[{"index":0,"mapped_to":"product_name"},...]';

    try {
      final resp = await http.post(
        Uri.parse(_ocrEdgeFn),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'image_base64': '', 'mime_type': 'text/plain', 'prompt': prompt}),
      ).timeout(const Duration(seconds: 30));
      if (resp.statusCode == 200) {
        final txt = (jsonDecode(resp.body) as Map<String, dynamic>)['text'] as String? ?? '';
        final jm = RegExp(r'\[[\s\S]*\]').firstMatch(txt);
        if (jm != null) {
          final mappings = jsonDecode(jm.group(0)!) as List<dynamic>;
          final idxMap = <int, String>{};
          for (final m in mappings) {
            final mm = m as Map<String, dynamic>;
            final idx = mm['index'] as int?;
            final mapped = mm['mapped_to'] as String? ?? 'ignore';
            if (idx != null) idxMap[idx] = mapped;
          }
          return _buildCols(headers, dataRows, idxMap);
        }
      }
    } catch (_) {}
    return _buildCols(headers, dataRows, {});
  }

  List<_ImpCol> _buildCols(List<String> headers, List<List<String>> dataRows, Map<int, String> idxMap) {
    return List.generate(headers.length, (i) {
      final samples = dataRows.map((r) => i < r.length ? r[i] : '').where((v) => v.trim().isNotEmpty).take(5).toList();
      return _ImpCol(fileIndex: i, header: headers[i], samples: samples, mappedTo: idxMap[i] ?? 'ignore');
    });
  }

  // ── Pick file and start import flow ──────────────────────────────────────────

  Future<void> _pickFile() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = false;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;
    final file = files.first;

    setState(() { _step = _ImpStep.parsing; _statusMsg = 'Reading file…'; });
    try {
      final table = await _parseFile(file);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file');
      setState(() { _step = _ImpStep.geminiCols; _statusMsg = 'Mapping columns with Gemini…'; });
      final cols = await _geminiMapCols(table.headers, table.rows);
      for (final c in _newColCtrls.values) c.dispose();
      _newColCtrls.clear();
      setState(() {
        _rawRows = table.rows;
        _cols = cols;
        for (final c in _cols) _newColCtrls[c.fileIndex] = TextEditingController();
        _step = _ImpStep.mapping;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _step = _ImpStep.idle; });
      showToast(context, e.toString().replaceFirst('Exception: ', ''), duration: const Duration(seconds: 6));
    }
  }

  // ── Confirm mapping ───────────────────────────────────────────────────────────

  Future<void> _confirmMapping() async {
    if (!_cols.any((c) => c.mappedTo == 'product_name')) {
      showToast(context, 'Map at least one column to "product_name" — it is required for matching.');
      return;
    }
    // Validate create_new entries
    for (final col in _cols.where((c) => c.mappedTo == 'create_new')) {
      final name = (_newColCtrls[col.fileIndex]?.text ?? '').trim();
      if (name.isEmpty) {
        showToast(context, 'Enter a name for the new column "${col.header.isNotEmpty ? col.header : "Column ${col.fileIndex + 1}"}"');
        return;
      }
      if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
        showToast(context, '"$name" is invalid — use lowercase letters, numbers, underscores, starting with a letter');
        return;
      }
      if (_kMedCols.contains(name)) {
        showToast(context, '"$name" already exists — map directly to that column instead');
        return;
      }
      col.newColName = name;
    }

    // Create new columns via RPC
    final toCreate = _cols.where((c) => c.mappedTo == 'create_new').toList();
    if (toCreate.isNotEmpty) {
      setState(() { _step = _ImpStep.geminiCols; _statusMsg = 'Creating new columns…'; });
      for (final col in toCreate) {
        try {
          await Supabase.instance.client.rpc('add_medicine_column', params: {
            'col_name': col.newColName,
            'col_type': col.newColType,
          });
          col.mappedTo = col.newColName;
        } catch (e) {
          if (!mounted) return;
          setState(() { _step = _ImpStep.mapping; });
          showToast(context, 'Could not create column "${col.newColName}": ${e.toString().replaceFirst('Exception: ', '')}', duration: const Duration(seconds: 8));
          return;
        }
      }
    }

    // Run matching
    setState(() { _step = _ImpStep.matching; _matchProgress = 0; _matchTotal = _rawRows.length; });
    final nameCol = _cols.firstWhere((c) => c.mappedTo == 'product_name');
    final rows = <_MRow>[];

    for (final raw in _rawRows) {
      final nameVal = nameCol.fileIndex < raw.length ? raw[nameCol.fileIndex].trim() : '';
      if (nameVal.isNotEmpty) {
        final extra = <String, String>{};
        for (final col in _cols) {
          if (col.mappedTo == 'ignore' || col.mappedTo == 'product_name') continue;
          final v = col.fileIndex < raw.length ? raw[col.fileIndex].trim() : '';
          if (v.isNotEmpty) extra[col.mappedTo] = v;
        }
        rows.add(await _matchOne(nameVal, extra));
      }
      if (!mounted) return;
      setState(() => _matchProgress = rows.length);
    }
    if (!mounted) return;
    setState(() { _rows = rows; _expandedRow = -1; _step = _ImpStep.reviewing; });
  }

  // ── Fuzzy match one row ───────────────────────────────────────────────────────

  Future<_MRow> _matchOne(String name, Map<String, String> extra) async {
    final term = name
        .replaceAll(RegExp(r'[,()*%]'), ' ')
        .replaceAll(RegExp(r'\.(?!\d)'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    if (term.isEmpty) return _MRow(lineItem: name, status: _MsStatus.unrecognized, candidates: [], extraData: extra);
    try {
      final raw = await _searchTop5(term);
      if (raw.isEmpty) return _MRow(lineItem: name, status: _MsStatus.unrecognized, candidates: [], extraData: extra);
      final products = raw.map((m) => Product.fromMap(m)).toList();
      final form = _detectForm(term);
      double top = _s2Score(term, products[0].name);
      if (form != null && _formMatch(products[0].name, form)) top += 0.02;
      return _MRow(
        lineItem: name,
        status: top >= 0.40 ? _MsStatus.matched : _MsStatus.partial,
        candidates: products,
        extraData: extra,
      );
    } catch (_) {
      return _MRow(lineItem: name, status: _MsStatus.unrecognized, candidates: [], extraData: extra);
    }
  }

  Future<List<Map<String, dynamic>>> _searchTop5(String name) async {
    final client = Supabase.instance.client;
    List<Map<String, dynamic>> list = [];
    try {
      final rows = await client.rpc('search_medicines_priority', params: {
        'search_term': name, 'category_filter': 'All', 'page_offset': 0, 'page_limit': 20,
      });
      list = List<Map<String, dynamic>>.from(rows as List);
    } catch (_) {}
    if (list.isEmpty) {
      try {
        final raw = await client.rpc('medicine_search_available',
            params: {'p_term': name, 'p_limit': 20});
        list = List<Map<String, dynamic>>.from(
            (((raw is List ? raw.first : raw) as Map)['rows'] as List? ?? const []));
      } catch (_) {}
    }
    list = list.where((row) {
      if (!row.containsKey('status')) return true;
      final s = (row['status'] as String? ?? '').toLowerCase();
      return s == 'available' || s == 'active' || s == '1' || s == 'true';
    }).toList();
    if (list.isEmpty) return list;
    final form = _detectForm(name);
    list.sort((a, b) => _s1Score(name, (b['product_name'] as String?) ?? '')
        .compareTo(_s1Score(name, (a['product_name'] as String?) ?? '')));
    final shortlist = list.take(20).toList();
    shortlist.sort((a, b) {
      final na = (a['product_name'] as String?) ?? '';
      final nb = (b['product_name'] as String?) ?? '';
      double sa = _s2Score(name, na), sb = _s2Score(name, nb);
      if (form != null) {
        if (_formMatch(na, form)) sa += 0.02;
        if (_formMatch(nb, form)) sb += 0.02;
      }
      return sb.compareTo(sa);
    });
    return shortlist.take(5).toList();
  }

  // ── Retry ─────────────────────────────────────────────────────────────────────

  Future<void> _retryAll() async {
    if (_isRetrying) return;
    setState(() { _isRetrying = true; _retryProgress = 0.0; });
    try {
      for (int i = 0; i < _rows.length; i++) {
        final old = _rows[i];
        final fresh = await _matchOne(old.lineItem, old.extraData);
        _MsStatus best;
        if (old.status == _MsStatus.matched && fresh.status != _MsStatus.matched) best = _MsStatus.matched;
        else if (old.status == _MsStatus.partial && fresh.status == _MsStatus.unrecognized) best = _MsStatus.partial;
        else best = fresh.status;
        if (mounted) setState(() {
          _rows[i] = _MRow(lineItem: old.lineItem, status: best,
              candidates: fresh.candidates.isNotEmpty ? fresh.candidates : old.candidates,
              extraData: old.extraData);
          _retryProgress = (i + 1) / _rows.length;
        });
      }
    } finally {
      if (mounted) setState(() { _isRetrying = false; _retryProgress = 0.0; });
    }
  }

  Future<void> _retryRow(int i, void Function(double) onP) async {
    final old = _rows[i];
    onP(0.3);
    final fresh = await _matchOne(old.lineItem, old.extraData);
    onP(0.9);
    _MsStatus best;
    if (old.status == _MsStatus.matched && fresh.status != _MsStatus.matched) best = _MsStatus.matched;
    else if (old.status == _MsStatus.partial && fresh.status == _MsStatus.unrecognized) best = _MsStatus.partial;
    else best = fresh.status;
    if (mounted) setState(() {
      _rows[i] = _MRow(lineItem: old.lineItem, status: best,
          candidates: fresh.candidates.isNotEmpty ? fresh.candidates : old.candidates,
          extraData: old.extraData);
    });
    onP(1.0);
  }

  // ── Search select callback ────────────────────────────────────────────────────

  void _onSearchSelect(int i, Product p) {
    setState(() {
      final row = _rows[i];
      // Put the selected product first in candidates list
      final newCands = [p, ...row.candidates.where((c) => c.id != p.id)].take(5).toList();
      _rows[i] = _MRow(
        lineItem: row.lineItem,
        status: _MsStatus.manuallyMatched,
        candidates: newCands,
        selectedIndex: 0,
        extraData: row.extraData,
      );
      _expandedRow = -1;
    });
  }

  // ── Final write ───────────────────────────────────────────────────────────────

  Future<void> _doWrite() async {
    setState(() { _step = _ImpStep.writing; _statusMsg = 'Saving to database…'; });
    int updated = 0, inserted = 0, skipped = 0;
    final client = Supabase.instance.client;
    // INSERT is blocked by MEDICINE RLS for all JWT-authenticated users.
    // We use the service role key via HTTP for inserts only.
    final svcKey = supabaseServiceKey;
    final restBase = '${SupabaseConfig.url}/rest/v1';

    for (final row in _rows) {
      if (row.isHidden || !row.isApproved) { skipped++; continue; }
      final product = row.selectedProduct;
      try {
        if (product != null && row.status != _MsStatus.unrecognized) {
          // UPDATE existing — never overwrite marketer. RLS allows UPDATE via admin JWT.
          final upd = <String, dynamic>{};
          for (final col in _cols) {
            if (col.mappedTo == 'ignore' || col.mappedTo == 'marketer') continue;
            final v = col.mappedTo == 'product_name' ? row.lineItem : row.extraData[col.mappedTo];
            if (v != null && v.isNotEmpty) upd[col.mappedTo] = v;
          }
          if (upd.isNotEmpty) {
            final resp = await http.patch(
              Uri.parse('$restBase/MEDICINE?id=eq.${int.parse(product.id)}'),
              headers: {
                'apikey': svcKey,
                'Authorization': 'Bearer $svcKey',
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal',
              },
              body: jsonEncode(upd),
            ).timeout(const Duration(seconds: 30));
            if (resp.statusCode >= 400) throw Exception('Update failed (${resp.statusCode}): ${resp.body}');
          }
          updated++;
        } else {
          // INSERT new medicine — uses service role to bypass INSERT RLS block.
          final ins = <String, dynamic>{
            'status': 'Available', 'sales_count': 0, 'has_scheme': false, 'has_image': false,
          };
          for (final col in _cols) {
            if (col.mappedTo == 'ignore') continue;
            final v = col.mappedTo == 'product_name' ? row.lineItem : row.extraData[col.mappedTo];
            if (v != null && v.isNotEmpty) ins[col.mappedTo] = v;
          }
          final resp = await http.post(
            Uri.parse('$restBase/MEDICINE'),
            headers: {
              'apikey': svcKey,
              'Authorization': 'Bearer $svcKey',
              'Content-Type': 'application/json',
              'Prefer': 'return=minimal',
            },
            body: jsonEncode(ins),
          ).timeout(const Duration(seconds: 30));
          if (resp.statusCode >= 400) throw Exception('Insert failed (${resp.statusCode}): ${resp.body}');
          inserted++;
        }
      } catch (e) {
        debugPrint('[AdminImport] Write error "${row.lineItem}": $e');
        skipped++;
      }
    }
    if (!mounted) return;
    setState(() { _updatedCount = updated; _insertedCount = inserted; _skippedCount = skipped; _step = _ImpStep.done; });
  }

  // ══ CHANGE #623 — BARCODE IMPORT ═══════════════════════════════════════════
  //
  // The backend owns every decision here. This side picks a mode, reuses the
  // medicine import's file pickers + Gemini mapper to turn a sheet into rows,
  // POSTs those rows, and renders the returned payload verbatim.

  /// p_date — only meaningful in order-wise mode; item-wise sends null so the
  /// backend matches the whole catalogue.
  String? get _bcDateParam => _bcMode == 'order' ? _isoDate(_bcDate) : null;

  String _isoDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Supabase returns a jsonb scalar either bare or wrapped in a one-element
  /// list depending on the client path — normalise both.
  Map<String, dynamic> _asMap(dynamic res) =>
      Map<String, dynamic>.from(((res is List ? res.first : res) as Map));

  /// Colours arrive as "#RRGGBB" strings from status_colors — parse, never pick.
  Color _hex(String? s, Color fallback) {
    final v = (s ?? '').replaceAll('#', '').trim();
    if (v.length != 6) return fallback;
    final n = int.tryParse(v, radix: 16);
    return n == null ? fallback : Color(0xFF000000 | n);
  }

  String _str(Map<String, dynamic>? m, String k) => (m?[k] ?? '').toString();

  void _bcStart(String mode) {
    setState(() {
      _bcMode = mode;
      _bcStep = _BcStep.setup;
      _bcDate = DateTime.now();
      _bcTargets = null;
      _bcPreview = null;
      _bcApply = null;
      _bcCols = [];
      _bcRawRows = [];
      _bcRows = [];
    });
    if (mode == 'order') _bcLoadTargets();
  }

  void _bcExit() => setState(() {
        _bcStep = _BcStep.none;
        _bcPreview = null;
        _bcApply = null;
      });

  // ── E1 — order-wise helper list ────────────────────────────────────────────

  Future<void> _bcLoadTargets() async {
    setState(() => _bcTargetsLoading = true);
    try {
      final res = await Supabase.instance.client.rpc('barcode_import_targets',
          params: {'p_date': _bcDateParam, 'p_supplier': null});
      if (!mounted) return;
      setState(() => _bcTargets = _asMap(res));
    } catch (e) {
      if (!mounted) return;
      showToast(context, e.toString().replaceFirst('Exception: ', ''), isError: true);
    } finally {
      if (mounted) setState(() => _bcTargetsLoading = false);
    }
  }

  // ── E2 — share the list as plain text, built from the returned fields ──────

  Future<void> _bcShareTargets() async {
    final rows = (_bcTargets?['rows'] as List<dynamic>? ?? const []);
    final lines = <String>[
      _str(_bcTargets, 'title'),
      _str(_bcTargets, 'note'),
      '',
      for (final r in rows)
        () {
          final m = Map<String, dynamic>.from(r as Map);
          final parts = <String>[
            _str(m, 'product_name'),
            if (_str(m, 'pack_label').isNotEmpty) _str(m, 'pack_label'),
            'x${_str(m, 'ordered_qty')}',
          ];
          return '${parts.join(' · ')}${m['has_barcode'] == true ? ' ✓' : ''}';
        }(),
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (mounted) showToast(context, 'List copied — paste it to the supplier');
  }

  // ── B — file → rows, through the SAME pipeline the medicine import uses ────

  Future<void> _bcPickFile() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = false;
    input.click();
    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;

    setState(() { _bcStep = _BcStep.busy; _bcStatusMsg = 'Reading file…'; });
    try {
      final table = await _parseFile(files.first);
      if (table.rows.isEmpty) throw Exception('No data rows found in the file');
      if (!mounted) return;
      setState(() => _bcStatusMsg = 'Mapping columns with Gemini…');
      final cols = await _geminiMapColsBarcode(table.headers, table.rows);
      if (!mounted) return;
      setState(() {
        _bcRawRows = table.rows;
        _bcCols = cols;
        for (final c in _bcCols) _newColCtrls.putIfAbsent(c.fileIndex, () => TextEditingController());
        _bcStep = _BcStep.mapping;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _bcStep = _BcStep.setup);
      showToast(context, e.toString().replaceFirst('Exception: ', ''), duration: const Duration(seconds: 6));
    }
  }

  _ImpCol? _bcColFor(String field) {
    for (final c in _bcCols) { if (c.mappedTo == field) return c; }
    return null;
  }

  // ── B3 — build the row payload ────────────────────────────────────────────

  Future<void> _bcConfirmMapping() async {
    final nameCol = _bcColFor('product_name');
    final bcCol   = _bcColFor('barcode');
    final idCol   = _bcColFor('product_id');
    if (bcCol == null) {
      showToast(context, 'Map one column to "barcode" — it is required.');
      return;
    }
    if (nameCol == null && idCol == null) {
      showToast(context, 'Map one column to "product_name" (or "product_id") so rows can be matched.');
      return;
    }

    final rows = <Map<String, dynamic>>[];
    for (final raw in _bcRawRows) {
      String cell(_ImpCol? c) =>
          (c != null && c.fileIndex < raw.length) ? raw[c.fileIndex].trim() : '';
      final name = cell(nameCol), bc = cell(bcCol), pid = cell(idCol);
      // A wholly blank sheet line is not a row — everything else goes to the
      // backend as-is, including blank barcodes (it labels them 'no_barcode').
      if (name.isEmpty && bc.isEmpty && pid.isEmpty) continue;
      rows.add({
        'name': name,
        'barcode': bc,
        if (pid.isNotEmpty) 'product_id': pid,
      });
    }
    if (rows.isEmpty) {
      showToast(context, 'No usable rows found in that file.');
      return;
    }
    _bcRows = rows;
    await _bcRunPreview();
  }

  // ── C — preview ───────────────────────────────────────────────────────────

  Future<void> _bcRunPreview() async {
    setState(() { _bcStep = _BcStep.busy; _bcStatusMsg = 'Checking rows…'; });
    try {
      final res = await Supabase.instance.client.rpc('barcode_import_preview', params: {
        'p_rows': _bcRows,
        'p_mode': _bcMode,
        'p_date': _bcDateParam,
        'p_supplier': null,
      });
      if (!mounted) return;
      final map = _asMap(res);
      if (map['ok'] != true) {
        setState(() => _bcStep = _BcStep.mapping);
        showToast(context, _str(map, 'message').isNotEmpty ? _str(map, 'message') : _str(map, 'error'),
            isError: true, duration: const Duration(seconds: 6));
        return;
      }
      setState(() { _bcPreview = map; _bcStep = _BcStep.previewing; });
      RenderLog.write('c623_barcode_preview', '${_bcMode}:${_str(map, 'summary_label')}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _bcStep = _BcStep.mapping);
      showToast(context, e.toString().replaceFirst('Exception: ', ''), isError: true, duration: const Duration(seconds: 6));
    }
  }

  // ── D — apply (send the SAME rows; the backend re-runs the preview) ───────

  Future<void> _bcApplyNow() async {
    setState(() { _bcStep = _BcStep.busy; _bcStatusMsg = 'Saving barcodes…'; });
    try {
      final res = await Supabase.instance.client.rpc('barcode_import_apply', params: {
        'p_rows': _bcRows,
        'p_mode': _bcMode,
        'p_date': _bcDateParam,
        'p_supplier': null,
        'p_allow_overwrite': true,
      });
      if (!mounted) return;
      final map = _asMap(res);
      if (map['ok'] != true) {
        setState(() => _bcStep = _BcStep.previewing);
        showToast(context, _str(map, 'message').isNotEmpty ? _str(map, 'message') : _str(map, 'error'),
            isError: true, duration: const Duration(seconds: 6));
        return;
      }
      setState(() { _bcApply = map; _bcStep = _BcStep.done; });
      RenderLog.write('c623_barcode_apply', _str(map, 'title'));
      if (_bcMode == 'order') await _bcLoadTargets();   // D3
    } catch (e) {
      if (!mounted) return;
      setState(() => _bcStep = _BcStep.previewing);
      showToast(context, e.toString().replaceFirst('Exception: ', ''), isError: true, duration: const Duration(seconds: 6));
    }
  }

  // ── F — one barcode, by hand ──────────────────────────────────────────────

  /// Reads the product's current barcode through the preview RPC (a zero-row
  /// write, read-only) rather than touching the table directly.
  Future<String> _bcCurrentBarcode(int productId) async {
    try {
      final res = await Supabase.instance.client.rpc('barcode_import_preview', params: {
        'p_rows': [{'product_id': '$productId', 'name': '', 'barcode': ''}],
        'p_mode': 'item',
        'p_date': null,
        'p_supplier': null,
      });
      final map = _asMap(res);
      final rows = map['rows'] as List<dynamic>? ?? const [];
      if (rows.isEmpty) return '';
      return (Map<String, dynamic>.from(rows.first as Map)['current_barcode'] ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _showBarcodeEditor({
    required int productId,
    required String productName,
    required String packLabel,
    String? currentBarcode,
  }) async {
    final current = currentBarcode ?? await _bcCurrentBarcode(productId);
    if (!mounted) return;
    final ctrl = TextEditingController(text: current);
    String err = '';
    bool saving = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => StatefulBuilder(builder: (dctx, setD) {
        Future<void> save() async {
          final nav = Navigator.of(dctx);   // captured before the await
          setD(() { saving = true; err = ''; });
          try {
            final res = await Supabase.instance.client.rpc('medicine_set_barcode', params: {
              'p_product_id': productId,
              'p_barcode': ctrl.text.trim(),
            });
            final map = _asMap(res);
            if (map['ok'] == true) {
              nav.pop();
              if (mounted) showToast(context, _str(map, 'message'));
              RenderLog.write('c623_barcode_manual', 'ok');
              if (_bcMode == 'order' && _bcStep != _BcStep.none) await _bcLoadTargets();
            } else {
              // F2 — barcode_taken: show the backend's message, do not save.
              setD(() {
                saving = false;
                err = _str(map, 'message').isNotEmpty ? _str(map, 'message') : _str(map, 'error');
              });
            }
          } catch (e) {
            setD(() { saving = false; err = e.toString().replaceFirst('Exception: ', ''); });
          }
        }

        return AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(productName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            if (packLabel.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(packLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w400, color: Color(0xFF6B7280))),
            ],
          ]),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                enabled: !saving,
                keyboardType: TextInputType.text,
                decoration: InputDecoration(
                  labelText: 'Barcode',
                  hintText: 'Leave empty to clear',
                  hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
                  filled: true,
                  fillColor: const Color(0xFFF5F6F8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                ),
                style: const TextStyle(fontSize: 15, color: Color(0xFF111827)),
              ),
              if (err.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: const Color(0xFFFEE2E2), borderRadius: BorderRadius.circular(8)),
                  child: Text(err, style: const TextStyle(fontSize: 13, color: Color(0xFF991B1B), height: 1.4)),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(dctx).pop(),
              child: const Text('Cancel', style: TextStyle(color: Color(0xFF6B7280), fontWeight: FontWeight.w600)),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: saving
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      }),
    );
    ctrl.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, c) {
      final isDesktop = c.maxWidth >= 768;
      if (_bcStep != _BcStep.none) {
        return switch (_bcStep) {
          _BcStep.setup      => _bcBuildSetup(isDesktop),
          _BcStep.busy       => _bcBuildLoading(),
          _BcStep.mapping    => _bcBuildMapping(isDesktop),
          _BcStep.previewing => _bcBuildPreview(isDesktop),
          _BcStep.done       => _bcBuildDone(),
          _BcStep.none       => const SizedBox.shrink(),
        };
      }
      return switch (_step) {
        _ImpStep.idle                                          => _buildIdle(isDesktop),
        _ImpStep.parsing || _ImpStep.geminiCols || _ImpStep.writing => _buildLoading(),
        _ImpStep.matching                                      => _buildMatchProgress(),
        _ImpStep.mapping                                       => _buildMapping(isDesktop),
        _ImpStep.reviewing                                     => _buildReview(isDesktop),
        _ImpStep.done                                          => _buildDone(),
      };
    });
  }

  // ── Idle ──────────────────────────────────────────────────────────────────────

  Widget _buildIdle(bool isDesktop) {
    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: isDesktop ? 32 : 20, vertical: 32),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Builder(builder: (_) {
                RenderLog.write('titles_removed_addmedicine', 'true');
                RenderLog.write('c623_barcode_import', 'cards=2');
                return const SizedBox(height: 8);
              }),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(28),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(width: 44, height: 44,
                        decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.upload_file, color: Color(0xFF1B7A43), size: 22)),
                    const SizedBox(width: 14),
                    const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Import medicine', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                      SizedBox(height: 2),
                      Text('Gemini auto-maps columns — you confirm before anything writes',
                          style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                    ])),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(child: _InfoTile(icon: Icons.table_chart_outlined, label: 'Files', sub: 'CSV · Excel · ODS · PDF · DOCX · TXT')),
                    const SizedBox(width: 12),
                    Expanded(child: _InfoTile(icon: Icons.photo_camera_outlined, label: 'Photos', sub: 'JPG · PNG · WEBP — Gemini reads the table')),
                  ]),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: const Color(0xFFFFF7ED), borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFED7AA))),
                    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.info_outline, size: 15, color: Color(0xFFEA580C)),
                      SizedBox(width: 8),
                      Expanded(child: Text(
                        'Matched rows → UPDATE existing medicine (company/marketer never overwritten)\n'
                        'Unrecognized rows → INSERT new medicine (status: Available)',
                        style: TextStyle(fontSize: 12, color: Color(0xFF9A3412), height: 1.5),
                      )),
                    ]),
                  ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity, height: 48,
                    child: FilledButton.icon(
                      onPressed: _pickFile,
                      icon: const Icon(Icons.upload_rounded, size: 18),
                      label: const Text('Import medicine', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),
              _bcBuildImportCard(),
              const SizedBox(height: 24),
              _bcBuildManualCard(),
            ]),
          ),
        ),
      ),
    );
  }

  // ── A2 — the second card: Import barcode ──────────────────────────────────

  Widget _bcBuildImportCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 44, height: 44,
              decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.qr_code_2, color: Color(0xFF1E40AF), size: 22)),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Import barcode', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            SizedBox(height: 2),
            Text('Same file types, same column mapping — barcodes only',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ])),
        ]),
        const SizedBox(height: 20),
        LayoutBuilder(builder: (ctx, bc) {
          final stacked = bc.maxWidth < 520;
          final itemBtn = _BcModeButton(
            icon: Icons.inventory_2_outlined,
            label: 'Item wise',
            sub: 'Match against the whole catalogue',
            onTap: () => _bcStart('item'),
          );
          final orderBtn = _BcModeButton(
            icon: Icons.event_note_outlined,
            label: 'Order wise',
            sub: 'Match only items ordered on a date',
            onTap: () => _bcStart('order'),
          );
          if (stacked) {
            return Column(children: [itemBtn, const SizedBox(height: 12), orderBtn]);
          }
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: itemBtn),
            const SizedBox(width: 12),
            Expanded(child: orderBtn),
          ]);
        }),
      ]),
    );
  }

  // ── F1 — set one barcode by hand ──────────────────────────────────────────

  Widget _bcBuildManualCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 3))],
      ),
      padding: const EdgeInsets.all(28),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 44, height: 44,
              decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.edit_outlined, color: Color(0xFF374151), size: 22)),
          const SizedBox(width: 14),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Barcode', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            SizedBox(height: 2),
            Text('Find a medicine and set or clear its barcode',
                style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ])),
        ]),
        const SizedBox(height: 20),
        _BarcodeQuickSet(
          onPick: (p) => _showBarcodeEditor(
            productId: p.productId,
            productName: p.productName,
            packLabel: p.packLabel,
          ),
        ),
      ]),
    );
  }

  // ── Barcode: mode setup (+ order-wise helper list) ────────────────────────

  Widget _bcBuildSetup(bool isDesktop) {
    final isOrder = _bcMode == 'order';
    final rows = (_bcTargets?['rows'] as List<dynamic>? ?? const []);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _StageHeader(
        title: isOrder ? 'Import barcode — Order wise' : 'Import barcode — Item wise',
        subtitle: isOrder
            ? 'Only items ordered on the chosen date are matched'
            : 'Rows are matched against the whole catalogue',
        onBack: _bcExit,
        action: FilledButton.icon(
          onPressed: _bcPickFile,
          icon: const Icon(Icons.upload_rounded, size: 16),
          label: const Text('Choose file', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
        ),
      ),
      Expanded(child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 16, vertical: 20),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (isOrder) ...[
              Container(
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB))),
                padding: const EdgeInsets.all(16),
                child: Row(children: [
                  const Icon(Icons.calendar_today_outlined, size: 18, color: Color(0xFF6B7280)),
                  const SizedBox(width: 10),
                  Expanded(child: Text(_isoDate(_bcDate),
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827)))),
                  TextButton(
                    onPressed: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _bcDate,
                        firstDate: DateTime(2024, 1, 1),
                        lastDate: DateTime.now().add(const Duration(days: 1)),
                      );
                      if (picked != null) {
                        setState(() => _bcDate = picked);
                        await _bcLoadTargets();
                      }
                    },
                    child: const Text('Change', style: TextStyle(color: Color(0xFF1B7A43), fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
              const SizedBox(height: 16),
              if (_bcTargetsLoading)
                const Padding(padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: SizedBox(width: 28, height: 28,
                        child: CircularProgressIndicator(strokeWidth: 3, color: Color(0xFF1B7A43)))))
              else if (_bcTargets != null) ...[
                Container(
                  decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE5E7EB))),
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      // E1 — title and note are the backend's strings.
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(_str(_bcTargets, 'title'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                        const SizedBox(height: 2),
                        Text(_str(_bcTargets, 'note'),
                            style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
                      ])),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: rows.isEmpty ? null : _bcShareTargets,
                        icon: const Icon(Icons.ios_share, size: 16),
                        label: const Text('Share list', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1B7A43),
                          side: const BorderSide(color: Color(0xFF1B7A43)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ]),
                    if (rows.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      const Divider(height: 1, color: Color(0xFFE5E7EB)),
                      for (final r in rows) _bcTargetRow(Map<String, dynamic>.from(r as Map)),
                    ],
                  ]),
                ),
              ],
              const SizedBox(height: 20),
            ],
            SizedBox(height: 48, child: FilledButton.icon(
              onPressed: _bcPickFile,
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('Choose file', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            )),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: _InfoTile(icon: Icons.table_chart_outlined, label: 'Files', sub: 'CSV · Excel · ODS · PDF · DOCX · TXT')),
              const SizedBox(width: 12),
              Expanded(child: _InfoTile(icon: Icons.photo_camera_outlined, label: 'Photos', sub: 'JPG · PNG · WEBP — Gemini reads the table')),
            ]),
          ]),
        )),
      )),
    ]);
  }

  Widget _bcTargetRow(Map<String, dynamic> m) {
    final img = _str(m, 'image_url');
    final has = m['has_barcode'] == true;
    final pid = int.tryParse(_str(m, 'product_id'));
    return InkWell(
      onTap: pid == null ? null : () => _showBarcodeEditor(
        productId: pid,
        productName: _str(m, 'product_name'),
        packLabel: _str(m, 'pack_label'),
        currentBarcode: _str(m, 'current_barcode'),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
            clipBehavior: Clip.antiAlias,
            child: img.isEmpty
                ? const Icon(Icons.medication_outlined, size: 18, color: Color(0xFF9CA3AF))
                : Image.network(img, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Icon(Icons.medication_outlined, size: 18, color: Color(0xFF9CA3AF))),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_str(m, 'product_name'),
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              [_str(m, 'pack_label'), _str(m, 'company'), _str(m, 'suppliers')]
                  .where((s) => s.isNotEmpty).join(' · '),
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
              maxLines: 1, overflow: TextOverflow.ellipsis,
            ),
          ])),
          const SizedBox(width: 10),
          Text(_str(m, 'ordered_qty'),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(width: 12),
          Icon(has ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18, color: has ? const Color(0xFF1B7A43) : const Color(0xFFD1D5DB)),
        ]),
      ),
    );
  }

  Widget _bcBuildLoading() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 3)),
        const SizedBox(height: 18),
        Text(_bcStatusMsg, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]),
    );
  }

  // ── B2 — confirm the mapping (same step, two fields) ──────────────────────

  Widget _bcBuildMapping(bool isDesktop) {
    final items = <DropdownMenuItem<String>>[
      ..._kBcCols.map((c) => DropdownMenuItem(value: c, child: Text(_colLabel(c), style: const TextStyle(fontSize: 13)))),
      const DropdownMenuItem(value: 'ignore', child: Text('— Ignore —', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _StageHeader(
        title: 'Confirm columns',
        subtitle: 'Map the product and the barcode — everything else can be ignored',
        onBack: () => setState(() => _bcStep = _BcStep.setup),
        action: FilledButton(
          onPressed: _bcConfirmMapping,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Confirm & Check →', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ),
      Expanded(child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 12, vertical: 20),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 920),
          child: LayoutBuilder(builder: (ctx, bc) {
            final isMobile = bc.maxWidth < 600;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!isMobile)
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6), child: Row(children: const [
                  Expanded(flex: 4, child: Text('FILE COLUMN', style: _kTh)),
                  Expanded(flex: 6, child: Text('SAMPLE VALUES', style: _kTh)),
                  Expanded(flex: 5, child: Text('MAPS TO', style: _kTh)),
                ])),
              if (!isMobile) const Divider(color: Color(0xFFE5E7EB)),
              for (int i = 0; i < _bcCols.length; i++) ...[
                _buildColRow(_bcCols[i], isMobile: isMobile, itemsOverride: items),
                if (!isMobile) const Divider(height: 1, color: Color(0xFFF3F4F6)),
                if (isMobile) const SizedBox(height: 8),
              ],
              const SizedBox(height: 24),
              SizedBox(width: double.infinity, height: 48, child: FilledButton(
                onPressed: _bcConfirmMapping,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Confirm Mapping & Check Rows', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
              )),
            ]);
          }))),
      )),
    ]);
  }

  // ── C — preview, rendered verbatim ────────────────────────────────────────

  Widget _bcBuildPreview(bool isDesktop) {
    final p = _bcPreview;
    final rows = (p?['rows'] as List<dynamic>? ?? const []);
    final canApply = p?['can_apply'] == true;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _StageHeader(
        // C2 — header IS summary_label; nothing counted here.
        title: _str(p, 'summary_label'),
        subtitle: 'Rows that will not be written are listed below with the reason',
        onBack: () => setState(() => _bcStep = _BcStep.mapping),
        action: FilledButton(
          onPressed: canApply ? _bcApplyNow : null,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          // C2 — button label IS apply_label.
          child: Text(_str(p, 'apply_label'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ),
      const Divider(height: 1, color: Color(0xFFE5E7EB)),
      Expanded(child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 12, vertical: 16),
        child: Center(child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: Container(
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))]),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            // C4 — given order, no filtering, no sorting.
            child: Column(children: [
              for (int i = 0; i < rows.length; i++)
                _bcPreviewRow(Map<String, dynamic>.from(rows[i] as Map), last: i == rows.length - 1),
            ]),
          ),
        )),
      )),
      SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(height: 48, child: FilledButton(
          onPressed: canApply ? _bcApplyNow : null,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
          child: Text(_str(p, 'apply_label'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        )),
      )),
    ]);
  }

  Widget _bcPreviewRow(Map<String, dynamic> m, {required bool last}) {
    // C3 — will_import decides emphasis; the chip's words and colours are the
    // backend's (status_label + status_colors).
    final willImport = m['will_import'] == true;
    final colors = Map<String, dynamic>.from((m['status_colors'] as Map?) ?? const {});
    final bg = _hex(colors['bg'] as String?, const Color(0xFFF3F4F6));
    final fg = _hex(colors['fg'] as String?, const Color(0xFF6B7280));
    final img = _str(m, 'image_url');
    final productName = _str(m, 'product_name');
    final currentBc = _str(m, 'current_barcode');

    return Opacity(
      opacity: willImport ? 1.0 : 0.55,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 44, height: 44,
              decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8)),
              clipBehavior: Clip.antiAlias,
              child: img.isEmpty
                  ? const Icon(Icons.medication_outlined, size: 18, color: Color(0xFF9CA3AF))
                  : Image.network(img, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.medication_outlined, size: 18, color: Color(0xFF9CA3AF))),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_str(m, 'input_name'),
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              if (productName.isNotEmpty) ...[
                const SizedBox(height: 3),
                Row(children: [
                  const Icon(Icons.subdirectory_arrow_right, size: 13, color: Color(0xFF9CA3AF)),
                  const SizedBox(width: 4),
                  Expanded(child: Text(productName,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF374151)),
                      maxLines: 1, overflow: TextOverflow.ellipsis)),
                ]),
              ],
              const SizedBox(height: 3),
              Text(
                [_str(m, 'pack_label'), _str(m, 'company')].where((s) => s.isNotEmpty).join(' · '),
                style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                maxLines: 1, overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(_str(m, 'barcode'),
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                        color: Color(0xFF111827), fontFeatures: [FontFeature.tabularFigures()])),
                if (currentBc.isNotEmpty)
                  Text('was $currentBc',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF),
                          decoration: TextDecoration.lineThrough)),
              ]),
            ])),
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
              child: Text(_str(m, 'status_label'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: fg)),
            ),
          ]),
        ),
        if (!last) const Divider(height: 1, color: Color(0xFFF3F4F6)),
      ]),
    );
  }

  // ── D2 — result ───────────────────────────────────────────────────────────

  Widget _bcBuildDone() {
    return Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(padding: const EdgeInsets.all(32), child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB))),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 68, height: 68,
              decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(18)),
              child: const Icon(Icons.check_circle_outline, color: Color(0xFF1B7A43), size: 38)),
          const SizedBox(height: 18),
          Text(_str(_bcApply, 'title'), textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
          const SizedBox(height: 8),
          Text(_str(_bcApply, 'note'), textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
          const SizedBox(height: 28),
          SizedBox(width: double.infinity, height: 48, child: FilledButton(
            onPressed: () => setState(() {
              _bcStep = _BcStep.setup;
              _bcPreview = null;
              _bcApply = null;
              _bcCols = [];
              _bcRawRows = [];
              _bcRows = [];
            }),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Import Another File', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          )),
          const SizedBox(height: 10),
          SizedBox(width: double.infinity, height: 44, child: TextButton(
            onPressed: _bcExit,
            child: const Text('Back to Add Medicine',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: Color(0xFF6B7280))),
          )),
        ]),
      )),
    ));
  }

  // ── Loading ───────────────────────────────────────────────────────────────────

  Widget _buildLoading() {
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(width: 40, height: 40, child: CircularProgressIndicator(color: Color(0xFF1B7A43), strokeWidth: 3)),
        const SizedBox(height: 18),
        Text(_statusMsg, style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280))),
      ]),
    );
  }

  // ── Match progress ────────────────────────────────────────────────────────────

  Widget _buildMatchProgress() {
    final pct = _matchTotal > 0 ? _matchProgress / _matchTotal : 0.0;
    return Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Matching medicines…', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
        const SizedBox(height: 8),
        Text('$_matchProgress of $_matchTotal rows', style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280))),
        const SizedBox(height: 22),
        ClipRRect(borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: pct, minHeight: 6, color: const Color(0xFF1B7A43), backgroundColor: const Color(0xFFE5E7EB))),
      ])),
    ));
  }

  // ── Column mapping UI (Stage 1) ───────────────────────────────────────────────

  Widget _buildMapping(bool isDesktop) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _StageHeader(
        title: 'Stage 1 — Column Mapping',
        subtitle: 'Confirm how each uploaded column maps to the medicine database',
        onBack: widget.preloadedBytes != null
            ? () => Navigator.of(context).maybePop()
            : () => setState(() => _step = _ImpStep.idle),
        action: FilledButton(
          onPressed: _confirmMapping,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
          child: const Text('Confirm & Match →', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ),
      Expanded(child: SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: isDesktop ? 24 : 12, vertical: 20),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 920), child: LayoutBuilder(builder: (ctx, bc) {
          final isMobile = bc.maxWidth < 600;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Column headers — desktop only
          if (!isMobile)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6), child: Row(children: const [
              Expanded(flex: 4, child: Text('FILE COLUMN', style: _kTh)),
              Expanded(flex: 6, child: Text('SAMPLE VALUES', style: _kTh)),
              Expanded(flex: 5, child: Text('MAPS TO', style: _kTh)),
            ])),
          if (!isMobile) const Divider(color: Color(0xFFE5E7EB)),
          for (int i = 0; i < _cols.length; i++) ...[
            _buildColRow(_cols[i], isMobile: isMobile),
            if (!isMobile) const Divider(height: 1, color: Color(0xFFF3F4F6)),
            if (isMobile) const SizedBox(height: 8),
          ],
          const SizedBox(height: 24),
          SizedBox(width: double.infinity, height: 48, child: FilledButton(
            onPressed: _confirmMapping,
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Confirm Mapping & Start Matching', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
          )),
        ]); }))),
      )),
    ]);
  }

  /// [itemsOverride] lets the barcode import reuse this exact row with its own
  /// (much shorter) field list — CHANGE #623.
  Widget _buildColRow(_ImpCol col, {bool isMobile = false, List<DropdownMenuItem<String>>? itemsOverride}) {
    final ctrl = _newColCtrls[col.fileIndex] ??= TextEditingController();
    final isCreate = col.mappedTo == 'create_new';
    final items = itemsOverride ?? <DropdownMenuItem<String>>[
      ..._kMedCols.map((c) => DropdownMenuItem(value: c, child: Text(_colLabel(c), style: const TextStyle(fontSize: 13)))),
      const DropdownMenuItem(value: 'ignore', child: Text('— Ignore —', style: TextStyle(fontSize: 13, color: Color(0xFF9CA3AF)))),
      const DropdownMenuItem(value: 'create_new', child: Text('Create new column…', style: TextStyle(fontSize: 13, color: Color(0xFF1B7A43)))),
    ];

    if (isMobile) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              col.header.isNotEmpty ? col.header : 'Column ${col.fileIndex + 1}',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                  color: col.header.isNotEmpty ? const Color(0xFF111827) : const Color(0xFF9CA3AF)),
            ),
            if (col.samples.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(col.samples.take(3).join(' · '),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: col.mappedTo,
              isExpanded: true,
              decoration: InputDecoration(isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                filled: true, fillColor: Colors.white,
              ),
              items: items,
              onChanged: (v) { if (v != null) setState(() { col.mappedTo = v; }); },
              style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
            ),
            if (isCreate) ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: ctrl,
                onChanged: (v) => col.newColName = v,
                decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                  hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                  enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                  filled: true, fillColor: const Color(0xFFECFDF5),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ]),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(flex: 4, child: Text(
            col.header.isNotEmpty ? '"${col.header}"' : 'Column ${col.fileIndex + 1}',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                color: col.header.isNotEmpty ? const Color(0xFF111827) : const Color(0xFF9CA3AF)),
            overflow: TextOverflow.ellipsis,
          )),
          Expanded(flex: 6, child: Text(col.samples.take(3).join(' · '),
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)), overflow: TextOverflow.ellipsis)),
          Expanded(flex: 5, child: DropdownButtonFormField<String>(
            value: col.mappedTo,
            decoration: InputDecoration(isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
              filled: true, fillColor: Colors.white,
            ),
            items: items,
            onChanged: (v) { if (v != null) setState(() { col.mappedTo = v; }); },
            style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
          )),
        ]),
        if (isCreate) ...[
          const SizedBox(height: 10),
          Row(children: [
            const SizedBox(width: 12),
            const Icon(Icons.subdirectory_arrow_right, size: 16, color: Color(0xFF9CA3AF)),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: TextFormField(
              controller: ctrl,
              onChanged: (v) => col.newColName = v,
              decoration: InputDecoration(isDense: true, hintText: 'new_column_name',
                hintStyle: const TextStyle(color: Color(0xFFD1D5DB)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                filled: true, fillColor: const Color(0xFFECFDF5),
              ),
              style: const TextStyle(fontSize: 13),
            )),
            const SizedBox(width: 10),
            const Text('Type:', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
            const SizedBox(width: 6),
            Expanded(flex: 2, child: DropdownButtonFormField<String>(
              value: col.newColType,
              decoration: InputDecoration(isDense: true,
                contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
                filled: true, fillColor: const Color(0xFFECFDF5),
              ),
              items: const [
                DropdownMenuItem(value: 'text', child: Text('text', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'numeric', child: Text('number', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'date', child: Text('date', style: TextStyle(fontSize: 13))),
                DropdownMenuItem(value: 'boolean', child: Text('boolean', style: TextStyle(fontSize: 13))),
              ],
              onChanged: (v) { if (v != null) setState(() => col.newColType = v); },
              style: const TextStyle(fontSize: 13, color: Color(0xFF111827)),
            )),
          ]),
        ],
      ]),
    );
  }

  String _colLabel(String col) => switch (col) {
    'product_name'      => 'product_name (medicine name)',
    'salt_composition'  => 'salt_composition (generic)',
    'marketer'          => 'marketer (company)',
    'mrp'               => 'mrp (price ₹)',
    'barcode'           => 'barcode (EAN / UPC)',
    'product_id'        => 'product_id (catalogue id)',
    'pack_qty'          => 'pack_qty (pack quantity)',
    'pack_size'         => 'pack_size',
    'pack_type'         => 'pack_type',
    'therapeutic_class' => 'therapeutic_class',
    'rx_required'       => 'rx_required',
    'status'            => 'status',
    _                   => col,
  };

  // ── Review UI (Stage 2) ───────────────────────────────────────────────────────

  Widget _buildReview(bool isDesktop) {
    final matched  = _rows.where((r) => !r.isHidden && r.status == _MsStatus.matched).length;
    final manual   = _rows.where((r) => !r.isHidden && r.status == _MsStatus.manuallyMatched).length;
    final partial  = _rows.where((r) => !r.isHidden && r.status == _MsStatus.partial).length;
    final unrec    = _rows.where((r) => !r.isHidden && r.status == _MsStatus.unrecognized).length;
    final approved = _rows.where((r) => !r.isHidden && r.isApproved).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(color: Colors.white,
        padding: const EdgeInsets.fromLTRB(20, 12, 16, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            IconButton(
              icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Color(0xFF374151)),
              onPressed: () => setState(() => _step = _ImpStep.mapping),
              tooltip: 'Back to column mapping',
            ),
            const SizedBox(width: 6),
            const Text('Stage 2 — Smart Match Preview',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
            const SizedBox(width: 10),
            Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
                child: Text('${_rows.length} rows', style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)))),
            const Spacer(),
            if (_isRetrying)
              SizedBox(width: 32, height: 32, child: Padding(padding: const EdgeInsets.all(6),
                  child: CircularProgressIndicator(value: _retryProgress, strokeWidth: 2.5,
                      color: const Color(0xFF6B7280), backgroundColor: const Color(0xFFE5E7EB))))
            else
              IconButton(icon: const Icon(Icons.refresh, size: 20), onPressed: _retryAll,
                  tooltip: 'Re-match all', color: const Color(0xFF6B7280)),
            const SizedBox(width: 6),
            FilledButton(
              onPressed: approved > 0 ? _doWrite : null,
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
              child: Text('Import $approved approved', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
          ]),
          const SizedBox(height: 4),
          Padding(padding: const EdgeInsets.only(left: 44),
              child: Text('$matched matched · $manual manually matched · $partial partial · $unrec unrecognized',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
        ]),
      ),
      const Divider(height: 1, color: Color(0xFFE5E7EB)),
      Expanded(child: isDesktop ? _buildDesktopList() : _buildMobileList()),
    ]);
  }

  Widget _buildDesktopList() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Center(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 8, offset: const Offset(0, 2))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 12, 12, 12), child: Row(children: const [
              Expanded(flex: 18, child: Text('LINE ITEM', style: _kTh)),
              Expanded(flex: 20, child: Text('MATCHED SKU', style: _kTh)),
              Expanded(flex: 8,  child: Text('PACK', style: _kTh)),
              Expanded(flex: 12, child: Text('COMPANY', style: _kTh)),
              Expanded(flex: 9,  child: Text('MRP', style: _kTh)),
              Expanded(flex: 8,  child: Text('STATUS', style: _kTh)),
              SizedBox(width: 36, child: Text('HIDE', style: _kTh)),
              SizedBox(width: 36, child: Text('✓', style: _kTh, textAlign: TextAlign.center)),
            ])),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            for (int i = 0; i < _rows.length; i++)
              _ImportDesktopRow(
                key: ValueKey('d-$i'),
                row: _rows[i], index: i, last: i == _rows.length - 1,
                isExpanded: _expandedRow == i,
                onToggle: () => setState(() => _expandedRow = _expandedRow == i ? -1 : i),
                onRowChanged: () => setState(() {}),
                onHideToggle: () => setState(() {
                  if (_expandedRow == i) _expandedRow = -1;
                  _rows[i].isHidden ? _rows[i].unhide() : _rows[i].hide();
                }),
                onRowRetry: (p) => _retryRow(i, p),
                onSearchSelect: (p) => _onSearchSelect(i, p),
              ),
          ]),
        ),
      )),
    );
  }

  Widget _buildMobileList() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
      child: Column(children: [
        for (int i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _ImportMobileCard(
              key: ValueKey('m-$i'),
              row: _rows[i], index: i,
              isExpanded: _expandedRow == i,
              onToggle: () => setState(() => _expandedRow = _expandedRow == i ? -1 : i),
              onRowChanged: () => setState(() {}),
              onHideToggle: () => setState(() {
                if (_expandedRow == i) _expandedRow = -1;
                _rows[i].isHidden ? _rows[i].unhide() : _rows[i].hide();
              }),
              onRowRetry: (p) => _retryRow(i, p),
              onSearchSelect: (p) => _onSearchSelect(i, p),
            ),
          ),
      ]),
    );
  }

  // ── Done ──────────────────────────────────────────────────────────────────────

  Widget _buildDone() {
    return Center(child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(padding: const EdgeInsets.all(32), child: Container(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFFE5E7EB))),
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 68, height: 68,
              decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(18)),
              child: const Icon(Icons.check_circle_outline, color: Color(0xFF1B7A43), size: 38)),
          const SizedBox(height: 18),
          const Text('Import Complete', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF111827))),
          const SizedBox(height: 24),
          _SumRow(icon: Icons.edit_outlined, color: const Color(0xFF3B82F6), label: 'Updated', count: _updatedCount),
          const SizedBox(height: 10),
          _SumRow(icon: Icons.add_circle_outline, color: const Color(0xFF1B7A43), label: 'Inserted', count: _insertedCount),
          const SizedBox(height: 10),
          _SumRow(icon: Icons.remove_circle_outline, color: const Color(0xFF9CA3AF), label: 'Skipped', count: _skippedCount),
          const SizedBox(height: 28),
          if (widget.onImportComplete != null)
            SizedBox(width: double.infinity, height: 48, child: FilledButton(
              onPressed: () { widget.onImportComplete!(); Navigator.of(context).pop(); },
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Mark as Imported & Go Back', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            ))
          else
            SizedBox(width: double.infinity, height: 48, child: FilledButton(
              onPressed: () => setState(() => _step = _ImpStep.idle),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1B7A43),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Import Another File', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            )),
        ]),
      )),
    ));
  }
}

// ─── Stage header ─────────────────────────────────────────────────────────────

class _StageHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onBack;
  final Widget action;
  const _StageHeader({required this.title, required this.subtitle, required this.onBack, required this.action});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Color(0xFF374151)), onPressed: onBack),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
          const SizedBox(height: 2),
          Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
        ])),
        const SizedBox(width: 12),
        action,
      ]),
    );
  }
}

// ─── Desktop match row ────────────────────────────────────────────────────────

class _ImportDesktopRow extends StatefulWidget {
  final _MRow row;
  final int index;
  final bool last;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;
  final VoidCallback onHideToggle;
  final Future<void> Function(void Function(double)) onRowRetry;
  final ValueChanged<Product> onSearchSelect;

  const _ImportDesktopRow({
    super.key,
    required this.row, required this.index, required this.last,
    required this.isExpanded, required this.onToggle,
    required this.onRowChanged, required this.onHideToggle,
    required this.onRowRetry, required this.onSearchSelect,
  });

  @override
  State<_ImportDesktopRow> createState() => _ImportDesktopRowState();
}

class _ImportDesktopRowState extends State<_ImportDesktopRow> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _retrying = false;
  double _retryP = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 250), value: widget.isExpanded ? 1.0 : 0.0);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_ImportDesktopRow old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) widget.isExpanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _doRetry() async {
    if (_retrying) return;
    setState(() { _retrying = true; _retryP = 0.0; });
    try {
      await widget.onRowRetry((p) { if (mounted) setState(() => _retryP = p); });
      if (mounted) await Future.delayed(const Duration(milliseconds: 400));
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
    widget.onRowChanged();
  }

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MsStatus.unrecognized) return;
    setState(() {
      if (row.status == _MsStatus.matched) row.status = _MsStatus.partial;
      else if (row.status == _MsStatus.partial) row.status = _MsStatus.manuallyMatched;
      else if (row.status == _MsStatus.manuallyMatched) row.status = _MsStatus.partial;
    });
    widget.onRowChanged();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final isEven = widget.index % 2 == 0;
    final p = row.selectedProduct;
    final isApproved = row.isApproved;

    Color badgeColor, badgeText, borderColor;
    String label;
    if (row.isHidden) {
      badgeColor = const Color(0xFFF3F4F6); badgeText = const Color(0xFF9CA3AF); borderColor = const Color(0xFFD1D5DB); label = 'Hidden';
    } else switch (row.status) {
      case _MsStatus.matched:
        badgeColor = const Color(0xFFDCFCE7); badgeText = const Color(0xFF15803D); borderColor = const Color(0xFF15803D); label = 'Matched';
      case _MsStatus.manuallyMatched:
        badgeColor = const Color(0xFFE0E7FF); badgeText = const Color(0xFF3730A3); borderColor = const Color(0xFF3730A3); label = 'Manually Matched';
      case _MsStatus.partial:
        badgeColor = const Color(0xFFFEF3C7); badgeText = const Color(0xFF92400E); borderColor = const Color(0xFFEA580C); label = 'Partial';
      case _MsStatus.unrecognized:
        badgeColor = const Color(0xFFFEE2E2); badgeText = const Color(0xFFDC2626); borderColor = const Color(0xFFDC2626); label = 'Unrecognized';
    }

    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    return Opacity(
      opacity: row.isHidden ? 0.45 : 1.0,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        GestureDetector(
          onTap: row.candidates.isNotEmpty && !row.isHidden ? widget.onToggle : null,
          child: Container(
            decoration: BoxDecoration(
              color: isEven ? Colors.white : const Color(0xFFFAFAFA),
              border: Border(
                left: BorderSide(color: borderColor, width: 3),
                bottom: (!widget.last || widget.isExpanded) ? const BorderSide(color: Color(0xFFEEEEEE)) : BorderSide.none,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(17, 11, 12, 11),
            child: Row(children: [
              Expanded(flex: 18, child: Text(row.lineItem, maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827)))),
              Expanded(flex: 20, child: Text(
                p?.name ?? (row.status != _MsStatus.unrecognized ? row.lineItem : '—'),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, fontWeight: p != null ? FontWeight.w600 : FontWeight.normal,
                    color: p != null ? const Color(0xFF111827) : const Color(0xFF9CA3AF)),
              )),
              Expanded(flex: 8, child: Text(p != null ? _iPackShort(p) : '', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
              Expanded(flex: 12, child: Text(p?.manufacturer ?? '', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
              Expanded(flex: 9, child: Text(p != null ? p.mrpText : '', textAlign: TextAlign.right,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF111827)))),
              Expanded(flex: 8, child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(20)),
                child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: badgeText)),
              )),
              SizedBox(width: 36, child: IconButton(
                icon: Icon(row.isHidden ? Icons.visibility_off : Icons.visibility,
                    size: 16, color: row.isHidden ? const Color(0xFF9CA3AF) : const Color(0xFF6B7280)),
                onPressed: widget.onHideToggle, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
              )),
              SizedBox(width: 36, child: GestureDetector(
                onTap: row.status != _MsStatus.unrecognized ? _toggleApproval : null,
                child: Container(
                  width: 20, height: 20, margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: isApproved ? borderColor : Colors.white,
                    border: Border.all(color: isApproved ? borderColor : const Color(0xFFD1D5DB), width: 1.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: isApproved ? const Icon(Icons.check, size: 13, color: Colors.white) : null,
                ),
              )),
            ]),
          ),
        ),
        SizeTransition(sizeFactor: _anim, child: Container(
          color: const Color(0xFFF9FAFB),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Alternates
            for (int k = 0; k < alts.length; k++)
              _AltRowDesktop(
                product: alts[k].$2, origIndex: alts[k].$1,
                isSelected: row.selectedIndex == alts[k].$1,
                isLast: k == alts.length - 1 && widget.isExpanded,
                onTap: () {
                  setState(() { row.selectedIndex = alts[k].$1; row.status = _MsStatus.manuallyMatched; });
                  widget.onRowChanged();
                },
              ),
            // Retry + search
            Padding(
              padding: const EdgeInsets.fromLTRB(17, 8, 12, 12),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _RetryBtn(retrying: _retrying, progress: _retryP, onRetry: _doRetry),
                const SizedBox(width: 16),
                Expanded(child: _SearchPanel(onSelect: widget.onSearchSelect)),
              ]),
            ),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
          ]),
        )),
      ]),
    );
  }
}

// ─── Desktop alt row ──────────────────────────────────────────────────────────

class _AltRowDesktop extends StatelessWidget {
  final Product product;
  final int origIndex;
  final bool isSelected;
  final bool isLast;
  final VoidCallback onTap;
  const _AltRowDesktop({required this.product, required this.origIndex, required this.isSelected, required this.isLast, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final nameColor = isSelected ? const Color(0xFF1B7A43) : const Color(0xFF374151);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(17, 8, 12, 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: isLast ? null : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(children: [
          const Expanded(flex: 18, child: SizedBox()),
          Expanded(flex: 20, child: Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal, color: nameColor))),
          Expanded(flex: 8, child: Text(_iPackShort(product), maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280)))),
          Expanded(flex: 12, child: Text(product.manufacturer, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)))),
          Expanded(flex: 9, child: Text(product.mrpText, textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: nameColor))),
          const Expanded(flex: 8, child: SizedBox()),
          const SizedBox(width: 36),
          const SizedBox(width: 36),
        ]),
      ),
    );
  }
}

// ─── Mobile match card ────────────────────────────────────────────────────────

class _ImportMobileCard extends StatefulWidget {
  final _MRow row;
  final int index;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;
  final VoidCallback onHideToggle;
  final Future<void> Function(void Function(double)) onRowRetry;
  final ValueChanged<Product> onSearchSelect;

  const _ImportMobileCard({
    super.key,
    required this.row, required this.index,
    required this.isExpanded, required this.onToggle,
    required this.onRowChanged, required this.onHideToggle,
    required this.onRowRetry, required this.onSearchSelect,
  });

  @override
  State<_ImportMobileCard> createState() => _ImportMobileCardState();
}

class _ImportMobileCardState extends State<_ImportMobileCard> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;
  bool _retrying = false;
  double _retryP = 0.0;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 220), value: widget.isExpanded ? 1.0 : 0.0);
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_ImportMobileCard old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) widget.isExpanded ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  Future<void> _doRetry() async {
    if (_retrying) return;
    setState(() { _retrying = true; _retryP = 0.0; });
    try {
      await widget.onRowRetry((p) { if (mounted) setState(() => _retryP = p); });
      if (mounted) await Future.delayed(const Duration(milliseconds: 400));
    } finally { if (mounted) setState(() => _retrying = false); }
    widget.onRowChanged();
  }

  void _toggleApproval() {
    final row = widget.row;
    if (row.status == _MsStatus.unrecognized) return;
    setState(() {
      if (row.status == _MsStatus.matched) row.status = _MsStatus.partial;
      else if (row.status == _MsStatus.partial) row.status = _MsStatus.manuallyMatched;
      else if (row.status == _MsStatus.manuallyMatched) row.status = _MsStatus.partial;
    });
    widget.onRowChanged();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final p = row.selectedProduct;
    final isApproved = row.isApproved;

    Color badgeColor, badgeText, accentColor;
    String label;
    if (row.isHidden) {
      badgeColor = const Color(0xFFF3F4F6); badgeText = const Color(0xFF9CA3AF); accentColor = const Color(0xFFD1D5DB); label = 'Hidden';
    } else switch (row.status) {
      case _MsStatus.matched:
        badgeColor = const Color(0xFFDCFCE7); badgeText = const Color(0xFF15803D); accentColor = const Color(0xFF15803D); label = 'Matched';
      case _MsStatus.manuallyMatched:
        badgeColor = const Color(0xFFE0E7FF); badgeText = const Color(0xFF3730A3); accentColor = const Color(0xFF3730A3); label = 'Manually Matched';
      case _MsStatus.partial:
        badgeColor = const Color(0xFFFEF3C7); badgeText = const Color(0xFF92400E); accentColor = const Color(0xFFEA580C); label = 'Partial';
      case _MsStatus.unrecognized:
        badgeColor = const Color(0xFFFEE2E2); badgeText = const Color(0xFFDC2626); accentColor = const Color(0xFFDC2626); label = 'Unrecognized';
    }

    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    return Opacity(
      opacity: row.isHidden ? 0.45 : 1.0,
      child: GestureDetector(
        onTap: row.candidates.isNotEmpty && !row.isHidden ? widget.onToggle : null,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE5E7EB)),
              boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 4, offset: const Offset(0, 1))]),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                decoration: BoxDecoration(border: Border(left: BorderSide(color: accentColor, width: 3))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                    child: Row(children: [
                      Expanded(child: Text(row.lineItem, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF111827)))),
                      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(20)),
                          child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: badgeText))),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: row.status != _MsStatus.unrecognized ? _toggleApproval : null,
                        child: Container(
                          width: 22, height: 22,
                          decoration: BoxDecoration(
                            color: isApproved ? accentColor : Colors.white,
                            border: Border.all(color: isApproved ? accentColor : const Color(0xFFD1D5DB), width: 1.5),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: isApproved ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                        ),
                      ),
                    ]),
                  ),
                  if (p != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Row(children: [
                        Expanded(child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF111827)))),
                        const SizedBox(width: 8),
                        Text(_iPackShort(p), style: const TextStyle(fontSize: 11, color: Color(0xFF374151))),
                        const SizedBox(width: 8),
                        Text(p.mrpText, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: Color(0xFF111827))),
                      ]),
                    ),
                ]),
              ),
              SizeTransition(sizeFactor: _anim, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Divider(height: 1, color: Color(0xFFE5E7EB)),
                // Alternates
                LayoutBuilder(builder: (ctx, constraints) {
                  final nameW = (constraints.maxWidth - 200.0).clamp(60.0, 200.0);
                  return Column(children: [
                    for (int k = 0; k < alts.length; k++)
                      GestureDetector(
                        onTap: () {
                          setState(() { row.selectedIndex = alts[k].$1; row.status = _MsStatus.manuallyMatched; });
                          widget.onToggle(); widget.onRowChanged();
                        },
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                          decoration: BoxDecoration(
                            color: row.selectedIndex == alts[k].$1 ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
                            border: const Border(top: BorderSide(color: Color(0xFFE5E7EB))),
                          ),
                          child: Row(children: [
                            SizedBox(width: nameW, child: Text(alts[k].$2.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, fontWeight: row.selectedIndex == alts[k].$1 ? FontWeight.w600 : FontWeight.normal,
                                    color: row.selectedIndex == alts[k].$1 ? const Color(0xFF1B7A43) : const Color(0xFF374151)))),
                            const SizedBox(width: 8),
                            SizedBox(width: 44, child: Text(_iPackShort(alts[k].$2), maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Color(0xFF374151)))),
                            const SizedBox(width: 8),
                            Expanded(child: Text(alts[k].$2.manufacturer, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF)))),
                            const SizedBox(width: 8),
                            Text(alts[k].$2.mrpText, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500,
                                color: row.selectedIndex == alts[k].$1 ? const Color(0xFF1B7A43) : const Color(0xFF6B7280))),
                          ]),
                        ),
                      ),
                  ]);
                }),
                // Retry + search
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      _RetryBtn(retrying: _retrying, progress: _retryP, onRetry: _doRetry),
                      const SizedBox(width: 8),
                      const Text('Re-run matching', style: TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                    ]),
                    const SizedBox(height: 10),
                    _SearchPanel(onSelect: widget.onSearchSelect),
                  ]),
                ),
              ])),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─── Retry button ─────────────────────────────────────────────────────────────

class _RetryBtn extends StatelessWidget {
  final bool retrying;
  final double progress;
  final VoidCallback onRetry;
  const _RetryBtn({required this.retrying, required this.progress, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (retrying) {
      return SizedBox(width: 32, height: 32, child: Padding(padding: const EdgeInsets.all(6),
          child: CircularProgressIndicator(value: progress, strokeWidth: 2.5,
              color: const Color(0xFF6B7280), backgroundColor: const Color(0xFFE5E7EB))));
    }
    return IconButton(icon: const Icon(Icons.refresh, size: 18), onPressed: onRetry,
        tooltip: 'Re-run matching', color: const Color(0xFF6B7280),
        padding: EdgeInsets.zero, visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32));
  }
}

// ─── Search panel ─────────────────────────────────────────────────────────────

class _SearchPanel extends StatefulWidget {
  final ValueChanged<Product> onSelect;
  const _SearchPanel({required this.onSelect});

  @override
  State<_SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<_SearchPanel> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  List<Product> _results = [];
  bool _searching = false;

  @override
  void dispose() { _ctrl.dispose(); _debounce?.cancel(); super.dispose(); }

  void _onChanged(String v) {
    _debounce?.cancel();
    if (v.trim().length < 2) { setState(() { _results = []; _searching = false; }); return; }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v.trim()));
  }

  Future<void> _search(String query) async {
    try {
      final rows = await Supabase.instance.client.rpc('search_medicines_priority', params: {
        'search_term': query, 'category_filter': 'All', 'page_offset': 0, 'page_limit': 8,
      });
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (mounted) setState(() { _results = list.map((m) => Product.fromMap(m)).toList(); _searching = false; });
    } catch (_) {
      if (mounted) setState(() { _searching = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _ctrl,
        onChanged: _onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search all medicines…',
          hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
          prefixIcon: _searching
              ? const SizedBox(width: 20, height: 20, child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF6B7280))))
              : const Icon(Icons.search, size: 18, color: Color(0xFF9CA3AF)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF1B7A43))),
          filled: true, fillColor: Colors.white,
        ),
        style: const TextStyle(fontSize: 13),
      ),
      if (_results.isNotEmpty) ...[
        const SizedBox(height: 4),
        Container(
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE5E7EB))),
          child: Column(children: [
            for (int i = 0; i < _results.length; i++)
              GestureDetector(
                onTap: () {
                  widget.onSelect(_results[i]);
                  _ctrl.clear();
                  setState(() => _results = []);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    border: i < _results.length - 1 ? const Border(bottom: BorderSide(color: Color(0xFFF3F4F6))) : null,
                  ),
                  child: Row(children: [
                    Expanded(child: Text(_results[i].name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF111827)), overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Text(_iPackShort(_results[i]), style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                    const SizedBox(width: 8),
                    Text(_results[i].mrpText, style: const TextStyle(fontSize: 12, color: Color(0xFF374151))),
                  ]),
                ),
              ),
          ]),
        ),
      ],
    ]);
  }
}

// ─── Small helper widgets ─────────────────────────────────────────────────────

class _InfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  const _InfoTile({required this.icon, required this.label, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFFF9FAFB), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE5E7EB))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 18, color: const Color(0xFF6B7280)),
        const SizedBox(width: 8),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151))),
          const SizedBox(height: 2),
          Text(sub, style: const TextStyle(fontSize: 11, color: Color(0xFF9CA3AF))),
        ])),
      ]),
    );
  }
}

// ─── CHANGE #623 — barcode import support widgets ─────────────────────────────

/// One of the two choices the admin makes BEFORE picking a file (A2).
class _BcModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sub;
  final VoidCallback onTap;
  const _BcModeButton({required this.icon, required this.label, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(children: [
          Icon(icon, size: 20, color: const Color(0xFF1B7A43)),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Color(0xFF111827))),
            const SizedBox(height: 2),
            Text(sub, style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
          ])),
          const Icon(Icons.chevron_right, size: 20, color: Color(0xFF9CA3AF)),
        ]),
      ),
    );
  }
}

class _BcPick {
  final int productId;
  final String productName;
  final String packLabel;
  const _BcPick(this.productId, this.productName, this.packLabel);
}

/// F1 — find a medicine, then set/clear its barcode. Search goes through the
/// same catalogue RPC the import matcher uses; the barcode itself is written
/// only by medicine_set_barcode.
class _BarcodeQuickSet extends StatefulWidget {
  final ValueChanged<_BcPick> onPick;
  const _BarcodeQuickSet({required this.onPick});

  @override
  State<_BarcodeQuickSet> createState() => _BarcodeQuickSetState();
}

class _BarcodeQuickSetState extends State<_BarcodeQuickSet> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  bool _busy = false;
  List<Map<String, dynamic>> _results = [];

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v));
  }

  Future<void> _search(String q) async {
    if (q.trim().length < 2) { setState(() => _results = []); return; }
    setState(() => _busy = true);
    try {
      final rows = await Supabase.instance.client.rpc('search_medicines_priority', params: {
        'search_term': q.trim(), 'category_filter': 'All', 'page_offset': 0, 'page_limit': 8,
      });
      if (!mounted) return;
      setState(() => _results = List<Map<String, dynamic>>.from(rows as List));
    } catch (_) {
      if (mounted) setState(() => _results = []);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(
        controller: _ctrl,
        onChanged: _onChanged,
        decoration: InputDecoration(
          hintText: 'Search a medicine…',
          hintStyle: const TextStyle(color: Color(0xFF9CA3AF)),
          prefixIcon: const Icon(Icons.search, size: 20, color: Color(0xFF9CA3AF)),
          suffixIcon: _busy
              ? const Padding(padding: EdgeInsets.all(12),
                  child: SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF1B7A43))))
              : null,
          isDense: true,
          filled: true,
          fillColor: const Color(0xFFF5F6F8),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFFE5E7EB))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: Color(0xFF1B7A43))),
        ),
        style: const TextStyle(fontSize: 15, color: Color(0xFF111827)),
      ),
      for (final r in _results) ...[
        const SizedBox(height: 8),
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            final id = r['id'];
            final pid = id is int ? id : int.tryParse('$id');
            if (pid == null) return;
            final pack = ((r['pack_qty'] ?? r['pack_type'] ?? '') as Object).toString().trim();
            widget.onPick(_BcPick(pid, (r['product_name'] ?? '').toString(), pack));
          },
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE5E7EB)),
            ),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((r['product_name'] ?? '').toString(),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF111827)),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(
                  [(r['pack_qty'] ?? '').toString(), (r['marketer'] ?? '').toString()]
                      .where((s) => s.trim().isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                ),
              ])),
              const Icon(Icons.chevron_right, size: 20, color: Color(0xFF9CA3AF)),
            ]),
          ),
        ),
      ],
    ]);
  }
}

class _SumRow extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final int count;
  const _SumRow({required this.icon, required this.color, required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Text(label, style: const TextStyle(fontSize: 14, color: Color(0xFF374151))),
      const Spacer(),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text('$count', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
      ),
    ]);
  }
}

// ─── Pack short helper ────────────────────────────────────────────────────────

String _iPackShort(Product p) {
  final raw = p.packSize.trim();
  if (raw.isEmpty) return '';
  final inIdx = raw.toLowerCase().indexOf(' in ');
  final leading = (inIdx >= 0 ? raw.substring(0, inIdx) : raw).trim();
  final parts = leading.split(RegExp(r'\s+'));
  if (parts.length < 2 || double.tryParse(parts[0]) == null || parts[1].isEmpty) return raw;
  final num = parts[0];
  final unit = parts[1].toLowerCase();
  if (unit == 'ml') return '${num}ml';
  if (unit == 'l' || unit == 'litre' || unit == 'liter') return '${num}L';
  final String typeCode;
  switch (unit) {
    case 'tablet': case 'tablets': case 'tab': case 'tabs': typeCode = 'T';
    case 'capsule': case 'capsules': case 'cap': case 'caps': typeCode = 'C';
    case 'gm': case 'g': case 'gram': case 'grams': typeCode = 'G';
    default: typeCode = parts[1].isNotEmpty ? parts[1][0].toUpperCase() : '?';
  }
  if (parts.length >= 3) {
    final mod = parts[2].toUpperCase();
    if (mod == 'SR' || mod == 'XR' || mod == 'ER' || mod == 'CR' || mod == 'MR') return "$num'$typeCode-$mod";
  }
  return "$num'$typeCode";
}

// ─── Fuzzy match helpers (identical logic to bulk_upload_screen.dart) ─────────

String _normStr(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9\s]'), ' ').trim().replaceAll(RegExp(r'\s+'), ' ');

Set<String> _trigrams(String s) {
  if (s.length < 3) return {};
  final t = <String>{};
  for (int i = 0; i + 3 <= s.length; i++) t.add(s.substring(i, i + 3));
  return t;
}

int _editDist(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n; if (n == 0) return m;
  final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
    if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
    else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
  }
  return dp[m][n];
}

int _dlEditDist(String s, String t) {
  final m = s.length, n = t.length;
  if (m == 0) return n; if (n == 0) return m;
  final dp = List.generate(m + 1, (i) => List.filled(n + 1, 0));
  for (int i = 0; i <= m; i++) dp[i][0] = i;
  for (int j = 0; j <= n; j++) dp[0][j] = j;
  for (int i = 1; i <= m; i++) for (int j = 1; j <= n; j++) {
    if (s[i-1] == t[j-1]) { dp[i][j] = dp[i-1][j-1]; }
    else { final a = dp[i-1][j], b = dp[i][j-1], c = dp[i-1][j-1]; dp[i][j] = 1 + (a < b ? (a < c ? a : c) : (b < c ? b : c)); }
    if (i > 1 && j > 1 && s[i-1] == t[j-2] && s[i-2] == t[j-1]) {
      final tr = dp[i-2][j-2] + 1; if (tr < dp[i][j]) dp[i][j] = tr;
    }
  }
  return dp[m][n];
}

double _s1Score(String query, String candidate) {
  final q = _normStr(query).replaceAll(' ', '');
  final c = _normStr(candidate).replaceAll(' ', '');
  if (q.isEmpty || c.isEmpty) return 0.0;
  final qT = _trigrams(q), cT = _trigrams(c);
  final triScore = qT.union(cT).isEmpty ? 0.0 : qT.intersection(cT).length / qT.union(cT).length.toDouble();
  final maxLen = q.length > c.length ? q.length : c.length;
  final editRatio = 1.0 - _editDist(q, c) / maxLen;
  return 0.55 * triScore + 0.45 * editRatio;
}

double _s2Score(String query, String candidate) {
  final q = _normStr(query), c = _normStr(candidate);
  if (q.isEmpty || c.isEmpty) return 0.0;
  final maxLen = q.length > c.length ? q.length : c.length;
  final editRatio = 1.0 - _dlEditDist(q, c) / maxLen;
  final qW = q.split(' ').where((t) => t.isNotEmpty).toSet();
  final cW = c.split(' ').where((t) => t.isNotEmpty).toSet();
  final tokenJaccard = qW.union(cW).isEmpty ? 0.0 : qW.intersection(cW).length / qW.union(cW).length.toDouble();
  final tokenRecall = qW.isEmpty ? 0.0 : qW.where((t) => cW.contains(t)).length / qW.length;
  final qL = q.split(' ').where((t) => t.isNotEmpty).toList();
  final cL = c.split(' ').where((t) => t.isNotEmpty).toList();
  final qF = qL.isEmpty ? '' : qL[0], cF = cL.isEmpty ? '' : cL[0];
  final fMax = qF.length > cF.length ? qF.length : cF.length;
  final prefixRatio = fMax == 0 ? 0.0 : 1.0 - _dlEditDist(qF, cF) / fMax;
  final qFT = _trigrams(qF), cFT = _trigrams(cF);
  final fwt = qFT.union(cFT).isEmpty ? 0.0 : qFT.intersection(cFT).length / qFT.union(cFT).length.toDouble();
  return 0.50 * editRatio + 0.12 * tokenJaccard + 0.13 * tokenRecall + 0.20 * prefixRatio + 0.05 * fwt;
}

String? _detectForm(String name) {
  final n = name.toLowerCase();
  if (n.contains('syrup') || n.contains('suspension') || n.contains('oral liquid')) return 'liquid';
  if (n.contains('injection') || n.contains('inj') || n.contains('vial')) return 'injection';
  if (n.contains('tablet') || n.contains('tab ') || n.endsWith(' tab') || n.contains(' tabs')) return 'tablet';
  if (n.contains('capsule') || n.contains('cap ') || n.endsWith(' cap')) return 'capsule';
  if (n.contains('cream') || n.contains('ointment') || n.contains('gel') || n.contains('lotion')) return 'topical';
  if (n.contains('drop') || n.contains('eye ') || n.contains('ear ')) return 'drops';
  if (n.contains('sachet') || n.contains('powder')) return 'sachet';
  return null;
}

bool _formMatch(String candidate, String form) {
  final c = candidate.toLowerCase();
  return switch (form) {
    'liquid'    => c.contains('syrup') || c.contains('suspension') || c.contains('oral'),
    'injection' => c.contains('inj') || c.contains('injection') || c.contains('vial'),
    'tablet'    => c.contains('tab') || c.contains('tablet'),
    'capsule'   => c.contains('cap') || c.contains('capsule'),
    'topical'   => c.contains('cream') || c.contains('gel') || c.contains('oint') || c.contains('lotion'),
    'drops'     => c.contains('drop') || c.contains('eye') || c.contains('ear'),
    'sachet'    => c.contains('sachet') || c.contains('powder'),
    _           => false,
  };
}
