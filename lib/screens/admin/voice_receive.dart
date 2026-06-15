// ignore_for_file: avoid_web_libraries_in_flutter
import 'dart:js_interop';

// ── JS bridge declarations (functions exposed by web/index.html) ───────────

/// Returns `true` if the browser's SpeechRecognition API is available.
@JS('mediboVoiceSupported')
external JSAny? _jsVoiceSupportedRaw;

/// Start one push-to-talk utterance.
/// - onInterim(String) — called with live partial transcript
/// - onFinal(String)   — called once with the final transcript (or '' on no-speech)
/// - onError(String)   — called with error code ('not-allowed', 'no-speech', …)
@JS('mediboVoiceStart')
external void _jsVoiceStart(JSFunction onInterim, JSFunction onFinal, JSFunction onError);

/// Stop/abort the current recognition session.
@JS('mediboVoiceStop')
external void _jsVoiceStop();

/// Speak a short string via SpeechSynthesis (optional TTS echo).
@JS('mediboVoiceSpeak')
external void _jsVoiceSpeak(JSString text);

// ── Public thin wrappers ────────────────────────────────────────────────────

bool get voiceApiSupported {
  try {
    final v = _jsVoiceSupportedRaw;
    return v != null && v.dartify() == true;
  } catch (_) {
    return false;
  }
}

/// Start listening. Callbacks receive Dart String values.
void startVoiceListen({
  required void Function(String) onInterim,
  required void Function(String) onFinal,
  required void Function(String) onError,
}) {
  try {
    _jsVoiceStart(
      ((JSAny? t) => onInterim((t?.dartify() as String?) ?? '')).toJS,
      ((JSAny? t) => onFinal((t?.dartify() as String?) ?? '')).toJS,
      ((JSAny? e) => onError((e?.dartify() as String?) ?? 'unknown')).toJS,
    );
  } catch (e) {
    onError('start-failed: $e');
  }
}

void stopVoiceListen() {
  try { _jsVoiceStop(); } catch (_) {}
}

void speakText(String text) {
  try { _jsVoiceSpeak(text.toJS); } catch (_) {}
}

// ── Data classes ─────────────────────────────────────────────────────────────

/// Result of parsing one utterance segment.
class ParsedItem {
  final String rawSegment;
  final String itemPhrase; // cleaned phrase without qty/unit
  final double? qty;       // null = not found, must prompt user
  final String? unit;      // optional spoken unit (for echo only)

  const ParsedItem({
    required this.rawSegment,
    required this.itemPhrase,
    this.qty,
    this.unit,
  });

  @override
  String toString() =>
      'ParsedItem(phrase="$itemPhrase", qty=$qty, unit=$unit, raw="$rawSegment")';
}

/// Result of matching an item phrase against the loaded box list.
sealed class MatchResult {}

class MatchConfident extends MatchResult {
  final int productId;
  final String productName;
  MatchConfident(this.productId, this.productName);
}

class MatchAmbiguous extends MatchResult {
  final List<MatchCandidate> candidates;
  MatchAmbiguous(this.candidates);
}

class MatchCandidate {
  final int productId;
  final String productName;
  final double score;
  MatchCandidate(this.productId, this.productName, this.score);
}

class MatchNone extends MatchResult {}

// ── Constants ─────────────────────────────────────────────────────────────────

/// Unit tokens recognized in utterances (for echo only; never block on missing).
const _kUnits = {
  'strip', 'strips', 'tab', 'tablet', 'tablets', 'cap', 'capsule', 'capsules',
  'bottle', 'bottles', 'syrup', 'tube', 'tubes', 'box', 'boxes', 'vial', 'vials',
  'ampoule', 'ampoules', 'injection', 'sachet', 'sachets', 'pack', 'packs',
  'piece', 'pieces', 'ml', 'gm', 'unit', 'units', 'patch', 'patches', 'cream',
  'lotion', 'gel', 'drop', 'drops', 'inhaler', 'inhale',
};

