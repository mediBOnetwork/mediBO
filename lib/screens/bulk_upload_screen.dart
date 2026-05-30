// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';
import 'package:xml/xml.dart' as xmlp;

import '../app_state.dart';
import '../config/api_keys.dart';
import '../models/product.dart';
import '../util.dart';

// ─── Loading step ─────────────────────────────────────────────────────────────

enum _LoadStep { idle, readingFile, aiAnalyzing, matching }

// ─── Data ─────────────────────────────────────────────────────────────────────

enum _MatchStatus { matched, partial, unrecognized, manuallyMatched }

class _MatchRow {
  final String lineItem;
  final int qty;
  _MatchStatus status;
  final List<Product> candidates;
  int selectedIndex;
  // Display-only fallbacks for hardcoded sample rows (no live candidates)
  final String _displaySku;
  final String _displayPrice;

  _MatchRow({
    required this.lineItem,
    required this.qty,
    required this.status,
    required this.candidates,
    this.selectedIndex = 0,
    String displaySku = 'No match found',
    String displayPrice = '-',
  })  : _displaySku = displaySku,
        _displayPrice = displayPrice;

  Product? get selectedProduct =>
      candidates.isEmpty ? null : candidates[selectedIndex];

  String get matchedSku {
    final p = selectedProduct;
    if (p != null) return p.packSize.isNotEmpty ? '${p.name} (${p.packSize})' : p.name;
    return _displaySku;
  }

  String get price => selectedProduct != null ? rupees(selectedProduct!.b2bPrice) : _displayPrice;
}

