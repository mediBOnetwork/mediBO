// lib/services/crash_scrub.dart — CHANGE #473
//
// The PII scrubber that runs inside Sentry's beforeSend, and again before a
// crash is handed to the backend's local queue.
//
// It is a pure class on purpose: no Sentry import, no Flutter import, no
// network. That is what lets test/protected/crash_scrub_test.dart pin it on the
// Dart VM in milliseconds — a scrubber that is only exercised through the SDK
// is a scrubber nobody can prove.
//
// THE APP RENDERS, IT NEVER DECIDES: this file holds no list of what is
// sensitive. The keys, the patterns and the mask all arrive from
// crash_config_get(); adding "irn" to the redaction list is an UPDATE on
// crash_config, not a deploy. A scrubber with no rules redacts nothing and says
// so ([hasRules]) rather than inventing a default list — a Dart fallback here
// would be a second, stale copy of the privacy policy.

/// One backend-supplied pattern. `ci` travels as data because Dart's RegExp
/// rejects an inline `(?i)` group while Postgres accepts it — same list, two
/// engines, identical result.
class CrashScrubPattern {
  final String name;
  final String regex;
  final bool caseInsensitive;

  const CrashScrubPattern({
    required this.name,
    required this.regex,
    required this.caseInsensitive,
  });

  factory CrashScrubPattern.fromJson(Map<String, dynamic> j) => CrashScrubPattern(
        name: j['name']?.toString() ?? '',
        regex: j['regex']?.toString() ?? '',
        caseInsensitive: j['ci'] == true,
      );
}

class CrashScrubber {
  /// jsonb keys whose VALUE is replaced wholesale, matched case-insensitively.
  final Set<String> keys;

  /// Patterns run over every string, wherever it sits in the payload.
  final List<RegExp> patterns;

  /// What a redacted value is replaced with, e.g. `[redacted]`.
  final String mask;

  CrashScrubber._(this.keys, this.patterns, this.mask);

  /// An explicitly empty scrubber. Used before the config lands: with no rules
  /// nothing is sent to Sentry at all, so "redacts nothing" is never reachable
  /// in production — see CrashReporting.
  static final CrashScrubber empty =
      CrashScrubber._(const <String>{}, const <RegExp>[], '');

  /// True once the backend's rules are loaded. False means "I have not been
  /// told what is sensitive yet", which is a reason to drop an event, never a
  /// reason to guess.
  bool get hasRules => keys.isNotEmpty || patterns.isNotEmpty;

  /// Builds a scrubber from the crash_config_get() payload. An unparseable
  /// pattern is skipped rather than thrown — one bad regex must not disable
  /// the other eight.
  factory CrashScrubber.fromConfig({
    required List<dynamic> scrubKeys,
    required List<dynamic> scrubPatterns,
    required String mask,
  }) {
    final k = <String>{};
    for (final e in scrubKeys) {
      final s = e?.toString().trim().toLowerCase() ?? '';
      if (s.isNotEmpty) k.add(s);
    }
    final p = <RegExp>[];
    for (final e in scrubPatterns) {
      if (e is! Map) continue;
      final pat = CrashScrubPattern.fromJson(Map<String, dynamic>.from(e));
      if (pat.regex.isEmpty) continue;
      try {
        p.add(RegExp(pat.regex, caseSensitive: !pat.caseInsensitive));
      } catch (_) {
        // A pattern this Dart RegExp engine cannot compile is skipped.
      }
    }
    return CrashScrubber._(k, p, mask);
  }

  /// Redacts every backend pattern found in [input].
  String text(String? input) {
    var s = input ?? '';
    if (s.isEmpty) return '';
    for (final re in patterns) {
      s = s.replaceAll(re, mask);
    }
    return s;
  }

  /// Recursively scrubs a JSON-shaped structure: a key on the backend's list
  /// loses its whole value; every remaining string is pattern-scrubbed.
  dynamic value(dynamic input) {
    if (input == null) return null;
    if (input is String) return text(input);
    if (input is num || input is bool) return input;
    if (input is List) return input.map(value).toList();
    if (input is Map) {
      final out = <String, dynamic>{};
      input.forEach((k, v) {
        final key = k?.toString() ?? '';
        if (keys.contains(key.toLowerCase())) {
          out[key] = mask;
        } else {
          out[key] = value(v);
        }
      });
      return out;
    }
    // Anything else (an object the SDK put in extra) is stringified and
    // scrubbed rather than passed through unread.
    return text(input.toString());
  }

  /// Convenience for the two Map-shaped fields a crash carries.
  Map<String, dynamic> map(Map<String, dynamic>? input) {
    if (input == null) return const <String, dynamic>{};
    final v = value(input);
    return v is Map<String, dynamic> ? v : <String, dynamic>{};
  }
}
