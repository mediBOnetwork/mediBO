// CMD #2055 — one wording, three channels.
//
// The WhatsApp template is the wording. Push and Email are DERIVED from it by
// the backend on every save, so this file computes nothing: it prints
// `wa_channel_preview(event_key, lang)` verbatim — every label, every chip
// word, every empty state — and sends back exactly two things, a language and
// a Reset.
//
// Chips live on the event card (`row['channels'].chips`, already in the screen
// payload) so the card needs no extra call; the sheet is the one RPC, opened on
// demand.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../design_tokens.dart';

typedef WaChannelPreviewRpc =
    Future<Map<String, dynamic>> Function(String eventKey, String lang);
typedef WaChannelResetRpc =
    Future<Map<String, dynamic>> Function(
      String eventKey,
      String channel,
      String lang,
    );

Map<String, dynamic> _map(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _list(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : <Map<String, dynamic>>[];

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Future<Map<String, dynamic>> waChannelPreview(
  String eventKey,
  String lang,
) async => _map(
  await Supabase.instance.client.rpc(
    'wa_channel_preview',
    params: {'p_event_key': eventKey, 'p_lang': lang},
  ),
);

Future<Map<String, dynamic>> waChannelReset(
  String eventKey,
  String channel,
  String lang,
) async => _map(
  await Supabase.instance.client.rpc(
    'wa_channel_reset',
    params: {'p_event_key': eventKey, 'p_channel': channel, 'p_lang': lang},
  ),
);

/// Backend tone word -> token colour. Tone to token only; an unknown tone is
/// the neutral secondary ink, never an invented colour.
Color _toneInk(String? tone) => switch (tone) {
  'good' => Ds.c.brand,
  'warn' => Ds.c.warning,
  'bad' => Ds.c.danger,
  _ => Ds.c.textSecondary,
};

Color _toneWash(String? tone) => switch (tone) {
  'good' => Ds.c.brandSoft,
  'warn' => Ds.c.warningSoft,
  'bad' => Ds.c.dangerSoft,
  _ => Ds.c.bg,
};

/// The one row of channel chips on an event card, plus the Preview button.
///
/// Equal gaps in both directions — the chips are one row that wraps at narrow
/// widths rather than a row that clips.
class WaChannelChips extends StatelessWidget {
  final Map<String, dynamic> channels;
  final VoidCallback onPreview;
  const WaChannelChips({
    super.key,
    required this.channels,
    required this.onPreview,
  });

  @override
  Widget build(BuildContext context) {
    final chips = _list(channels['chips']);
    if (chips.isEmpty) return const SizedBox.shrink();
    final label = _s(channels, 'label');
    final previewLabel = _s(channels, 'preview_label');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x8),
            child: Text(label, style: Ds.t.caption),
          ),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final ch in chips)
              _ChannelChip(
                channel: _s(ch, 'channel_label'),
                label: _s(ch, 'label'),
                tone: ch['tone']?.toString(),
              ),
          ],
        ),
        if (previewLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x12),
            child: SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: OutlinedButton.icon(
                onPressed: onPreview,
                icon: const Icon(Icons.visibility_outlined),
                label: Text(previewLabel),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String channel;
  final String label;
  final String? tone;
  const _ChannelChip({required this.channel, required this.label, this.tone});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(
      horizontal: Ds.space.x12,
      vertical: Ds.space.x4,
    ),
    decoration: BoxDecoration(color: _toneWash(tone), borderRadius: Ds.r.rChip),
    child: Text(
      '$channel · $label',
      style: Ds.t.caption.copyWith(
        color: _toneInk(tone),
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

/// Opens the three-channel preview. One RPC, one sheet, phone-first.
Future<void> showWaChannelPreview(
  BuildContext context, {
  required String eventKey,
  WaChannelPreviewRpc? previewRpc,
  WaChannelResetRpc? resetRpc,
  VoidCallback? onChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
    ),
    builder: (_) => WaChannelPreviewSheet(
      eventKey: eventKey,
      previewRpc: previewRpc,
      resetRpc: resetRpc,
      onChanged: onChanged,
    ),
  );
}

class WaChannelPreviewSheet extends StatefulWidget {
  final String eventKey;
  final WaChannelPreviewRpc? previewRpc;
  final WaChannelResetRpc? resetRpc;
  final VoidCallback? onChanged;
  const WaChannelPreviewSheet({
    super.key,
    required this.eventKey,
    this.previewRpc,
    this.resetRpc,
    this.onChanged,
  });

  @override
  State<WaChannelPreviewSheet> createState() => _WaChannelPreviewSheetState();
}

class _WaChannelPreviewSheetState extends State<WaChannelPreviewSheet> {
  Map<String, dynamic>? _data;
  String _lang = 'en';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    final rpc = widget.previewRpc ?? waChannelPreview;
    final res = await rpc(widget.eventKey, _lang);
    if (!mounted) return;
    setState(() {
      _data = res;
      _busy = false;
    });
  }

  Future<void> _reset(String channel) async {
    setState(() => _busy = true);
    final rpc = widget.resetRpc ?? waChannelReset;
    final res = await rpc(widget.eventKey, channel, _lang);
    if (!mounted) return;
    final msg = (res['message'] ?? res['error'] ?? '').toString();
    if (msg.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
    widget.onChanged?.call();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final maxH = MediaQuery.of(context).size.height * 0.9;

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: d == null
            ? Padding(
                padding: EdgeInsets.all(Ds.space.x32),
                child: const Center(child: CircularProgressIndicator()),
              )
            : (d['ok'] == true ? _body(d) : _error(d)),
      ),
    );
  }

  Widget _error(Map<String, dynamic> d) => Padding(
    padding: EdgeInsets.all(Ds.space.x24),
    child: Text(
      (d['message'] ?? d['error'] ?? '').toString(),
      style: Ds.t.body,
    ),
  );

  Widget _body(Map<String, dynamic> d) {
    final langs = _list(d['language_options']);
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.fromLTRB(
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x16,
        Ds.space.x32,
      ),
      children: [
        Text(_s(d, 'title'), style: Ds.t.title),
        SizedBox(height: Ds.space.x4),
        Text(_s(d, 'subtitle'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x12),
        Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final ch in _list(d['chips']))
              _ChannelChip(
                channel: _s(ch, 'channel_label'),
                label: _s(ch, 'label'),
                tone: ch['tone']?.toString(),
              ),
          ],
        ),
        SizedBox(height: Ds.space.x12),
        Text(_s(d, 'rule_label'), style: Ds.t.caption),
        if (_s(d, 'source_label').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(d, 'source_label'), style: Ds.t.caption),
        ],
        if (langs.length > 1) ...[
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final l in langs)
                ChoiceChip(
                  label: Text(_s(l, 'label')),
                  selected: _lang == _s(l, 'key'),
                  onSelected: _busy
                      ? null
                      : (_) {
                          setState(() => _lang = _s(l, 'key'));
                          _load();
                        },
                ),
            ],
          ),
        ],
        SizedBox(height: Ds.space.x24),
        _ChannelBlock(
          data: _map(d['whatsapp']),
          isSource: true,
          onReset: null,
          busy: _busy,
        ),
        SizedBox(height: Ds.space.x16),
        _ChannelBlock(
          data: _map(d['push']),
          isSource: false,
          onReset: _busy ? null : () => _reset('push'),
          busy: _busy,
        ),
        SizedBox(height: Ds.space.x16),
        _ChannelBlock(
          data: _map(d['email']),
          isSource: false,
          onReset: _busy ? null : () => _reset('email'),
          busy: _busy,
        ),
        SizedBox(height: Ds.space.x16),
        Text(_s(d, 'note'), style: Ds.t.caption),
        SizedBox(height: Ds.space.x8),
        Text(_s(d, 'synced_label'), style: Ds.t.caption),
      ],
    );
  }
}