// Sample rows for display before a file is uploaded.
// Candidates are empty so no dropdown; real matching runs on "Add to cart".
final _kSampleRows = <_MatchRow>[
  _MatchRow(lineItem: 'Augmentin 625',    qty: 5,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Augmentin 625 Duo Tab (10s)',       displayPrice: '₹210.00'),
  _MatchRow(lineItem: 'Pan 40',           qty: 10, status: _MatchStatus.matched,  candidates: [], displaySku: 'Pan 40mg Tab (15s)',                 displayPrice: '₹96.50'),
  _MatchRow(lineItem: 'Dolo 650',         qty: 20, status: _MatchStatus.matched,  candidates: [], displaySku: 'Dolo 650mg Tab (15s)',               displayPrice: '₹58.36'),
  _MatchRow(lineItem: 'Metformin 500 SR', qty: 8,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Glycomet 500 SR Tab (20s)',          displayPrice: '₹52.00'),
  _MatchRow(lineItem: 'Atorva 10',        qty: 6,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Atorvastatin 10mg Tab (10s)',        displayPrice: '₹89.00'),
  _MatchRow(lineItem: 'Azithro 500',      qty: 4,  status: _MatchStatus.matched,  candidates: [], displaySku: 'Azithromycin 500mg Tab (5s)',        displayPrice: '₹75.40'),
  _MatchRow(lineItem: 'Montar LC',        qty: 5,  status: _MatchStatus.partial,  candidates: [], displaySku: 'Montelukast+Levo 5+2.5mg (10s)',     displayPrice: '₹148.80'),
  _MatchRow(lineItem: 'Vitamin D sachet', qty: 12, status: _MatchStatus.matched,  candidates: [], displaySku: 'D-Rise 60K IU Sachet',              displayPrice: '₹43.80'),
];

// ─── Screen ───────────────────────────────────────────────────────────────────

class BulkUploadScreen extends StatefulWidget {
  const BulkUploadScreen({super.key});

  @override
  State<BulkUploadScreen> createState() => _BulkUploadScreenState();
}

class _BulkUploadScreenState extends State<BulkUploadScreen> {
  List<_MatchRow> _rows = _kSampleRows;
  _LoadStep _step = _LoadStep.idle;
  int _matchProgress = 0;
  int _matchTotal = 0;
  bool _isFromFile = false;
  String? _fileName;
  bool _addingToCart = false;

  bool get _isLoading => _step != _LoadStep.idle;

  String get _loadingMessage {
    switch (_step) {
      case _LoadStep.readingFile:
        return '📂 Reading file...';
      case _LoadStep.aiAnalyzing:
        return '🤖 AI analyzing file structure...';
      case _LoadStep.matching:
        return '🔍 Matching medicines with database... ($_matchProgress/$_matchTotal)';
      case _LoadStep.idle:
        return '';
    }
  }

  // ── File picking & orchestration ───────────────────────────────────────────

  Future<void> _pickAndProcess() async {
    final input = html.FileUploadInputElement()
      ..accept = '.csv,.xlsx,.xls,.pdf,.ods,.tsv,.txt,.docx,.doc,.html,.htm,.jpg,.jpeg,.png,.webp,.heic,.heif,.gif'
      ..multiple = false;
    input.click();

    await input.onChange.first;
    final files = input.files;
    if (files == null || files.isEmpty) return;

    final file = files.first;
    setState(() {
      _step = _LoadStep.readingFile;
      _fileName = file.name;
      _matchProgress = 0;
      _matchTotal = 0;
    });

    try {
      // Step 1: extract raw text / bytes from file
      final rawContent = await _getRawFileContent(file);

      // Step 2: Try AI; silently fall back to header-column matching on failure
      setState(() => _step = _LoadStep.aiAnalyzing);
      final isBinary = rawContent.startsWith('PDF_BYTES:') ||
          rawContent.startsWith('IMAGE_BYTES:');
      // Structured spreadsheets have unambiguous column layout; parse locally
      // to avoid Gemini misidentifying the qty column as rate/amount/mrp.
      final fileExt = file.name.toLowerCase().split('.').last;
      final isStructuredSheet =
          const {'xlsx', 'xls', 'ods', 'csv', 'tsv'}.contains(fileExt);
      List<Map<String, dynamic>> extracted;
      if (isStructuredSheet) {
        extracted = _extractWithFallback(rawContent);
      } else {
        try {
          extracted = await _extractWithGeminiAI(rawContent, file.name);
        } catch (_) {
          if (isBinary) {
            throw Exception(
                'Could not extract medicines from this file. For image-based PDFs or photos, ensure the content is clear and legible, or use a typed CSV/Excel/text file instead.');
          }
          extracted = _extractWithFallback(rawContent);
        }
      }

      if (extracted.isEmpty) throw Exception('No medicine rows found in file');

      // Step 3: fuzzy-match each extracted medicine against Supabase
      setState(() {
        _step = _LoadStep.matching;
        _matchTotal = extracted.length;
        _matchProgress = 0;
      });

      final rows = <_MatchRow>[];
      for (final item in extracted) {
        final name = item['name']?.toString().trim() ?? '';
        final qty = (int.tryParse(item['qty']?.toString() ?? '') ?? 1).clamp(1, 99999);
        if (name.isNotEmpty) {
          rows.add(await _matchOne(name, qty));
        }
        if (!mounted) return;
        setState(() => _matchProgress = rows.length);
      }

      if (!mounted) return;
      setState(() {
        _rows = rows;
        _isFromFile = true;
        _step = _LoadStep.idle;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _LoadStep.idle;
        _isFromFile = false;
        _fileName = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyError(e)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  // ── Raw content extraction ─────────────────────────────────────────────────

  /// Converts any supported file to either a plain-text string (spreadsheets,
  /// CSV, TSV, TXT, DOCX) or a base64-prefixed string for images sent to Gemini.
  Future<String> _getRawFileContent(html.File file) async {
    final ext = file.name.toLowerCase().split('.').last;
    switch (ext) {
      case 'csv':
      case 'tsv':
      case 'txt':
      case 'html':
      case 'htm':
        return _readAsText(file);
      case 'pdf':
        final bytes = await _readBinaryBytes(file);
        // Try local text extraction first (works for typed PDFs)
        final localText = await _extractPdfText(bytes);
        if (localText.trim().length > 20) return localText;
        // Scanned/image PDF — send to Gemini
        return 'PDF_BYTES:${base64Encode(bytes)}';
      case 'xlsx':
      case 'xls':
        return _xlsxToRawText(file);
      case 'ods':
        return _odsToRawText(file);
      case 'docx':
        return _docxToRawText(file);
      case 'doc':
        return _docToRawText(file);
      case 'jpg':
      case 'jpeg':
        return 'IMAGE_BYTES:image/jpeg:${base64Encode(await _readBinaryBytes(file))}';
      case 'png':
        return 'IMAGE_BYTES:image/png:${base64Encode(await _readBinaryBytes(file))}';
      case 'webp':
        return 'IMAGE_BYTES:image/webp:${base64Encode(await _readBinaryBytes(file))}';
      case 'heic':
      case 'heif':
        return 'IMAGE_BYTES:image/heic:${base64Encode(await _readBinaryBytes(file))}';
      case 'gif':
        return 'IMAGE_BYTES:image/gif:${base64Encode(await _readBinaryBytes(file))}';
      default:
        // Try unknown format as plain text before giving up
        try {
          return await _readAsText(file);
        } catch (_) {
          throw Exception(
              'Format .$ext is not supported. Please use CSV, Excel, PDF, TXT, or DOCX.');
        }
    }
  }

  Future<String> _readAsText(html.File file) async {
    final reader = html.FileReader();
    reader.readAsText(file);
    await reader.onLoad.first;
    return (reader.result as String)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  Future<Uint8List> _readBinaryBytes(html.File file) async {
    final reader = html.FileReader();
    reader.readAsDataUrl(file);
    await reader.onLoad.first;
    final dataUrl = reader.result as String;
    return base64Decode(dataUrl.split(',').last);
  }

  /// Extracts plain text from a typed PDF using syncfusion. Returns empty string
  /// for scanned/image-only PDFs so caller can fall back to Gemini.
  Future<String> _extractPdfText(Uint8List bytes) async {
    try {
      final doc = PdfDocument(inputBytes: bytes);
      final extractor = PdfTextExtractor(doc);
      final text = extractor.extractText();
      doc.dispose();
      return text;
    } catch (_) {
      return '';
    }
  }

  /// Parses DOCX ZIP+XML structure and returns paragraph text as plain lines.
  Future<String> _docxToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('Could not open DOCX file. Make sure it is a valid Word document.');
    }

    ArchiveFile? docFile;
    for (final f in archive) {
      if (f.name.toLowerCase() == 'word/document.xml') {
        docFile = f;
        break;
      }
    }
    if (docFile == null) throw Exception('Not a valid DOCX file — document.xml missing.');

    final xmlStr = utf8.decode(docFile.content as List<int>);
    final doc = xmlp.XmlDocument.parse(xmlStr);

    final sb = StringBuffer();
    for (final para in doc.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'p')) {
      final text = para.descendants
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 't')
          .map((e) => e.innerText)
          .join();
      if (text.trim().isNotEmpty) sb.writeln(text);
    }
    return sb.toString();
  }

  /// Extracts readable text from legacy binary .doc files.
  /// Tries plain-text read first (works for RTF-based .doc), then ASCII runs.
  Future<String> _docToRawText(html.File file) async {
    try {
      final text = await _readAsText(file);
      if (text.isNotEmpty) {
        final printable = text.codeUnits
            .where((c) => c >= 32 && c < 127 || c == 9 || c == 10 || c == 13)
            .length;
        final ratio = printable / text.length.clamp(1, 1 << 30);
        if (ratio > 0.70) {
          // RTF: strip control words and return plain text
          if (text.startsWith('{\\rtf')) {
            return text
                .replaceAll(RegExp(r'\\[a-z]+\d* ?'), '')
                .replaceAll(RegExp(r'\{[^{}]{0,200}\}'), '')
                .replaceAll(RegExp(r'[^\x20-\x7E\n\t]'), ' ')
                .trim();
          }
          return text;
        }
      }
    } catch (_) {}

    // Binary DOC: extract printable ASCII runs of ≥6 chars
    final bytes = await _readBinaryBytes(file);
    final sb = StringBuffer();
    int runStart = -1;
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      if (b >= 32 && b < 127) {
        if (runStart == -1) runStart = i;
      } else {
        if (runStart != -1 && i - runStart >= 6) {
          sb.writeln(String.fromCharCodes(bytes.sublist(runStart, i)));
        }
        runStart = -1;
      }
    }
    if (runStart != -1 && bytes.length - runStart >= 6) {
      sb.writeln(String.fromCharCodes(bytes.sublist(runStart)));
    }
    final result = sb.toString().trim();
    if (result.isEmpty) {
      throw Exception(
          'Could not read DOC file content. Please save as DOCX or CSV format.');
    }
    return result;
  }

  /// Parses XLSX ZIP+XML structure and returns all sheet data as tab-separated rows.
  Future<String> _xlsxToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('Excel file could not be opened. Save as .xlsx format (Excel 2007+).');
    }

    ArchiveFile? findFile(String path) {
      final lower = path.toLowerCase();
      for (final f in archive) {
        if (f.name.toLowerCase() == lower) return f;
      }
      return null;
    }

    // Build shared-strings table (t="s" cells reference this by index)
    final sharedStrings = <String>[];
    final ssFile = findFile('xl/sharedStrings.xml');
    if (ssFile != null) {
      try {
        final ssXml = utf8.decode(ssFile.content as List<int>);
        final doc = xmlp.XmlDocument.parse(ssXml);
        for (final si in doc.findAllElements('si')) {
          sharedStrings.add(si.findAllElements('t').map((t) => t.innerText).join());
        }
      } catch (_) {}
    }

    // Find the first sheet
    ArchiveFile? sheetFile;
    for (int n = 1; n <= 10; n++) {
      sheetFile = findFile('xl/worksheets/sheet$n.xml');
      if (sheetFile != null) break;
    }
    if (sheetFile == null) throw Exception('No worksheet found in Excel file.');

    final wsXml = utf8.decode(sheetFile.content as List<int>);
    final wsDoc = xmlp.XmlDocument.parse(wsXml);

    String? readCell(xmlp.XmlElement cell) {
      final t = cell.getAttribute('t');
      if (t == 'inlineStr') {
        return cell.findAllElements('t').map((e) => e.innerText).join();
      } else if (t == 's') {
        final v = cell.findElements('v').firstOrNull?.innerText;
        if (v == null) return null;
        final idx = int.tryParse(v);
        if (idx == null || idx >= sharedStrings.length) return null;
        return sharedStrings[idx];
      } else if (t == 'str') {
        return cell.findElements('v').firstOrNull?.innerText;
      } else {
        return cell.findElements('v').firstOrNull?.innerText;
      }
    }

    final sb = StringBuffer();
    for (final row in wsDoc.findAllElements('row')) {
      final cells = <String, String>{};
      for (final cell in row.findElements('c')) {
        final ref = cell.getAttribute('r') ?? '';
        final col = ref.replaceAll(RegExp(r'[0-9]'), '');
        if (col.isNotEmpty) cells[col] = readCell(cell) ?? '';
      }
      if (cells.isEmpty) continue;
      final cols = cells.keys.toList()..sort();
      sb.writeln(cols.map((c) => cells[c]!).join('\t'));
    }
    return sb.toString();
  }

  /// Parses ODS content.xml and returns all table data as tab-separated rows.
  Future<String> _odsToRawText(html.File file) async {
    final bytes = await _readBinaryBytes(file);

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw Exception('ODS file could not be opened.');
    }

    ArchiveFile? contentFile;
    for (final f in archive) {
      if (f.name.toLowerCase() == 'content.xml') {
        contentFile = f;
        break;
      }
    }
    if (contentFile == null) throw Exception('Not a valid ODS file — content.xml missing.');

    final xmlStr = utf8.decode(contentFile.content as List<int>);
    final doc = xmlp.XmlDocument.parse(xmlStr);

    String cellText(xmlp.XmlElement cell) {
      final paragraphs = cell.descendants
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 'p');
      if (paragraphs.isNotEmpty) {
        return paragraphs.map((e) => e.innerText).join(' ').trim();
      }
      for (final attr in cell.attributes) {
        if (attr.localName == 'value') return attr.value;
      }
      return '';
    }

    final tables = doc.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'table');
    if (tables.isEmpty) throw Exception('No sheets found in ODS file.');

    final sb = StringBuffer();
    for (final row in tables.first.descendants
        .whereType<xmlp.XmlElement>()
        .where((e) => e.localName == 'table-row')) {
      final cells = row.children
          .whereType<xmlp.XmlElement>()
          .where((e) => e.localName == 'table-cell')
          .toList();
      if (cells.isEmpty) continue;
      sb.writeln(cells.map(cellText).join('\t'));
    }
    return sb.toString();
  }

  // ── Gemini AI extraction ──────────────────────────────────────────────────

  // Retries up to 3 times; images also retry on empty result with a broader prompt.
  Future<List<Map<String, dynamic>>> _extractWithGeminiAI(
      String rawContent, String fileName) async {
    if (geminiApiKey.isEmpty || geminiApiKey.startsWith('YOUR_')) {
      debugPrint('[Gemini] API key not configured');
      throw Exception(
          'Gemini API key is not configured. Contact support to enable AI image processing.');
    }
    debugPrint('[Gemini] Key prefix: ${geminiApiKey.substring(0, geminiApiKey.length.clamp(0, 10))}…');

    final isImage = rawContent.startsWith('IMAGE_BYTES:');
    Object? lastError;

    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final result = await _callGeminiOnce(rawContent, attempt: attempt);
        if (result.isNotEmpty) return result;
        // Empty response — retry images with the fallback prompt once
        if (isImage && attempt < 2) {
          await Future.delayed(const Duration(milliseconds: 800));
          continue;
        }
        throw Exception('empty_response');
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future.delayed(Duration(milliseconds: 600 * (attempt + 1)));
        }
      }
    }

    if (isImage) {
      throw Exception(
          'Image unclear or no medicines detected. Please ensure good lighting, clear handwriting, and that the full list is visible in the photo.');
    }
    throw lastError!;
  }

  Future<List<Map<String, dynamic>>> _callGeminiOnce(
      String rawContent, {int attempt = 0}) async {
    final isPdf = rawContent.startsWith('PDF_BYTES:');
    final isImage = rawContent.startsWith('IMAGE_BYTES:');

    final List<Map<String, dynamic>> parts;
    if (isImage) {
      final withoutPrefix = rawContent.substring('IMAGE_BYTES:'.length);
      final colonIdx = withoutPrefix.indexOf(':');
      final mimeType = withoutPrefix.substring(0, colonIdx);
      final base64Data = withoutPrefix.substring(colonIdx + 1);
      // Second attempt uses a broader, simpler prompt to catch cases where the
      // detailed prompt confuses the model on low-quality handwriting
      final imagePromptText =
          attempt == 0 ? _geminiImagePrompt : _geminiImageFallbackPrompt;
      parts = [
        {'inline_data': {'mime_type': mimeType, 'data': base64Data}},
        {'text': imagePromptText},
      ];
    } else if (isPdf) {
      final base64Pdf = rawContent.substring('PDF_BYTES:'.length);
      parts = [
        {'inline_data': {'mime_type': 'application/pdf', 'data': base64Pdf}},
        {'text': _geminiPrompt},
      ];
    } else {
      parts = [{'text': _geminiTextPrompt(rawContent)}];
    }

    final response = await http.post(
      Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$geminiApiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': isImage ? 0.2 : 0.1,
          'maxOutputTokens': isImage ? 4096 : 3000,
        },
      }),
    );

    if (response.statusCode != 200) {
      debugPrint('[Gemini] HTTP ${response.statusCode}: ${response.body}');
      throw Exception('Gemini API error (HTTP ${response.statusCode}). Check API key or quota.');
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final text =
        data['candidates'][0]['content']['parts'][0]['text'] as String;
    final match = RegExp(r'\[[\s\S]*\]').firstMatch(text);
    if (match == null) throw Exception('no_json_in_response');

    return (jsonDecode(match.group(0)!) as List).cast<Map<String, dynamic>>();
  }

  // Fallback parser for structured files (CSV/TSV/XLSX/ODS) and typed-PDF text.
  // Detects name + qty columns by header keywords, then by type inference.
  List<Map<String, dynamic>> _extractWithFallback(String rawContent) {
    final lines =
        rawContent.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];

    final sep = lines.first.contains('\t') ? '\t' : ',';
    final rows = lines
        .map((l) => l
            .split(sep)
            .map((c) => c.trim().replaceAll(RegExp(r'''^["']+|["']+$'''), ''))
            .toList())
        .toList();
    if (rows.isEmpty) return [];

    const namePatterns = [
      'medicine', 'product', 'name', 'drug', 'item', 'description',
      'salt', 'brand', 'particular', 'detail', 'dawa',
    ];
    const qtyPatterns = [
      'qty', 'quantity', 'count', 'units', 'pcs', 'pack',
      'nos', 'pieces', 'strips', 'boxes', 'tablet', 'req', 'demand',
    ];
    // Columns with these headers hold prices, not quantities — exclude them.
    const pricePatterns = [
      'rate', 'price', 'mrp', 'amount', 'value', 'total', 'cost',
      'discount', 'disc', 'net', 'tax', 'gst',
    ];
    const skipWords = ['total', 'subtotal', 'grand', 's.no', 'sl.', 'serial'];

    int nameCol = -1;
    int qtyCol = -1;
    int headerRow = -1;
    final priceColIndices = <int>{};

    // Scan up to first 5 rows to find the header row.
    for (int r = 0; r < rows.length.clamp(0, 5); r++) {
      int foundName = -1, foundQty = -1;
      for (int c = 0; c < rows[r].length; c++) {
        final cell = rows[r][c].toLowerCase().trim();
        if (cell.isEmpty) continue;
        if (pricePatterns.any((p) => cell.contains(p))) priceColIndices.add(c);
        if (foundName == -1 && namePatterns.any((p) => cell.contains(p))) {
          foundName = c;
        }
        // Accept as qty only if not also a price-like header.
        if (foundQty == -1 &&
            qtyPatterns.any((p) => cell.contains(p)) &&
            !pricePatterns.any((p) => cell.contains(p))) {
          foundQty = c;
        }
      }
      if (foundName != -1) {
        nameCol = foundName;
        qtyCol = foundQty;
        headerRow = r;
        break;
      }
    }

    // No structured header — fall back to line-by-line plain-text parsing.
    if (headerRow == -1 || nameCol == -1) {
      return _extractFromPlainTextLines(lines);
    }

    // If no qty column found by header name, try type inference on data rows.
    if (qtyCol == -1) {
      final dataRows = rows.length > headerRow + 1
          ? rows.sublist(headerRow + 1)
          : <List<String>>[];
      qtyCol = _inferQtyColumn(dataRows, nameCol, priceColIndices);
    }

    final result = <Map<String, dynamic>>[];
    for (int r = headerRow + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.length <= nameCol) continue;
      final name = row[nameCol].trim();
      if (name.isEmpty || name.length < 2) continue;
      final nameLower = name.toLowerCase();
      // Skip total/serial/header rows.
      if (skipWords.any((s) => nameLower.contains(s))) continue;
      if (namePatterns.any((p) => nameLower == p)) continue;
      if (qtyPatterns.any((p) => nameLower == p)) continue;
      if (RegExp(r'^\d+\.?\s*$').hasMatch(name)) continue;

      int qty = 1;
      if (qtyCol >= 0 && qtyCol < row.length) {
        final raw = row[qtyCol].replaceAll(RegExp(r'[^\d]'), '');
        qty = int.tryParse(raw) ?? 1;
      }
      result.add({'name': name, 'qty': qty.clamp(1, 99999)});
    }
    return result;
  }

  /// Parses plain-text order lists and WhatsApp exports line-by-line.
  /// Handles formats like "Medicine - 5", "Medicine x5", "5 Medicine", and
  /// "[date time] Name: Medicine x 5" (WhatsApp).
  List<Map<String, dynamic>> _extractFromPlainTextLines(List<String> lines) {
    final result = <Map<String, dynamic>>[];

    // Matches WhatsApp timestamp prefixes in both bracket and dash styles
    final whatsAppPattern = RegExp(
      r'(?:\[\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4},?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?\s*\]'
      r'|\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4},?\s+\d{1,2}:\d{2}(?::\d{2})?\s*[-–])'
      r'\s*[^:]+:\s*(.+)',
    );

    // "Medicine Name - 5" / "Medicine x 10" / "Medicine : 3"
    final qtyAtEnd = RegExp(r'^(.+?)(?:\s+[-–x×:]\s*|\s+)(\d{1,4})\s*$', caseSensitive: false);

    const skipPrefixes = [
      'total', 'subtotal', 'grand', 'date:', 'time:', 'regards', 'thanks',
      'hello', 'hi,', 'dear ', 'note:', 's.no', 'serial', 'sr.', 'from:', 'to:',
    ];

    for (var line in lines) {
      line = line.trim();
      if (line.length < 3) continue;

      // Strip WhatsApp timestamp and sender prefix
      final waMatch = whatsAppPattern.firstMatch(line);
      String work = waMatch != null ? waMatch.group(1)!.trim() : line;
      if (work.length < 2) continue;

      // Skip system/metadata lines
      if (skipPrefixes.any((s) => work.toLowerCase().startsWith(s))) continue;
      if (work.contains('end-to-end encrypted')) continue;
      if (RegExp(r'^\d+\.?\s*$').hasMatch(work)) continue; // bare number
      // Skip header-like lines that contain 2+ column-header keywords
      if (_isColumnHeaderLine(work)) continue;

      String name = work;
      int qty = 1;

      final endMatch = qtyAtEnd.firstMatch(work);
      if (endMatch != null) {
        final potentialName = endMatch.group(1)!.trim();
        final potentialQty = int.tryParse(endMatch.group(2)!);
        if (potentialQty != null &&
            potentialQty >= 1 &&
            potentialQty <= 9999 &&
            potentialName.length >= 2) {
          name = potentialName;
          qty = potentialQty;
        }
      }

      name = name.replaceAll(RegExp(r'[.,;:]+$'), '').trim();
      if (name.length >= 2) {
        result.add({'name': name, 'qty': qty.clamp(1, 99999)});
      }
    }
    return result;
  }

  /// Returns true when a line looks like a column header row (≥2 header keywords).
  /// Used to prevent "Product Name  Qty  Rate  Amount" from being ingested as a product.
  static bool _isColumnHeaderLine(String line) {
    const keywords = [
      'product', 'medicine', 'item', 'drug', 'description',
      'qty', 'quantity', 'rate', 'mrp', 'price', 'amount',
      's.no', 'serial', 'sr.', 'units', 'pack', 'strips',
    ];
    final lower = line.toLowerCase();
    final hits = keywords.where((k) => lower.contains(k)).length;
    return hits >= 2;
  }

  /// Identifies the quantity column by type inference when header matching fails.
  /// Prefers columns of small integers (1–9999) that are not price/rate columns.
  int _inferQtyColumn(
      List<List<String>> dataRows, int nameCol, Set<int> priceColIndices) {
    if (dataRows.isEmpty) return -1;
    final maxCols =
        dataRows.fold(0, (m, r) => r.length > m ? r.length : m);

    final smallIntCount = List.filled(maxCols, 0);
    final decimalCount = List.filled(maxCols, 0);
    final largeCount = List.filled(maxCols, 0);

    for (final row in dataRows) {
      for (int c = 0; c < row.length; c++) {
        if (c == nameCol) continue;
        final cell = row[c].replaceAll(',', '').trim();
        if (cell.isEmpty) continue;
        final num = double.tryParse(cell);
        if (num == null) continue;
        final isWhole = num == num.truncateToDouble();
        if (isWhole && num >= 1 && num <= 9999) {
          smallIntCount[c]++;
        } else {
          if (!isWhole) decimalCount[c]++;
          if (num > 9999) largeCount[c]++;
        }
      }
    }

    int bestCol = -1;
    int bestScore = 0;
    for (int c = 0; c < maxCols; c++) {
      if (c == nameCol) continue;
      if (priceColIndices.contains(c)) continue;
      if (smallIntCount[c] == 0) continue;
      // Penalise columns with many decimals or very large numbers.
      final score = smallIntCount[c] - decimalCount[c] * 2 - largeCount[c];
      if (score > bestScore) {
        bestScore = score;
        bestCol = c;
      }
    }
    return bestCol;
  }

  static const _geminiPrompt =
      'You are an expert Indian pharmacy procurement assistant. '
      'Extract ALL medicine/product names and their quantities from this order document.\n'
      'Return ONLY a valid JSON array — no explanation, no markdown:\n'
      '[{"name": "medicine name exactly as written", "qty": 5}]\n\n'
      'CRITICAL RULES:\n'
      '- SKIP the header row: any row whose cells are column labels like '
      '"Product", "Medicine", "Item", "Name", "Qty", "Quantity", "Rate", '
      '"MRP", "Price", "Amount", "S.No", "Serial", "Units", "Pack". '
      'Never return a header keyword as a medicine name.\n'
      '- SKIP total, subtotal, and grand total rows.\n'
      '- SKIP serial-number-only rows.\n'
      '- The QTY column contains small integers (1–9999). '
      'Do NOT confuse it with the Rate/MRP/Price/Amount column (larger values or decimals). '
      'Read each row\'s actual quantity from the qty/quantity column.\n'
      '- Keep medicine names with dosage (e.g. "Paracetamol 500mg").\n'
      '- Use qty=1 only when no quantity column exists at all.\n'
      '- Return EVERY medicine found.';

  static const _geminiImagePrompt =
      'This is a handwritten medicine order list from a pharmacy. '
      'Please extract ALL medicine names and quantities from this handwritten image. '
      'The handwriting may not be perfect. Look for:\n'
      '- Medicine/drug names (may include brand names, generic names, tablet/capsule/gel suffixes)\n'
      '- Quantities (numbers next to medicine names)\n'
      '- Units (Box, B, Piece, P, Strip, Tab, etc.)\n'
      'Return ONLY a JSON array like: [{"name": "medicine name", "qty": 5, "unit": "Box"}]\n'
      'Do not return anything else. Extract every medicine you can see even if handwriting is unclear.';

  static const _geminiImageFallbackPrompt =
      'Look at this image carefully. It contains a list of medicines/drugs written by hand. '
      'List every item you can read, even partially. '
      'For each item write the medicine name and the number next to it. '
      'If no number is visible use 1. '
      'Respond with ONLY this JSON — nothing else:\n'
      '[{"name": "drug name", "qty": 1}]';

  static String _geminiTextPrompt(String content) =>
      'You are an expert Indian pharmacy procurement assistant.\n'
      'Below is raw content from a medicine order file (PDF, text, or Word document).\n'
      'Extract ALL medicine/product names and their actual quantities.\n\n'
      'CRITICAL RULES — follow exactly:\n'
      '1. HEADER ROW: Any row whose cells are column labels such as "Product", '
      '"Medicine", "Item", "Name", "Description", "Qty", "Quantity", "Rate", '
      '"MRP", "Price", "Amount", "Sr", "S.No", "Serial", "Units", "Pack" is a '
      'HEADER ROW. Do NOT include it. Never return a header keyword as a medicine name.\n'
      '2. SKIP these rows entirely: header rows, blank rows, total / subtotal / '
      'grand total rows, and serial-number-only rows.\n'
      '3. QTY vs PRICE: The quantity column holds small integers (typically 1–500). '
      'The rate / MRP / price / amount column holds larger numbers or decimals. '
      'Read qty ONLY from the quantity column — never from rate, MRP, price, or '
      'amount columns. A medicine ordered "5 times" has qty=5 even if its MRP is ₹210.\n'
      '4. If a Qty column exists, read each row\'s actual value — do NOT return '
      'qty=1 for every row unless quantities are truly absent from the file.\n'
      '5. Keep medicine names with their dosage (e.g. "Paracetamol 500mg", '
      '"Augmentin 625 Duo").\n'
      '6. Decode common abbreviations: PCM=Paracetamol, Aug=Augmentin, MTF=Metformin.\n\n'
      'File content:\n\n$content\n\n'
      'Return ONLY a valid JSON array, no markdown fences:\n'
      '[{"name":"Augmentin 625 Duo","qty":5},{"name":"Pan 40mg","qty":10}]';

  // ── Supabase matching ──────────────────────────────────────────────────────

  Future<_MatchRow> _matchOne(String name, int qty) async {
    final term = name.replaceAll(RegExp(r'[,()*%]'), ' ').trim();
    if (term.isEmpty) {
      return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: []);
    }
    try {
      final rawMatches = await _searchMedicineTop5(term);
      if (rawMatches.isEmpty) {
        return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: []);
      }
      final products = rawMatches.map((m) => Product.fromMap(m)).toList();
      final termLower = term.toLowerCase();
      final nameLower = products[0].name.toLowerCase();
      final isStrong = nameLower == termLower ||
          nameLower.startsWith(termLower) ||
          (termLower.length > 4 && nameLower.contains(termLower));
      return _MatchRow(
        lineItem: name,
        qty: qty,
        status: isStrong ? _MatchStatus.matched : _MatchStatus.partial,
        candidates: products,
      );
    } catch (_) {
      return _MatchRow(lineItem: name, qty: qty, status: _MatchStatus.unrecognized, candidates: []);
    }
  }

  Future<List<Map<String, dynamic>>> _searchMedicineTop5(String name) async {
    final sb = Supabase.instance.client;
    try {
      final rows = await sb.rpc('search_medicines_priority', params: {
        'search_term': name,
        'category_filter': 'All',
        'page_offset': 0,
        'page_limit': 5,
      });
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (list.isNotEmpty) return list;
    } catch (_) {}
    final results = await sb
        .from('MEDICINE')
        .select()
        .or('product_name.ilike.%$name%,salt_composition.ilike.%$name%,marketer.ilike.%$name%')
        .order('sales_count', ascending: false)
        .limit(5);
    return List<Map<String, dynamic>>.from(results);
  }

  // ── Error messages ─────────────────────────────────────────────────────────

  String _friendlyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('no medicine rows')) {
      return 'No medicine rows found in the file. Make sure the file contains medicine names.';
    }
    if (msg.contains('empty file')) return 'The file appears to be empty.';
    if (msg.contains('not configured') || msg.contains('no_api_key')) {
      return 'AI image processing is not configured. Please upload a CSV or Excel file instead.';
    }
    if (msg.contains('image unclear') || msg.contains('no medicines detected')) {
      return e.toString().replaceFirst('Exception: ', '');
    }
    // All other throw sites use clear messages — pass them through directly
    final clean = e.toString().replaceFirst('Exception: ', '');
    if (clean.isNotEmpty) return clean;
    return 'Failed to process the file. Please try a different format (CSV, Excel, or text).';
  }

  // ── Cart ───────────────────────────────────────────────────────────────────

  Future<void> _addMatchedToCart() async {
    final cart = AppState.of(context);
    if (_isFromFile) {
      final toAdd = _rows
          .where((r) =>
              (r.status == _MatchStatus.matched ||
               r.status == _MatchStatus.manuallyMatched) &&
              r.selectedProduct != null)
          .toList();
      for (final row in toAdd) {
        cart.setQuantity(row.selectedProduct!, row.qty);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${toAdd.length} medicines added to cart'),
          backgroundColor: const Color(0xFF16A34A),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } else {
      setState(() => _addingToCart = true);
      try {
        final matchedRows = await Future.wait(
          _kSampleRows.map((row) => _matchOne(row.lineItem, row.qty)),
        );
        final entries = matchedRows
            .where((r) => r.selectedProduct != null)
            .map((r) => MapEntry(r.selectedProduct!, r.qty))
            .toList();
        if (!mounted) return;
        cart.addSampleItems(entries);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${entries.length} sample items added · auto-removed in 15s'),
          behavior: SnackBarBehavior.floating,
        ));
      } finally {
        if (mounted) setState(() => _addingToCart = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Container(
        color: const Color(0xFFF9FAFB),
        width: double.infinity,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _PageHeader(),
                  const SizedBox(height: 28),
                  _MainLayout(
                    rows: _rows,
                    isLoading: _isLoading,
                    loadingMessage: _loadingMessage,
                    matchProgress: _matchProgress,
                    matchTotal: _matchTotal,
                    isFromFile: _isFromFile,
                    fileName: _fileName,
                    addingToCart: _addingToCart,
                    onPickFile: _pickAndProcess,
                    onAddToCart: _addMatchedToCart,
                  ),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Page header ─────────────────────────────────────────────────────────────

class _PageHeader extends StatelessWidget {
  const _PageHeader();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final titleSize = constraints.maxWidth < 360
            ? 22.0
            : constraints.maxWidth < 600
                ? 26.0
                : 30.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Place Bulk Order',
              style: TextStyle(
                  fontSize: titleSize,
                  fontWeight: FontWeight.w800,
                  color: const Color(0xFF111827)),
            ),
            const SizedBox(height: 6),
            const Text(
              "Choose how you'd like to send your order — WhatsApp for quick photo orders, or upload a file for smart SKU matching.",
              style: TextStyle(fontSize: 14, color: Color(0xFF6B7280), height: 1.5),
            ),
          ],
        );
      },
    );
  }
}

