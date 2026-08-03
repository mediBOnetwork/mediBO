import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../utils/render_log.dart';

/// CHANGE #639 PART A — the public stock-update page, reached from the
/// WhatsApp link `/stock-update/<token>`. No auth: the token in the URL is the
/// authorisation, exactly as `/inquiry/<token>` works.
///
/// This screen decides NOTHING. Every string it prints — the title, the intro,
/// the two button labels, the "OOS since …" line, the success copy and both
/// error states — arrives from `get_stock_update_form()`. Items render in
/// payload order; there is no sort here. The only thing this file owns is
/// which of the two buttons is currently lit, which is the user's own input.
const _kGreen = Color(0xFF1B7A43);

/// Tone -> the palette the app already uses for that state. `tone` is the
/// backend's word ('oos' / 'available'); the swatch is this app's existing
/// visual language for it, the same one inquiry_v12 paints. Nothing here
/// decides WHICH tone a button has — only how the app draws the tone it was
/// handed.
class _Tone {
  final Color bg;
  final Color border;
  final Color fg;
  const _Tone(this.bg, this.border, this.fg);
}

const _kToneOos = _Tone(Color(0xFFFAECE7), Color(0xFFF0997B), Color(0xFF993C1D));
const _kToneAvailable =
    _Tone(Color(0xFFE1F5EE), Color(0xFF5DCAA5), Color(0xFF0F6E56));
const _kToneNeutral =
    _Tone(Colors.white, Color(0xFFE5E7EB), Color(0xFF6B7280));

_Tone _toneFor(String tone) {
  switch (tone) {
    case 'oos':
      return _kToneOos;
    case 'available':
      return _kToneAvailable;
    default:
      return _kToneNeutral;
  }
}

class StockUpdateFormScreen extends StatefulWidget {
  final String token;
  const StockUpdateFormScreen({super.key, required this.token});

  /// Test seam, same shape as CartModel.rpcTransport: a widget test can feed a
  /// payload back without a network or a Supabase client.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<StockUpdateFormScreen> createState() => _StockUpdateFormScreenState();
}

class _StockUpdateFormScreenState extends State<StockUpdateFormScreen> {
  bool _loading = true;
  bool _submitting = false;
  bool _done = false;

  Map<String, dynamic> _payload = const {};
  List<Map<String, dynamic>> _items = const [];
  List<Map<String, dynamic>> _buttons = const [];

  /// product_id -> button key ('still_oos' | 'back_in_stock'). An item absent
  /// from this map is unanswered and is simply not submitted.
  final Map<int, String> _answers = {};

  String? _error;

