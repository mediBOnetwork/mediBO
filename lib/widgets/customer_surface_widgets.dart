import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../design_tokens.dart';
import '../screens/admin/nav_registry_view.dart' show navIcon;
import '../screens/customer/profile_account_menu.dart' show customerMenuScreen;
import '../services/customer_surfaces.dart';
import '../services/ui_copy.dart';
import '../user_state.dart';
import 'animations.dart' show Shimmer, SkeletonBox;
import 'notification_bell.dart' show NotifUnread;
import '../utils/render_log.dart';

/// CHANGE #745 — the three customer surfaces the profile menu emptied into.
///
/// Om decided WHERE each feature belongs; `customer_feature_placement` records
/// it, so these widgets ask "what did the backend place here?" and draw the
/// answer. None of them names a feature: delete the wishlist's `home_chip` row
/// tomorrow and the chip is gone with no deploy, exactly as adding a third
/// entry to the app bar is one INSERT.

/// Every widget below shares this: fetch once, repaint on the answer, draw
/// nothing at all when the backend placed nothing here.
abstract class _SurfaceState<T extends StatefulWidget> extends State<T> {
  @override
  void initState() {
    super.initState();
    CustomerSurfaces.ensureLoaded();
  }
}

/// The catalogue app bar's actions — today one heart, whatever the registry
/// says tomorrow. The count on it is the backend's own `count_label`; an empty
/// wishlist carries no badge because the payload sends no label, not because
/// Dart compared a number to zero.
class CustomerAppBarActions extends StatefulWidget {
  const CustomerAppBarActions({super.key});

  @override
  State<CustomerAppBarActions> createState() => _CustomerAppBarActionsState();
}

class _CustomerAppBarActionsState extends _SurfaceState<CustomerAppBarActions> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        final items = CustomerSurfaces.itemsFor(payload, 'catalogue_appbar');
        if (items.isEmpty) return const SizedBox.shrink();
        RenderLog.write('c745_appbar_actions', items.length);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [for (final e in items) _AppBarAction(entry: e)],
        );
      },
    );
  }
}

class _AppBarAction extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _AppBarAction({required this.entry});

  @override
  Widget build(BuildContext context) {
    // The trailing text is the ENTRY's own `badge`. Round 1 QA: this used to be
    // `feature_key == 'cust.wishlist' ? …` — a Dart feature list, which is the
    // exact thing this change deletes. Move the wishlist to another placement
    // now and it takes its own number with it.
    final badge = (entry['badge'] ?? '').toString();
    final route = (entry['route_key'] ?? '').toString();
    final screen = customerMenuScreen(route);
    if (screen == null) return const SizedBox.shrink();
    final label = (entry['label'] ?? '').toString();
    return Tooltip(
      message: label,
      child: SizedBox(
        width: Ds.touch.minTarget,
        height: Ds.touch.minTarget,
        child: IconButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => screen)),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(navIcon((entry['icon_key'] ?? '').toString()),
                  size: 22, color: Ds.c.brand),
              if (badge.isNotEmpty)
                Positioned(
                  right: -6,
                  top: -4,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                        horizontal: Ds.space.x4, vertical: 0),
                    constraints: const BoxConstraints(minWidth: 16),
                    decoration: BoxDecoration(
                      color: Ds.c.brand,
                      borderRadius: Ds.r.rChip,
                    ),
                    child: Text(
                      badge,
                      textAlign: TextAlign.center,
                      style: Ds.t.caption.copyWith(
                          color: Ds.c.surface, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The strip above the home feed: the wishlist chip and the rewards badge, in
/// the backend's order. Both are placements, so either can leave without a
/// deploy — and the strip disappears entirely when neither is placed.
class CustomerHomeStrip extends StatefulWidget {
  const CustomerHomeStrip({super.key});

  @override
  State<CustomerHomeStrip> createState() => _CustomerHomeStripState();
}

class _CustomerHomeStripState extends _SurfaceState<CustomerHomeStrip> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        // ONE ordered list, not two concatenated in Dart: round 1 QA pointed
        // out that a chip row built from `home_chip` + `home_badge` let
        // sort_order order only WITHIN a placement, so putting the badge first
        // was impossible without a deploy. `home_strip` is the backend's own
        // merge of both, already ordered.
        final chips = CustomerSurfaces.itemsFor(payload, 'home_strip');
        if (chips.isEmpty) return const SizedBox.shrink();
        RenderLog.write('c745_home_strip', chips.length);
        return Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
          child: Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final e in chips) _HomeChip(entry: e),
            ],
          ),
        );
      },
    );
  }
}

