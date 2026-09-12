// lib/widgets/live_delivery_map.dart — CMD #1840
//
// THE PERSISTENT MAP.
//
// The problem this widget exists to solve is not "draw a map" — the app already
// had one. It is that the map used to be created, destroyed and created again
// every time the customer changed its size or the host rebuilt, and every one of
// those re-creations is another Google Maps JS load billed to the account and
// another two-second grey rectangle for the buyer.
//
// So the map is built ONCE, into a [GlobalKey], and that same element is reused
// for the life of this card. Expanding and collapsing changes exactly one thing:
// the height passed down to it. Nothing is unmounted, no key changes, no branch
// swaps a map for a thumbnail — the two states are the same live map at two
// sizes. `c1840_map_inits` counts the creations and `c1840_map_toggles` counts
// the size changes: a healthy session reads inits=1 with toggles climbing.
//
// WHAT THIS FILE DECIDES: nothing a customer reads. The two heights, the two
// button words, the heading, the staleness sentence, its tone, the last-updated
// sentence, whether live tiles are allowed while collapsed and whether the
// location stream should still be open all arrive finished in the `map` and
// `trust` blocks (_c1840_map_block / _c1840_trust_block). The only judgement
// made here is which token colour a tone NAME maps to, the same single lookup
// every other card in this app performs.

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/delivery/run_live_map.dart';
import '../utils/render_log.dart';

/// The backend's `map` block, read once so no widget below re-reads raw keys.
class LiveMapContract {
  final bool has;
  final String heading;
  final double collapsedHeight;
  final double expandedHeight;
  final String expandLabel;
  final String collapseLabel;

  /// 'always' — live tiles at both sizes. 'expanded' — the collapsed state is
  /// frozen (not unmounted: it keeps rendering, it just stops taking taps).
  final String liveWhen;
  final bool startsExpanded;

  const LiveMapContract({
    required this.has,
    required this.heading,
    required this.collapsedHeight,
    required this.expandedHeight,
    required this.expandLabel,
    required this.collapseLabel,
    required this.liveWhen,
    required this.startsExpanded,
  });

  static double _d(dynamic v, double fallback) =>
      (v as num?)?.toDouble() ?? fallback;

  factory LiveMapContract.from(Map<String, dynamic> m) => LiveMapContract(
        has: m['has'] == true,
        heading: (m['heading'] ?? '').toString(),
        collapsedHeight: _d(m['collapsed_height'], 180),
        expandedHeight: _d(m['expanded_height'], 420),
        expandLabel: (m['expand_label'] ?? '').toString(),
        collapseLabel: (m['collapse_label'] ?? '').toString(),
        liveWhen: (m['live_when'] ?? 'always').toString(),
        startsExpanded: m['starts_expanded'] == true,
      );

  static const LiveMapContract absent = LiveMapContract(
    has: false,
    heading: '',
    collapsedHeight: 180,
    expandedHeight: 420,
    expandLabel: '',
    collapseLabel: '',
    liveWhen: 'always',
    startsExpanded: false,
  );
}

/// The backend's `trust` block: can this pin be believed, and should the client
/// still be listening. Nothing here is derived from a clock in this build.
class LiveMapTrust {
  final bool has;
  final String state;
  final String label;
  final String tone;
  final String note;
  final String updatedLabel;
  final bool pinStale;

  /// 'stop' the moment the stop is delivered or failed. The card obeys it by
  /// handing the map an empty channel, which is how a subscription is closed.
  final String stream;

  const LiveMapTrust({
    required this.has,
    required this.state,
    required this.label,
    required this.tone,
    required this.note,
    required this.updatedLabel,
    required this.pinStale,
    required this.stream,
  });

  bool get streaming => stream != 'stop';

  factory LiveMapTrust.from(Map<String, dynamic> m) => LiveMapTrust(
        has: m['has'] == true,
        state: (m['state'] ?? '').toString(),
        label: (m['label'] ?? '').toString(),
        tone: (m['tone'] ?? 'muted').toString(),
        note: (m['note'] ?? '').toString(),
        updatedLabel: (m['updated_label'] ?? '').toString(),
        pinStale: m['pin_stale'] == true,
        stream: (m['stream'] ?? 'open').toString(),
      );

  static const LiveMapTrust absent = LiveMapTrust(
    has: false,
    state: '',
    label: '',
    tone: 'muted',
    note: '',
    updatedLabel: '',
    pinStale: false,
    stream: 'open',
  );
}

/// One tone NAME -> one token pair. Unknown tones stay neutral so the backend
/// can add a tone without a deploy.
class LiveMapTone {
  final Color bg;
  final Color fg;
  const LiveMapTone(this.bg, this.fg);

  static LiveMapTone of(String tone) {
    switch (tone) {
      case 'success':
        return LiveMapTone(Ds.c.successSoft, Ds.c.success);
      case 'warning':
        return LiveMapTone(Ds.c.warningSoft, Ds.c.warning);
      case 'danger':
        return LiveMapTone(Ds.c.dangerSoft, Ds.c.danger);
      case 'info':
        return LiveMapTone(Ds.c.infoSoft, Ds.c.info);
      default:
        return LiveMapTone(Ds.c.bg, Ds.c.textSecondary);
    }
  }
}

/// The persistent live map: a trust line, a size toggle and ONE map.
class LiveDeliveryMapCard extends StatefulWidget {
  const LiveDeliveryMapCard({
    super.key,
    required this.contract,
    required this.trust,
    required this.channel,
    required this.stops,
    required this.live,
    this.initialPoint,
    this.note = '',
    this.animateMs = 1200,
    this.roadPolyline = '',
    this.onFrame,
  });