  @override
  void initState() {
    super.initState();
    RenderLog.write('c639_stock_form_init', widget.token.length >= 8
        ? widget.token.substring(0, 8)
        : widget.token);
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final raw = await StockUpdateFormScreen.rpc(
          'get_stock_update_form', {'p_token': widget.token});
      if (!mounted) return;
      final data = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      if (data is! Map) {
        setState(() {
          _error = 'invalid';
          _loading = false;
        });
        return;
      }
      final map = data.cast<String, dynamic>();
      if (map['error'] != null) {
        setState(() {
          _payload = map;
          _error = map['error'].toString();
          _loading = false;
        });
        RenderLog.write('c639_stock_form_error', _error);
        return;
      }
      final items = ((map['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      final buttons = ((map['buttons'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      setState(() {
        _payload = map;
        // PAYLOAD ORDER, verbatim. No sort, no grouping.
        _items = items;
        _buttons = buttons;
        _error = null;
        _loading = false;
      });
      RenderLog.write('c639_stock_form_items', items.length);
      RenderLog.write('c639_stock_form_buttons', buttons.length);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'invalid';
        _loading = false;
      });
      RenderLog.write('c639_stock_form_load_error', 1);
    }
  }

  String _s(String key) => (_payload[key] ?? '').toString();

  int? _pid(Map<String, dynamic> item) =>
      (item['product_id'] as num?)?.toInt();

  void _choose(int pid, String key) {
    // Mutual exclusivity: one key per product id, so selecting one button
    // necessarily deselects the other.
    setState(() => _answers[pid] = key);
  }

  Future<void> _submit() async {
    if (_submitting || _answers.isEmpty) return;
    setState(() => _submitting = true);
    try {
      // Only ANSWERED items are sent. Unanswered ones are omitted entirely —
      // silence is not an answer and must not be turned into one here.
      final answers = <Map<String, dynamic>>[];
      for (final item in _items) {
        final pid = _pid(item);
        if (pid == null) continue;
        final key = _answers[pid];
        if (key == null) continue;
        answers.add({'product_id': pid, 'back_in_stock': key == 'back_in_stock'});
      }
      final raw = await StockUpdateFormScreen.rpc('submit_stock_update_form', {
        'p_token': widget.token,
        'p_answers': answers,
      });
      if (!mounted) return;
      final data = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
      final map = data is Map ? data.cast<String, dynamic>() : const {};
      if (map['status'] == 'ok') {
        RenderLog.write('c639_stock_form_submitted', answers.length);
        setState(() {
          _done = true;
          _submitting = false;
        });
        return;
      }
      if (map['error'] != null) {
        setState(() {
          _error = map['error'].toString();
          if (map['error_title'] != null) _payload = {..._payload, ...map};
          _submitting = false;
        });
        return;
      }
      setState(() => _submitting = false);
      _toastSubmitError();
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toastSubmitError();
    }
  }

  void _toastSubmitError() {
    final msg = _s('submit_error');
    if (msg.isEmpty) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: const Color(0xFFDC2626),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _loading
                ? const _StockSkeleton()
                : _error != null
                    ? _buildError()
                    : _done
                        ? _buildSuccess()
                        : _buildForm(),
          ),
        ),
      ),
    );
  }

  // ── Error / expired ────────────────────────────────────────────────────────

  Widget _buildError() {
    final expired = _error == 'expired';
    // Both strings come from the payload. When the RPC could not be reached at
    // all there is no payload, so the icon still renders and the text stays
    // empty rather than this file inventing a sentence.
    final title = _s('error_title');
    final note = _s('error_note');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFF3F4F6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Icon(
                expired ? Icons.timer_off_outlined : Icons.link_off_outlined,
                size: 36,
                color: const Color(0xFF9CA3AF),
              ),
            ),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF374151)),
              ),
            ],
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                note,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Success ────────────────────────────────────────────────────────────────

  Widget _buildSuccess() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: const Color(0xFFD1FAE5),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.check_circle_outline,
                  size: 38, color: Color(0xFF065F46)),
            ),
            const SizedBox(height: 20),
            Text(
              _s('success_title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF065F46)),
            ),
            const SizedBox(height: 8),
            Text(
              _s('success_note'),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
    );
  }

  // ── Form ───────────────────────────────────────────────────────────────────

  Widget _buildForm() {
    final answered = _answers.length;
    final canSubmit = answered > 0 && !_submitting;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _buildHeader()),
        if (_items.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
              child: Text(
                _s('empty_text'),
                style: const TextStyle(fontSize: 14, color: Color(0xFF6B7280)),
              ),
            ),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            sliver: SliverList.builder(
              itemCount: _items.length,
              itemBuilder: (_, i) => _StockItemCard(
                key: ValueKey(_items[i]['product_id'] ?? i),
                item: _items[i],
                buttons: _buttons,
                selectedKey: _answers[_pid(_items[i]) ?? -1],
                onChoose: (key) {
                  final pid = _pid(_items[i]);
                  if (pid != null) _choose(pid, key);
                },
              ),
            ),
          ),
        SliverToBoxAdapter(child: _buildSubmit(canSubmit, answered)),
      ],
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: _kGreen,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.inventory_2_outlined,
                    color: Colors.white, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _s('eyebrow'),
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _s('supplier_name'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          Text(
            _s('title'),
            style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Color(0xFF111827)),
          ),
          if (_s('intro').isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              _s('intro'),
              style: const TextStyle(fontSize: 13, color: Color(0xFF6B7280)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSubmit(bool canSubmit, int answered) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      child: Column(
        children: [
          SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton(
              onPressed: canSubmit ? _submit : null,
              style: FilledButton.styleFrom(
                backgroundColor: _kGreen,
                disabledBackgroundColor: const Color(0xFFD1FAE5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                _submitting ? _s('submitting_label') : _s('submit_label'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white),
              ),
            ),
          ),
          if (_items.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '$answered/${_items.length} ${_s('answered_suffix')}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF9CA3AF)),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── One item ────────────────────────────────────────────────────────────────

class _StockItemCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final List<Map<String, dynamic>> buttons;
  final String? selectedKey;
  final void Function(String key) onChoose;

  const _StockItemCard({
    super.key,
    required this.item,
    required this.buttons,
    required this.selectedKey,
    required this.onChoose,
  });

  String _f(String key) => (item[key] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    // side is the backend's layout instruction, read as data. Partitioning
    // (rather than sorting) keeps a payload that sends neither/both from
    // silently dropping a button.
    final left = buttons.where((b) => b['side'] == 'left').toList();
    final right = buttons.where((b) => b['side'] == 'right').toList();
    final ordered = <Map<String, dynamic>>[
      ...left,
      ...buttons.where((b) => b['side'] != 'left' && b['side'] != 'right'),
      ...right,
    ];

    final company = _f('company');
    final pack = _f('pack_label');
    final oos = _f('oos_label');

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ItemImage(url: _f('image')),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _f('product_name'),
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF111827),
                            height: 1.3),
                      ),
                      if (company.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          company.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF9CA3AF),
                              letterSpacing: 0.4),
                        ),
                      ],
                      if (pack.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          pack,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF6B7280)),
                        ),
                      ],
                      if (oos.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          oos,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: Color(0xFF993C1D)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (var i = 0; i < ordered.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _ChoiceButton(
                      label: (ordered[i]['label'] ?? '').toString(),
                      tone: (ordered[i]['tone'] ?? '').toString(),
                      selected:
                          selectedKey == (ordered[i]['key'] ?? '').toString(),
                      onTap: () =>
                          onChoose((ordered[i]['key'] ?? '').toString()),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceButton extends StatelessWidget {
  final String label;
  final String tone;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceButton({
    required this.label,
    required this.tone,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = _toneFor(tone);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? t.bg : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? t.border : const Color(0xFFE5E7EB),
            width: selected ? 1.2 : 0.5,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: selected ? t.fg : const Color(0xFF6B7280),
          ),
        ),
      ),
    );
  }
}