class _HomeChip extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _HomeChip({required this.entry});

  @override
  Widget build(BuildContext context) {
    final trailing = (entry['badge'] ?? '').toString();
    final screen = customerMenuScreen((entry['route_key'] ?? '').toString());
    if (screen == null) return const SizedBox.shrink();
    return InkWell(
      borderRadius: Ds.r.rChip,
      onTap: () => Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => screen)),
      child: Container(
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x8),
        decoration: BoxDecoration(
          color: Ds.c.surface,
          borderRadius: Ds.r.rChip,
          border: Border.all(color: Ds.c.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(navIcon((entry['icon_key'] ?? '').toString()),
                size: 18, color: Ds.c.brand),
            SizedBox(width: Ds.space.x8),
            Text((entry['label'] ?? '').toString(),
                style: Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
            if (trailing.isNotEmpty) ...[
              SizedBox(width: Ds.space.x8),
              Text(trailing,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            ],
          ],
        ),
      ),
    );
  }
}

/// The Rewards section on the Orders tab — points, slab and the referral code,
/// every one of them a string `loyalty_my_rewards()` already composed. When no
/// programme is running the backend says so (`has:false`) and the section
/// renders its own off-note instead of an empty card.
class CustomerRewardsSection extends StatefulWidget {
  const CustomerRewardsSection({super.key});

  @override
  State<CustomerRewardsSection> createState() => _CustomerRewardsSectionState();
}

class _CustomerRewardsSectionState
    extends _SurfaceState<CustomerRewardsSection> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        final items = CustomerSurfaces.itemsFor(payload, 'orders_section');
        if (items.isEmpty) return const SizedBox.shrink();
        final entry = items.first;
        final screen =
            customerMenuScreen((entry['route_key'] ?? '').toString());
        // The card's body is the ENTRY's own `lines`, already composed and
        // already ordered. Round 1 QA: Dart used to pick three fields out of
        // the rewards block and join two of them with a space — a display
        // string written in Dart, and a feature-key switch besides. When no
        // programme is running the backend sends its own off-note as the only
        // line, so the card never has to know what "off" means.
        final lines = ((entry['lines'] as List?) ?? const [])
            .map((e) => (e ?? '').toString())
            .where((s) => s.isNotEmpty)
            .toList(growable: false);
        RenderLog.write('c745_orders_rewards', lines.length);

        return Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x12, Ds.space.x16, 0),
          child: InkWell(
            borderRadius: Ds.r.rCard,
            onTap: screen == null
                ? null
                : () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => screen)),
            child: Container(
              padding: EdgeInsets.all(Ds.space.x16),
              decoration: BoxDecoration(
                color: Ds.c.surface,
                borderRadius: Ds.r.rCard,
                border: Border.all(color: Ds.c.divider),
                boxShadow: Ds.elevation.e1,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(navIcon((entry['icon_key'] ?? '').toString()),
                      size: 22, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((entry['label'] ?? '').toString(),
                            style: Ds.t.subtitle
                                .copyWith(fontWeight: FontWeight.w700)),
                        for (final line in lines) ...[
                          SizedBox(height: Ds.space.x4),
                          Text(line,
                              style: Ds.t.caption
                                  .copyWith(color: Ds.c.textSecondary)),
                        ],
                      ],
                    ),
                  ),
                  if (screen != null)
                    Icon(Icons.chevron_right,
                        size: 20, color: Ds.c.textSecondary),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// CMD #1914 — the profile dropdown.
