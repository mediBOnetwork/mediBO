// CHANGE — WhatsApp Ops: event routes, account health, contact ledger.
//
// /admin/wa-ops — the screen that explains what the WhatsApp pipeline is doing
// ON ITS OWN, which number it is doing it from, and who it has already talked
// to. Three backend reads, one screen.
//
// This file computes NOTHING a backend already answered:
//
//   • stage_label / stage_tone / pipeline_note are printed verbatim. The app
//     holds no map from a template's Meta status to a sentence — the whole
//     point of section A is that the backend narrates its own automation, so a
//     new pipeline stage tomorrow needs no deploy here.
//   • status_label, window_label, templates_label, tier_label, quality_label,
//     checked_label, summary, last_*_label, free_from_label — all backend
//     sentences, printed as given.
//   • the send window, the marketing frequency cap and the template ceiling are
//     never recomputed. They arrive as words and a percentage.
//   • which route may be edited is `auto_manage`, not a status this file reads.
//
// TWO DELIBERATE CHOICES, both in service of "the app renders, it never
// decides":
//
//   1. A control change SAVES IMMEDIATELY and then re-reads. There is no Save
//      button and no optimistic paint: the switch does not move until
//      wa_event_route_save has answered and the screen has re-read the routes.
//      A control that moved first would be the app asserting a value the
//      backend had not agreed to.
//
//   2. THE "SEND ANY TIME" CONTROL READS `bypass_send_window`, NEVER
//      `window_label`. #648 shipped this control tristate-and-unknown because
//      the payload carried only window_label — a sentence — and parsing that
//      sentence back into a bool ("if it says 'any time' the switch is on")
//      would have been the two-answers-to-one-question bug this repo keeps
//      paying for: reword the sentence in Postgres and the switch silently
//      flips. The backend now returns the boolean itself, so the control is a
//      plain two-state switch initialised from it. window_label stays exactly
//      what it was — the descriptive line beneath the switch, rendered
//      verbatim — and is still never read back into a value.
//
//      p_bypass_window is STILL sent only when an admin actually toggles the
//      switch — onBypass fires on interaction and nowhere else. Same rule as
//      p_variable_map: untouched means null means "leave it alone", which is
//      what wa_event_route_save's coalesce() already does. Initialising the
//      control from the payload is not the same as asserting it back; a screen
//      that re-sent every value it merely displayed would overwrite a
//      concurrent change made anywhere else.
//
//      The switch holds NO local copy of its value, exactly like the enabled
//      switch above it. It paints row['bypass_send_window'] and nothing else,
//      so rule 1 holds here too: a save that fails leaves the control showing
//      what the backend still says, with nothing to roll back.
//
// TONE VOCABULARY. These RPCs speak good/warn/bad/muted; WaToneChip's palette
// speaks green/yellow/red/blue and greys anything it does not know. That is a
// token->token adapter (_chipTone), not a status->colour decision: no wording
// is produced here, and an unrecognised tone still renders its label in grey
// rather than blanking the row.
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../features/whatsapp/ui/wa_campaign_chips.dart';
import '../../utils/render_log.dart';

const _kGreen = Color(0xFF1B7A43);
const _kBg = Color(0xFFF5F6F8);
const _kCard = Colors.white;
const _kBorder = Color(0xFFE5E7EB);
const _kText = Color(0xFF111827);
const _kMuted = Color(0xFF6B7280);
const _kRed = Color(0xFFB91C1C);

// ── RPC seams ────────────────────────────────────────────────────────────────
//
// Injectable function types, same shape as wa_campaign_api.dart: production
// leaves them null and gets the Supabase call; tests pass a stub and never
// touch the network. The wrappers do exactly one thing — call the RPC and hand
// back the jsonb as a Map. No defaulting, no reshaping, no swallowing of an
// `error` key, because the screen is required to render those error strings.
//
// Parameter names verified against pg_proc on 2026-08-04:
//   wa_event_routes_screen()
//   wa_event_route_save(p_event_key, p_template_id, p_variable_map,
//                       p_enabled, p_bypass_window)   <- all but the first
//                                                        default to null, and
//                                                        the function coalesces
//   wa_waba_status()  wa_waba_refresh()
//   wa_contact_ledger(p_days, p_phone)
typedef WaEventRoutesRpc = Future<Map<String, dynamic>> Function();
typedef WaEventRouteSaveRpc = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> params);
typedef WaWabaStatusRpc = Future<Map<String, dynamic>> Function();
typedef WaWabaRefreshRpc = Future<Map<String, dynamic>> Function();
typedef WaContactLedgerRpc = Future<Map<String, dynamic>> Function(
    int days, String? phone);
