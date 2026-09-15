// lib/widgets/delivery_arrival_card.dart — CHANGE #703
//
// The doorbell, and the cold box. Two blocks every delivery surface shares, so
// "the rider is here" cannot be worded one way in the tracker and another on
// the shared link, and a cold-chain clock cannot read one number for the rider
// and another for the buyer.
//
// Before this change the geofence had exactly one ring at 150 m and it did one
// thing: stamp arrived_at. The buyer was told nothing until the rider was
// already knocking, and the handover QR only appeared at that same instant —
// so the phone came out of the pocket while somebody stood at the counter
// waiting. The backend now crosses two rings, tells the buyer at 500 m and
// opens the handover credentials there, and this file draws whichever of the
// three states (`enroute` / `approaching` / `here`) the payload names.
//
// NOTHING HERE COMPUTES. There is no minute arithmetic — `waiting_label` is a
// finished sentence and the fixture in the protected test deliberately
// disagrees with its own dwell_started_at, so a client-side clock fails. There
// is no "should the QR show" boolean: the backend opens the handover and this
// widget prints it. And there is no OTP fallback — `has_otp:false` is the
// backend refusing to hand the code to this particular caller (CHANGE #354),
// not a value that went missing.

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

// The card's own constants — the four numbers that are NOT a design choice a
// token could recolour, called out here rather than buried inline (QA round 2
// named them). A QR module grid has to be big enough for a counter phone to
// read across a counter, its quiet zone has to be white or no scanner sees it
// at all, and the handover code is read aloud digit by digit, so it is tracked
// wider than prose. Everything else on this card is Ds.
const double _kQrSize = 160;
const Color _kQrQuietZone = Colors.white;
const double _kOtpTracking = 6;
const double _kColdIconSize = 18;

String _s(Map<String, dynamic> m, String k) => (m[k] ?? '').toString();

Map<String, dynamic> _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : const <String, dynamic>{};

/// Maps the payload's own tone word onto the token palette. A tone this build
/// has never heard of falls back to the neutral one rather than throwing —
/// the backend must be able to add a tone without a deploy.
class _Tone {
  final Color bg;
  final Color fg;
  const _Tone(this.bg, this.fg);

  static _Tone of(String tone) {
    switch (tone) {
      case 'success':
        return _Tone(Ds.c.successSoft, Ds.c.success);
      case 'warning':
        return _Tone(Ds.c.warningSoft, Ds.c.warning);
      case 'danger':
        return _Tone(Ds.c.dangerSoft, Ds.c.danger);
      default:
        return _Tone(Ds.c.infoSoft, Ds.c.info);
    }
  }
}

/// "Rider is close" / "Rider is here", with the face, the name, the call
/// button the host supplies, and the handover credentials.
///
/// [call] is passed in rather than built here because the masked-call button
/// is a stateful widget that already lives on each host surface — this card
/// places it, it does not own it. Pass null and the row is simply absent.
class DeliveryArrivalCard extends StatelessWidget {
  final Map<String, dynamic> arrival;

  /// The host's rider-avatar widget, if it has one to give.
  final Widget? avatar;

  /// The host's masked-call button, if the backend offered one.
  final Widget? call;

  const DeliveryArrivalCard({
    super.key,
    required this.arrival,
    this.avatar,
    this.call,
  });

  @override
  Widget build(BuildContext context) {
    if (arrival['has'] != true) return const SizedBox.shrink();

    final state = _s(arrival, 'state');
    final heading = _s(arrival, 'heading');
    if (heading.isEmpty) return const SizedBox.shrink();

    RenderLog.write('c703_arrival_card', 1);
    RenderLog.write('c703_arrival_$state', 1);

    final tone = _Tone.of(_s(arrival, 'tone'));
    final body = _s(arrival, 'body');
    final chip = _s(arrival, 'chip');
    final waiting = _s(arrival, 'waiting_label');
    final handover = _m(arrival['handover']);

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x16),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
                  children: [
                    Text(heading,
                        style: Ds.t.subtitle.copyWith(color: tone.fg)),
                    if (body.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(body, style: Ds.t.body),
                    ],
                    if (waiting.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(waiting, style: Ds.t.caption),
                    ],
                  ],
                ),
              ),
              if (chip.isNotEmpty) _Chip(label: chip, tone: tone),
            ],
          ),
          if (call != null) ...[
            SizedBox(height: Ds.space.x12),
            call!,
          ],
          if (handover['has'] == true) ...[
            SizedBox(height: Ds.space.x16),
            _Handover(handover: handover),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final _Tone tone;

  const _Chip({required this.label, required this.tone});

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x8, vertical: Ds.space.x4),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
        ),
        child: Text(label, style: Ds.t.caption.copyWith(color: tone.fg)),
      );
}

