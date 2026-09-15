// lib/widgets/rider_vehicle_card.dart — CMD #1840
//
// WHO IS BRINGING IT, ON WHAT, AND HOW TO REACH THEM.
//
// The customer's tracking screens showed a name and, since #463, a face. They
// never showed the vehicle — which is the one thing a buyer standing at a gate
// actually uses to recognise the delivery. This card carries the name, the
// verified face, the vehicle and its plate, the masked call button, a WhatsApp
// affordance and "stops before you", all in one block under the map.
//
// It computes NOTHING. Every string is `_c1840_rider_card()`'s: the heading,
// the word "Vehicle", the vehicle name, the plate, the WhatsApp label, the
// whole wa.me URL (built server-side precisely so no phone number ever reaches
// this build) and the stops-before sentence. A block whose `has` is false is
// omitted, never dashed and never replaced with a placeholder.
//
// The face and the masked call button are passed IN as widgets, because both
// already exist on the tracking view and belong to the layers that own them —
// storage signing for one, the #404 masking contract for the other. This card
// places them; it does not re-implement them.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

class RiderVehicleCard extends StatelessWidget {
  const RiderVehicleCard({
    super.key,
    required this.card,
    this.avatar,
    this.call,
    this.onOpenUrl,
  });

  /// The backend's `rider_card` block.
  final Map<String, dynamic> card;

  /// The rider's verified face, built by the caller (private bucket, signed on
  /// demand). Null when the backend said there is no photo to show.
  final Widget? avatar;

  /// The masked call button, built by the caller from the payload's own
  /// `call_action`. Null when the backend offered no call.
  final Widget? call;

  /// Injected so a test can prove the card opens the BACKEND's url and not one
  /// it assembled. Production passes null and the launcher is used.
  final Future<void> Function(String url)? onOpenUrl;

  static String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

  static Map<String, dynamic> _m(Map<String, dynamic> m, String k) =>
      m[k] is Map ? Map<String, dynamic>.from(m[k] as Map) : const {};

  @override
  Widget build(BuildContext context) {
    if (card['has'] != true) return const SizedBox.shrink();

    final name = _s(card, 'name');
    final heading = _s(card, 'heading');
    final vehicle = _m(card, 'vehicle');
    final wa = _m(card, 'whatsapp');
    final stops = _m(card, 'stops_before');

    RenderLog.write(
        'c1840_rider_card',
        'name:${name.isEmpty ? 0 : 1}'
        ';veh:${vehicle['has'] == true ? 1 : 0}'
        ';wa:${wa['has'] == true ? 1 : 0}'
        ';call:${call != null ? 1 : 0}'
        ';stops:${stops['has'] == true ? 1 : 0}');

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border.all(color: Ds.c.divider),
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (heading.isNotEmpty) ...[
            Text(heading, style: Ds.t.caption),
            SizedBox(height: Ds.space.x12),
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (avatar != null) ...[
                avatar!,
                SizedBox(width: Ds.space.x12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (name.isNotEmpty)
                      Text(name, style: Ds.t.subtitle),
                    // The vehicle line: "Vehicle" then the model, then the
                    // plate. Every one of the three is the payload's, and an
                    // absent one is simply not printed.
                    if (vehicle['has'] == true) ...[
                      SizedBox(height: Ds.space.x4),
                      _VehicleLine(vehicle: vehicle),
                    ],
                    if (stops['has'] == true) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(_s(stops, 'label'), style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (call != null || wa['has'] == true) ...[
            SizedBox(height: Ds.space.x16),
            Row(
              children: [
                if (call != null) Flexible(child: call!),
                if (call != null && wa['has'] == true)
                  SizedBox(width: Ds.space.x8),
                if (wa['has'] == true)
                  Flexible(
                    child: _WhatsAppButton(
                      label: _s(wa, 'label'),
                      url: _s(wa, 'url'),
                      onOpenUrl: onOpenUrl,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _VehicleLine extends StatelessWidget {
  const _VehicleLine({required this.vehicle});
  final Map<String, dynamic> vehicle;

  @override
  Widget build(BuildContext context) {
    final label = (vehicle['label'] ?? '').toString();
    final name = (vehicle['name'] ?? '').toString();
    final number = (vehicle['number'] ?? '').toString();

    return Wrap(
      spacing: Ds.space.x8,
      runSpacing: Ds.space.x4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (label.isNotEmpty) Text(label, style: Ds.t.caption),
        if (name.isNotEmpty) Text(name, style: Ds.t.body),
        // The plate is set apart because that is what a buyer reads off a
        // vehicle. It is still the payload's string, untouched — not
        // upper-cased, not spaced, not reformatted.
        if (number.isNotEmpty)
          Container(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x8, vertical: Ds.space.x4),
            decoration: BoxDecoration(
              color: Ds.c.bg,
              borderRadius: Ds.r.rChip,
              border: Border.all(color: Ds.c.divider),
            ),
            child: Text(number, style: Ds.t.bodyStrong),
          ),
      ],
    );
  }
}

/// Opens the URL the BACKEND built. This widget never assembles a wa.me link
/// and never sees a phone number: if the backend decided the rider's number may
/// not be disclosed (the masking layer is on), it sent has:false and this
/// button does not exist.
class _WhatsAppButton extends StatelessWidget {
  const _WhatsAppButton({
    required this.label,
    required this.url,
    this.onOpenUrl,
  });

  final String label;
  final String url;
  final Future<void> Function(String url)? onOpenUrl;

  @override
  Widget build(BuildContext context) {
    if (label.isEmpty || url.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: Ds.touch.minTarget,
      child: OutlinedButton.icon(
        onPressed: () async {
          RenderLog.write('c1840_wa_tap', 1);
          final open = onOpenUrl;
          if (open != null) {
            await open(url);
            return;
          }
          try {
            await launchUrlString(url);
          } catch (_) {
            // A launcher that will not open is not a sentence this card is
            // allowed to write.
          }
        },
        icon: const Icon(Icons.chat_outlined, size: 18),
        label: Text(label, overflow: TextOverflow.ellipsis),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: Ds.c.divider),
          shape: RoundedRectangleBorder(borderRadius: Ds.r.rButton),
        ),
      ),
    );
  }
}