// zones_contact_screen()  zone_contact_save(p_zone_id, p_phone, p_label)
// p_label defaults to null; an empty p_phone clears the number and the zone
// falls back to the default zone's. The save RPC validates the number itself
// and returns the reason it refuses — this file never reads a phone.
typedef ZonesContactScreenRpc = Future<Map<String, dynamic>> Function();
typedef ZoneContactSaveRpc = Future<Map<String, dynamic>> Function(
    Map<String, dynamic> params);

Map<String, dynamic> _asMap(dynamic res) =>
    res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};

SupabaseClient get _db => Supabase.instance.client;

Future<Map<String, dynamic>> waEventRoutesScreen() async =>
    _asMap(await _db.rpc('wa_event_routes_screen'));

Future<Map<String, dynamic>> waEventRouteSave(
        Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('wa_event_route_save', params: params));

Future<Map<String, dynamic>> waWabaStatus() async =>
    _asMap(await _db.rpc('wa_waba_status'));

Future<Map<String, dynamic>> waWabaRefresh() async =>
    _asMap(await _db.rpc('wa_waba_refresh'));

Future<Map<String, dynamic>> waContactLedger(int days, String? phone) async =>
    _asMap(await _db
        .rpc('wa_contact_ledger', params: {'p_days': days, 'p_phone': phone}));

Future<Map<String, dynamic>> zonesContactScreen() async =>
    _asMap(await _db.rpc('zones_contact_screen'));

Future<Map<String, dynamic>> zoneContactSave(
        Map<String, dynamic> params) async =>
    _asMap(await _db.rpc('zone_contact_save', params: params));

/// Backend ops tone -> WaToneChip palette token.
///
/// Token to token only. `muted` (and anything unknown) falls through to the
/// chip's grey default, which never throws and never hides a label.
String? _chipTone(String? tone) => switch (tone) {
      'good' => 'green',
      'warn' => 'yellow',
      'bad' => 'red',
      _ => null,
    };

/// The foreground colour of a tone, for the bars and the sentences that are not
/// chips. Same lookup the chip uses, so a tone can never mean two colours.
Color _toneInk(String? tone) => waToneColors(_chipTone(tone)).$2;

Color _toneWash(String? tone) => waToneColors(_chipTone(tone)).$1;

/// The message an `{error: ...}` payload should print.
///
/// `message` when the backend wrote one (`no_template`, `not_approved`), the
/// bare code when it did not (`not_authorized`, `unknown_event`). Printed
/// verbatim either way — this file never turns a code into a sentence.
String _errorText(Map<String, dynamic> res) {
  final msg = (res['message'] ?? '').toString();
  if (msg.isNotEmpty) return msg;
  return (res['error'] ?? '').toString();
}

bool _isError(Map<String, dynamic> res) =>
    res['error'] != null && res['error'].toString().isNotEmpty;

class WaOpsScreen extends StatefulWidget {
  // Injected RPCs — tests stub these; production leaves them null.
  final WaEventRoutesRpc? routesRpc;
  final WaEventRouteSaveRpc? routeSaveRpc;
  final WaWabaStatusRpc? wabaStatusRpc;
  final WaWabaRefreshRpc? wabaRefreshRpc;
  final WaContactLedgerRpc? ledgerRpc;
  final ZonesContactScreenRpc? zonesRpc;
  final ZoneContactSaveRpc? zoneSaveRpc;

  /// How long Refresh waits between queueing the Meta fetch and re-reading it.
  /// Three seconds in production (the edge function has to come back); tests
  /// pass Duration.zero so they do not sit on a real timer.
  final Duration refreshDelay;

  const WaOpsScreen({
    super.key,
    this.routesRpc,
    this.routeSaveRpc,
    this.wabaStatusRpc,
    this.wabaRefreshRpc,
    this.ledgerRpc,
    this.zonesRpc,
    this.zoneSaveRpc,
    this.refreshDelay = const Duration(seconds: 3),
  });

  @override
  State<WaOpsScreen> createState() => _WaOpsScreenState();
}