///
/// Om's steer: the mobile header wore an avatar on the left and THREE icons on
/// the right (wishlist heart, inbox bell, cart), so the logo between them was
/// never centred — it sat wherever the leftover space put it. The heart and the
/// bell moved in here, and moving them was a placement row, not a Dart edit:
/// this widget draws `placements.profile_dropdown` in the backend's order and
/// names no feature. The heading, the caption, every label and every badge —
/// the wishlist count and the unread count alike — arrive in the payload.
class CustomerProfileDropdown extends StatefulWidget {
  const CustomerProfileDropdown({super.key, this.title});

  /// The signed-in identity's own display name, which is `my_session()`'s
  /// string and is passed in rather than re-fetched here.
  final String? title;

  @override
  State<CustomerProfileDropdown> createState() =>
      _CustomerProfileDropdownState();
}

class _CustomerProfileDropdownState
    extends _SurfaceState<CustomerProfileDropdown> {
  @override
  void initState() {
    super.initState();
    // The unread count is the dropdown's own badge now, so it is refreshed on
    // open rather than by a bell that is no longer on the header.
    NotifUnread.refresh();
    // CMD #2108 — ask AGAIN on open. `ensureLoaded` fetches once per session,
    // so a sheet opened after the boot fetch had failed (or after a sign-in
    // that landed while the listener was detaching) was drawing an empty
    // payload for the rest of the session: a sheet with a name on it and
    // nothing under it, which is exactly what Om saw.
    CustomerSurfaces.load();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: CustomerSurfaces.value,
      builder: (context, payload, _) {
        final items = CustomerSurfaces.itemsFor(payload, 'profile_dropdown');
        final heading = (widget.title ?? '').trim().isNotEmpty
            ? widget.title!.trim()
            : (payload['dropdown_title'] ?? '').toString();
        final caption = (payload['dropdown_caption'] ?? '').toString();

        // CMD #2108 — the sheet renders EVERY row the backend placed here, by
        // its own render_kind, the way the profile's Account group already
        // did. Before this it built one shape only and threw away anything
        // whose route_key had no Dart screen — which is every 'action' row,
        // Logout included, because signing out is not a screen. A sheet that
        // silently drops what the backend sent is the bug, not the payload.
        final rows = <Widget>[];
        var hasLogout = false;
        for (final e in items) {
          final kind = (e['render_kind'] ?? 'row').toString();
          final label = (e['label'] ?? '').toString();
          if (label.isEmpty) continue;
          switch (kind) {
            case 'action':
              hasLogout = true;
              rows.add(_DropdownLogout(label: label));
              break;
            case 'danger_zone':
              // Deleting an account belongs on the profile page behind its own
              // confirmation, never one tap inside a header sheet.
              break;
            default:
              final row = _DropdownRow(entry: e);
              if (row.opens == null) break; // forward compat: skip, never throw
              rows.add(row);
          }
        }
        // The same rule the Account group has carried since #745: a signed-in
        // pharmacy the payload does not describe must still be able to sign
        // out. The word is the backend's either way.
        if (!hasLogout) {
          rows.add(_DropdownLogout(label: c('profile.btn_logout')));
        }
        RenderLog.write('c1914_profile_dropdown', items.length);
        RenderLog.write('c2108_dropdown_rows', rows.length);

        // Nothing has landed yet: a skeleton at the shape of the real rows,
        // never a bare spinner and never a sheet that is only a name.
        final loading = items.isEmpty && payload.isEmpty;

        return SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x24, Ds.space.x16, Ds.space.x24, Ds.space.x24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: Ds.space.x32,
                    height: Ds.space.x4,
                    decoration: BoxDecoration(
                      color: Ds.c.divider,
                      borderRadius: Ds.r.rChip,
                    ),
                  ),
                ),
                SizedBox(height: Ds.space.x16),
                if (heading.isNotEmpty)
                  Text(heading,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          Ds.t.subtitle.copyWith(fontWeight: FontWeight.w700)),
                if (caption.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(caption,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
                ],
                SizedBox(height: Ds.space.x16),
                // A phone in landscape, or a payload that grows a fifth row,
                // must scroll inside the sheet rather than overflow it.
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: loading
                          ? const [_DropdownSkeleton()]
                          : rows,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The rows' own shape while the first answer is still in flight.
class _DropdownSkeleton extends StatelessWidget {
  const _DropdownSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: EdgeInsets.only(bottom: Ds.space.x8),
              child: SkeletonBox(height: Ds.touch.minTarget + Ds.space.x8),
            ),
        ],
      ),
    );
  }
}