// ─── Main layout ─────────────────────────────────────────────────────────────

class _MainLayout extends StatelessWidget {
  final List<_MatchRow> rows;
  final bool isLoading;
  final String loadingMessage;
  final int matchProgress;
  final int matchTotal;
  final bool isFromFile;
  final String? fileName;
  final bool addingToCart;
  final VoidCallback onPickFile;
  final Future<void> Function() onAddToCart;

  const _MainLayout({
    required this.rows,
    required this.isLoading,
    required this.loadingMessage,
    required this.matchProgress,
    required this.matchTotal,
    required this.isFromFile,
    this.fileName,
    required this.addingToCart,
    required this.onPickFile,
    required this.onAddToCart,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 720) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Expanded(flex: 35, child: _WhatsAppCard()),
                  const SizedBox(width: 16),
                  Expanded(
                    flex: 35,
                    child: _UploadCard(
                      onPickFile: onPickFile,
                      fileName: fileName,
                      isLoading: isLoading,
                    ),
                  ),
                  const SizedBox(width: 16),
                  const Expanded(flex: 30, child: _HowItWorksCard()),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _SmartMatchSection(
              rows: rows,
              isLoading: isLoading,
              loadingMessage: loadingMessage,
              matchProgress: matchProgress,
              matchTotal: matchTotal,
              isFromFile: isFromFile,
              fileName: fileName,
              addingToCart: addingToCart,
              onAddToCart: onAddToCart,
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _WhatsAppCard(),
          const SizedBox(height: 16),
          _UploadCard(onPickFile: onPickFile, fileName: fileName, isLoading: isLoading),
          const SizedBox(height: 16),
          const _HowItWorksCard(),
          const SizedBox(height: 16),
          _SmartMatchSection(
            rows: rows,
            isLoading: isLoading,
            loadingMessage: loadingMessage,
            matchProgress: matchProgress,
            matchTotal: matchTotal,
            isFromFile: isFromFile,
            fileName: fileName,
            addingToCart: addingToCart,
            onAddToCart: onAddToCart,
          ),
        ],
      );
    });
  }
}