  final LiveMapContract contract;
  final LiveMapTrust trust;

  /// The run channel the backend authorised. Handed to the map ONLY while the
  /// backend says the stream is open — that is how "stop the subscription the
  /// moment the order is delivered or failed" is enforced.
  final String channel;

  final List<Map<String, dynamic>> stops;
  final Map<String, dynamic> live;
  final RiderPoint? initialPoint;
  final String note;
  final int animateMs;
  final String roadPolyline;
  final void Function(Map<String, dynamic> frame)? onFrame;

  /// How many times a map has been CREATED in this session, and how many times
  /// one has been resized. Visible for the protected test and reported to the
  /// render log, because "the map was not re-initialised" is a claim that has
  /// to be counted rather than asserted.
  static int inits = 0;
  static int toggles = 0;

  @override
  State<LiveDeliveryMapCard> createState() => _LiveDeliveryMapCardState();
}

class _LiveDeliveryMapCardState extends State<LiveDeliveryMapCard> {
  /// The identity of the one map. Held in the STATE, never rebuilt, so the
  /// element (and with it the platform view and the Google JS instance) is
  /// reused across every rebuild of this card.
  final GlobalKey _mapKey = GlobalKey();

  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.contract.startsExpanded;
    LiveDeliveryMapCard.inits += 1;
    RenderLog.write('c1840_map_inits', LiveDeliveryMapCard.inits);
  }

  void _toggle() {
    LiveDeliveryMapCard.toggles += 1;
    setState(() => _expanded = !_expanded);
    RenderLog.write('c1840_map_toggles', LiveDeliveryMapCard.toggles);
    RenderLog.write('c1840_map_state', _expanded ? 'expanded' : 'collapsed');
  }

  /// The map is frozen — not removed — when the backend restricts live tiles to
  /// the expanded state. Freezing is a pointer lock and a scrim; the widget
  /// underneath keeps its subscription and its position.
  bool get _frozen =>
      widget.contract.liveWhen == 'expanded' && !_expanded;

  @override
  Widget build(BuildContext context) {
    final c = widget.contract;
    final t = widget.trust;
    final tone = LiveMapTone.of(t.tone);

    RenderLog.write(
        'c1840_map_card',
        'state:${_expanded ? 'expanded' : 'collapsed'}'
        ';trust:${t.state}'
        ';stream:${t.stream}'
        ';stale:${t.pinStale ? 1 : 0}');

    final toggleLabel = _expanded ? c.collapseLabel : c.expandLabel;

    final map = RunLiveMap(
      key: _mapKey,
      // An empty channel is an unsubscribed map. The backend decides when that
      // happens; this card never works it out from a status word.
      channel: t.streaming ? widget.channel : '',
      stops: widget.stops,
      live: widget.live,
      note: widget.note,
      animateMs: widget.animateMs,
      initialPoint: widget.initialPoint,
      roadPolyline: widget.roadPolyline,
      height: _expanded ? c.expandedHeight : c.collapsedHeight,
      // The staleness chip lives on THIS card's header now: two staleness
      // lines on one screen is two answers to one question.
      showLiveChip: false,
      onFrame: widget.onFrame,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── the trust line: what the pin means, and when it was last true ──
        Padding(
          padding: EdgeInsets.only(bottom: Ds.space.x8),
          // The heading used to sit in a Flexible NEXT TO a Spacer. A Row
          // splits its free space between flex children by weight, so the
          // Spacer took half of it and "Live location" ellipsised to
          // "Live loc…" at 420 px with visible whitespace to its right.
          // Heading + chip now own one Expanded between them and the toggle
          // is the only fixed child, so the heading shortens ONLY when there
          // is genuinely no room left.
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (c.heading.isNotEmpty)
                      Flexible(
                        child: Text(c.heading,
                            style: Ds.t.bodyStrong,
                            overflow: TextOverflow.ellipsis),
                      ),
                    if (t.label.isNotEmpty) ...[
                      SizedBox(width: Ds.space.x8),
                      Flexible(
                        child: Container(
                          padding: EdgeInsets.symmetric(
                              horizontal: Ds.space.x12, vertical: Ds.space.x4),
                          decoration: BoxDecoration(
                            color: tone.bg,
                            borderRadius: Ds.r.rChip,
                          ),
                          child: Text(t.label,
                              style: Ds.t.caption.copyWith(color: tone.fg),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (toggleLabel.isNotEmpty)
                SizedBox(
                  height: Ds.touch.minTarget,
                  child: TextButton(
                    onPressed: _toggle,
                    child: Text(toggleLabel, style: Ds.t.caption),
                  ),
                ),
            ],
          ),
        ),

        // ── the ONE map. Only its height changes. ──
        //
        // The AbsorbPointer is ALWAYS in the tree — only its `absorbing` flag
        // moves — so freezing a collapsed map never changes the shape of the
        // subtree above it and never costs a re-creation.
        AbsorbPointer(absorbing: _frozen, child: map),

        // ── when it was last true, and the backend's caveat if it is not ──
        if (t.updatedLabel.isNotEmpty || t.note.isNotEmpty) ...[
          SizedBox(height: Ds.space.x8),
          Row(
            children: [
              if (t.updatedLabel.isNotEmpty)
                Text(t.updatedLabel, style: Ds.t.caption),
              if (t.note.isNotEmpty) ...[
                if (t.updatedLabel.isNotEmpty) SizedBox(width: Ds.space.x8),
                Flexible(
                  child: Text(t.note,
                      style: Ds.t.caption, overflow: TextOverflow.ellipsis),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
