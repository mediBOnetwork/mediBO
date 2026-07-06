import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../theme.dart';
import '../../utils/render_log.dart';

const Color kBagHeaderGreen = Brand.green;
const int _kHeaderGreen = 0xFF1B7A43;

const double _headerFrac = 0.18; // header band height as fraction of card height

class BagPrintItem {
  final String bagNo;   // exactly what the card shows, e.g. "Bag 1"
  final String qrData;  // EXACT same string encoded in the on-screen QR
  const BagPrintItem(this.bagNo, this.qrData);
}

// Fixed density -> [cols, rows] grid.
const Map<int, List<int>> _grid = {
  1: [1, 1], 2: [1, 2], 4: [2, 2], 6: [2, 3], 8: [2, 4], 9: [3, 3],
  10: [2, 5], 12: [3, 4], 14: [2, 7], 16: [4, 4], 18: [3, 6],
  20: [4, 5], 21: [3, 7], 24: [4, 6],
};

List<int> _gridFor(int n) {
  if (_grid.containsKey(n)) return _grid[n]!;
  final cols = math.max(1, (math.sqrt(n * (210 / 297))).round());
  return [cols, (n / cols).ceil()];
}

// One fixed header font size per column count — same size on EVERY card of a
// given sheet, so "Bag 1" and "Bag 24" never differ in size on the same page.
double _fontSizeForCols(int cols) {
  if (cols <= 2) return 12;
  if (cols == 3) return 10;
  if (cols == 4) return 8.5;
  return 8;
}

Future<void> printBags(List<BagPrintItem> bags, int perPage) async {
  if (bags.isEmpty) return;
  final g = _gridFor(perPage);
  final cols = g[0], rows = g[1];
  final double fontSize = _fontSizeForCols(cols);

  const mm = PdfPageFormat.mm;
  const double gut = 5.0;
  final double areaW = (210 - 16) * mm; // 8mm L/R margins
  final double areaH = (297 - 20) * mm; // 10mm T/B margins

  // Cards FILL the slots (no aspect lock) so they tile the whole printable
  // area with only the small fixed gutter between them — no dead margins.
  final double cardW = (areaW - (cols - 1) * gut) / cols;
  final double cardH = (areaH - (rows - 1) * gut) / rows;

  final doc = pw.Document();
  for (var start = 0; start < bags.length; start += perPage) {
    final end = math.min(start + perPage, bags.length);
    final slice = bags.sublist(start, end);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: 8 * mm,
          marginRight: 8 * mm,
          marginTop: 10 * mm,
          marginBottom: 10 * mm,
        ),
        build: (ctx) => pw.Column(
          children: List.generate(rows, (r) {
            return pw.Padding(
              padding: pw.EdgeInsets.only(bottom: r < rows - 1 ? gut : 0),
              child: pw.Row(
                children: List.generate(cols, (c) {
                  final idx = r * cols + c;
                  return pw.Padding(
                    padding: pw.EdgeInsets.only(right: c < cols - 1 ? gut : 0),
                    child: idx < slice.length
                        ? _card(slice[idx], cardW, cardH, fontSize)
                        : pw.SizedBox(width: cardW, height: cardH),
                  );
                }),
              ),
            );
          }),
        ),
      ),
    );
  }
  RenderLog.write('c387_pdf_built_$perPage', bags.length);
  RenderLog.write('c387_fixed_font_fill', 1);
  await Printing.layoutPdf(onLayout: (_) async => doc.save());
}

pw.Widget _card(BagPrintItem b, double w, double h, double fontSize) {
  final double headerH = h * _headerFrac;
  final double bodyH = h - headerH;
  final double qr = math.min(w, bodyH) - 8; // even padding, max square

  return pw.SizedBox(
    width: w,
    height: h,
    child: pw.Container(
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        border: pw.Border.all(color: PdfColors.grey500, width: 0.6),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(children: [
        pw.Container(
          width: double.infinity,
          height: headerH,
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(_kHeaderGreen),
            borderRadius: pw.BorderRadius.only(
              topLeft: pw.Radius.circular(4), topRight: pw.Radius.circular(4)),
          ),
          child: pw.Center(
            child: pw.Text(
              b.bagNo,
              maxLines: 1,
              softWrap: false,
              style: pw.TextStyle(
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                  fontSize: fontSize),
            ),
          ),
        ),
        pw.Expanded(
          child: pw.Center(
            child: pw.SizedBox(
              width: qr,
              height: qr,
              child: pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: b.qrData,
                drawText: false,
                color: PdfColors.black,
              ),
            ),
          ),
        ),
      ]),
    ),
  );
}
