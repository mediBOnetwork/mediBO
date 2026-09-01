// CMD #409 — the two buttons that live in the storefront search bar, and the
// two sheets behind them.
//
// Both sheets are pure chrome. The camera produces a code and the mic produces
// bytes; WHICH product a code means, whether a scan is refused, what the
// refusal says, how long the mic may listen and every word on either sheet all
// come from the backend (`storefront_barcode_resolve`, `voice_search_config`,
// `voice_search_resolve`). Nothing here decides anything.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../design_tokens.dart';
import '../models/product.dart';
import '../services/storefront_fast_order.dart';
import '../services/ui_copy.dart';
import '../services/voice_receive_service.dart';
import '../utils/render_log.dart';
import '../widgets/compact_product_card.dart';

/// The scan button, as it sits inside the search field.
class ScanSearchButton extends StatelessWidget {
  /// Injected so a test can drive the whole sheet with no camera and no
  /// Supabase — the same constructor-injected-closure seam the rest of the
  /// suite uses.
  final Future<ScanResult> Function(String code)? resolver;
  final Color color;

  const ScanSearchButton({super.key, this.resolver, required this.color});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('c409_scan_button'),
      tooltip: c('storefront.scan_button'),
      onPressed: () => openScanSheet(context, resolver: resolver),
      icon: Icon(Icons.qr_code_scanner, size: 20, color: color),
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(
          minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
    );
  }
}

/// The mic button, as it sits inside the search field.
class VoiceSearchButton extends StatelessWidget {
  /// Called with the query the BACKEND resolved — never with raw speech.
  final ValueChanged<String> onQuery;
  final Future<VoiceSearchConfig> Function()? configLoader;
  final Future<VoiceSearchResult> Function(String transcript, String lang)?
      transcriber;
  final Color color;

  const VoiceSearchButton({
    super.key,
    required this.onQuery,
    required this.color,
    this.configLoader,
    this.transcriber,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      key: const Key('c409_mic_button'),
      tooltip: c('storefront.mic_button'),
      onPressed: () => openVoiceSheet(context,
          onQuery: onQuery,
          configLoader: configLoader,
          transcriber: transcriber),
      icon: Icon(Icons.mic_none, size: 20, color: color),
      visualDensity: VisualDensity.compact,
      constraints: BoxConstraints(
          minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
    );
  }
}

Future<void> openScanSheet(
  BuildContext context, {
  Future<ScanResult> Function(String code)? resolver,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => ScanSheet(resolver: resolver),
  );
}

Future<void> openVoiceSheet(
  BuildContext context, {
  required ValueChanged<String> onQuery,
  Future<VoiceSearchConfig> Function()? configLoader,
  Future<VoiceSearchResult> Function(String transcript, String lang)?
      transcriber,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => VoiceSearchSheet(
      onQuery: onQuery,
      configLoader: configLoader,
      transcriber: transcriber,
    ),
  );
}

// ───────────────────────────── the scan sheet ─────────────────────────────

class ScanSheet extends StatefulWidget {
  final Future<ScanResult> Function(String code)? resolver;
  const ScanSheet({super.key, this.resolver});