class _WaOpsScreenState extends State<WaOpsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kCard,
        foregroundColor: _kText,
        elevation: 0,
        shape: const Border(bottom: BorderSide(color: _kBorder)),
        // Matches the nav entry's label. Nav labels are unavoidably Dart
        // literals (the nav list is const and renders before any RPC); the
        // title reuses that same word rather than inventing a second name.
        title: const Text('WhatsApp Ops',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 40),
        children: [
          _SectionHeading(
            icon: Icons.settings_suggest_outlined,
            // Section headings are the screen's own furniture, not data.
            text: 'Automatic messages',
          ),
          _EventRoutesSection(
            routesRpc: widget.routesRpc,
            saveRpc: widget.routeSaveRpc,
          ),
          const SizedBox(height: 22),
          _SectionHeading(
            icon: Icons.verified_outlined,
            text: 'Account health',
          ),
          _AccountHealthSection(
            statusRpc: widget.wabaStatusRpc,
            refreshRpc: widget.wabaRefreshRpc,
            refreshDelay: widget.refreshDelay,
          ),
          const SizedBox(height: 22),
          _SectionHeading(
            icon: Icons.people_outline,
            text: 'Who we have messaged',
          ),
          _ContactLedgerSection(ledgerRpc: widget.ledgerRpc),
          const SizedBox(height: 22),
          _SectionHeading(
            icon: Icons.call_outlined,
            text: 'Zone contact numbers',
          ),
          _ZoneContactSection(
            screenRpc: widget.zonesRpc,
            saveRpc: widget.zoneSaveRpc,
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  final IconData icon;
  final String text;
  const _SectionHeading({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Icon(icon, size: 18, color: _kGreen),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                  fontSize: 15.5, fontWeight: FontWeight.w700, color: _kText)),
        ]),
      );
}

// ── SECTION A — automatic messages (event routes) ────────────────────────────

class _EventRoutesSection extends StatefulWidget {
  final WaEventRoutesRpc? routesRpc;
  final WaEventRouteSaveRpc? saveRpc;
  const _EventRoutesSection({this.routesRpc, this.saveRpc});

  @override
  State<_EventRoutesSection> createState() => _EventRoutesSectionState();
}

class _EventRoutesSectionState extends State<_EventRoutesSection> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

  /// Which auto-managed cards the admin has opened the manual controls on.
  /// Purely a disclosure state — it decides nothing about the data.
  final _overridden = <String>{};

  /// The audience the admin has narrowed to, empty means show every section.
  /// Selecting a section's own chip again clears it back to all — that is why
  /// there is no invented "All" label anywhere: the chips are the backend's
  /// audience labels and nothing else. It decides nothing about the data, only
  /// which of the already-grouped sections are on screen.
  String _audienceFilter = '';

  /// Event keys with a save in flight — their controls are disabled so a second
  /// tap cannot race the first.
  final _saving = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.routesRpc ?? waEventRoutesScreen)();
      if (!mounted) return;
      // not_authorized is a payload, not an exception — print what it said.
      if (_isError(res)) {
        setState(() {
          _loading = false;
          _error = _errorText(res);
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write(
            'wa_ops_routes', 'rows=${(res['rows'] as List?)?.length ?? 0}');
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  List<Map<String, dynamic>> get _approved =>
      ((_payload?['approved_templates'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Send, await, render the response. A save that fails prints the backend's
  /// own message and changes nothing else — no local flag is flipped first, so
  /// there is nothing to roll back.
  Future<void> _save(String eventKey, Map<String, dynamic> params) async {
    if (_saving.contains(eventKey)) return;
    setState(() => _saving.add(eventKey));
    try {
      final res = await (widget.saveRpc ?? waEventRouteSave)({
        'p_event_key': eventKey,
        ...params,
      });
      if (!mounted) return;
      if (_isError(res)) {
        setState(() => _saving.remove(eventKey));
        _tell(_errorText(res));
        return;
      }
      setState(() => _saving.remove(eventKey));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving.remove(eventKey));
      _tell(e.toString());
    }
  }

  void _tell(String message) {
    if (message.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: _kRed),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Loading();
    if (_error != null) return _ErrorBlock(message: _error!, onRetry: _load);

    final note = (_payload?['note'] ?? '').toString();
    final rows = _rows;

    // Group by audience, keeping the order the rows arrived in. The backend
    // already ordered them by audience_sort (then within each group), so
    // first-appearance order IS audience_sort — nothing is sorted here, and no
    // user-type name is spelled out: the header and the chip are audience_label.
    final order = <String>[];
    final labels = <String, String>{};
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final r in rows) {
      final aud = (r['audience'] ?? '').toString();
      if (!grouped.containsKey(aud)) {
        grouped[aud] = [];
        order.add(aud);
        labels[aud] = (r['audience_label'] ?? '').toString();
      }
      grouped[aud]!.add(r);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note.isNotEmpty) _NoteBlock(note),
        // The filter row: one chip per audience present, in the same order. A
        // user type with no routes never reaches this list, so it shows no chip
        // and no section.
        if (order.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              children: [
                for (final aud in order) _audienceChip(aud, labels[aud] ?? ''),
              ],
            ),
          ),
        for (final aud in order)
          if (_audienceFilter.isEmpty || _audienceFilter == aud) ...[
            Padding(
              key: Key('wa_ops_aud_header:$aud'),
              padding: const EdgeInsets.only(top: 2, bottom: 8),
              child: Text(
                labels[aud] ?? '',
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: _kText),
              ),
            ),
            for (final r in grouped[aud]!)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _EventRouteCard(
                  row: r,
                  approved: _approved,
                  overridden:
                      _overridden.contains((r['event_key'] ?? '').toString()),
                  busy: _saving.contains((r['event_key'] ?? '').toString()),
                  bypass: r['bypass_send_window'] == true,
                  onOverride: () => setState(() =>
                      _overridden.add((r['event_key'] ?? '').toString())),
                  onPickTemplate: (id) => _save(
                      (r['event_key'] ?? '').toString(), {'p_template_id': id}),
                  onEnabled: (v) => _save(
                      (r['event_key'] ?? '').toString(), {'p_enabled': v}),
                  onBypass: (v) => _save(
                      (r['event_key'] ?? '').toString(), {'p_bypass_window': v}),
                ),
              ),
          ],
      ],
    );
  }

  /// One filter chip, captioned with the backend's audience_label. Tapping the
  /// selected one again clears the filter — so "all" needs no label of its own.
  Widget _audienceChip(String aud, String label) {
    final selected = _audienceFilter == aud;
    return GestureDetector(
      key: Key('wa_ops_aud_chip:$aud'),
      onTap: () =>
          setState(() => _audienceFilter = selected ? '' : aud),
      child: Container(
        margin: const EdgeInsets.only(right: 6, bottom: 6),
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 14),
        decoration: BoxDecoration(
          color: selected ? _kGreen : const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : _kMuted,
          ),
        ),
      ),
    );
  }
}

