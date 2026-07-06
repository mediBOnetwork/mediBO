import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../theme.dart';
import '../../utils/render_log.dart';

const Color kBagHeaderGreen = Brand.green;
const int _kHeaderGreen = 0xFF1B7A43;

class BagPrintItem {
  final String bagNo;   // exactly what the card shows, e.g. "Bag 1"
  final String qrData;  // EXACT same string encoded in the on-screen QR
  const BagPrintItem(this.bagNo, this.qrData);
}

// Fixed density -> [cols, rows] grid so the card shape stays constant
// (near-square) across every density option; only count-per-page changes.
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

Future<void> printBags(List<BagPrintItem> bags, int perPage) async {
  if (bags.isEmpty) return;
  final g = _gridFor(perPage);
  final cols = g[0], rows = g[1];

  const double mLR = 8, mTB = 10;

  final doc = pw.Document();
  for (var start = 0; start < bags.length; start += perPage) {
    final end = math.min(start + perPage, bags.length);
    final slice = bags.sublist(start, end);
    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4.copyWith(
          marginLeft: mLR * PdfPageFormat.mm,
          marginRight: mLR * PdfPageFormat.mm,
          marginTop: mTB * PdfPageFormat.mm,
          marginBottom: mTB * PdfPageFormat.mm,
        ),
        build: (ctx) {
          // Fixed grid via nested Expanded rows/columns -> constant cell
          // shape at every density (NOT a GridView/childAspectRatio, which
          // reshapes cells as the density changes).
          return pw.Column(children: List.generate(rows, (r) {
            return pw.Expanded(child: pw.Row(children: List.generate(cols, (c) {
              final idx = r * cols + c;
              return pw.Expanded(
                child: idx < slice.length ? _cell(slice[idx]) : pw.Container(),
              );
            })));
          }));
        },
      ),
    );
  }
  RenderLog.write('c385_pdf_built_$perPage', bags.length);
  await Printing.layoutPdf(onLayout: (_) async => doc.save());
}

pw.Widget _cell(BagPrintItem b) {
  return pw.Container(
    margin: const pw.EdgeInsets.all(3),
    decoration: pw.BoxDecoration(
      color: PdfColors.white,
      border: pw.Border.all(color: PdfColors.grey500, width: 0.6),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(children: [
      pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        decoration: const pw.BoxDecoration(
          color: PdfColor.fromInt(_kHeaderGreen),
          borderRadius: pw.BorderRadius.only(
            topLeft: pw.Radius.circular(4), topRight: pw.Radius.circular(4)),
        ),
        child: pw.Center(
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            child: pw.Text(b.bagNo,
                style: pw.TextStyle(
                    color: PdfColors.white,
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 11)),
          ),
        ),
      ),
      pw.Expanded(
        child: pw.Center(
          child: pw.Padding(
            padding: const pw.EdgeInsets.all(4),
            child: pw.AspectRatio(
              aspectRatio: 1,
              child: pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: b.qrData,
                drawText: false,
                color: PdfColors.black,
              ),
            ),
          ),
        ),
      ),
    ]),
  );
}