// ─── WhatsApp card ────────────────────────────────────────────────────────────

class _WhatsAppCard extends StatelessWidget {
  const _WhatsAppCard();

  void _openWhatsApp() {
    html.window.open(
      'https://wa.me/918357881873?text=Hi%2C%20I%20want%20to%20place%20a%20bulk%20medicine%20order',
      '_blank',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF16a34a), Color(0xFF15803d)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: SvgPicture.asset('assets/whatsapp.svg', fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Send on WhatsApp',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Take a photo of your order list and send directly',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Checklist(
                      items: const [
                        'Send photo of handwritten list',
                        'Your details sent automatically',
                        'Fastest way to order',
                      ],
                      iconColor: const Color(0xFF16A34A),
                      textColor: const Color(0xFF374151),
                    ),
                    const SizedBox(height: 48),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _openWhatsApp,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF25D366),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SvgPicture.asset('assets/whatsapp.svg', width: 20, height: 20),
                            const SizedBox(width: 8),
                            const Text(
                              'Send Order on WhatsApp',
                              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Upload card ─────────────────────────────────────────────────────────────

class _UploadCard extends StatelessWidget {
  final VoidCallback onPickFile;
  final String? fileName;
  final bool isLoading;

  const _UploadCard({
    required this.onPickFile,
    this.fileName,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(15),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 22),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0xFF1e2a3a), Color(0xFF253444)],
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: const Icon(Icons.cloud_upload_outlined, color: Colors.white, size: 26),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'Upload Order File',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Upload any file — AI detects medicines automatically',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                color: Colors.white,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _Checklist(
                      items: const [
                        'Any format, any template supported',
                        'AI detects medicine names automatically',
                        'Review & add to cart in one click',
                      ],
                      iconColor: const Color(0xFF16A34A),
                      textColor: const Color(0xFF374151),
                    ),
                    const SizedBox(height: 48),
                    SizedBox(
                      height: 52,
                      child: fileName != null && !isLoading
                          ? OutlinedButton.icon(
                              onPressed: onPickFile,
                              icon: const Icon(Icons.check_circle_outline,
                                  size: 18, color: Color(0xFF16A34A)),
                              label: Text(
                                fileName!.length > 22
                                    ? '${fileName!.substring(0, 19)}...'
                                    : fileName!,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: Color(0xFF16A34A),
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: const BorderSide(color: Color(0xFF16A34A)),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            )
                          : FilledButton.icon(
                              onPressed: isLoading ? null : onPickFile,
                              icon: isLoading
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2, color: Colors.white),
                                    )
                                  : const Icon(Icons.upload_file_outlined, size: 18),
                              label: Text(
                                isLoading ? 'Processing...' : 'Choose File to Upload',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700, fontSize: 12),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFF1e2a3a),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                                elevation: 0,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── How It Works card ────────────────────────────────────────────────────────

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF1e2a3a),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: Colors.grey.withValues(alpha: 0.15), width: 1),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'HOW IT WORKS',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: Color(0xFF4ade80),
              letterSpacing: 1.2,
            ),
          ),
          SizedBox(height: 10),
          Text(
            'Three steps to a packed cart.',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              height: 1.25,
            ),
          ),
          SizedBox(height: 24),
          _Step(1, 'Drop your file.', 'AI detects columns & extracts medicines from any format.'),
          _Step(2, 'Smart matcher pairs each line', 'to the best in-stock SKU.'),
          _Step(3, 'Review, edit, and push to cart', 'in one click.'),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  final int number;
  final String title;
  final String subtitle;
  const _Step(this.number, this.title, this.subtitle);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: Color(0xFF16A34A),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white)),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.55),
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Template section ─────────────────────────────────────────────────────────

