import 'dart:async';
import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../services/ui_copy.dart';
import '../../../utils/toast.dart';
import 'claude_auth_banner.dart';
import 'dev_queue_branch.dart';
import 'dev_queue_common.dart';
import 'dev_queue_context.dart';
import 'dev_queue_health.dart';
import 'restart_safety.dart';
import 'dev_queue_service.dart';
import 'dev_queue_workers.dart';
import 'usage_meter.dart';
import 'vm_toggle_policy.dart';

/// CHANGE #1401 — the two payload moves the Runner card makes for the Claude
/// login, kept pure so they can be held down without a Supabase client.
///
/// Both are moves, not decisions: what red says, whether a re-login may be
/// offered and whether the banner draws at all are `claude_auth_status()`'s and
/// [ClaudeAuthBanner]'s. What can go wrong HERE is plumbing — reading the block
/// out of the wrong key, or letting a re-login reply (which carries the login
/// block ALONE) overwrite the snapshot that also holds the toggles, the
/// breaker, the pool and the queue counts.
class ClaudeAuthSnap {
  /// `dev_ctl_get().claude_auth`, verbatim — absent is an empty map, never a
  /// synthesised one.
  static Map<String, dynamic> read(Map<String, dynamic> snap) =>
      (snap['claude_auth'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// A `claude_auth_relogin_request()` reply, folded into the snapshot the card
  /// is already rendering. An empty reply changes nothing at all.
  static Map<String, dynamic> fold(
          Map<String, dynamic> snap, Map<String, dynamic> reply) =>
      reply.isEmpty ? snap : {...snap, 'claude_auth': reply};
}

/// The runner control strip at the top of the Dev Queue tab: three toggles
/// (VM / Claude / Workflow) with live status chips. Renders `dev_ctl_get`
/// verbatim; every flip is a `dev_ctl_set` (+ the vm-control edge fn for VM).
/// The backend/supervisor is the source of truth — this never infers state.
class DevQueueControl extends StatefulWidget {
  final DevQueueService service;
  const DevQueueControl({
    super.key,
    required this.service,
    this.startExpanded = false,
    this.embedded = false,
  });

  /// CHANGE #1197 — open the panel on arrival.
  ///
  /// Everything inside this card (the Context economy section included) lives
  /// behind a header tap, and a Flutter canvas cannot be tapped by any headless
  /// tool — so nothing in here could ever be photographed or write its
  /// render-log key. `/admin/dev-queue?panel=runner` sets this, which makes the
  /// panel provable and gives Om a link that lands straight on it.
  final bool startExpanded;

  /// CHANGE #1570 — draw the CONTENTS only, with no card chrome of its own.
  ///
  /// #1367 put the v3 strip ABOVE this card rather than replacing it, and the
  /// top of Dev Queue has shown two runner cards ever since — overlapping
  /// headers, two sets of toggles, one of them stale. Neither could simply be
  /// deleted: v3 knows whether a capability is actually RUNNING, and this card
  /// owns the breaker, the usage meter, health, the worker grid and context
  /// economy. So this one moves INSIDE v3 as its footer. Embedded means: no
  /// Container, no margin, no shadow, and no VM/Claude/Workflow rows — v3
  /// already draws those three, with `actual` beside `desired`.
  final bool embedded;

  @override
  State<DevQueueControl> createState() => _DevQueueControlState();
}

class _DevQueueControlState extends State<DevQueueControl> {
  Timer? _poll;
  Map<String, dynamic> _snap = const {};
  Map<String, dynamic> _usage = const {};
  final Set<String> _busy = {}; // keys mid-flip
  late bool _expanded = widget.startExpanded; // collapsed unless asked to open
  // Anchors so a lock/confirm popup can float right next to the tapped toggle.
  final Map<String, GlobalKey> _anchors = {
    'vm': GlobalKey(),
    'claude': GlobalKey(),
    'workflow': GlobalKey(),
  };
  OverlayEntry? _mini; // the single live mini popup
  bool _vmChecking = false; // a live EC2 read is already in flight
  bool _reloginBusy = false; // a claude re-login request is already in flight

  @override
  void initState() {
    super.initState();
    _tick();
    // Opening via the header pulls a fresh usage reading; arriving already
    // open has to do the same or the panel paints with an empty usage block.
    if (_expanded) _refreshUsage();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _tick());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _mini?.remove();
    _mini = null;
    super.dispose();
  }

  Map<String, dynamic> get _controls =>
      (_snap['controls'] as Map?)?.cast<String, dynamic>() ?? const {};

  bool _locked(String key) =>
      ((_controls[key] as Map?)?['locked'] ?? false) == true;

  String _lockMsg(String key) =>
      ((_controls[key] as Map?)?['lock_msg'] ?? '').toString();

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.service.ctlGet(),
        widget.service.sessionUsage(),
      ]);
      if (mounted) {
        setState(() {
          _snap = results[0];
          _usage = results[1];
        });
      }
    } catch (_) {}
  }

  /// The 10s refresh, plus the backend's freshness verdict on the VM chip.
  /// Kept apart from [_load] so the poll chase can re-read without recursing
  /// back into another live check.
  Future<void> _tick() async {
    await _load();
    await _liveCheckIfStale();
  }

  /// Opening the panel signals the VM to fetch a live reading, then re-reads a
  /// few times over the next several seconds to catch it — no manual button.
  /// The VM guards the rate limit, so a rapid re-open just re-serves fresh data.
  void _refreshUsage() {
    widget.service.requestUsageRefresh();
    _load();
    for (final s in const [2, 5, 9]) {
      Timer(Duration(seconds: s), () {
        if (mounted && _expanded) _load();
      });
    }
  }

  Map<String, dynamic> get _desired =>
      (_snap['desired_state'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _status =>
      (_snap['runner_status'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _vm =>
      (_snap['vm'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// CHANGE #1366 — the fleet's two silent states, both printed verbatim.
  /// `blocked` is runner_blocked_badge(): present only while a runner's boot
  /// doctor is red, which is the state that ran for 21 hours on 4-5 Sep with
  /// nothing on this strip to say so. `disk` is runner_disk_state().
  Map<String, dynamic> get _blocked =>
      (_snap['blocked'] as Map?)?.cast<String, dynamic>() ?? const {};
  Map<String, dynamic> get _disk =>
      (_snap['disk'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// CHANGE #755 — the self-healing breaker's card, delivered on the same
  /// dev_ctl_get poll as the toggles so it can never be a beat behind them.
  Map<String, dynamic> get _health =>
      (_snap['health'] as Map?)?.cast<String, dynamic>() ?? const {};

  /// CHANGE #1401 — the Claude login, delivered on the poll this card already
  /// makes. `dev_ctl_get().claude_auth` is `claude_auth_status()` verbatim, so
  /// nothing here decides whether the login is healthy, what red says, or
  /// whether a re-login may be offered at all.
  Map<String, dynamic> get _claudeAuth => ClaudeAuthSnap.read(_snap);

  /// The one tap, on the card where every other fleet-stopping state is
  /// already reported. It is the same RPC the Cron health panel calls: the
  /// backend starts the login on the VM, answers with the whole claude_auth
  /// block, and publishes the link and the code onto it as the VM scrapes them
  /// off its own login pane. So this asks, folds the reply into the snapshot
  /// the card is already rendering, and re-reads — it never guesses at the
  /// states between "requested" and the link appearing.
  Future<void> _relogin() async {
    if (_reloginBusy) return;
    setState(() => _reloginBusy = true);
    try {
      final r = await widget.service.claudeAuthRelogin();
      if (!mounted) return;
      // Folded, never assigned: the reply carries the login block alone, and
      // the toggles, the breaker and the pool on this same snapshot must
      // survive it untouched.
      setState(() => _snap = ClaudeAuthSnap.fold(_snap, r));
    } catch (_) {
      // Same contract as every badge on this strip: the line degrades, the
      // card does not.
    } finally {
      if (mounted) setState(() => _reloginBusy = false);
    }
    for (final s in const [5, 15, 30]) {
      Timer(Duration(seconds: s), () {
        if (mounted) _load();
      });
    }
  }

  bool _isOn(String k) => (_desired[k] ?? 'off') == 'on';

  bool get _claudeAlive {
    final at = DateTime.tryParse((_status['alive_at'] ?? '').toString());
    final now = DateTime.tryParse((_snap['server_now'] ?? '').toString());
    if (at == null || now == null) return false;
    return now.difference(at).inSeconds < 180;
  }

  int? get _buildingId {
    final v = _status['current_command_id'];
    return v is num ? v.toInt() : null;
  }

  // CHANGE #233A — the live-view badge is now honest in BOTH directions. The
  // backend measures whether the bridge is genuinely reachable (unit active +
  // tmux session alive + fresh beacon) and hands down the label and the tone;
  // Dart no longer decides that "off" simply means "show nothing".
  RemoteBadge get _remote => RemoteBadge(_status);

  // CHANGE #237 — a SECOND, separate badge: the Claude Code app's device list.
  // _remote above is mediBO's own live-view bridge; this one counts worker
  // companions that reached Anthropic's session bridge. They read the same
  // payload but never the same keys — conflating them is exactly how "On phone"
  // stayed green while Om's app showed no devices at all.
  PhoneBadge get _phone => PhoneBadge(_status);

  /// A toggle tap. Locked toggles (per the backend ordering vm→claude→workflow)
  /// don't flip — they float a mini reason popup next to the switch and keep
  /// their colour. VM-off while building asks to confirm in that same mini
  /// popup, never a centre dialog.
  void _onToggle(String key, bool on) {
    if (_locked(key)) {
      _showMini(key, message: _lockMsg(key));
      return;
    }
    if (key == 'vm' && !on && _buildingId != null) {
      _showMini(key,
          message: c('dev_queue.ctl_confirm_vm_off'),
          confirmLabel: c('dev_queue.btn_submit'),
          onConfirm: () => _doFlip(key, on));
      return;
    }
    _doFlip(key, on);
  }

  Future<void> _doFlip(String key, bool on) async {
    final val = on ? 'on' : 'off';
    setState(() => _busy.add(key));
    try {
      final res = await widget.service.ctlSet(key, val);
      // Whether the cloud is touched at all, and with which action, is the
      // backend's verdict — see VmTogglePolicy. There is deliberately no
      // "already in that state, skip it" check here: vm-control answers that
      // from a live DescribeInstances read, so a stale cache cannot eat a flip.
      final plan = VmTogglePolicy.plan(res);
      if (plan.invoke) {
        // The edge function words its own outcome (start sent / stopping /
        // already running / the exact IAM action AWS refused) — print it
        // verbatim. Only a failure with no wording at all falls back to
        // backend copy.
        try {
          final reply = await widget.service.vmControl(plan.action);
          final out = VmTogglePolicy.outcome(reply);
          if (mounted && !out.isSilent) {
            showToast(
                context,
                out.needsFallbackCopy
                    ? c('dev_queue.ctl_edge_failed')
                    : out.message,
                isError: out.isError);
          }
          // pending / stopping: keep reading EC2 until it rests.
          _chaseVmState(reply);
        } catch (_) {
          if (mounted) showToast(context, c('dev_queue.ctl_edge_failed'), isError: true);
        }
      }
      await _load();
    } catch (e) {
      // Backend also enforces the ordering — surface a refusal as a mini popup.
      final msg = e.toString();
      if (mounted && msg.contains('LOCKED')) {
        _showMini(key, message: _lockMsg(key));
      } else if (mounted) {
        showToast(context, msg, isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  /// Follow a toggle down to a RESTING EC2 state.
  ///
  /// `StartInstances` returns `pending`, not `running`; `StopInstances` returns
  /// `stopping`. Painting either and walking away is the guessed label the chip
  /// used to show. So while the backend says the reply is not `settled`, ask
  /// vm-control for `status` again on the interval IT named, up to the cap IT
  /// named, refreshing the panel each time. Every number here is payload.
  Future<void> _chaseVmState(Map<String, dynamic> reply) async {
    var plan = VmTogglePolicy.poll(reply);
    for (var i = 0; plan.again && i < plan.maxPolls; i++) {
      await Future<void>.delayed(plan.delay);
      if (!mounted) return;
      try {
        final next = await widget.service.vmControl('status');
        plan = VmTogglePolicy.poll(next);
      } catch (_) {
        return; // transport trouble: stop chasing, the 10s _load still runs
      }
      await _load();
    }
  }

  /// One live EC2 read when the BACKEND says the cached chip reading is too old
  /// to trust (`vm.needs_live_check`). Without this the chip is only as fresh as
  /// the last writer — and while the box is off, its own status timer is the
  /// writer that has stopped. The threshold lives in the `vm_poll` config row,
  /// and the edge function stamps `last_checked`, so this self-limits to about
  /// one call per staleness window rather than one per 10-second refresh.
  Future<void> _liveCheckIfStale() async {
    if (!VmTogglePolicy.needsLiveCheck(_vm)) return;
    if (_vmChecking) return;
    _vmChecking = true;
    try {
      await widget.service.vmControl('status');
      if (mounted) await _load();
    } catch (_) {
      // A refusal (no key / IAM) already surfaces on a real flip; a background
      // freshness read must never toast.
    } finally {
      _vmChecking = false;
    }
  }

  /// A small floating card anchored just above the tapped toggle. Info popups
  /// auto-dismiss; confirm popups carry a Cancel / action pair.
  void _showMini(String key,
      {required String message, String? confirmLabel, VoidCallback? onConfirm}) {
    _mini?.remove();
    _mini = null;
    final ctx = _anchors[key]?.currentContext;
    final overlay = Overlay.of(context);
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset.zero);
    final screen = MediaQuery.of(context).size;
    // right-align the card to the switch; place it above, or below if near top.
    const w = 210.0;
    final right = (screen.width - (topLeft.dx + box.size.width)).clamp(8.0, screen.width - w - 8);
    final above = topLeft.dy > 130;
    final top = above ? topLeft.dy - 8 : topLeft.dy + box.size.height + 8;

    void close() {
      _mini?.remove();
      _mini = null;
    }

    final entry = OverlayEntry(builder: (_) {
      return Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: close,
          ),
        ),
        Positioned(
          right: right,
          top: above ? null : top,
          bottom: above ? (screen.height - topLeft.dy + 8) : null,
          width: w,
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kTextHi,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withValues(alpha: 0.22),
                      blurRadius: 14,
                      offset: const Offset(0, 4)),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(confirmLabel == null ? Icons.lock_outline : Icons.help_outline,
                        size: 15, color: Colors.white),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(message,
                          style: const TextStyle(
                              fontSize: 12.5,
                              height: 1.3,
                              fontWeight: FontWeight.w600,
                              color: Colors.white)),
                    ),
                  ]),
                  if (confirmLabel != null) ...[
                    const SizedBox(height: 10),
                    Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      TextButton(
                        onPressed: close,
                        style: TextButton.styleFrom(
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 10)),
                        child: Text(c('dev_queue.btn_cancel'),
                            style: const TextStyle(
                                fontSize: 12.5, color: Colors.white70)),
                      ),
                      const SizedBox(width: 4),
                      FilledButton(
                        onPressed: () {
                          close();
                          onConfirm?.call();
                        },
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF991B1B),
                            minimumSize: const Size(0, 32),
                            padding: const EdgeInsets.symmetric(horizontal: 14)),
                        child: Text(confirmLabel,
                            style: const TextStyle(fontSize: 12.5)),
                      ),
                    ]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ]);
    });
    _mini = entry;
    overlay.insert(entry);
    if (confirmLabel == null) {
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (_mini == entry) close();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _blockedBanner(),
        InkWell(
          onTap: () {
            setState(() => _expanded = !_expanded);
            if (_expanded) _refreshUsage(); // pull a FRESH reading on open
          },
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: _expanded ? _expandedHeader() : _collapsedHeader(),
          ),
        ),
        // CHANGE #641 — the circuit breaker, always visible. It is rendered
        // OUTSIDE the expand gate on purpose: the one state Om must never have
        // to open a panel to discover is "the fleet paused itself".
        _breakerBadge(),
        // CHANGE #1401 — outside the expand gate for the same reason the
        // breaker above it is: on 5 Sep the VM's Claude login expired and
        // every runner claimed, registered a NULL pid, spent nothing and
        // handed its row back — 28 claims in 40 minutes with no surface able
        // to say why. "No worker can start a session at all" is not a state
        // Om should have to open a panel to discover. A healthy login draws
        // NOTHING, so this adds no clutter while it is green.
        ClaudeAuthBanner(
            auth: _claudeAuth, busy: _reloginBusy, onRelogin: _relogin),
        // CHANGE #1365 — outside the expand gate, like the breaker above:
        // a usage sync that has stopped working is exactly the state Om
        // must not have to open a panel to discover, because the card
        // otherwise keeps printing a comfortable "synced Nh ago" over a
        // figure the supervisor is still obeying.
        _syncFailureBadge(),
        if (_expanded) ...[
          const SizedBox(height: 4),
          // The three toggles are v3's when embedded — two sets of switches for
          // the same three keys is how a card starts disagreeing with itself.
          if (!widget.embedded) ...[
            _row('vm', c('dev_queue.ctl_vm'), Icons.dns_outlined, _vmChip()),
            _divider(),
            _row('claude', c('dev_queue.ctl_claude'), Icons.terminal, _claudeChip()),
            _divider(),
            _row('workflow', c('dev_queue.ctl_workflow'), Icons.sync, _workflowChip()),
            _divider(),
          ],
          WorkerGridCard(
            pool: (_snap['pool'] as Map?)?.cast<String, dynamic>() ?? const {},
            disk: _disk,
            service: widget.service,
            onChanged: _load,
          ),
          // CHANGE #1470 — the build branch rides the payload this card already
          // fetches. has:false draws nothing at all.
          if (((_snap['build_branch'] as Map?)?['has'] ?? false) == true) ...[
            _divider(),
            BuildBranchCard(
              branch: (_snap['build_branch'] as Map?)?.cast<String, dynamic>() ??
                  const {},
            ),
          ],
          if (_health.isNotEmpty) ...[
            _divider(),
            RunnerHealthCard(health: _health),
          ],
          if ((_usage['has_usage'] ?? false) == true) ...[
            _divider(),
            UsageMeter(usage: _usage, onRates: _openRates),
          ],
          if ((_context['has'] ?? false) == true) ...[
            _divider(),
            ContextEconomyCard(payload: _context),
          ],
        ],
      ]);
    if (widget.embedded) return body;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      // The whole card is a tap-to-expand panel: collapsed by default (a slim
      // summary bar so it never blocks the list), tapped open to reveal the
      // toggles + real usage. No chevron — the header itself is the control.
      child: body,
    );
  }

  /// The DB circuit breaker (CHANGE #641). Every string, the tone and the
  /// decision to show it at all come from `dev_ctl_get().breaker` — nothing
  /// here is computed, pluralised or worded in Dart. It clears itself when
  /// Workflow goes back on, because that is what the backend does to the flag.
  /// The widget itself lives in dev_queue_common.dart so the protected suite
  /// can render it against a real payload.
  /// CHANGE #1365 — "the usage sync is broken" as its own always-visible line.
  ///
  /// `fetch_failing`, the sentence and the tone are all
  /// `dev_cmd_session_usage()`'s: nothing here decides that a fetch has failed,
  /// and nothing here writes the words. When sync is healthy this draws
  /// absolutely nothing.
  Widget _syncFailureBadge() {
    if ((_usage['fetch_failing'] ?? false) != true) return const SizedBox.shrink();
    final txt = '${_usage['updated_display'] ?? ''}';
    if (txt.isEmpty) return const SizedBox.shrink();
    final tone = statusTone((_usage['updated_tone'] ?? 'failed').toString());
    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x8),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x12, vertical: Ds.space.x8),
        decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rChip),
        child: Row(children: [
          Icon(Icons.sync_problem, size: Ds.t.bodySize, color: tone.fg),
          SizedBox(width: Ds.space.x8),
          Expanded(
            child: Text(txt,
                style: Ds.t.caption
                    .copyWith(color: tone.fg, fontWeight: FontWeight.w600)),
          ),
        ]),
      ),
    );
  }

  Widget _breakerBadge() => BreakerBanner(
      breaker: (_snap['breaker'] as Map?)?.cast<String, dynamic>() ?? const {});

  /// CHANGE #1197 — `dev_ctl_get().context` is `dev_context_metrics()`
  /// verbatim; ContextEconomyCard prints it and computes nothing.
  Map<String, dynamic> get _context =>
      (_snap['context'] as Map?)?.cast<String, dynamic>() ?? const {};

  Widget _blockedBanner() => RunnersBlockedBanner(blocked: _blocked);

  Widget _expandedHeader() => Row(children: [
        Text(c('dev_queue.ctl_section'),
            style: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: kTextLo)),
        const Spacer(),
        if (_remote.show)
          ToneChip(
              label: _remote.display,
              tone: toneByName(_remote.tone),
              icon: _remote.isOn
                  ? Icons.phone_iphone
                  : Icons.mobile_off_outlined),
        if (_phone.show) ...[
          SizedBox(width: Ds.space.x8),
          // Tap target is the whole chip row in the sheet-opening wrapper; the
          // chip itself is short, so pad it out to the token touch minimum.
          InkWell(
            onTap: _openPhoneSessions,
            borderRadius: BorderRadius.circular(Ds.r.chip),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
              child: Center(
                child: ToneChip(
                    label: _phone.display,
                    tone: toneByName(_phone.tone),
                    icon: _phone.isOn
                        ? Icons.smartphone
                        : Icons.mobile_off_outlined),
              ),
            ),
          ),
        ],
      ]);

  /// The device list, verbatim: every string (label, hint, session names) is
  /// composed on the VM or in ui_copy. Dart adds no wording and no count.
  void _openPhoneSessions() {
    final badge = _phone;
    showModalBottomSheet(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(Ds.r.sheet))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(badge.display, style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x4),
              Text(badge.hint, style: Ds.t.caption),
              SizedBox(height: Ds.space.x16),
              for (final n in badge.names)
                Padding(
                  padding: EdgeInsets.only(bottom: Ds.space.x8),
                  child: Row(children: [
                    Icon(Icons.smartphone,
                        size: Ds.t.bodySize, color: Ds.c.textSecondary),
                    SizedBox(width: Ds.space.x8),
                    Expanded(child: Text(n, style: Ds.t.body)),
                  ]),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Slim one-line summary shown when collapsed: workflow state + the top usage
  /// percent, so Om reads the essentials without opening the panel.
  Widget _collapsedHeader() {
    final wf = _isOn('workflow');
    final limits = (_usage['limits'] as List?) ?? const [];
    Map<String, dynamic>? first =
        limits.isNotEmpty ? Map<String, dynamic>.from(limits.first as Map) : null;
    return Row(children: [
      Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
            color: wf && _claudeAlive
                ? const Color(0xFF1B7A43)
                : kTextLo.withValues(alpha: 0.5),
            shape: BoxShape.circle),
      ),
      const SizedBox(width: 8),
      Text(c('dev_queue.ctl_section'),
          style: const TextStyle(
              fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
            _workflowSummary(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, color: kTextLo)),
      ),
      RunnerHealthChip(health: _health),
      if (first != null) ...[
        const SizedBox(width: 6),
        ToneChip(
            label: '${first['pct_display']}',
            tone: statusTone((first['tone'] ?? 'completed').toString())),
      ],
    ]);
  }

  String _workflowSummary() {
    final wf = _isOn('workflow');
    final id = _buildingId;
    if (id != null) return '${c('dev_queue.status_building')} #$id';
    return wf ? c('dev_queue.status_pending') : c('dev_queue.ctl_workflow');
  }

  /// Read-only "API-equivalent rates" sheet — the official per-model ₹/Mtok
  /// table, fed entirely by dev_rates_get(). ₹ = USD × usd_inr, exactly as the
  /// RPC's own note prescribes; no price is written in Dart.
  Future<void> _openRates() async {
    Map<String, dynamic> rates = const {};
    try {
      rates = await widget.service.ratesGet();
    } catch (_) {/* sheet shows empty then */}
    if (!mounted) return;
    final models = (rates['models'] as Map?)?.cast<String, dynamic>() ?? const {};
    final usdInr = rates['usd_inr'];
    final note = (rates['note'] ?? '').toString();
    num inr(dynamic usd) =>
        (usd is num && usdInr is num) ? (usd * usdInr).round() : 0;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (_, ctl) => ListView(
          controller: ctl,
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          children: [
            Text(c('dev_queue.rates_title'),
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700, color: kTextHi)),
            const SizedBox(height: 4),
            if (usdInr != null)
              Text(cf('dev_queue.rates_usd_inr', {'rate': '$usdInr'}),
                  style: const TextStyle(fontSize: 12, color: kTextLo)),
            const SizedBox(height: 12),
            for (final e in models.entries)
              _rateRow(e.key, (e.value as Map?)?.cast<String, dynamic>() ?? const {}, inr),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(note, style: const TextStyle(fontSize: 11, color: kTextLo)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rateRow(String model, Map<String, dynamic> r, num Function(dynamic) inr) {
    final hasFast = r['fast_in'] != null || r['fast_out'] != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(model.replaceFirst('claude-', ''),
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: kTextHi)),
        const SizedBox(height: 2),
        Text('${c('dev_queue.rates_in')}: ₹${inr(r['in'])}   ${c('dev_queue.rates_out')}: ₹${inr(r['out'])}',
            style: const TextStyle(fontSize: 12, color: kTextLo)),
        if (hasFast)
          Text('${c('dev_queue.rates_fast_in')}: ₹${inr(r['fast_in'])}   ${c('dev_queue.rates_fast_out')}: ₹${inr(r['fast_out'])}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF92400E))),
      ]),
    );
  }

  Widget _divider() =>
      const Divider(height: 12, thickness: 1, color: Color(0xFFF1F2F4));

  Widget _row(String key, String label, IconData icon, Widget chip) {
    final on = _isOn(key);
    final busy = _busy.contains(key);
    return Row(children: [
      Icon(icon, size: 18, color: kTextLo),
      const SizedBox(width: 8),
      SizedBox(
          width: 74,
          child: Text(label,
              style: const TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: kTextHi))),
      const SizedBox(width: 4),
      Expanded(child: Align(alignment: Alignment.centerLeft, child: chip)),
      if (busy)
        const Padding(
          padding: EdgeInsets.only(right: 8),
          child: SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      // The switch keeps its colour even when locked — a locked tap floats a
      // reason popup instead of flipping (handled in _onToggle), so we never
      // grey it out. onChanged stays live unless a real flip is in flight.
      KeyedSubtree(
        key: _anchors[key],
        child: Switch(
          value: on,
          activeTrackColor: kBrand,
          onChanged: busy ? null : (v) => _onToggle(key, v),
        ),
      ),
    ]);
  }

  /// The chip is the live EC2 state, and tapping it is the diagnostic: it asks
  /// vm-control to DryRun each EC2 call against the saved key and toasts the
  /// backend's verdict — "all 3 permissions present" or the exact IAM actions
  /// missing. That is the answer to "why won't it start?" without power-cycling
  /// anything, and it is reachable in one tap from the Dev Queue.
  Widget _vmChip() {
    final s = (_vm['status'] ?? 'unknown').toString();
    const map = {
      'running': ['dev_queue.ctl_vm_running', 'completed'],
      'stopped': ['dev_queue.ctl_vm_stopped', 'paused'],
      'starting': ['dev_queue.ctl_vm_starting', 'awaiting_approval'],
      'stopping': ['dev_queue.ctl_vm_stopping', 'awaiting_approval'],
    };
    final e = map[s] ?? const ['dev_queue.ctl_vm_unknown', 'paused'];
    return Semantics(
      button: true,
      label: c('dev_queue.ctl_vm_check'),
      child: InkWell(
        onTap: _vmPreflight,
        borderRadius: Ds.r.rChip,
        // A chip is short; pad the hit box out to the token min target.
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          child: Center(child: ToneChip(label: c(e[0]), tone: statusTone(e[1]))),
        ),
      ),
    );
  }

  /// Tap the VM chip → refresh the live state, then report the key's EC2
  /// permissions. Both sentences are the backend's.
  Future<void> _vmPreflight() async {
    if (_vmChecking) return;
    _vmChecking = true;
    try {
      await widget.service.vmControl('status');
      if (mounted) await _load();
      final out =
          VmTogglePolicy.outcome(await widget.service.vmControl('preflight'));
      if (mounted && !out.isSilent) {
        showToast(
            context,
            out.needsFallbackCopy ? c('dev_queue.ctl_edge_failed') : out.message,
            isError: out.isError);
      }
    } catch (_) {
      if (mounted) {
        showToast(context, c('dev_queue.ctl_edge_failed'), isError: true);
      }
    } finally {
      _vmChecking = false;
    }
  }

  Widget _claudeChip() {
    if (_isOn('claude') && !_claudeAlive) {
      return ToneChip(label: c('dev_queue.ctl_applying'), tone: statusTone('awaiting_approval'));
    }
    return _claudeAlive
        ? ToneChip(label: c('dev_queue.ctl_claude_alive'), tone: statusTone('completed'))
        : ToneChip(label: c('dev_queue.ctl_claude_offline'), tone: statusTone('paused'));
  }

  Widget _workflowChip() {
    if (!_isOn('workflow')) {
      return ToneChip(label: c('dev_queue.ctl_wf_off'), tone: statusTone('paused'));
    }
    final bid = _buildingId;
    if (bid != null) {
      return ToneChip(
          label: cf('dev_queue.ctl_wf_building', {'id': '$bid'}),
          tone: statusTone('building'),
          spinning: true);
    }
    final st = (_status['state'] ?? '').toString();
    if (st == 'workflow_running') {
      return ToneChip(label: c('dev_queue.ctl_wf_running'), tone: statusTone('completed'));
    }
    return ToneChip(label: c('dev_queue.ctl_applying'), tone: statusTone('awaiting_approval'));
  }
}

