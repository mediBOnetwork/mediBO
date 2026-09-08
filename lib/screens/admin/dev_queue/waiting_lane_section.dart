import 'package:flutter/material.dart';

import 'dev_queue_waiting.dart';

/// CHANGE #1819 — the Waiting lane, on the Cron health screen.
///
/// The fourth lane, beside the database lane, the deploy lane and the build
/// lane, and the one that says what waiting COST. The other three answer "what
/// is serialised?"; this one answers "what did a runner burn while it was
/// serialised?" — measured over 48 h at 2.03M tokens before a wait released
/// anything.
///
/// It owns no layout of its own: `dev_wait_report()` is a printer's payload and
/// [WaitingEconomyCard] is the printer. Two widgets drawing the same payload
/// two ways is how a panel about a single number starts showing two.
class WaitingLaneSection extends StatelessWidget {
  final Map<String, dynamic> data;
  const WaitingLaneSection({super.key, required this.data});

  @override
  Widget build(BuildContext context) => WaitingEconomyCard(payload: data);
}