/// One channel, drawn the way that channel looks. Nothing here decides what to
/// show: a key the backend left null simply is not painted.
class _ChannelBlock extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isSource;
  final VoidCallback? onReset;
  final bool busy;
  const _ChannelBlock({
    required this.data,
    required this.isSource,
    required this.onReset,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final empty = _s(data, 'empty_label');
    final image = _s(data, 'image_url');
    final thumb = _s(data, 'thumb_url');
    final header = _map(data['header']);
    final headerUrl = _s(header, 'media_url');
    final subject = _s(data, 'subject');
    final title = _s(data, 'title');
    final body = _s(data, 'body');
    final footer = _s(data, 'footer');
    final style = _s(data, 'style_label');
    final attachment = _s(data, 'attachment_label');
    final buttons = [..._list(data['buttons']), ..._list(data['actions'])];
    final quick = _list(data['quick_replies']);
    final manual = data['manual'] == true;
    final resetLabel = _s(data, 'reset_label');
    final shot = image.isNotEmpty
        ? image
        : (thumb.isNotEmpty ? thumb : headerUrl);

    return Container(
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rCard,
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(_s(data, 'label'), style: Ds.t.subtitle)),
              if (style.isNotEmpty)
                Text(style, style: Ds.t.caption, textAlign: TextAlign.end),
            ],
          ),
          if (empty.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(empty, style: Ds.t.caption),
          ],
          if (shot.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            ClipRRect(
              borderRadius: Ds.r.rButton,
              child: Image.network(
                shot,
                fit: BoxFit.cover,
                errorBuilder: (c, e, st) => const SizedBox.shrink(),
              ),
            ),
          ],
          if (attachment.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Row(
              children: [
                Icon(
                  Icons.attach_file,
                  size: Ds.t.captionSize,
                  color: Ds.c.textSecondary,
                ),
                SizedBox(width: Ds.space.x4),
                Expanded(child: Text(attachment, style: Ds.t.caption)),
              ],
            ),
          ],
          if (subject.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(
              subject,
              style: Ds.t.body.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
          if (title.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Text(title, style: Ds.t.body.copyWith(fontWeight: FontWeight.w700)),
          ],
          if (body.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(body, style: Ds.t.body),
          ],
          if (footer.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(footer, style: Ds.t.caption),
          ],
          if (buttons.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final b in buttons)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12,
                      vertical: Ds.space.x8,
                    ),
                    decoration: BoxDecoration(
                      color: Ds.c.brandSoft,
                      borderRadius: Ds.r.rButton,
                    ),
                    child: Text(
                      _s(b, 'text'),
                      style: Ds.t.caption.copyWith(
                        color: Ds.c.brand,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ],
          if (quick.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                for (final b in quick)
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x12,
                      vertical: Ds.space.x8,
                    ),
                    decoration: BoxDecoration(
                      color: Ds.c.bg,
                      borderRadius: Ds.r.rButton,
                    ),
                    child: Text(_s(b, 'text'), style: Ds.t.caption),
                  ),
              ],
            ),
          ],
          if (!isSource && manual && resetLabel.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: busy ? null : onReset,
                style: FilledButton.styleFrom(
                  backgroundColor: Ds.c.brand,
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(resetLabel),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