/// CHANGE #1366 — the "Runners blocked" banner, on its own so it can be tested
/// without a Supabase client behind it.
///
/// It is a PRINTER. `runner_blocked_badge()` decides whether the fleet is
/// blocked, which runner and check blocked it, and how long it has been that
/// way; this draws the three strings it is given and resolves one tone name.
/// Absence is `has:false` — then it draws nothing at all, which is why it is
/// safe to keep it above the collapsed header where it is always visible.
class RunnersBlockedBanner extends StatelessWidget {
  final Map<String, dynamic> blocked;
  const RunnersBlockedBanner({super.key, required this.blocked});

  @override
  Widget build(BuildContext context) {
    if ((blocked['has'] ?? false) != true) return const SizedBox.shrink();
    final tone = toneByName((blocked['tone'] ?? 'danger').toString());
    final detail = (blocked['detail'] ?? '').toString();
    final since = (blocked['since_label'] ?? '').toString();
    return Container(
      margin: EdgeInsets.only(bottom: Ds.space.x8),
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x12, vertical: Ds.space.x8),
      decoration: BoxDecoration(color: tone.bg, borderRadius: Ds.r.rButton),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.report_gmailerrorred, size: Ds.space.x16, color: tone.fg),
        SizedBox(width: Ds.space.x8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((blocked['label'] ?? '').toString(),
                style: Ds.t.caption
                    .copyWith(fontWeight: FontWeight.w700, color: tone.fg)),
            if (detail.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(detail, style: Ds.t.caption.copyWith(color: tone.fg)),
            ],
            if (since.isNotEmpty) ...[
              SizedBox(height: Ds.space.x4),
              Text(since, style: Ds.t.caption.copyWith(color: tone.fg)),
            ],
          ]),
        ),
      ]),
    );
  }
}