/// Logout, as a row of the same shape as every other row in the sheet.
class _DropdownLogout extends StatelessWidget {
  final String label;
  const _DropdownLogout({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Semantics(
        identifier: 'cust_dropdown_logout',
        button: true,
        child: InkWell(
          borderRadius: Ds.r.rCard,
          onTap: () async {
            Navigator.of(context).pop();
            await UserState.read(context).signOut();
          },
          child: Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x12),
            decoration: BoxDecoration(
              color: Ds.c.surface,
              borderRadius: Ds.r.rCard,
              border: Border.all(color: Ds.c.divider),
            ),
            child: Row(
              children: [
                Icon(Icons.logout, size: 22, color: Ds.c.textSecondary),
                SizedBox(width: Ds.space.x12),
                Expanded(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: Ds.c.textSecondary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DropdownRow extends StatelessWidget {
  final Map<String, dynamic> entry;
  const _DropdownRow({required this.entry});

  /// The screen this row opens, or null when this build of the app does not
  /// know the backend's route key yet. The sheet asks BEFORE it adds the row,
  /// so an unknown route is skipped instead of leaving an invisible gap.
  Widget? get opens =>
      customerMenuScreen((entry['route_key'] ?? '').toString());

  @override
  Widget build(BuildContext context) {
    final screen = opens;
    if (screen == null) return const SizedBox.shrink();
    final label = (entry['label'] ?? '').toString();
    if (label.isEmpty) return const SizedBox.shrink();
    final caption = (entry['caption'] ?? '').toString();
    // The trailing number is the ENTRY's own badge — the wishlist count for
    // one row, the unread count for another. This widget never asks which.
    final badge = (entry['badge'] ?? '').toString();
    return Padding(
      padding: EdgeInsets.only(bottom: Ds.space.x8),
      child: Semantics(
        identifier: 'cust_dropdown_${(entry['route_key'] ?? '').toString()}',
        button: true,
        child: InkWell(
        borderRadius: Ds.r.rCard,
        onTap: () {
          Navigator.of(context).pop();
          Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => screen));
        },
        child: Container(
          constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x16, vertical: Ds.space.x12),
          decoration: BoxDecoration(
            color: Ds.c.surface,
            borderRadius: Ds.r.rCard,
            border: Border.all(color: Ds.c.divider),
          ),
          child: Row(
            children: [
              Icon(navIcon((entry['icon_key'] ?? '').toString()),
                  size: 22, color: Ds.c.brand),
              SizedBox(width: Ds.space.x12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style:
                            Ds.t.body.copyWith(fontWeight: FontWeight.w600)),
                    if (caption.isNotEmpty) ...[
                      SizedBox(height: Ds.space.x4),
                      Text(caption,
                          style: Ds.t.caption
                              .copyWith(color: Ds.c.textSecondary)),
                    ],
                  ],
                ),
              ),
              if (badge.isNotEmpty)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: Ds.space.x8, vertical: 0),
                  constraints: BoxConstraints(minWidth: Ds.space.x24),
                  decoration: BoxDecoration(
                    color: Ds.c.brand,
                    borderRadius: Ds.r.rChip,
                  ),
                  child: Text(
                    badge,
                    textAlign: TextAlign.center,
                    style: Ds.t.caption.copyWith(
                        color: Ds.c.surface, fontWeight: FontWeight.w700),
                  ),
                ),
              SizedBox(width: Ds.space.x8),
              Icon(Icons.chevron_right, size: 20, color: Ds.c.textSecondary),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// The unread dot the avatar wears now that the bell has left the header.
///
/// It is the same value the dropdown's Notifications row prints — one fetch,
/// one number, two places that draw it. The label is the backend's, "99+" cap
/// included; this only decides whether to paint it.
class ProfileUnreadDot extends StatelessWidget {
  const ProfileUnreadDot({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: NotifUnread.value,
      builder: (context, s, _) {
        final show = (s['show'] as bool?) ?? false;
        final label = (s['label'] as String?) ?? '';
        if (!show || label.isEmpty) return const SizedBox.shrink();
        RenderLog.write('c1914_avatar_unread', 1);
        return Container(
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
          constraints: BoxConstraints(minWidth: Ds.space.x16),
          decoration: BoxDecoration(
            color: Ds.c.danger,
            borderRadius: Ds.r.rChip,
            border: Border.all(color: Ds.c.surface, width: 2),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: Ds.t.caption.copyWith(
                color: Ds.c.surface, fontWeight: FontWeight.w700),
          ),
        );
      },
    );
  }
}

/// CMD #1935 — the "Complete registration" banner.
///
/// The registration flow is never force-opened on launch: that is what made
/// closing it leave a blank screen, because it was the root of the stack. It
/// is ADVERTISED instead — one persistent line on Home, for exactly as long as
/// the backend says something is still owed.
///
/// It decides nothing. `customer_registration_banner()` answers whether to
/// show at all, which sentence to print, what the button says and which
/// address it opens; an account with nothing outstanding gets `show:false` and
/// this widget renders a zero-height box.
class RegistrationBanner extends StatefulWidget {
  const RegistrationBanner({super.key});

  /// Test seam — the same shape every screen in this app uses.
  @visibleForTesting
  static Future<dynamic> Function(String fn, Map<String, dynamic>? params)?
      rpcTransport;

  static Future<dynamic> rpc(String fn, [Map<String, dynamic>? params]) {
    final t = rpcTransport;
    if (t != null) return t(fn, params);
    return Supabase.instance.client.rpc(fn, params: params);
  }

  @override
  State<RegistrationBanner> createState() => _RegistrationBannerState();
}

class _RegistrationBannerState extends State<RegistrationBanner> {
  Map<String, dynamic> _b = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await RegistrationBanner.rpc('customer_registration_banner');
      if (!mounted) return;
      setState(() => _b = r is Map ? Map<String, dynamic>.from(r) : const {});
      RenderLog.write('c1935_reg_banner', _b['show'] == true ? 1 : 0);
    } catch (_) {
      if (!mounted) return;
      setState(() => _b = const {});
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_b['show'] != true) return const SizedBox.shrink();
    final title = (_b['title'] ?? '').toString();
    final line = (_b['line'] ?? '').toString();
    final cta = (_b['cta'] ?? '').toString();
    final route = (_b['route'] ?? '').toString();
    final step = Map<String, dynamic>.from((_b['step'] as Map?) ?? const {});
    final steps = ((_b['steps'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    // CMD #2059 — a phone column, not a row: the two step chips and a
    // full-width button never squeeze the sentence at 360px.
    return Container(
      width: double.infinity,
      margin: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x4),
      padding: EdgeInsets.all(Ds.space.x16),
      decoration: BoxDecoration(
        color: Ds.c.warningSoft,
        borderRadius: Ds.r.rCard,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title.isNotEmpty) Text(title, style: Ds.t.bodyStrong),
          if (line.isNotEmpty) ...[
            SizedBox(height: Ds.space.x4),
            Text(line, style: Ds.t.caption),
          ],
          if (steps.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            RegistrationStepStrip(
              step: step,
              steps: steps,
              onOpen: (r) async {
                await Navigator.of(context).pushNamed(r);
                if (mounted) await _load();
              },
            ),
          ],
          if (cta.isNotEmpty && route.isNotEmpty) ...[
            SizedBox(height: Ds.space.x12),
            SizedBox(
              width: double.infinity,
              height: Ds.touch.minTarget,
              child: FilledButton(
                onPressed: () async {
                  await Navigator.of(context).pushNamed(route);
                  if (mounted) await _load();
                },
                child: Text(cta),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// CMD #2059 — where the account is in registration, printed the same way on
/// the Home banner, on the details form and on the document checklist.
///
/// Every word is the backend's: the "Step 1 of 2" line, each step's name, its
/// state word and the progress sentence all arrive in
/// `customer_registration_payload().step / .steps`. Both steps are tappable
/// wherever this strip appears, so the checklist is never behind the form.
class RegistrationStepStrip extends StatelessWidget {
  const RegistrationStepStrip({
    super.key,
    required this.step,
    required this.steps,
    this.onOpen,
  });

  final Map<String, dynamic> step;
  final List<Map<String, dynamic>> steps;
  final void Function(String route)? onOpen;

  @override
  Widget build(BuildContext context) {
    final label = (step['label'] ?? '').toString();
    final progress = (step['progress_label'] ?? '').toString();
    final ratio = (step['ratio'] is num) ? (step['ratio'] as num).toDouble() : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label.isNotEmpty || progress.isNotEmpty)
          Row(
            children: [
              if (label.isNotEmpty)
                Flexible(child: Text(label, style: Ds.t.bodyStrong)),
              if (label.isNotEmpty && progress.isNotEmpty)
                SizedBox(width: Ds.space.x8),
              if (progress.isNotEmpty)
                Flexible(
                    child: Text(progress,
                        style: Ds.t.caption, overflow: TextOverflow.ellipsis)),
            ],
          ),
        SizedBox(height: Ds.space.x8),
        ClipRRect(
          borderRadius: Ds.r.rButton,
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: Ds.space.x8,
            backgroundColor: Ds.c.divider,
            valueColor: AlwaysStoppedAnimation<Color>(Ds.c.brand),
          ),
        ),
        if (steps.isNotEmpty) ...[
          SizedBox(height: Ds.space.x12),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [for (final st in steps) _chip(context, st)],
          ),
        ],
      ],
    );
  }

  Widget _chip(BuildContext context, Map<String, dynamic> st) {
    final done = st['done'] == true;
    final state = (st['state'] ?? '').toString();
    final name = (st['label'] ?? '').toString();
    final stepLabel = (st['step_label'] ?? '').toString();
    final stateLabel = (st['state_label'] ?? '').toString();
    final route = (st['route'] ?? '').toString();
    final bg = done
        ? Ds.c.successSoft
        : (state == 'current' ? Ds.c.brandSoft : Ds.c.surface);
    final open = onOpen;
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
      child: Material(
        color: bg,
        borderRadius: Ds.r.rChip,
        child: InkWell(
          borderRadius: Ds.r.rChip,
          onTap: (open == null || route.isEmpty) ? null : () => open(route),
          child: Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x12, vertical: Ds.space.x8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  done ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: Ds.space.x16,
                  color: done ? Ds.c.success : Ds.c.textSecondary,
                ),
                SizedBox(width: Ds.space.x8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (stepLabel.isNotEmpty)
                      Text(stepLabel, style: Ds.t.caption),
                    if (name.isNotEmpty) Text(name, style: Ds.t.body),
                  ],
                ),
                if (stateLabel.isNotEmpty) ...[
                  SizedBox(width: Ds.space.x8),
                  Text(stateLabel, style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
