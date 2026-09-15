// CHANGE #327 · LAYER 1 guard — a god-file is tech debt, and tech debt you
// cannot see is tech debt you keep paying.
//
// home_shell.dart was 5,139 lines holding boot, routing, the customer chrome,
// the admin chrome, the cart panel, the login panel and the view-as previews.
// That is why two unrelated commands — a partner-routing fix and a dashboard
// rebuild — collided on one file and one of them parked mid-build holding a
// loaded context. Sharding removed that particular hot spot; this scanner
// stops the next one forming quietly.
//
// It is a REPORT, never a gate: the biggest files in this repo are 15k-line
// admin screens, and failing the build on them would block every deploy
// tomorrow instead of paying the debt down deliberately. The report lands in
// rg_alerts as a warn-level 'god_file' row and on the Build lane card, so the
// list shrinks because someone chose to shrink it.
//
//   dart run tool/god_files.dart            # human-readable table
//   dart run tool/god_files.dart --json     # the payload scripts/god_files.sh posts
import 'dart:convert';
import 'dart:io';

/// Line count past which one file is presumed to hold more than one job.
const int kSizeThreshold = 900;

/// A file smaller than this is never flagged, however many concerns it names —
/// small files with several concerns are just normal Flutter widgets.
const int kConcernFloor = 400;

/// The concerns a shell-shaped file tends to accumulate. Keyed by the concern
/// name that ends up in the report; the values are the declaration-name
/// fragments that betray it. Matched against TOP-LEVEL DECLARATION NAMES only,
/// never free text, so a comment mentioning "login" is not a concern.
const Map<String, List<String>> kConcerns = {
  'boot/routing': ['route', 'router', 'boot', 'shell', 'splash', 'redirect'],
  'navigation': ['nav', 'sidebar', 'bottombar', 'header', 'menu', 'tab'],
  'auth': ['login', 'signin', 'signup', 'otp', 'password', 'reset'],
  'cart/checkout': ['cart', 'checkout', 'discount', 'sticky'],
  'search': ['search', 'suggest', 'query'],
  'profile/identity': ['profile', 'avatar', 'account', 'viewas'],
  'catalog': ['category', 'product', 'medicine', 'company'],
  'admin': ['admin', 'dashboard', 'registry'],
  'orders': ['order', 'pack', 'delivery', 'bag'],
  'money': ['price', 'bill', 'invoice', 'payment', 'upi', 'gst'],
};

final RegExp _decl = RegExp(
  r'^(?:abstract\s+|sealed\s+|final\s+|base\s+|interface\s+)*'
  r'(class|mixin|enum|extension)\s+([A-Za-z_][A-Za-z0-9_]*)',
  multiLine: true,
);

class FileDebt {
  final String path;
  final int lines;
  final int decls;
  final List<String> concerns;
  FileDebt(this.path, this.lines, this.decls, this.concerns);

  bool get oversize => lines > kSizeThreshold;
  bool get multiConcern => concerns.length > 1 && lines >= kConcernFloor;
  bool get flagged => oversize || multiConcern;

  /// Why it is on the list, in one sentence — the backend prints this verbatim.
  String get reason {
    if (oversize && multiConcern) {
      return '$lines lines and ${concerns.length} concerns '
          '(${concerns.join(', ')}) — split it before it is contended';
    }
    if (oversize) return '$lines lines — over the $kSizeThreshold-line threshold';
    return '${concerns.length} concerns (${concerns.join(', ')}) in one file';
  }

  Map<String, dynamic> toJson() => {
    'path': path,
    'lines': lines,
    'declarations': decls,
    'concerns': concerns,
    'oversize': oversize,
    'multi_concern': multiConcern,
    'reason': reason,
  };
}

List<String> _concernsOf(Iterable<String> names) {
  final hit = <String>[];
  for (final entry in kConcerns.entries) {
    final lowered = names.map((n) => n.toLowerCase());
    if (lowered.any((n) => entry.value.any(n.contains))) hit.add(entry.key);
  }
  return hit;
}

FileDebt _scan(File f, String repoRelative) {
  final src = f.readAsStringSync();
  final names = _decl.allMatches(src).map((m) => m.group(2)!).toList();
  return FileDebt(
    repoRelative,
    '\n'.allMatches(src).length + 1,
    names.length,
    _concernsOf(names),
  );
}

void main(List<String> args) {
  final asJson = args.contains('--json');
  final root = Directory('lib');
  if (!root.existsSync()) {
    stderr.writeln('god_files: run me from the repo root (no lib/ here)');
    exit(2);
  }

  final all = <FileDebt>[];
  for (final e in root.listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    all.add(_scan(e, e.path));
  }
  all.sort((a, b) => b.lines.compareTo(a.lines));
  final flagged = all.where((d) => d.flagged).toList();

  if (asJson) {
    stdout.writeln(
      jsonEncode({
        'scanned': all.length,
        'size_threshold': kSizeThreshold,
        'concern_floor': kConcernFloor,
        'total_lines': all.fold<int>(0, (s, d) => s + d.lines),
        'files': flagged.map((d) => d.toJson()).toList(),
      }),
    );
    return;
  }

  stdout.writeln('Scanned ${all.length} Dart files under lib/.');
  stdout.writeln('${flagged.length} carry god-file debt '
      '(> $kSizeThreshold lines, or >1 concern in ≥ $kConcernFloor lines):\n');
  for (final d in flagged) {
    stdout.writeln('  ${d.lines.toString().padLeft(6)}  ${d.path}');
    stdout.writeln('          ${d.reason}');
  }
}
