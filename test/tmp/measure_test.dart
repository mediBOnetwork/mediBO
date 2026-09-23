import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('measure', () async {
    final loader = FontLoader('DMSans');
    for (final w in ['400', '500', '600', '700']) {
      final f = File('assets/fonts/DMSans-$w.ttf');
      loader.addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    }
    await loader.load();
    const full = [
      'Ordering is open','Ordering closed for today','Ordering closing soon',
      'Ordering closed right now','Keep your list ready','Order fast','Order now',
      'Last chance today','We are packing today’s orders','We are accepting your orders',
      'We are collecting your items','Items arriving at warehouse','We are asking suppliers',
      'We are taking orders','Ordering opens in 45 minutes','Only 25 minutes left to order',
    ];
    const narrow = [
      'Open now','Closed today','Closing soon','Closed right now','Open all day',
      'List ready','Order fast','Order now','Last chance','Packing orders',
      'Accepting orders','Collecting items','Items arriving','Asking suppliers',
      'Taking orders','Ordering stock','Ready to dispatch','Out for delivery',
      'Counting items','45 min left','Only 1 min left','12 hrs left','1 hr left',
      'Opens in 45 min','Opens in 12 hrs','Opens tomorrow','Register to order',
      'Only 25 min left',
    ];
    double w(String t) {
      final tp = TextPainter(
        text: TextSpan(text: t, style: const TextStyle(fontFamily: 'DMSans', fontSize: 14, fontWeight: FontWeight.w600, height: 1)),
        textDirection: TextDirection.ltr)..layout();
      return tp.width;
    }
    double mx = 0; String mxs = '';
    for (final t in full) { final x = w(t); if (x > mx) { mx = x; mxs = t; } }
    // ignore: avoid_print
    print('FULL max ${mx.toStringAsFixed(1)} "$mxs"');
    mx = 0; mxs = '';
    for (final t in narrow) { final x = w(t); if (x > mx) { mx = x; mxs = t; } print('N ${x.toStringAsFixed(1)} $t'); }
    // ignore: avoid_print
    print('NARROW max ${mx.toStringAsFixed(1)} "$mxs"');
  });
}
