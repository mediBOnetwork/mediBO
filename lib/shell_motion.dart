// CMD #2187 — ONE THING ANIMATES AT A TIME.
//
// The header pill rolls its three lines every `hold_ms` and the search
// placeholder rotates its word every `placeholder_rotate_ms`, ten logical
// pixels apart. On two clocks they drift into each other and the header reads
// as broken, so Om's rule is: whichever is on screen OWNS the motion.
//
//   header row visible  → the pill rolls, the placeholder is FROZEN
//   header row hidden   → no pill, so the placeholder rotates
//   the search screen   → the band is fully collapsed, so the same applies
//
// The handover is deliberately a gap, not a swap: the pill stops the moment
// the row starts travelling and the placeholder does not start until the row
// is entirely gone, so nothing at all moves during the 200 ms slide.
//
// NOTHING HERE DECIDES THE POLICY. `shell_style().motion.one_at_a_time` and
// `shell_style().search.placeholder_rotate_when` do; this file is the wire
// between that payload and the two widgets that obey it, and flipping either
// key hands both their own clocks back with no deploy.
//
// It is a plain library rather than a `part` of the shell on purpose: the two
// widgets that read it (`widgets/order_hours_pill.dart` and
// `widgets/search_surface.dart`) live outside the shell's library and must be
// able to import the gate without importing the shell.

import 'package:flutter/foundation.dart';

/// How much of the header row is on screen: 1 = fully shown, 0 = entirely
/// gone. Written by the shell's collapsing band (the ONE scroll driver), so
/// there is no second scroll listener anywhere in this feature.
final ValueNotifier<double> shellHeaderShown = ValueNotifier<double>(1);

/// `shell_style().motion` merged with the search row's rotate keys, verbatim.
/// Empty until the payload lands — an app that has not heard from the backend
/// yet behaves exactly as `one_at_a_time` describes, which is the safe half.
final ValueNotifier<Map<String, dynamic>> shellMotionPolicy =
    ValueNotifier<Map<String, dynamic>>(const <String, dynamic>{});

/// Is there a pill on screen with something to roll? Set by the pill itself:
/// a single-line pill (and no pill at all) owns no motion, so the placeholder
/// keeps its own clock — Om's "pill has one line → placeholder rotates".
final ValueNotifier<bool> shellPillCanRoll = ValueNotifier<bool>(false);

/// The one thing to listen to; any of the three moves the verdicts below.
Listenable get shellMotion => Listenable.merge(
      <Listenable>[shellHeaderShown, shellMotionPolicy, shellPillCanRoll],
    );

/// The backend's switch. Absent (or anything but `false`) means the rule is on.
bool get _oneAtATime => shellMotionPolicy.value['one_at_a_time'] != false;

/// Publishes the motion half of `shell_style()`.
void shellMotionPublish(Map<String, dynamic> motion, Map<String, dynamic> search) {
  shellMotionPolicy.value = <String, dynamic>{
    ...motion,
    if (search['placeholder_rotate_when'] != null)
      'placeholder_rotate_when': search['placeholder_rotate_when'],
    if (search['placeholder_rotate_ms'] != null)
      'placeholder_rotate_ms': search['placeholder_rotate_ms'],
  };
}

/// May the pill roll right now? Only while the header row is FULLY on screen.
bool get pillMayRoll => !_oneAtATime || shellHeaderShown.value >= 1;

/// May the search placeholder rotate right now? Only once the header row is
/// FULLY gone — or when there is no rolling pill to collide with.
bool get placeholderMayRotate {
  if (!_oneAtATime) return true;
  if (shellMotionPolicy.value['placeholder_rotate_when'] != 'header_hidden') {
    return true;
  }
  if (!shellPillCanRoll.value) return true;
  return shellHeaderShown.value <= 0;
}
