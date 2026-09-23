// CMD #2191 (Om) — "the new mediBO logo should show in the Android app, the
// one the website shows".
//
// The website draws web/icons/Icon-512.v4.png: a rounded green tile with the
// white mark on it. Android's launcher was still drawing a LEGACY icon, which
// Android 8+ shrinks onto a white plate — same artwork, wrong presentation, so
// the phone looked like it was on an older logo than the site.
//
// This writes the ADAPTIVE icon from that exact file, so the two can never
// drift: the background layer is the tile's own green (sampled from it, top to
// bottom, as a gradient), the foreground layer is the tile's own white mark on
// a transparent canvas, placed in the 66% safe zone, and the monochrome layer
// is the same mark for themed icons. The legacy ic_launcher.png per density is
// written from the same source too.
//
//   dart run tool/c2191_android_icon.dart
//
// Nothing here is a brand decision: every pixel comes out of the source PNG.

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const String kSource = 'web/icons/Icon-512.v4.png';
const String kRes = 'android/app/src/main/res';

/// dp of the adaptive canvas, per density bucket.
const Map<String, int> kAdaptive = {
  'mipmap-mdpi': 108,
  'mipmap-hdpi': 162,
  'mipmap-xhdpi': 216,
  'mipmap-xxhdpi': 324,
  'mipmap-xxxhdpi': 432,
};

