import 'dart:math' as math;
import 'package:flutter/painting.dart' show Color;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

const Color kBagHeaderRed = Color(0xFFD32F2F);
const int _kRedHeader = 0xFFD32F2F;

class BagPrintItem {
  final String bagNo;   // exactly what the card shows, e.g. "Bag 1"
  final String qrData;  // EXACT same string encoded in the on-screen QR
  const BagPrintItem(this.bagNo, this.qrData);
}

// Columns per page-density option (chosen for scannable QR on A4 portrait).
const Map<int, int> kBagGridCols = {
  4: 2, 6: 2, 8: 2, 10: 2, 12: 3, 14: 2,
  16: 4, 18: 3, 20: 4, 22: 2, 24: 4,
};

int _colsFor(int perPage) =>
    kBagGridCols[perPage] ??
    math.max(1, (math.sqrt(perPage * (210 / 297))).round());

Future<void> printBags(List<BagPrintItem> bags, int perPage) async {
  if (bags.isEmpty) return;
  final cols = _colsFor(perPage);
  final rows = (perPage / cols).ceil();

  // Printable area of A4 portrait after margins (mm).
  const double mLR = 8, mTB = 10;
  final double areaW = 210 - 2 * mLR;
  final double areaH = 297 - 2 * mTB;
  final double cellAspect = (areaW / cols) / (areaH / rows); // w/h

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
        build: (ctx) => pw.GridView(
          crossAxisCount: cols,
          childAspectRatio: cellAspect,
          children: slice.map(_cell).toList(),
        ),
      ),
    );
  }
  await Printing.layoutPdf(onLayout: (_) async => doc.save());
}

pw.Widget _cell(BagPrintItem b) {
  return pw.Container(
    margin: const pw.EdgeInsets.all(4),
    decoration: pw.BoxDecoration(
      border: pw.Border.all(color: PdfColors.grey500, width: 0.6),
      borderRadius: pw.BorderRadius.circular(4),
    ),
    child: pw.Column(
      mainAxisAlignment: pw.MainAxisAlignment.center,
      children: [
        pw.Container(
          width: double.infinity,
          padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 2),
          decoration: const pw.BoxDecoration(
            color: PdfColor.fromInt(_kRedHeader),
            borderRadius: pw.BorderRadius.only(
              topLeft: pw.Radius.circular(4), topRight: pw.Radius.circular(4)),
          ),
          child: pw.Center(
            child: pw.Text(b.bagNo,
              style: pw.TextStyle(
                color: PdfColors.white,
                fontWeight: pw.FontWeight.bold,
                fontSize: 11)),
          ),
        ),
        pw.Expanded(
          child: pw.Padding(
            padding: const pw.EdgeInsets.all(6),
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: b.qrData,
              drawText: false,
              color: PdfColors.black,
            ),
          ),
        ),
      ],
    ),
  );
}