class _EventRouteCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> approved;
  final bool overridden;
  final bool busy;
  final bool bypass;
  final VoidCallback onOverride;
  final ValueChanged<String> onPickTemplate;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<bool> onBypass;

  const _EventRouteCard({
    required this.row,
    required this.approved,
    required this.overridden,
    required this.busy,
    required this.bypass,
    required this.onOverride,
    required this.onPickTemplate,
    required this.onEnabled,
    required this.onBypass,
  });

  String _s(String k) => (row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final autoManage = row['auto_manage'] == true;
    // Auto-managed cards are read-only until the admin explicitly overrides.
    // A hand-managed route has nothing to override — its controls are the card.
    final showControls = !autoManage || overridden;

    final pipelineNote = _s('pipeline_note');
    final description = _s('description');
    final sent = (row['sent_30d'] ?? 0).toString();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _s('label'),
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: _kText),
          ),
          const SizedBox(height: 6),
          // The primary chip is the STAGE, not the on/off status: the whole
          // point of this screen is what the pipeline is doing by itself.
          //
          // Under the headline rather than beside it — stage_label is a phrase
          // ("Live — switched on automatically"), not a word, and a chip that
          // long clips against a headline at phone widths.
          Align(
            alignment: Alignment.centerLeft,
            child: WaToneChip(
                label: _s('stage_label'),
                tone: _chipTone(row['stage_tone']?.toString())),
          ),
          if (description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(description,
                  style: const TextStyle(
                      fontSize: 12.5, height: 1.35, color: _kMuted)),
            ),
          if (pipelineNote.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(pipelineNote,
                  style: TextStyle(
                      fontSize: 12.5,
                      height: 1.35,
                      color: _toneInk(row['stage_tone']?.toString()))),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              WaPlainChip(label: _s('template_name')),
              WaPlainChip(label: _s('language')),
              // Only while the controls are closed. Once they open,
              // window_label is the label of the control it describes, and
              // printing the same backend sentence twice on one card invites
              // the two to drift apart on screen.
              if (!showControls) WaPlainChip(label: _s('window_label')),
              WaToneChip(
                  label: _s('status_label'),
                  tone: _chipTone(row['status_tone']?.toString())),
            ],
          ),
          const SizedBox(height: 8),
          // The only figures on this card the backend did not pre-word.
          // sent_30d is a bare count and updated_label is already a date
          // string; neither is recomputed here.
          Row(children: [
            const Icon(Icons.send_outlined, size: 13, color: _kMuted),
            const SizedBox(width: 5),
            Text('$sent sent in 30 days',
                style: const TextStyle(fontSize: 11.5, color: _kMuted)),
            const SizedBox(width: 12),
            const Icon(Icons.schedule, size: 13, color: _kMuted),
            const SizedBox(width: 5),
            Flexible(
              child: Text(_s('updated_label'),
                  style: const TextStyle(fontSize: 11.5, color: _kMuted)),
            ),
          ]),
          if (autoManage && !overridden)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: onOverride,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kGreen,
                    side: const BorderSide(color: _kBorder),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    minimumSize: const Size(0, 34),
                  ),
                  // pipeline_note already said what the system is doing; this
                  // button explains nothing, it only unlocks.
                  child: const Text('Override',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          if (showControls) ...[
            const Divider(height: 22, color: _kBorder),
            _RouteControls(
              row: row,
              approved: approved,
              busy: busy,
              bypass: bypass,
              onPickTemplate: onPickTemplate,
              onEnabled: onEnabled,
              onBypass: onBypass,
            ),
          ],
        ],
      ),
    );
  }
}