  @override
  State<ScanSheet> createState() => _ScanSheetState();
}

class _ScanSheetState extends State<ScanSheet> {
  MobileScannerController? _ctrl;
  ScanResult? _result;
  bool _busy = false;
  String _lastCode = '';
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // A test injects a resolver and never wants a camera; production always
    // gets one. Same formats the counting scanner is configured with, so a
    // code that counts also scans.
    if (widget.resolver == null) {
      _ctrl = MobileScannerController(
        formats: const [
          BarcodeFormat.ean13,
          BarcodeFormat.ean8,
          BarcodeFormat.upcA,
          BarcodeFormat.code39,
          BarcodeFormat.code128,
          BarcodeFormat.dataMatrix,
          BarcodeFormat.qrCode,
        ],
        detectionSpeed: DetectionSpeed.normal,
        detectionTimeoutMs: 700,
      );
    }
    RenderLog.write('c409_scan_sheet', 'open=1;camera=${_ctrl != null ? 'y' : 'n'}');
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy || _result != null) return;
    final code = capture.barcodes
        .map((b) => b.rawValue ?? '')
        .firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    if (code.trim().isEmpty) return;
    final now = DateTime.now();
    if (code == _lastCode && now.difference(_lastAt).inMilliseconds < 900) {
      return;
    }
    _lastCode = code;
    _lastAt = now;
    handleCode(code.trim());
  }

  /// Public so the widget test can feed a code without a camera.
  Future<void> handleCode(String code) async {
    setState(() => _busy = true);
    ScanResult res;
    try {
      final resolve = widget.resolver ?? StorefrontFastOrder.resolveBarcode;
      res = await resolve(code);
    } catch (_) {
      // A refusal the backend never got to word is still not worded here: an
      // empty title/message renders as nothing rather than as a Dart sentence.
      res = const ScanResult(ok: false, error: 'network');
    }
    if (!mounted) return;
    setState(() {
      _result = res;
      _busy = false;
    });
    RenderLog.write('c409_scan_result',
        'ok=${res.ok ? 'y' : 'n'};error=${res.error};card=${res.card != null ? 'y' : 'n'}');
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(c('storefront.scan_sheet_title'),
                      style: Ds.t.title),
                ),
                IconButton(
                  tooltip: c('storefront.scan_close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close, color: Ds.c.textSecondary),
                  constraints: BoxConstraints(
                      minWidth: Ds.touch.minTarget,
                      minHeight: Ds.touch.minTarget),
                ),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            if (r == null) ...[
              Text(c('storefront.scan_sheet_hint'), style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              ClipRRect(
                borderRadius: Ds.r.rCard,
                child: SizedBox(
                  height: 240,
                  child: _ctrl == null
                      ? const SizedBox.shrink()
                      : MobileScanner(
                          controller: _ctrl!,
                          onDetect: _onDetect,
                          errorBuilder: (_, _, _) => Center(
                            child: Padding(
                              padding: EdgeInsets.all(Ds.space.x16),
                              child: Text(c('storefront.scan_camera_error'),
                                  textAlign: TextAlign.center,
                                  style: Ds.t.caption),
                            ),
                          ),
                        ),
                ),
              ),
              if (_busy) ...[
                SizedBox(height: Ds.space.x16),
                const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ] else
              _ScanOutcome(
                result: r,
                onAgain: () => setState(() {
                  _result = null;
                  _lastCode = '';
                }),
              ),
            SizedBox(height: Ds.space.x8),
          ],
        ),
      ),
    );
  }
}

/// What a resolved (or refused) scan looks like. Every word is [ScanResult]'s.
class _ScanOutcome extends StatelessWidget {
  final ScanResult result;
  final VoidCallback onAgain;
  const _ScanOutcome({required this.result, required this.onAgain});