class _TemplateSection extends StatelessWidget {
  const _TemplateSection();

  void _downloadTemplate() {
    const csvContent = 'product_name,quantity\n'
        'Augmentin 625,5\n'
        'Pan 40,10\n'
        'Dolo 650,20\n'
        'Metformin 500 SR,8\n'
        'Atorva 10,6\n';
    final encoded = Uri.encodeComponent(csvContent);
    final anchor = html.AnchorElement()
      ..href = 'data:text/csv;charset=utf-8,$encoded'
      ..setAttribute('download', 'medibo_order_template.csv')
      ..click();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Need a sample?',
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
          ),
          const SizedBox(height: 5),
          const Text(
            'Download our sample CSV to see example formatting. Any variation is accepted.',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280), height: 1.5),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _downloadTemplate,
              icon: const Icon(Icons.download_outlined, size: 15),
              label: const Text('Download sample .csv'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF374151),
                side: const BorderSide(color: Color(0xFFD1D5DB)),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFDCFCE7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.auto_awesome, color: Color(0xFF16A34A), size: 16),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AI-powered parsing',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF15803D),
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Works with any column order, any header name, any language. No fixed template required.',
                        style:
                            TextStyle(fontSize: 11, color: Color(0xFF166534), height: 1.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Smart match section ─────────────────────────────────────────────────────

class _SmartMatchSection extends StatefulWidget {
  final List<_MatchRow> rows;
  final bool isLoading;
  final String loadingMessage;
  final int matchProgress;
  final int matchTotal;
  final bool isFromFile;
  final String? fileName;
  final bool addingToCart;
  final Future<void> Function() onAddToCart;

  const _SmartMatchSection({
    required this.rows,
    required this.isLoading,
    required this.loadingMessage,
    required this.matchProgress,
    required this.matchTotal,
    required this.isFromFile,
    this.fileName,
    required this.addingToCart,
    required this.onAddToCart,
  });

  @override
  State<_SmartMatchSection> createState() => _SmartMatchSectionState();
}

class _SmartMatchSectionState extends State<_SmartMatchSection> {
  int? _expandedIndex;

  void _toggleRow(int index) {
    setState(() => _expandedIndex = _expandedIndex == index ? null : index);
  }

  void _onRowChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final matched = widget.rows.where((r) => r.status == _MatchStatus.matched).length;
    final manuallyMatched = widget.rows.where((r) => r.status == _MatchStatus.manuallyMatched).length;
    final partial = widget.rows.where((r) => r.status == _MatchStatus.partial).length;
    final unrecognized = widget.rows.where((r) => r.status == _MatchStatus.unrecognized).length;
    final canAdd = (matched + manuallyMatched) > 0 && !widget.addingToCart && !widget.isLoading;

    return LayoutBuilder(builder: (ctx, lc) {
      if (lc.maxWidth < 600) return _buildMobile(matched, manuallyMatched, partial, unrecognized, canAdd);
      return _buildWeb(matched, manuallyMatched, partial, unrecognized, canAdd);
    });
  }

  Widget _buildMobile(int matched, int manuallyMatched, int partial, int unrecognized, bool canAdd) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Smart match preview',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    if (matched > 0)
                      _StatusPillBadge(label: '✓ $matched Matched', bg: const Color(0xFFDCFCE7), fg: const Color(0xFF15803D)),
                    if (partial > 0)
                      _StatusPillBadge(label: '~ $partial Partial', bg: const Color(0xFFFEF3C7), fg: const Color(0xFF92400E)),
                    if (unrecognized > 0)
                      _StatusPillBadge(label: '✗ $unrecognized Unrecognized', bg: const Color(0xFFFEE2E2), fg: const Color(0xFFDC2626)),
                    if (manuallyMatched > 0)
                      _StatusPillBadge(label: '● $manuallyMatched Manually Matched', bg: const Color(0xFFE0E7FF), fg: const Color(0xFF3730A3)),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: canAdd ? () => widget.onAddToCart() : null,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF16A34A),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    child: widget.addingToCart
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('Add matched to cart', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          if (widget.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.matchTotal > 0) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: widget.matchProgress / widget.matchTotal,
                        backgroundColor: const Color(0xFFE5E7EB),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('${widget.matchProgress} of ${widget.matchTotal} medicines matched',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ] else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      ),
                    ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                children: [
                  for (int i = 0; i < widget.rows.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _MobileMatchCard(
                        key: ValueKey('mob-$i'),
                        row: widget.rows[i],
                        isExpanded: _expandedIndex == i,
                        onToggle: () => _toggleRow(i),
                        onRowChanged: _onRowChanged,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildWeb(int matched, int manuallyMatched, int partial, int unrecognized, bool canAdd) {
    final badge = widget.isFromFile
        ? (widget.fileName != null && widget.fileName!.length > 20
            ? '${widget.fileName!.substring(0, 17)}…'
            : widget.fileName ?? 'file')
        : 'sample';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: LayoutBuilder(
              builder: (_, lc) {
                final narrow = lc.maxWidth < 460;
                final badgeWidget = Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(color: const Color(0xFFF3F4F6), borderRadius: BorderRadius.circular(4)),
                  child: Text(badge, style: const TextStyle(fontSize: 11, color: Color(0xFF6B7280))),
                );
                final addButton = FilledButton(
                  onPressed: canAdd ? () => widget.onAddToCart() : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    padding: EdgeInsets.symmetric(horizontal: narrow ? 12 : 18, vertical: 10),
                    textStyle: TextStyle(fontWeight: FontWeight.w600, fontSize: narrow ? 12 : 13),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    elevation: 0,
                  ),
                  child: Text(narrow ? 'Add to cart' : 'Add matched to cart'),
                );
                final spinner = const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2));
                final statsText = Text(
                  widget.isLoading
                      ? widget.loadingMessage
                      : '$matched matched · $manuallyMatched manually matched · $partial partial · $unrecognized unrecognized',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
                );
                if (narrow) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        const Flexible(
                          child: Text('Smart match preview',
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827)),
                              overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(width: 8),
                        badgeWidget,
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(child: statsText),
                        const SizedBox(width: 8),
                        widget.addingToCart ? spinner : addButton,
                      ]),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                      const Text('Smart match preview',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                      const SizedBox(width: 8),
                      badgeWidget,
                      const Spacer(),
                      widget.addingToCart ? spinner : addButton,
                    ]),
                    const SizedBox(height: 4),
                    statsText,
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          if (widget.isLoading)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.matchTotal > 0) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: widget.matchTotal > 0 ? widget.matchProgress / widget.matchTotal : null,
                        backgroundColor: const Color(0xFFE5E7EB),
                        valueColor: const AlwaysStoppedAnimation(Color(0xFF16A34A)),
                        minHeight: 6,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text('${widget.matchProgress} of ${widget.matchTotal} medicines matched',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280))),
                  ] else
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.symmetric(vertical: 24),
                        child: SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 2.5)),
                      ),
                    ),
                ],
              ),
            )
          else ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: const BoxDecoration(
                color: Color(0xFFF9FAFB),
                border: Border(
                  top: BorderSide(color: Color(0xFFE5E7EB)),
                  bottom: BorderSide(color: Color(0xFFE5E7EB)),
                ),
              ),
              child: const Row(
                children: [
                  Expanded(flex: 20, child: Text('YOUR LINE ITEM', style: _kTh)),
                  Expanded(flex: 28, child: Text('MATCHED SKU', style: _kTh)),
                  Expanded(flex: 8, child: Text('QTY', style: _kTh)),
                  Expanded(flex: 12, child: Text('PRICE', style: _kTh)),
                  Expanded(flex: 14, child: Text('STATUS', style: _kTh)),
                ],
              ),
            ),
            for (int i = 0; i < widget.rows.length; i++)
              _ExpandableMatchRow(
                key: ValueKey(i),
                row: widget.rows[i],
                index: i,
                last: i == widget.rows.length - 1,
                isExpanded: _expandedIndex == i,
                onToggle: () => _toggleRow(i),
                onRowChanged: _onRowChanged,
              ),
          ],
        ],
      ),
    );
  }
}

