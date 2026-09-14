// lib/screens/admin/onboarding_notices_screen.dart — CMD #1936
//
// What a new shop hears from us, and when.
//
// Six events decide the whole of a customer's first week: the message an admin
// import sends, the different message a self-signup sends, the daily reminder
// for documents that have not arrived, the two document verdicts, and the
// approval. Until this screen the only way to know whether any of them COULD
// fire was to read wa_event_routes by hand — which is how two of them sat with
// enabled routes and no template, answering route_disabled, for months.
//
// This file computes nothing. Every word on it — the state chip, the "waiting
// on Meta" wording, the reminder counter, the missing-document sentence, the
// send counts, the zone and the date line — is written by
// onboarding_notices_screen() and printed exactly as it arrives. The one thing
// Dart decides is which colour token a backend tone word maps to, because a
// Color is not a string Postgres can hold.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/render_log.dart';

/// Injectable RPC seam: production leaves it null and gets the Supabase call,
/// a test passes a stub and never touches the network.
typedef OnboardingNoticesRpc = Future<Map<String, dynamic>> Function();

Map<String, dynamic> _asMap(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> _asRows(dynamic v) => v is List
    ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
    : const <Map<String, dynamic>>[];

String _s(Map<String, dynamic> m, String k) {
  final v = m[k];
  return v == null ? '' : v.toString();
}

Future<Map<String, dynamic>> _defaultRpc() async =>
    _asMap(await Supabase.instance.client.rpc('onboarding_notices_screen'));

/// The backend's tone vocabulary -> the design tokens. An unknown tone stays
/// neutral rather than blanking the chip, so a tone added in Postgres tomorrow
/// still renders its label.
({Color bg, Color fg}) _tone(String tone) {
  switch (tone) {
    case 'success':
      return (bg: Ds.c.successSoft, fg: Ds.c.success);
    case 'warning':
      return (bg: Ds.c.warningSoft, fg: Ds.c.warning);
    case 'danger':
      return (bg: Ds.c.dangerSoft, fg: Ds.c.danger);
    case 'info':
      return (bg: Ds.c.infoSoft, fg: Ds.c.info);
    default:
      return (bg: Ds.c.bg, fg: Ds.c.textSecondary);
  }
}

class OnboardingNoticesScreen extends StatefulWidget {
  final OnboardingNoticesRpc? rpc;
  const OnboardingNoticesScreen({super.key, this.rpc});

  @override
  State<OnboardingNoticesScreen> createState() =>
      _OnboardingNoticesScreenState();
}

class _OnboardingNoticesScreenState extends State<OnboardingNoticesScreen> {
  Map<String, dynamic> _d = const <String, dynamic>{};
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final d = await (widget.rpc ?? _defaultRpc)();
      RenderLog.write(
          'c1936_onboarding_notices',
          'ok=${d['ok']} events=${_asRows(d['events']).length} '
              'queue=${_asRows(d['queue']).length}');
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = d['ok'] == true ? '' : _s(d, 'message');
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Ds.c.bg,
      appBar: AppBar(
        title: Text(_s(_d, 'title').isEmpty ? ' ' : _s(_d, 'title')),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? _skeleton()
            : (_error.isNotEmpty ? _errorState() : _content()),
      ),
    );
  }

  // ── states ────────────────────────────────────────────────────────────────

  Widget _skeleton() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: List<Widget>.generate(
          4,
          (_) => Padding(
            padding: EdgeInsets.only(bottom: Ds.space.x12),
            child: Container(
              height: Ds.space.x48 + Ds.space.x32,
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                boxShadow: Ds.elevation.e1,
              ),
            ),
          ),
        ),
      );

  Widget _errorState() => ListView(
        padding: EdgeInsets.all(Ds.space.x16),
        children: [
          SizedBox(height: Ds.space.x32),
          Text(_error, textAlign: TextAlign.center, style: Ds.t.body),
          SizedBox(height: Ds.space.x24),
          Center(
            child: OutlinedButton(
              onPressed: _load,
              child: Text(_s(_d, 'retry').isEmpty ? 'Retry' : _s(_d, 'retry')),
            ),
          ),
        ],
      );

  Widget _content() {
    final events = _asRows(_d['events']);
    final queue = _asRows(_d['queue']);
    return ListView(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x48),
      children: [
        _header(),
        SizedBox(height: Ds.space.x24),
        _sectionTitle(_s(_d, 'events_heading')),
        SizedBox(height: Ds.space.x12),
        for (final e in events) ...[
          _eventCard(e),
          SizedBox(height: Ds.space.x12),
        ],
        SizedBox(height: Ds.space.x24),
        _sectionTitle(_s(_d, 'queue_heading')),
        if (_s(_d, 'queue_hint').isNotEmpty) ...[
          SizedBox(height: Ds.space.x4),
          Text(_s(_d, 'queue_hint'), style: Ds.t.caption),
        ],
        SizedBox(height: Ds.space.x12),
        if (queue.isEmpty)
          _emptyQueue()
        else
          for (final q in queue) ...[
            _queueCard(q),
            SizedBox(height: Ds.space.x8),
          ],
      ],
    );
  }

  // ── pieces ────────────────────────────────────────────────────────────────

  Widget _header() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(_d, 'subtitle'), style: Ds.t.bodySecondary),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              if (_s(_d, 'summary').isNotEmpty)
                _chip(_s(_d, 'summary'), 'info'),
              if (_s(_d, 'zone_label').isNotEmpty)
                _chip(_s(_d, 'zone_label'), 'neutral'),
              if (_s(_d, 'as_of').isNotEmpty) _chip(_s(_d, 'as_of'), 'neutral'),
            ],
          ),
        ],
      );

  Widget _sectionTitle(String s) => Text(s, style: Ds.t.subtitle);

  Widget _chip(String label, String tone) {
    final t = _tone(tone);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x4),
      decoration: BoxDecoration(color: t.bg, borderRadius: Ds.r.rChip),
      child: Text(label, style: Ds.t.caption.copyWith(color: t.fg)),
    );
  }

  Widget _card({required Widget child}) => Container(
        padding: EdgeInsets.all(Ds.space.x16),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rCard,
          boxShadow: Ds.elevation.e1,
        ),
        child: child,
      );

  Widget _eventCard(Map<String, dynamic> e) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Title and state wrap rather than clip: at 360 px a long label
            // plus "Waiting on Meta" does not fit one line.
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(_s(e, 'label'), style: Ds.t.bodyStrong),
                _chip(_s(e, 'state_label'), _s(e, 'state_tone')),
              ],
            ),
            if (_s(e, 'description').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(e, 'description'), style: Ds.t.bodySecondary),
            ],
            if (_s(e, 'fires_when').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(e, 'fires_when'), style: Ds.t.caption),
            ],
            if (_s(e, 'note').isNotEmpty) ...[
              SizedBox(height: Ds.space.x8),
              Text(_s(e, 'note'), style: Ds.t.caption),
            ],
            SizedBox(height: Ds.space.x12),
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x8,
              children: [
                _chip(_s(e, 'template_label'), 'neutral'),
                _chip(_s(e, 'sent_label'), 'neutral'),
                _chip(_s(e, 'last_label'), 'neutral'),
              ],
            ),
          ],
        ),
      );

  Widget _queueCard(Map<String, dynamic> q) => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: Ds.space.x8,
              runSpacing: Ds.space.x4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(_s(q, 'title'), style: Ds.t.bodyStrong),
                _chip(_s(q, 'chip_label'), _s(q, 'chip_tone')),
              ],
            ),
            SizedBox(height: Ds.space.x8),
            Text(_s(q, 'subtitle'), style: Ds.t.bodySecondary),
            SizedBox(height: Ds.space.x4),
            Text(_s(q, 'meta'), style: Ds.t.caption),
          ],
        ),
      );

  Widget _emptyQueue() => _card(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: Ds.space.x24),
          child: Center(
            child: Text(_s(_d, 'queue_empty'),
                textAlign: TextAlign.center, style: Ds.t.bodySecondary),
          ),
        ),
      );
}
