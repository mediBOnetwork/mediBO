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

Future<void> printBags(List<BagPrintItem> bags, int perPage) async {
  RenderLog.write('c391_perpage_$perPage', perPage);
  if (bags.isEmpty) return;

  final layout = layoutFor(perPage);
  final cols = layout.cols, rows = layout.rows;
  final double cardW = layout.cellW, cardH = layout.cellH;
  final double fontSize = fontSizeForCellH(cardH);
  RenderLog.write(
      'c391_cellH_${cardH.round()}_font_${fontSize.toStringAsFixed(1)}', 1);
  RenderLog.write('c391_fits_${layout.fits ? 1 : 0}', layout.fits ? 1 : 0);

  const mm = PdfPageFormat.mm;
  const double gut = kBagGutterPt;

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
            return pw.Container(
              height: cardH,
              margin: pw.EdgeInsets.only(bottom: r < rows - 1 ? gut : 0),
              child: pw.Row(
                children: List.generate(cols, (c) {
                  final idx = r * cols + c;
                  return pw.Container(
                    width: cardW,
                    height: cardH,
                    margin: pw.EdgeInsets.only(right: c < cols - 1 ? gut : 0),
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
  RenderLog.write('c391_total_$total', total);
  RenderLog.write('c391_rendered_$rendered', rendered);
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
