// lib/widgets/delivery_proof_card.dart — CHANGE #691 (register rows 122 + 126)
//
// Two blocks that every delivery surface shares, so an arrival window and a
// proof of delivery cannot be worded one way in the tracker and another way on
// the bill.
//
// Register row 122: deliveries.eta_min was written once by the route optimiser
// and never rebased, so the only thing this app could ever tell a buyer was
// "3 stops before you". A stop count is not a time. The backend now rebases on
// every stop completion, run start and rider location update and hands over a
// finished sentence — "Arriving 4:10–4:30 pm" — which this file prints.
//
// Register row 126: completion already stored proof_method, proof_photo_path,
// receiver_name, delivered_lat/lng, signature_path and handover_at, and showed
// none of it to the person who paid. _delivery_proof_block() says all of it,
// once; this file draws it.
//
// NOTHING HERE COMPUTES. There is no time arithmetic, no "in X minutes", no
// method-name prettifying, no pluralising and no URL building: every string is
// a payload string, and absence is the payload's own `has:false` — never an
// empty value this widget had to test for.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// The arrival window, as its own card. `has:false` renders the backend's own
/// state sentence (delivered / not started yet) or nothing at all — it never
/// invents "ETA unavailable".
class DeliveryEtaCard extends StatelessWidget {
  final Map<String, dynamic> eta;

  const DeliveryEtaCard({super.key, required this.eta});

  @override
  Widget build(BuildContext context) {
    if (eta.isEmpty) return const SizedBox.shrink();

    final has = eta['has'] == true;
    final label = _s(eta, 'label');
    if (!has && label.isEmpty) return const SizedBox.shrink();

    RenderLog.write('c691_eta_card', has ? 1 : 0);

    final heading = _s(eta, 'heading');
    final countdown = _s(eta, 'countdown_label');
    final ahead = _s(eta, 'stops_ahead_label');
    final note = _s(eta, 'note');

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: has ? Ds.c.brandSoft : Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (heading.isNotEmpty) Text(heading, style: Ds.t.caption),
          if (heading.isNotEmpty) SizedBox(height: Ds.space.x4),
          Text(label, style: Ds.t.subtitle),
          if (countdown.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(countdown, style: Ds.t.body),
          ],
          if (ahead.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: Ds.space.x12, vertical: Ds.space.x4),
              decoration: BoxDecoration(
                color: Ds.c.infoSoft,
                borderRadius: Ds.r.rChip,
              ),
              child: Text(ahead, style: Ds.t.caption),
            ),
          ],
          if (note.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(note, style: Ds.t.caption),
          ],
        ],
      ),
    );
  }
}

/// The same window on one line, for a list row that has no space for a card.
class DeliveryEtaLine extends StatelessWidget {
  final Map<String, dynamic> eta;

  const DeliveryEtaLine({super.key, required this.eta});

  @override
  Widget build(BuildContext context) {
    if (eta['has'] != true) return const SizedBox.shrink();
    final label = _s(eta, 'label');
    if (label.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c691_eta_line', 1);
    return Container(
      padding:
          EdgeInsets.symmetric(horizontal: Ds.space.x8, vertical: Ds.space.x4),
      decoration: BoxDecoration(
        color: Ds.c.brandSoft,
        borderRadius: Ds.r.rChip,
      ),
      child: Text(label, style: Ds.t.caption),
    );
  }
}

/// Proof of delivery: who took it, when, how it was confirmed, the photo and
/// the pin. Every caption and every value is a backend string; the photo
/// travels as bucket + path because `delivery-proofs` is private, so the
/// signature is minted here under the viewer's own storage policy.
class DeliveryProofCard extends StatelessWidget {
  final Map<String, dynamic> proof;

  /// Set on surfaces that already print their own section headings.
  final bool showHeading;

  const DeliveryProofCard({
    super.key,
    required this.proof,
    this.showHeading = true,
  });