/// The QR and the OTP. Either half may be absent and the other still renders:
/// the QR is missing when the stop has no token yet, and the OTP is missing
/// when the caller is the RIDER, who must never be handed the buyer's code.
class _Handover extends StatelessWidget {
  final Map<String, dynamic> handover;

  const _Handover({required this.handover});

  @override
  Widget build(BuildContext context) {
    // CHANGE #703 (QA round 1) — absence is the BACKEND's flag, both times.
    // The QR is a credential the same way the OTP is, so it now travels only
    // to the buyer, and the card asks has_qr rather than inferring anything
    // from an empty string.
    final hasQr = handover['has_qr'] == true;
    final token = _s(handover, 'qr_token');
    final hasOtp = handover['has_otp'] == true;
    final otp = _s(handover, 'otp');

    if (!hasQr && !hasOtp) return const SizedBox.shrink();
    RenderLog.write('c703_handover', 1);

    return Column(
      children: [
        if (hasQr && token.isNotEmpty) ...[
          Text(_s(handover, 'qr_label'),
              textAlign: TextAlign.center, style: Ds.t.caption),
          SizedBox(height: Ds.space.x8),
          Center(
            child: Container(
              padding: EdgeInsets.all(Ds.space.x8),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
              ),
              child: QrImageView(
                data: token,
                size: _kQrSize,
                backgroundColor: _kQrQuietZone,
              ),
            ),
          ),
        ],
        if (hasOtp && otp.isNotEmpty) ...[
          SizedBox(height: Ds.space.x16),
          Text(_s(handover, 'otp_label'), style: Ds.t.caption),
          SizedBox(height: Ds.space.x4),
          Text(otp,
              style: Ds.t.display.copyWith(letterSpacing: _kOtpTracking)),
          SizedBox(height: Ds.space.x4),
          Text(_s(handover, 'otp_hint'), style: Ds.t.caption),
        ],
      ],
    );
  }
}

/// The cold box, as a strip. Elapsed, allowed and remaining are all backend
/// sentences; `tone` is the backend's judgement of urgency, not a threshold
/// this widget re-derives from two integers it happens to also receive.
class ColdChainStrip extends StatelessWidget {
  final Map<String, dynamic> cold;

  const ColdChainStrip({super.key, required this.cold});

  @override
  Widget build(BuildContext context) {
    if (cold['has'] != true || cold['is_cold_chain'] != true) {
      return const SizedBox.shrink();
    }
    final heading = _s(cold, 'heading');
    final elapsed = _s(cold, 'elapsed_label');
    final window = _s(cold, 'window_label');
    final left = _s(cold, 'left_label');
    final breach = _s(cold, 'breach_label');
    if (heading.isEmpty && elapsed.isEmpty && breach.isEmpty) {
      return const SizedBox.shrink();
    }

    RenderLog.write('c703_cold_strip', 1);
    if (cold['breach'] == true) RenderLog.write('c703_cold_breach', 1);

    final tone = _Tone.of(_s(cold, 'tone'));

    return Container(
      margin: EdgeInsets.only(top: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: Ds.r.rCard,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.ac_unit, size: _kColdIconSize, color: tone.fg),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(breach.isNotEmpty ? breach : heading,
                    style: Ds.t.body.copyWith(color: tone.fg)),
                if (elapsed.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(elapsed, style: Ds.t.caption),
                ],
                if (window.isNotEmpty || left.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text([window, left].where((s) => s.isNotEmpty).join(' · '),
                      style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The rider's nudge: every anomaly the run currently has open, in the words
/// the backend chose for the rider (not the words ops reads on the console).
/// `has:false` — a clean run — renders nothing at all.
class RiderNudgeStrip extends StatelessWidget {
  final Map<String, dynamic> nudge;

  const RiderNudgeStrip({super.key, required this.nudge});

  @override
  Widget build(BuildContext context) {
    if (nudge['has'] != true) return const SizedBox.shrink();
    final items = (nudge['items'] as List?) ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();

    RenderLog.write('c703_rider_nudge', items.length);

    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x12),
      padding: EdgeInsets.all(Ds.space.x12),
      decoration: BoxDecoration(
        color: Ds.c.warningSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_s(nudge, 'heading'),
              style: Ds.t.subtitle.copyWith(color: Ds.c.warning)),
          for (final raw in items) ...[
            SizedBox(height: Ds.space.x8),
            Builder(builder: (_) {
              final it = _m(raw);
              final label = _s(it, 'label');
              final body = _s(it, 'body');
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (label.isNotEmpty)
                    Text(label, style: Ds.t.body),
                  if (body.isNotEmpty) Text(body, style: Ds.t.caption),
                ],
              );
            }),
          ],
        ],
      ),
    );
  }
}