/// The manual controls. Every change saves immediately and the screen re-reads;
/// nothing here paints a value the backend has not returned.
class _RouteControls extends StatelessWidget {
  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> approved;
  final bool busy;
  final bool bypass;
  final ValueChanged<String> onPickTemplate;
  final ValueChanged<bool> onEnabled;
  final ValueChanged<bool> onBypass;

  const _RouteControls({
    required this.row,
    required this.approved,
    required this.busy,
    required this.bypass,
    required this.onPickTemplate,
    required this.onEnabled,
    required this.onBypass,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = row['enabled'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Approved templates only — the backend refuses anything else, and the
        // list it sends is already the allowed set.
        DropdownButtonFormField<String>(
          key: const Key('wa_ops_template_picker'),
          initialValue: null,
          isExpanded: true,
          decoration: const InputDecoration(
            isDense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            border: OutlineInputBorder(),
          ),
          // The current template is already printed as a chip above; this
          // control is the change, and its options are the backend's labels.
          hint: Text(
            (row['template_name'] ?? '').toString(),
            style: const TextStyle(fontSize: 13, color: _kText),
          ),
          items: [
            for (final t in approved)
              DropdownMenuItem<String>(
                value: (t['id'] ?? '').toString(),
                child: Text((t['label'] ?? '').toString(),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13)),
              ),
          ],
          onChanged: busy
              ? null
              : (v) {
                  if (v != null && v.isNotEmpty) onPickTemplate(v);
                },
        ),
        const SizedBox(height: 4),
        // Label is status_label — the backend's own word for on/off. The app
        // owns no "On"/"Off" vocabulary.
        //
        // A bare Switch, not a SwitchListTile: a ListTile paints its background
        // and ink on the nearest Material ancestor, and this card's own
        // DecoratedBox sits in between, so the framework asserts.
        Row(children: [
          Switch(
            key: const Key('wa_ops_enabled_switch'),
            value: enabled,
            onChanged: busy ? null : onEnabled,
            activeThumbColor: _kGreen,
          ),
          Expanded(
            child: Text((row['status_label'] ?? '').toString(),
                style: const TextStyle(fontSize: 13, color: _kText)),
          ),
        ]),
        // Two-state, initialised from the payload's bypass_send_window — see
        // the file header. window_label is still only ever rendered, never
        // read back into this value.
        Row(children: [
          Switch(
            key: const Key('wa_ops_bypass_switch'),
            value: bypass,
            onChanged: busy ? null : onBypass,
            activeThumbColor: _kGreen,
          ),
          Expanded(
            child: Text((row['window_label'] ?? '').toString(),
                style: const TextStyle(fontSize: 13, color: _kText)),
          ),
        ]),
        // How long the route stands down after the legacy sender already
        // delivered. Read-only: there is no control for it, and the label is
        // the field's own name so no wording is invented here.
        Padding(
          padding: const EdgeInsets.only(top: 2, left: 4),
          child: Text(
            'Dedupe minutes: ${row['dedupe_minutes'] ?? ''}',
            key: const Key('wa_ops_dedupe_minutes'),
            style: const TextStyle(fontSize: 12, color: _kMuted),
          ),
        ),
      ],
    );
  }
}

// ── SECTION B — account health ───────────────────────────────────────────────

class _AccountHealthSection extends StatefulWidget {
  final WaWabaStatusRpc? statusRpc;
  final WaWabaRefreshRpc? refreshRpc;
  final Duration refreshDelay;
  const _AccountHealthSection({
    this.statusRpc,
    this.refreshRpc,
    required this.refreshDelay,
  });

  @override
  State<_AccountHealthSection> createState() => _AccountHealthSectionState();
}