/// Fixed-size tile so a slow image can never shift the row (Part G: zero
/// layout shift). cacheWidth keeps the decoded bitmap small on the list.
class _ItemImage extends StatelessWidget {
  final String url;
  const _ItemImage({required this.url});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: const Color(0xFFF3F4F6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE5E7EB), width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: url.isEmpty
          ? const _ImgPlaceholder()
          : Image.network(
              url,
              fit: BoxFit.cover,
              cacheWidth: 192,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const _ImgPlaceholder(),
            ),
    );
  }
}

class _ImgPlaceholder extends StatelessWidget {
  const _ImgPlaceholder();
  @override
  Widget build(BuildContext context) => const Center(
        child: Icon(Icons.medication_outlined,
            size: 26, color: Color(0xFFD1D5DB)),
      );
}

/// Skeleton — fixed heights matching the real card, so the swap to real
/// content moves nothing.
class _StockSkeleton extends StatelessWidget {
  const _StockSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: [
        _bar(height: 76, radius: 12),
        const SizedBox(height: 16),
        _bar(height: 22, width: 160),
        const SizedBox(height: 16),
        for (var i = 0; i < 4; i++) ...[
          _bar(height: 148, radius: 12),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _bar({double? height, double? width, double radius = 8}) => Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: const Color(0xFFE9EBEF),
          borderRadius: BorderRadius.circular(radius),
        ),
      );
}