const _kTh = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w600,
  color: Color(0xFF9CA3AF),
  letterSpacing: 0.5,
);

class _ExpandableMatchRow extends StatefulWidget {
  final _MatchRow row;
  final int index;
  final bool last;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;

  const _ExpandableMatchRow({
    super.key,
    required this.row,
    required this.index,
    required this.last,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
  });

  @override
  State<_ExpandableMatchRow> createState() => _ExpandableMatchRowState();
}

class _ExpandableMatchRowState extends State<_ExpandableMatchRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: widget.isExpanded ? 1.0 : 0.0,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_ExpandableMatchRow old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) {
      if (widget.isExpanded) {
        _ctrl.forward();
      } else {
        _ctrl.reverse();
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final isEven = widget.index % 2 == 0;
    final hasCandidates = row.candidates.isNotEmpty;

    // Status badge styling
    Color badgeColor;
    Color badgeText;
    String label;
    Color leftBorderColor;
    switch (row.status) {
      case _MatchStatus.matched:
        badgeColor = const Color(0xFFDCFCE7);
        badgeText = const Color(0xFF15803D);
        label = 'Matched';
        leftBorderColor = const Color(0xFF15803D);
      case _MatchStatus.manuallyMatched:
        badgeColor = const Color(0xFFE0E7FF);
        badgeText = const Color(0xFF3730A3);
        label = 'Manually Matched';
        leftBorderColor = const Color(0xFF3730A3);
      case _MatchStatus.partial:
        badgeColor = const Color(0xFFFEF3C7);
        badgeText = const Color(0xFF92400E);
        label = 'Partial';
        leftBorderColor = const Color(0xFFEA580C);
      case _MatchStatus.unrecognized:
        badgeColor = const Color(0xFFFEE2E2);
        badgeText = const Color(0xFFDC2626);
        label = 'Unrecognized';
        leftBorderColor = const Color(0xFFDC2626);
    }

    // Top 4 alternates excluding the currently selected candidate
    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    final bottomBorder = (!widget.last || widget.isExpanded)
        ? const BorderSide(color: Color(0xFFEEEEEE))
        : BorderSide.none;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onTap: hasCandidates ? widget.onToggle : null,
          child: Container(
            decoration: BoxDecoration(
              color: isEven ? Colors.white : const Color(0xFFFAFAFA),
              border: Border(
                left: BorderSide(color: leftBorderColor, width: 3),
                bottom: bottomBorder,
              ),
            ),
            padding: const EdgeInsets.fromLTRB(17, 12, 20, 12),
            child: Row(
              children: [
                Expanded(
                  flex: 20,
                  child: Text(row.lineItem,
                      style: const TextStyle(fontSize: 13, color: Color(0xFF9CA3AF))),
                ),
                Expanded(
                  flex: 28,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.matchedSku,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: row.status != _MatchStatus.unrecognized
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: row.status != _MatchStatus.unrecognized
                                ? const Color(0xFF111827)
                                : const Color(0xFF9CA3AF),
                          ),
                        ),
                      ),
                      if (hasCandidates) ...[
                        const SizedBox(width: 4),
                        AnimatedRotation(
                          turns: widget.isExpanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: const Icon(Icons.expand_more,
                              size: 16, color: Color(0xFF9CA3AF)),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  flex: 8,
                  child: Text('${row.qty}',
                      style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
                ),
                Expanded(
                  flex: 12,
                  child: Text(row.price,
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: Color(0xFF374151))),
                ),
                Expanded(
                  flex: 14,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                        decoration: BoxDecoration(
                          color: badgeColor,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(label,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badgeText)),
                      ),
                      if (hasCandidates) ...[
                        const SizedBox(height: 3),
                        GestureDetector(
                          onTap: widget.onToggle,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Change match',
                                  style: TextStyle(fontSize: 10, color: Color(0xFF3B82F6), fontWeight: FontWeight.w500)),
                              AnimatedRotation(
                                turns: widget.isExpanded ? 0.5 : 0,
                                duration: const Duration(milliseconds: 250),
                                child: const Icon(Icons.expand_more, size: 12, color: Color(0xFF3B82F6)),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizeTransition(
          sizeFactor: _anim,
          child: Container(
            decoration: const BoxDecoration(
              color: Color(0xFFF3F4F6),
              border: Border(left: BorderSide(color: Color(0xFFE5E7EB), width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int k = 0; k < alts.length; k++)
                  _AlternativeRow(
                    product: alts[k].$2,
                    isSelected: false,
                    isLast: k == alts.length - 1,
                    onTap: () {
                      setState(() {
                        row.selectedIndex = alts[k].$1;
                        row.status = _MatchStatus.manuallyMatched;
                      });
                      widget.onToggle();
                      widget.onRowChanged();
                    },
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Status pill badge (mobile header) ───────────────────────────────────────

class _StatusPillBadge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color fg;
  const _StatusPillBadge({required this.label, required this.bg, required this.fg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

// ─── Mobile match card ────────────────────────────────────────────────────────

class _MobileMatchCard extends StatefulWidget {
  final _MatchRow row;
  final bool isExpanded;
  final VoidCallback onToggle;
  final VoidCallback onRowChanged;

  const _MobileMatchCard({
    super.key,
    required this.row,
    required this.isExpanded,
    required this.onToggle,
    required this.onRowChanged,
  });

  @override
  State<_MobileMatchCard> createState() => _MobileMatchCardState();
}

class _MobileMatchCardState extends State<_MobileMatchCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      value: widget.isExpanded ? 1.0 : 0.0,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut);
  }

  @override
  void didUpdateWidget(_MobileMatchCard old) {
    super.didUpdateWidget(old);
    if (widget.isExpanded != old.isExpanded) {
      widget.isExpanded ? _ctrl.forward() : _ctrl.reverse();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final canChange = row.candidates.isNotEmpty && row.status != _MatchStatus.unrecognized;

    Color badgeColor, badgeText, accentColor;
    String label;
    switch (row.status) {
      case _MatchStatus.matched:
        badgeColor = const Color(0xFFDCFCE7);
        badgeText = const Color(0xFF15803D);
        accentColor = const Color(0xFF15803D);
        label = 'Matched';
      case _MatchStatus.manuallyMatched:
        badgeColor = const Color(0xFFE0E7FF);
        badgeText = const Color(0xFF3730A3);
        accentColor = const Color(0xFF3730A3);
        label = 'Manually Matched';
      case _MatchStatus.partial:
        badgeColor = const Color(0xFFFEF3C7);
        badgeText = const Color(0xFF92400E);
        accentColor = const Color(0xFFEA580C);
        label = 'Partial';
      case _MatchStatus.unrecognized:
        badgeColor = const Color(0xFFFEE2E2);
        badgeText = const Color(0xFFDC2626);
        accentColor = const Color(0xFFDC2626);
        label = 'Unrecognized';
    }

    final alts = <(int, Product)>[];
    for (int i = 0; i < row.candidates.length && alts.length < 4; i++) {
      if (i != row.selectedIndex) alts.add((i, row.candidates[i]));
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 6, offset: const Offset(0, 2)),
          ],
          border: Border(left: BorderSide(color: accentColor, width: 3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                            const Text('YOUR ITEM',
                                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF), letterSpacing: 0.5)),
                            const SizedBox(height: 2),
                            Text(row.lineItem,
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111827))),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(20)),
                        child: Text(label,
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: badgeText)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: Color(0xFFE5E7EB)),
                  const SizedBox(height: 8),
                  const Text('MATCHED TO',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Color(0xFF9CA3AF), letterSpacing: 0.5)),
                  const SizedBox(height: 2),
                  Text(
                    row.status != _MatchStatus.unrecognized ? row.matchedSku : 'No match found',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: row.status != _MatchStatus.unrecognized ? const Color(0xFF111827) : const Color(0xFF9CA3AF),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('Qty: ${row.qty}',
                          style: const TextStyle(fontSize: 13, color: Color(0xFF374151))),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Price: ${row.price}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF15803D)),
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                        ),
                      ),
                      if (canChange)
                        GestureDetector(
                          onTap: widget.onToggle,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text('Change match',
                                  style: TextStyle(fontSize: 11, color: Color(0xFF3B82F6), fontWeight: FontWeight.w600)),
                              AnimatedRotation(
                                turns: widget.isExpanded ? 0.5 : 0,
                                duration: const Duration(milliseconds: 220),
                                child: const Icon(Icons.expand_more, size: 14, color: Color(0xFF3B82F6)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            SizeTransition(
              sizeFactor: _anim,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFFF3F4F6),
                  border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (int k = 0; k < alts.length; k++)
                      _AlternativeRow(
                        product: alts[k].$2,
                        isSelected: false,
                        isLast: k == alts.length - 1,
                        onTap: () {
                          setState(() {
                            row.selectedIndex = alts[k].$1;
                            row.status = _MatchStatus.manuallyMatched;
                          });
                          widget.onToggle();
                          widget.onRowChanged();
                        },
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlternativeRow extends StatelessWidget {
  final Product product;
  final bool isSelected;
  final bool isLast;
  final VoidCallback onTap;

  const _AlternativeRow({
    required this.product,
    required this.isSelected,
    required this.isLast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sku = product.packSize.isNotEmpty
        ? '${product.name} (${product.packSize})'
        : product.name;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(40, 10, 20, 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFDCFCE7) : const Color(0xFFF3F4F6),
          border: isLast
              ? null
              : const Border(bottom: BorderSide(color: Color(0xFFE5E7EB))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                sku,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? const Color(0xFF16A34A)
                      : const Color(0xFF374151),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              rupees(product.b2bPrice),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: isSelected
                    ? const Color(0xFF16A34A)
                    : const Color(0xFF6B7280),
              ),
            ),
            const SizedBox(width: 8),
            if (isSelected)
              const Icon(Icons.check_circle, size: 16, color: Color(0xFF16A34A))
            else
              const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }
}

// ─── Checklist widget ─────────────────────────────────────────────────────────

class _Checklist extends StatelessWidget {
  final List<String> items;
  final Color iconColor;
  final Color textColor;

  const _Checklist({
    required this.items,
    required this.iconColor,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (int i = 0; i < items.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(Icons.check, color: iconColor, size: 17),
              ),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  items[i],
                  style: TextStyle(color: textColor, fontSize: 13, height: 1.4),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