class _AccountHealthSectionState extends State<_AccountHealthSection> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.statusRpc ?? waWabaStatus)();
      if (!mounted) return;
      if (_isError(res) && res['waba_name'] == null) {
        // A gate refusal (not_authorized) — no figures came at all.
        setState(() {
          _loading = false;
          _error = _errorText(res);
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write('wa_ops_waba', (res['review_status'] ?? '').toString());
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// Queue the Meta fetch, give the edge function time to land, then re-read.
  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await (widget.refreshRpc ?? waWabaRefresh)();
      await Future<void>.delayed(widget.refreshDelay);
      if (!mounted) return;
      await _load();
    } catch (_) {
      // A failed queue leaves the figures exactly as they were.
    }
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Loading();
    if (_error != null) return _ErrorBlock(message: _error!, onRetry: _load);

    final p = _payload ?? const <String, dynamic>{};
    String s(String k) => (p[k] ?? '').toString();

    // `error` here is Meta's own last failure, stored on wa_waba_state. It
    // replaces the figures rather than sitting beside them.
    final metaError = (p['error'] ?? '').toString();
    final note = s('note');
    final pct = ((p['templates_pct'] as num?) ?? 0).toDouble().clamp(0, 100);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _kCard,
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Text(s('waba_name'),
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: _kText)),
                ),
                const SizedBox(width: 8),
                WaPlainChip(label: s('review_status')),
              ]),
              const SizedBox(height: 12),
              if (metaError.isNotEmpty)
                Container(
                  key: const Key('wa_ops_waba_error'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _toneWash('bad'),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(metaError,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.35,
                          color: _toneInk('bad'))),
                )
              else ...[
                Text(s('templates_label'),
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _kText)),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const Key('wa_ops_templates_bar'),
                    value: pct / 100.0,
                    minHeight: 7,
                    backgroundColor: const Color(0xFFF3F4F6),
                    valueColor: AlwaysStoppedAnimation<Color>(
                        _toneInk(p['templates_tone']?.toString())),
                  ),
                ),
                const SizedBox(height: 12),
                Text(s('tier_label'),
                    style: const TextStyle(fontSize: 13, color: _kText)),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: WaToneChip(
                      label: s('quality_label'),
                      tone: _chipTone(p['quality_tone']?.toString()),
                      fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: Text(s('checked_label'),
                      style: const TextStyle(fontSize: 11.5, color: _kMuted)),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _refreshing ? null : _refresh,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _kGreen,
                    side: const BorderSide(color: _kBorder),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    minimumSize: const Size(0, 34),
                  ),
                  child: const Text('Refresh',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
          ),
        ),
        if (note.isNotEmpty) _NoteBlock(note, topGap: 10),
      ],
    );
  }
}

// ── SECTION C — who we have messaged ─────────────────────────────────────────

class _ContactLedgerSection extends StatefulWidget {
  final WaContactLedgerRpc? ledgerRpc;
  const _ContactLedgerSection({this.ledgerRpc});

  @override
  State<_ContactLedgerSection> createState() => _ContactLedgerSectionState();
}

class _ContactLedgerSectionState extends State<_ContactLedgerSection> {
  /// The window stays at 30 days; only the phone filter changes.
  static const _days = 30;

  final _searchCtrl = TextEditingController();
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(null);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load(String? phone) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.ledgerRpc ?? waContactLedger)(_days, phone);
      if (!mounted) return;
      if (_isError(res)) {
        setState(() {
          _loading = false;
          _error = _errorText(res);
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write(
            'wa_ops_ledger', 'contacts=${(res['contacts'] ?? 0)}');
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Loading();
    if (_error != null) {
      return _ErrorBlock(message: _error!, onRetry: () => _load(null));
    }

    final summary = (_payload?['summary'] ?? '').toString();
    final rows = _rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(summary,
                style: const TextStyle(
                    fontSize: 12.5, height: 1.35, color: _kMuted)),
          ),
        TextField(
          key: const Key('wa_ops_ledger_search'),
          controller: _searchCtrl,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: _kCard,
            hintText: 'Search a number',
            hintStyle: const TextStyle(fontSize: 13, color: _kMuted),
            prefixIcon: const Icon(Icons.search, size: 18, color: _kMuted),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: const OutlineInputBorder(),
          ),
          style: const TextStyle(fontSize: 13),
          onSubmitted: (v) {
            final q = v.trim();
            _load(q.isEmpty ? null : q);
          },
        ),
        const SizedBox(height: 10),
        // An empty result is the summary alone — the backend already worded
        // what "nothing here" means for the window it was asked about.
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _LedgerRow(row: r),
          ),
      ],
    );
  }
}