  @override
  Widget build(BuildContext context) {
    if (proof['has'] != true) return const SizedBox.shrink();
    RenderLog.write('c691_proof_card', 1);

    final photo = _m(proof['photo']);
    final sign = _m(proof['signature']);
    final map = _m(proof['map']);

    final rows = <List<String>>[
      if (proof['has_receiver'] == true)
        [_s(proof, 'receiver_caption'), _s(proof, 'receiver_name')],
      if (proof['has_time'] == true)
        [_s(proof, 'time_caption'), _s(proof, 'time_label')],
      [_s(proof, 'method_caption'), _s(proof, 'method_label')],
    ];

    return Container(
      width: double.infinity,
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        borderRadius: Ds.r.rCard,
        border: Border.all(color: Ds.c.divider),
        boxShadow: Ds.elevation.e1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeading && _s(proof, 'heading').isNotEmpty) ...[
            Text(_s(proof, 'heading'), style: Ds.t.subtitle),
            SizedBox(height: Ds.space.x12),
          ],
          for (final r in rows)
            if (r[1].isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(r[0], style: Ds.t.caption)),
                    SizedBox(width: Ds.space.x12),
                    Expanded(
                      flex: 2,
                      child: Text(r[1],
                          style: Ds.t.body, textAlign: TextAlign.right),
                    ),
                  ],
                ),
              ),
          if (photo['has'] == true) ...[
            SizedBox(height: Ds.space.x4),
            DeliveryProofImage(
              bucket: (photo['bucket'] ?? '').toString(),
              path: (photo['path'] ?? '').toString(),
              label: (photo['label'] ?? '').toString(),
            ),
          ],
          if (sign['has'] == true) ...[
            SizedBox(height: Ds.space.x12),
            DeliveryProofImage(
              bucket: (sign['bucket'] ?? '').toString(),
              path: (sign['path'] ?? '').toString(),
              label: (sign['label'] ?? '').toString(),
            ),
          ],
          if (map['has'] == true && (map['url'] ?? '').toString().isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            _ProofMapLink(
              label: (map['label'] ?? '').toString(),
              url: (map['url'] ?? '').toString(),
            ),
          ],
        ],
      ),
    );
  }
}

/// A private-bucket image, signed on demand. A path this viewer may not read
/// renders nothing — an empty frame would claim a photo exists and cannot be
/// shown, which is a different (and untrue) statement.
class DeliveryProofImage extends StatefulWidget {
  final String bucket;
  final String path;
  final String label;

  const DeliveryProofImage({
    super.key,
    required this.bucket,
    required this.path,
    required this.label,
  });

  @override
  State<DeliveryProofImage> createState() => _DeliveryProofImageState();
}

class _DeliveryProofImageState extends State<DeliveryProofImage> {
  String _url = '';

  @override
  void initState() {
    super.initState();
    _sign();
  }

  Future<void> _sign() async {
    if (widget.bucket.isEmpty || widget.path.isEmpty) return;
    try {
      final u = await Supabase.instance.client.storage
          .from(widget.bucket)
          .createSignedUrl(widget.path, 3600);
      if (mounted) setState(() => _url = u);
    } catch (_) {
      // Not permitted, or gone. Silence is the correct render.
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_url.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c691_proof_photo', 1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label.isNotEmpty) ...[
          Text(widget.label, style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
        ],
        ClipRRect(
          borderRadius: Ds.r.rChip,
          child: Image.network(
            _url,
            width: double.infinity,
            height: Ds.space.x48 * 4,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _ProofMapLink extends StatelessWidget {
  final String label;
  final String url;

  const _ProofMapLink({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () async {
        final uri = Uri.tryParse(url);
        if (uri == null) return;
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      },
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.space.x48),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: Ds.c.infoSoft,
          borderRadius: Ds.r.rChip,
        ),
        child: Row(children: [
          Icon(Icons.place_outlined, size: Ds.space.x16, color: Ds.c.info),
          SizedBox(width: Ds.space.x8),
          Expanded(child: Text(label, style: Ds.t.body)),
        ]),
      ),
    );
  }
}
