import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../theme.dart';
import '../../utils/render_log.dart';
import 'bag_print_grid.dart';

export 'bag_print_grid.dart';

const Color kBagHeaderGreen = Brand.green;
const int _kHeaderGreen = 0xFF1B7A43;

const double _headerFrac = 0.18; // header band height as fraction of card height

class BagPrintItem {
  final String bagNo;   // exactly what the card shows, e.g. "Bag 1"
  final String qrData;  // EXACT same string encoded in the on-screen QR
  const BagPrintItem(this.bagNo, this.qrData);
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
  RenderLog.write('c390_perPage_received_$perPage', perPage);
  if (bags.isEmpty) return;

  final g = gridFor(perPage);
  final cols = g[0], rows = g[1];
  RenderLog.write('c390_cols_${cols}_rows_${rows}_perpage_$perPage', 1);
  final double fontSize = _fontSizeForCols(cols);

  const mm = PdfPageFormat.mm;
  const double gut = 5.0;
  final double areaW = (210 - 16) * mm; // 8mm L/R margins
  final double areaH = (297 - 20) * mm; // 10mm T/B margins

  // Cards FILL the slots (no aspect lock) so they tile the whole printable
  // area with only the small fixed gutter between them — no dead margins.
  final double cardW = (areaW - (cols - 1) * gut) / cols;
  final double cardH = (areaH - (rows - 1) * gut) / rows;

  final int total = bags.length;
  var rendered = 0;
  final pages = paginateBagIndices(total, perPage);

  final doc = pw.Document();
  for (final pageIndices in pages) {
    final slice = pageIndices.map((i) => bags[i]).toList();
    rendered += slice.length;
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
  RenderLog.write('c390_bags_total_$total', total);
  RenderLog.write('c390_bags_rendered_$rendered', rendered);
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