class _LedgerRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _LedgerRow({required this.row});

  String _s(String k) => (row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final blocked = row['blocked_now'] == true;

    return Container(
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s('phone'),
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w700, color: _kText)),
          // The cap chip only exists while the cap is actually biting.
          //
          // On its own line, not beside the number: free_from_label is a full
          // sentence carrying a date ("Marketing allowed again 06 Aug, 06:10
          // PM"), and sharing a row with the phone clips it at a 360 px
          // viewport. Backend sentences get the width they need.
          if (blocked)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: WaToneChip(
                    label: _s('free_from_label'),
                    tone: _chipTone(row['tone']?.toString())),
              ),
            ),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            WaPlainChip(label: (row['messages'] ?? 0).toString()),
            WaPlainChip(label: (row['marketing'] ?? 0).toString()),
            WaPlainChip(label: (row['campaigns'] ?? 0).toString()),
          ]),
          const SizedBox(height: 8),
          Text(_s('last_marketing_label'),
              style: const TextStyle(fontSize: 11.5, color: _kMuted)),
          Text(_s('last_any_label'),
              style: const TextStyle(fontSize: 11.5, color: _kMuted)),
        ],
      ),
    );
  }
}

// ── SECTION D — zone contact numbers ─────────────────────────────────────────
//
// One WhatsApp number sends every message, but each zone carries its OWN number
// that customers are told to CALL, resolved per customer as the zone_phone value
// in a template. This panel is a thin editor over zones_contact_screen /
// zone_contact_save.
//
// It decides nothing: `note`, `status_label`, `tone`, `default_note` and every
// save `message` are the backend's own strings, printed verbatim. The phone is
// NEVER validated here — an empty value is a legitimate save meaning "use the
// default zone's number", and the RPC returns the reason whenever it refuses.
// The two field captions ("Number", "Label") are the only words this section
// owns; the default marker is an icon, not a coined label.

class _ZoneContactSection extends StatefulWidget {
  final ZonesContactScreenRpc? screenRpc;
  final ZoneContactSaveRpc? saveRpc;
  const _ZoneContactSection({this.screenRpc, this.saveRpc});

  @override
  State<_ZoneContactSection> createState() => _ZoneContactSectionState();
}

class _ZoneContactSectionState extends State<_ZoneContactSection> {
  Map<String, dynamic>? _payload;
  bool _loading = true;
  String? _error;

  /// Zone ids with a save in flight — their Save button is disabled so a second
  /// tap cannot race the first.
  final _saving = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await (widget.screenRpc ?? zonesContactScreen)();
      if (!mounted) return;
      // not_authorized is a payload, not an exception — print what it said.
      if (_isError(res)) {
        setState(() {
          _loading = false;
          _error = _errorText(res);
        });
        return;
      }
      setState(() {
        _payload = res;
        _loading = false;
      });
      try {
        RenderLog.write(
            'wa_ops_zones', 'rows=${(res['rows'] as List?)?.length ?? 0}');
      } catch (_) {}
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  List<Map<String, dynamic>> get _rows =>
      ((_payload?['rows'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// Send, await, show the backend's `message`, then re-read. An `{error: ...}`
  /// shows its message and changes nothing — no re-read, so the fields the admin
  /// typed stay exactly as typed. An empty phone is submitted like any other
  /// value; this file blocks nothing.
  Future<void> _save(int zoneId, String phone, String label) async {
    if (_saving.contains(zoneId)) return;
    setState(() => _saving.add(zoneId));
    try {
      final res = await (widget.saveRpc ?? zoneContactSave)({
        'p_zone_id': zoneId,
        'p_phone': phone,
        'p_label': label,
      });
      if (!mounted) return;
      setState(() => _saving.remove(zoneId));
      _tell(_errorText(res));
      if (!_isError(res)) await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving.remove(zoneId));
      _tell(e.toString());
    }
  }

  void _tell(String message) {
    if (message.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _Loading();
    if (_error != null) return _ErrorBlock(message: _error!, onRetry: _load);

    final note = (_payload?['note'] ?? '').toString();
    final defaultNote = (_payload?['default_note'] ?? '').toString();
    final rows = _rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note.isNotEmpty) _NoteBlock(note),
        for (final r in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _ZoneContactCard(
              key: ValueKey('wa_ops_zone:${r['zone_id']}'),
              row: r,
              busy: _saving.contains((r['zone_id'] as num?)?.toInt() ?? -1),
              onSave: (phone, label) => _save(
                  (r['zone_id'] as num?)?.toInt() ?? 0, phone, label),
            ),
          ),
        if (defaultNote.isNotEmpty) _NoteBlock(defaultNote, topGap: 2),
      ],
    );
  }
}