/// Filler words to strip from the item phrase.
const _kFillers = {
  'the', 'a', 'an', 'add', 'mark', 'received', 'receive', 'got', 'get',
  'we', 'put', 'set', 'please', 'also', 'and', 'next',
};

/// Command words (not product names).
const _kCommands = {'undo', 'stop', 'done', 'finish', 'cancel', 'repeat', 'again'};

// ── Text normalization ────────────────────────────────────────────────────────

String normalizeText(String s) {
  // lowercase, collapse whitespace, strip punctuation except digits, hyphens, spaces
  var result = s
      .toLowerCase()
      .replaceAll(RegExp(r"[^\w\s\-]"), ' ')
      .replaceAll('-', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return result;
}

// ── Number word parsing ───────────────────────────────────────────────────────

const _kOnes = <String, double>{
  'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
  'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10,
  'eleven': 11, 'twelve': 12, 'thirteen': 13, 'fourteen': 14,
  'fifteen': 15, 'sixteen': 16, 'seventeen': 17, 'eighteen': 18,
  'nineteen': 19,
};
const _kTens = <String, double>{
  'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50,
  'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90,
};

/// Convert a (possibly multi-word) number string to a double.
/// Returns null if not recognized.
/// Pure function — safe to call from render_verify.js test harness.
double? numberWordsToDouble(String s) {
  s = s.trim().toLowerCase();
  if (s.isEmpty) return null;

  // Direct digit(s) — allow decimal
  final direct = double.tryParse(s.replaceAll(RegExp(r'[^\d.]'), ''));
  if (direct != null && RegExp(r'^\d').hasMatch(s)) return direct;

  // Special phrases
  if (s == 'a' || s == 'an') return 1.0;
  if (s == 'couple' || s == 'a couple') return 2.0;
  if (s == 'half a dozen') return 6.0;
  if (s == 'dozen' || s == 'a dozen') return 12.0;
  if (s == 'one and a half' || s == '1 and a half') return 1.5;

  // Ones/teens
  if (_kOnes.containsKey(s)) return _kOnes[s];

  // Tens
  if (_kTens.containsKey(s)) return _kTens[s];

  // "twenty five", "thirty-two", etc.
  for (final e in _kTens.entries) {
    for (final sep in [' ', '-']) {
      if (s.startsWith(e.key + sep)) {
        final rest = s.substring(e.key.length + 1).trim();
        if (_kOnes.containsKey(rest)) return e.value + _kOnes[rest]!;
      }
    }
  }
  return null;
}

// ── Utterance parser ──────────────────────────────────────────────────────────

/// Split a raw transcript into segments and parse each into a [ParsedItem].
/// Pure — no UI side effects. Safe to unit-test from render_verify.js.
List<ParsedItem> parseUtterance(String transcript) {
  // Normalize
  final norm = normalizeText(transcript);

  // Check for command words (whole utterance)
  final trimmed = norm.trim();
  if (_kCommands.contains(trimmed)) {
    return [ParsedItem(rawSegment: transcript, itemPhrase: trimmed, qty: null, unit: null)];
  }

  // Split on " and ", commas, "next"
  final segments = norm
      .split(RegExp(r'\s*(?:,|\band\b|\bnext\b)\s*'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  return segments.map((seg) => _parseSegment(seg, transcript)).toList();
}

ParsedItem _parseSegment(String seg, String rawTranscript) {
  // Tokenize
  final tokens = seg.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  if (tokens.isEmpty) {
    return ParsedItem(rawSegment: rawTranscript, itemPhrase: '', qty: null, unit: null);
  }

  // ── Step 1: find the UNIT token (look at last 1-2 tokens) ──────────────────
  String? unit;
  int unitIdx = -1;
  for (var i = tokens.length - 1; i >= tokens.length - 2 && i >= 0; i--) {
    if (_kUnits.contains(tokens[i])) {
      unit = tokens[i];
      unitIdx = i;
      break;
    }
  }

  // ── Step 2: find the QUANTITY ─────────────────────────────────────────────
  // Prefer a number immediately before the unit (or at end if no unit).
  double? qty;
  int qtyStartIdx = -1;
  int qtyEndIdx = -1; // inclusive

  if (unitIdx > 0) {
    // Check the token(s) immediately before the unit for a number
    // Try multi-word numbers: "twenty five" before unit
    if (unitIdx >= 2) {
      final twoWord = '${tokens[unitIdx - 2]} ${tokens[unitIdx - 1]}';
      final v = numberWordsToDouble(twoWord);
      if (v != null) {
        qty = v;
        qtyStartIdx = unitIdx - 2;
        qtyEndIdx = unitIdx - 1;
      }
    }
    if (qty == null) {
      final oneWord = tokens[unitIdx - 1];
      final v = numberWordsToDouble(oneWord);
      if (v != null) {
        qty = v;
        qtyStartIdx = unitIdx - 1;
        qtyEndIdx = unitIdx - 1;
      }
    }
  }

  if (qty == null) {
    // No unit or no number before unit: scan from the END for a standalone number
    // Heuristic: a trailing number not bound to a brand name is the qty.
    final scanLimit = unitIdx >= 0 ? unitIdx : tokens.length;
    for (var i = scanLimit - 1; i >= 0; i--) {
      final v = numberWordsToDouble(tokens[i]);
      if (v != null) {
        // C6: strength-in-name check — if this is the ONLY number and we have a
        // candidate product whose name contains this number as strength,
        // don't treat it as qty yet (return qty=null so the caller can prompt).
        // We can't check against the box list here (it's a pure fn), so we set a
        // flag in ParsedItem. The CALLER must handle qty=null by prompting.
        // Note: if there's a unit token present, the number is almost certainly qty.
        if (unitIdx >= 0 || i == scanLimit - 1) {
          qty = v;
          qtyStartIdx = i;
          qtyEndIdx = i;
        }
        break;
      }
    }
  }

  // ── Step 3: build item phrase (remove qty tokens + unit token) ─────────────
  final keepMask = List<bool>.filled(tokens.length, true);
  if (qtyStartIdx >= 0) {
    for (var i = qtyStartIdx; i <= qtyEndIdx; i++) keepMask[i] = false;
  }
  if (unitIdx >= 0) keepMask[unitIdx] = false;

  final phraseTokens = <String>[];
  for (var i = 0; i < tokens.length; i++) {
    if (keepMask[i]) phraseTokens.add(tokens[i]);
  }

  // ── Step 4: strip filler words from the phrase ─────────────────────────────
  final cleaned = phraseTokens.where((t) => !_kFillers.contains(t)).toList();

  final itemPhrase = cleaned.join(' ').trim();

  return ParsedItem(
    rawSegment: seg,
    itemPhrase: itemPhrase,
    qty: qty,
    unit: unit,
  );
}

// ── Box list matcher ──────────────────────────────────────────────────────────

/// Match [phrase] against [boxItems] from get_receiving_box.
/// Returns a [MatchConfident], [MatchAmbiguous], or [MatchNone].
/// Pure — no UI side effects.
MatchResult matchToBox(String phrase, List<Map<String, dynamic>> boxItems) {
  if (phrase.isEmpty || boxItems.isEmpty) return MatchNone();

  final normPhrase = normalizeText(phrase);
  if (normPhrase.isEmpty || normPhrase.length < 3) return MatchNone();

  // Build deduped product list (product_id -> product_name)
  final seen = <int>{};
  final products = <({int id, String name})>[];
  for (final item in boxItems) {
    final id = (item['product_id'] as num?)?.toInt();
    final name = item['product_name']?.toString();
    if (id != null && name != null && seen.add(id)) {
      products.add((id: id, name: name));
    }
  }
  if (products.isEmpty) return MatchNone();

  // Score each candidate
  final scores = products.map((p) {
    final normName = normalizeText(p.name);
    return (id: p.id, name: p.name, score: _matchScore(normPhrase, normName));
  }).toList();

  scores.sort((a, b) => b.score.compareTo(a.score));

  const kConfidentThreshold = 0.35;
  const kConfidentMargin = 0.12;

  final top = scores.first;
  if (top.score < kConfidentThreshold) return MatchNone();

  final second = scores.length > 1 ? scores[1].score : 0.0;
  final margin = top.score - second;

  if (margin >= kConfidentMargin) {
    return MatchConfident(top.id, top.name);
  }

  // Ambiguous: return top 3 that are above half the top score
  final candidates = scores
      .where((s) => s.score >= top.score * 0.6 && s.score >= kConfidentThreshold * 0.8)
      .take(3)
      .map((s) => MatchCandidate(s.id, s.name, s.score))
      .toList();

  return candidates.length >= 2
      ? MatchAmbiguous(candidates)
      : MatchConfident(top.id, top.name);
}

double _matchScore(String phrase, String candidate) {
  if (phrase.isEmpty || candidate.isEmpty) return 0.0;

  final pTokens = phrase.split(RegExp(r'\s+')).where((t) => t.length >= 2).toList();
  final cTokens = candidate.split(RegExp(r'\s+')).where((t) => t.length >= 2).toList();

  if (pTokens.isEmpty) return 0.0;

  // ── Token overlap (with partial prefix matching) ──
  double matched = 0.0;
  for (final pt in pTokens) {
    double best = 0.0;
    for (final ct in cTokens) {
      if (pt == ct) {
        best = 1.0;
        break;
      }
      // Prefix match (min 3 chars for reliability)
      if (pt.length >= 3 && ct.length >= 3) {
        if (ct.startsWith(pt) || pt.startsWith(ct)) {
          final shorter = pt.length < ct.length ? pt.length : ct.length;
          final longer = pt.length > ct.length ? pt.length : ct.length;
          best = 0.5 + 0.5 * (shorter / longer);
        }
      }
    }
    matched += best;
  }
  final tokenScore = matched / pTokens.length;

  // ── Brand prefix bonus ──
  double brandBonus = 0.0;
  if (pTokens.isNotEmpty && cTokens.isNotEmpty) {
    final pFirst = pTokens.first;
    final cFirst = cTokens.first;
    if (pFirst == cFirst) {
      brandBonus = 0.3;
    } else if (pFirst.length >= 3 && cFirst.length >= 3) {
      if (cFirst.startsWith(pFirst) || pFirst.startsWith(cFirst)) {
        brandBonus = 0.15;
      }
    }
  }

  // ── Whole-string contains bonus ──
  final subBonus = (candidate.contains(phrase) || phrase.contains(candidate)) ? 0.1 : 0.0;

  // ── Normalized Levenshtein ──
  final lev = _levenshtein(phrase, candidate);
  final maxLen = phrase.length > candidate.length ? phrase.length : candidate.length;
  final levScore = (1.0 - lev / maxLen).clamp(0.0, 1.0);

  return (tokenScore * 0.45 + brandBonus + levScore * 0.2 + subBonus).clamp(0.0, 1.0);
}

/// Classic Levenshtein distance. O(m*n), fine for short pharma names.
int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  // Keep only two rows to save memory
  var prev = List<int>.generate(b.length + 1, (i) => i);
  var curr = List<int>.filled(b.length + 1, 0);

  for (var i = 1; i <= a.length; i++) {
    curr[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a[i - 1] == b[j - 1] ? 0 : 1;
      curr[j] = _min3(curr[j - 1] + 1, prev[j] + 1, prev[j - 1] + cost);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[b.length];
}

int _min3(int a, int b, int c) => a < b ? (a < c ? a : c) : (b < c ? b : c);