  @override
  Widget build(BuildContext context) {
    final card = result.card;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (result.title.isNotEmpty)
          Text(result.title, style: Ds.t.subtitle, key: const Key('c409_scan_title')),
        if (result.message.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(result.message,
              style: Ds.t.bodySecondary, key: const Key('c409_scan_message')),
        ],
        if (result.hint.isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(result.hint, style: Ds.t.caption),
        ],
        if (card != null) ...[
          SizedBox(height: Ds.space.x16),
          Center(
            child: SizedBox(
              width: 172,
              height: CompactProductCard.extent,
              child: CompactProductCard(
                product: Product.fromHomeCard(card),
                onTap: () {
                  Navigator.of(context).maybePop();
                  Navigator.of(context)
                      .pushNamed('/product/${card['id']}');
                },
              ),
            ),
          ),
        ],
        SizedBox(height: Ds.space.x16),
        SizedBox(
          height: Ds.touch.minTarget,
          child: OutlinedButton(
            key: const Key('c409_scan_again'),
            onPressed: onAgain,
            child: Text(c('storefront.scan_again')),
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────── the mic sheet ──────────────────────────────

class VoiceSearchSheet extends StatefulWidget {
  final ValueChanged<String> onQuery;
  final Future<VoiceSearchConfig> Function()? configLoader;
  final Future<VoiceSearchResult> Function(String transcript, String lang)?
      transcriber;

  const VoiceSearchSheet({
    super.key,
    required this.onQuery,
    this.configLoader,
    this.transcriber,
  });

  @override
  State<VoiceSearchSheet> createState() => _VoiceSearchSheetState();
}

enum _MicPhase { loading, listening, working, denied, failed }

class _VoiceSearchSheetState extends State<VoiceSearchSheet> {
  VoiceSearchConfig _cfg = VoiceSearchConfig.none;
  _MicPhase _phase = _MicPhase.loading;
  VoiceReceiveService? _rec;
  Timer? _cap;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _cap?.cancel();
    _rec?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    VoiceSearchConfig cfg;
    try {
      cfg = await (widget.configLoader ?? StorefrontFastOrder.voiceConfig)();
    } catch (_) {
      cfg = VoiceSearchConfig.none;
    }
    if (!mounted) return;
    setState(() => _cfg = cfg);

    // The test seam short-circuits the microphone entirely: it supplies the
    // transcript, which is the only thing the vocabulary path consumes.
    if (widget.transcriber != null) {
      setState(() => _phase = _MicPhase.listening);
      return;
    }
    try {
      final rec = VoiceReceiveService();
      await rec.start();
      _rec = rec;
      if (!mounted) return;
      setState(() => _phase = _MicPhase.listening);
      // The backend owns how long the mic may listen.
      _cap = Timer(Duration(seconds: _cfg.maxSeconds), _stopAndSend);
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _MicPhase.denied);
    }
    RenderLog.write('c409_voice_sheet',
        'phase=${_phase.name};lang=${_cfg.lang};max_s=${_cfg.maxSeconds}');
  }

  Future<void> _stopAndSend() async {
    _cap?.cancel();
    if (_phase != _MicPhase.listening) return;
    setState(() => _phase = _MicPhase.working);
    VoiceSearchResult res;
    try {
      if (widget.transcriber != null) {
        res = await widget.transcriber!('', _cfg.lang);
      } else {
        final clip = await _rec?.stop();
        if (clip == null) {
          setState(() => _phase = _MicPhase.failed);
          return;
        }
        res = await StorefrontFastOrder.transcribeSearch(clip.bytes, clip.mime,
            lang: _cfg.lang);
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _phase = _MicPhase.failed);
      return;
    }
    if (!mounted) return;
    RenderLog.write('c409_voice_result',
        'ok=${res.ok ? 'y' : 'n'};error=${res.error};q_len=${res.query.length}');
    if (!res.ok) {
      setState(() => _phase = _MicPhase.failed);
      return;
    }
    widget.onQuery(res.query);
    Navigator.of(context).maybePop();
  }

  /// Public seam: the test taps Stop, exactly as a person would.
  @visibleForTesting
  Future<void> stopNow() => _stopAndSend();

  @override
  Widget build(BuildContext context) {
    final String headline = switch (_phase) {
      _MicPhase.denied => _cfg.deniedTitle,
      _MicPhase.failed => _cfg.errorMessage,
      _MicPhase.working => _cfg.working,
      _ => _cfg.title,
    };
    final String body = switch (_phase) {
      _MicPhase.denied => _cfg.deniedMessage,
      _MicPhase.listening => _cfg.listening,
      _MicPhase.loading => '',
      _MicPhase.working => '',
      _MicPhase.failed => '',
    };

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (headline.isNotEmpty)
              Text(headline,
                  key: const Key('c409_voice_headline'),
                  textAlign: TextAlign.center,
                  style: Ds.t.title),
            SizedBox(height: Ds.space.x8),
            if (_cfg.hint.isNotEmpty && _phase == _MicPhase.listening)
              Text(_cfg.hint, textAlign: TextAlign.center, style: Ds.t.caption),
            SizedBox(height: Ds.space.x24),
            Icon(
              _phase == _MicPhase.denied ? Icons.mic_off : Icons.mic,
              size: 48,
              color: _phase == _MicPhase.listening
                  ? Ds.c.brand
                  : Ds.c.textSecondary,
            ),
            SizedBox(height: Ds.space.x12),
            if (body.isNotEmpty)
              Text(body,
                  key: const Key('c409_voice_body'),
                  textAlign: TextAlign.center,
                  style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x24),
            if (_phase == _MicPhase.listening && _cfg.stopLabel.isNotEmpty)
              SizedBox(
                height: Ds.touch.minTarget,
                child: FilledButton(
                  key: const Key('c409_voice_stop'),
                  onPressed: _stopAndSend,
                  child: Text(_cfg.stopLabel),
                ),
              ),
            if (_phase == _MicPhase.working)
              const Center(child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(height: Ds.space.x8),
            if (_cfg.cancelLabel.isNotEmpty)
              SizedBox(
                height: Ds.touch.minTarget,
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(_cfg.cancelLabel),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