/// One zone. The phone and label fields are the current values, editable in
/// place; the card holds no answer of its own beyond what the admin is typing.
class _ZoneContactCard extends StatefulWidget {
  final Map<String, dynamic> row;
  final bool busy;
  final void Function(String phone, String label) onSave;

  const _ZoneContactCard({
    super.key,
    required this.row,
    required this.busy,
    required this.onSave,
  });

  @override
  State<_ZoneContactCard> createState() => _ZoneContactCardState();
}

class _ZoneContactCardState extends State<_ZoneContactCard> {
  late final TextEditingController _phone;
  late final TextEditingController _label;

  @override
  void initState() {
    super.initState();
    _phone = TextEditingController(
        text: (widget.row['contact_phone'] ?? '').toString());
    _label = TextEditingController(
        text: (widget.row['contact_label'] ?? '').toString());
  }

  @override
  void dispose() {
    _phone.dispose();
    _label.dispose();
    super.dispose();
  }

  String _s(String k) => (widget.row[k] ?? '').toString();

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final isDefault = row['is_default'] == true;
    final isActive = row['is_active'] != false;
    final customers = (row['customers'] ?? 0).toString();

    final card = Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _kCard,
        border: Border.all(color: _kBorder),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(_s('name'),
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _kText)),
            ),
            const SizedBox(width: 6),
            WaPlainChip(label: _s('code')),
            // The default marker is an icon, not a coined word — the app owns no
            // "Default" label. status_label already narrates the fallback.
            if (isDefault) ...[
              const SizedBox(width: 6),
              Container(
                key: Key('wa_ops_zone_default:${row['zone_id']}'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: _toneWash('blue'),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(Icons.star, size: 13, color: _toneInk('blue')),
              ),
            ],
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.people_outline, size: 13, color: _kMuted),
            const SizedBox(width: 5),
            Text(customers,
                style: const TextStyle(fontSize: 11.5, color: _kMuted)),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: WaToneChip(
                label: _s('status_label'),
                tone: _chipTone(row['tone']?.toString())),
          ),
          const Divider(height: 22, color: _kBorder),
          TextField(
            key: Key('wa_ops_zone_phone:${row['zone_id']}'),
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Number',
              labelStyle: TextStyle(fontSize: 13, color: _kMuted),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13, color: _kText),
          ),
          const SizedBox(height: 8),
          TextField(
            key: Key('wa_ops_zone_label:${row['zone_id']}'),
            controller: _label,
            decoration: const InputDecoration(
              isDense: true,
              labelText: 'Label',
              labelStyle: TextStyle(fontSize: 13, color: _kMuted),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontSize: 13, color: _kText),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            // Save carries no word — the app owns none here; the icon is the
            // affordance and the backend's returned message is the result.
            child: ElevatedButton(
              key: Key('wa_ops_zone_save:${row['zone_id']}'),
              onPressed:
                  widget.busy ? null : () => widget.onSave(_phone.text, _label.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGreen,
                foregroundColor: Colors.white,
                elevation: 0,
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 18),
              ),
              child: const Icon(Icons.check, size: 18),
            ),
          ),
        ],
      ),
    );

    // An inactive zone renders dimmed — visual only, still fully editable.
    return isActive ? card : Opacity(opacity: 0.5, child: card);
  }
}

// ── shared small parts ───────────────────────────────────────────────────────

class _NoteBlock extends StatelessWidget {
  final String note;
  final double topGap;
  const _NoteBlock(this.note, {this.topGap = 0});

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: topGap, bottom: 10),
        child: Container(
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            border: Border.all(color: _kBorder),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.info_outline, size: 14, color: _kMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(note,
                  style: const TextStyle(
                      fontSize: 12, height: 1.4, color: _kMuted)),
            ),
          ]),
        ),
      );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2, color: _kGreen),
          ),
        ),
      );
}

/// Prints the backend's refusal or the transport's exception verbatim and
/// offers another read. It never rewrites either into friendlier words.
class _ErrorBlock extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBlock({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _toneWash('bad'),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.error_outline, size: 16, color: _toneInk('bad')),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: TextStyle(
                    fontSize: 12.5, height: 1.35, color: _toneInk('bad'))),
          ),
          IconButton(
            onPressed: onRetry,
            icon: Icon(Icons.refresh, size: 18, color: _toneInk('bad')),
            visualDensity: VisualDensity.compact,
          ),
        ]),
      );
}
