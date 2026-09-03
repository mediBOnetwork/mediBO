import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../screens/admin/nav_registry_view.dart' show navIcon;
import '../screens/customer/profile_account_menu.dart' show customerMenuScreen;
import '../services/customer_surfaces.dart';
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