/// Legacy launcher icon sizes, unchanged from Flutter's own template.
const Map<String, int> kLegacy = {
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

void main() {
  final src = img.decodePng(File(kSource).readAsBytesSync());
  if (src == null) throw StateError('cannot read $kSource');

  // The tile itself: the source PNG has an opaque WHITE margin around it, so
  // the artwork has to be found before it can be read.
  final box = _tileBox(src);
  stdout.writeln('tile: ${box[0]},${box[1]} -> ${box[2]},${box[3]}');
  final top = _sampleGreen(src, box, 0.12),
      bottom = _sampleGreen(src, box, 0.88);
  stdout.writeln('background gradient: '
      '#${_hex(top)} -> #${_hex(bottom)}');

  // The mark alone: every near-white opaque pixel of the tile, cropped tight.
  final mark = _extractMark(src, box);
  stdout.writeln('mark: ${mark.width}x${mark.height}');

  for (final e in kAdaptive.entries) {
    final dir = Directory('$kRes/${e.key}')..createSync(recursive: true);
    final n = e.value;

    final bg = img.Image(width: n, height: n, numChannels: 4);
    for (var y = 0; y < n; y++) {
      final t = y / (n - 1);
      final c = img.ColorRgba8(
        _mix(top.r, bottom.r, t), _mix(top.g, bottom.g, t),
        _mix(top.b, bottom.b, t), 255);
      for (var x = 0; x < n; x++) {
        bg.setPixel(x, y, c);
      }
    }
    File('${dir.path}/ic_launcher_background.png')
        .writeAsBytesSync(img.encodePng(bg));

    // The mark sits in the 66 dp safe zone of the 108 dp canvas: anything
    // outside it can be masked away by the launcher's shape.
    final safe = (n * 0.42).round();
    final scaled = img.copyResize(mark,
        width: mark.width >= mark.height ? safe : null,
        height: mark.height > mark.width ? safe : null,
        interpolation: img.Interpolation.cubic);
    final fg = img.Image(width: n, height: n, numChannels: 4);
    img.compositeImage(fg, scaled,
        dstX: ((n - scaled.width) / 2).round(),
        dstY: ((n - scaled.height) / 2).round());
    File('${dir.path}/ic_launcher_foreground.png')
        .writeAsBytesSync(img.encodePng(fg));
    File('${dir.path}/ic_launcher_monochrome.png')
        .writeAsBytesSync(img.encodePng(fg));

    // The legacy icon: the whole tile, for launchers older than adaptive.
    final legacy = img.copyResize(src,
        width: kLegacy[e.key]!,
        height: kLegacy[e.key]!,
        interpolation: img.Interpolation.cubic);
    File('${dir.path}/ic_launcher.png')
        .writeAsBytesSync(img.encodePng(legacy));
  }

  // The status-bar icon: the same mark, white on transparent, at 24 dp. Android
  // tints it, so anything but a silhouette comes out as a white blob.
  const Map<String, int> stat = {
    'drawable-mdpi': 24,
    'drawable-hdpi': 36,
    'drawable-xhdpi': 48,
    'drawable-xxhdpi': 72,
    'drawable-xxxhdpi': 96,
  };
  for (final e in stat.entries) {
    final dir = Directory('$kRes/${e.key}')..createSync(recursive: true);
    final n = e.value;
    final inner = (n * 0.82).round();
    final scaled = img.copyResize(mark,
        width: mark.width >= mark.height ? inner : null,
        height: mark.height > mark.width ? inner : null,
        interpolation: img.Interpolation.cubic);
    final out = img.Image(width: n, height: n, numChannels: 4);
    img.compositeImage(out, scaled,
        dstX: ((n - scaled.width) / 2).round(),
        dstY: ((n - scaled.height) / 2).round());
    File('${dir.path}/ic_stat_medibo.png').writeAsBytesSync(img.encodePng(out));
  }

  // The launch screen: the tile itself, centred on white, so the app opens on
  // the mark on every Android version rather than on a blank sheet.
  for (final d in const ['drawable', 'drawable-v21']) {
    final dir = Directory('$kRes/$d')..createSync(recursive: true);
    File('${dir.path}/launch_background.xml').writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<!-- CMD #2191 (Om) — the launch screen carries the mark, not a blank sheet.
     @mipmap/ic_launcher is generated from web/icons/Icon-512.v4.png by
     tool/c2191_android_icon.dart, so it is the website's own artwork. -->
<layer-list xmlns:android="http://schemas.android.com/apk/res/android">
    <item android:drawable="@android:color/white" />
    <item>
        <bitmap
            android:gravity="center"
            android:src="@mipmap/ic_launcher" />
    </item>
</layer-list>
''');
  }

  final any = Directory('$kRes/mipmap-anydpi-v26')..createSync(recursive: true);
  const xml = '''<?xml version="1.0" encoding="utf-8"?>
<!-- CMD #2191 — generated by tool/c2191_android_icon.dart from
     web/icons/Icon-512.v4.png, the same file the website serves. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome"/>
</adaptive-icon>
''';
  File('${any.path}/ic_launcher.xml').writeAsStringSync(xml);
  File('${any.path}/ic_launcher_round.xml').writeAsStringSync(xml);
  stdout.writeln('adaptive icon, status-bar icon and launch screen written '
      'for ${kAdaptive.length} densities');
}

int _mix(num a, num b, double t) => (a + (b - a) * t).round().clamp(0, 255);

String _hex(img.Color c) => [c.r, c.g, c.b]
    .map((v) => v.toInt().toRadixString(16).padLeft(2, '0'))
    .join();

/// The bounding box of the green tile inside the (white-margined) source.
List<int> _tileBox(img.Image im) {
  int x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
  for (var y = 0; y < im.height; y++) {
    for (var x = 0; x < im.width; x++) {
      final p = im.getPixel(x, y);
      final green = p.g > p.r + 20 && p.g > p.b + 20;
      if (!green) continue;
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x > x1) x1 = x;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) throw StateError('no green tile found in $kSource');
  return [x0, y0, x1, y1];
}

/// The tile's green at [frac] of ITS height, read a little inside its left
/// edge where the mark never reaches and the corner rounding has ended.
img.Color _sampleGreen(img.Image im, List<int> box, double frac) {
  final h = box[3] - box[1], w = box[2] - box[0];
  final y = (box[1] + h * frac).round();
  for (var x = (box[0] + w * 0.12).round(); x < box[2]; x++) {
    final p = im.getPixel(x, y);
    if (p.g > p.r + 20 && p.g > p.b + 20) return p;
  }
  return img.ColorRgba8(27, 122, 67, 255);
}

/// The mark alone: the near-white pixels INSIDE the tile, cropped tight. The
/// margin outside the tile is white too, which is why the box matters.
img.Image _extractMark(img.Image im, List<int> box) {
  int x0 = im.width, y0 = im.height, x1 = -1, y1 = -1;
  final out = img.Image(width: im.width, height: im.height, numChannels: 4);
  bool green(int x, int y) {
    final p = im.getPixel(x, y);
    return p.g > p.r + 20 && p.g > p.b + 20;
  }

  // A white pixel counts as the MARK only when the tile surrounds it: green
  // somewhere to its left AND right AND above AND below. The rounded tile's
  // corners are white margin inside the same bounding box, and that is what
  // dragged the first attempt out to the full square.
  bool enclosed(int x, int y) {
    var l = false, r = false, u = false, d = false;
    for (var i = box[0]; i < x && !l; i++) {
      l = green(i, y);
    }
    for (var i = box[2]; i > x && !r; i--) {
      r = green(i, y);
    }
    for (var j = box[1]; j < y && !u; j++) {
      u = green(x, j);
    }
    for (var j = box[3]; j > y && !d; j--) {
      d = green(x, j);
    }
    return l && r && u && d;
  }

  for (var y = box[1]; y <= box[3]; y++) {
    for (var x = box[0]; x <= box[2]; x++) {
      final p = im.getPixel(x, y);
      if (!(p.r > 200 && p.g > 200 && p.b > 200)) continue;
      if (!enclosed(x, y)) continue;
      out.setPixel(x, y, img.ColorRgba8(255, 255, 255, 255));
      if (x < x0) x0 = x;
      if (y < y0) y0 = y;
      if (x > x1) x1 = x;
      if (y > y1) y1 = y;
    }
  }
  if (x1 < 0) throw StateError('no mark found in $kSource');
  return img.copyCrop(out, x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1);
}
