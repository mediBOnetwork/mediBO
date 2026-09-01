// CHANGE #537 — Fulfill is the order pipeline, and the pipeline is a payload.
//
// The physical route an order travels is:
//
//   1 Customer order → 2 Supplier inquiry → 3 Supplier order → 4 Supplier shop
//   → 5 Warehouse → 6 Bag → 7 Pack → 8 Delivery → 9 Dispute
//
// That sequence is NOT written down in this file. It arrives from
// `fulfill_tabs()` — label, order, permission and badge together — and this
// file renders it verbatim. Which is the whole point: an admin and a region
// partner get the SAME bar from the SAME RPC, and a partner who holds no
// permission for a stage simply does not receive that tab. The remaining tabs
// keep their order, because the order is the backend's `sort`, never an index
// in Dart.
//
// Deliberately Supabase-free and dart:html-free so it can be rendered in a
// plain Dart VM widget test (the trap that left five test files silently
// never compiling before #635).

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../utils/render_log.dart';

/// One stage of the pipeline, exactly as `fulfill_tabs().tabs[]` sent it.
///
/// Nothing here is computed. `badgeLabel` is already '7' or '99+' when the
/// backend wanted a badge and null when it did not — this class never counts,
/// never caps and never pluralises.
class FulfillPipelineTab {
  /// Stable identity of the stage — `customer_order`, `warehouse`, `dispute`…
  /// This is what the screen maps to a body widget, and what a deep link names.
  final String stageKey;

  /// The feature_registry key that gated this tab.
  final String featureKey;

  /// Backend copy. Printed verbatim.
  final String label;

  /// The backend's own ordering value. Kept so a caller can prove the render
  /// order is the payload's order and not a client-side sort.
  final int sort;

  /// 'read' | 'write' — already reduced across the partner and staff matrices.
  final String access;
  final bool canWrite;

  /// Badge, entirely backend-owned. `badgeLabel` is null when no badge is due.
  final int badgeCount;
  final bool hasBadge;
  final String? badgeLabel;

  final String deepLink;

  const FulfillPipelineTab({
    required this.stageKey,
    required this.featureKey,
    required this.label,
    required this.sort,
    required this.access,
    required this.canWrite,
    required this.badgeCount,
    required this.hasBadge,
    required this.badgeLabel,
    required this.deepLink,
  });

  static FulfillPipelineTab fromJson(Map<String, dynamic> m) {
    final raw = m['badge_label'];
    final label = raw == null ? null : raw.toString();
    return FulfillPipelineTab(
      stageKey: (m['stage_key'] ?? '').toString(),
      featureKey: (m['feature_key'] ?? '').toString(),
      label: (m['label'] ?? '').toString(),
      sort: (m['sort'] as num?)?.toInt() ?? 0,
      access: (m['access'] ?? 'none').toString(),
      canWrite: m['can_write'] == true,
      badgeCount: (m['badge_count'] as num?)?.toInt() ?? 0,
      hasBadge: m['has_badge'] == true,
      badgeLabel: (label == null || label.isEmpty) ? null : label,
      deepLink: (m['deep_link'] ?? '').toString(),
    );
  }
}

/// The whole `fulfill_tabs()` reply.
class FulfillPipelinePayload {
  final bool ok;

  /// In payload order. Never re-sorted here.
  final List<FulfillPipelineTab> tabs;

  /// Backend copy for the refusal / empty states.
  final String message;
  final String emptyTitle;
  final String emptyMessage;

  final bool isPartner;
  final String zoneLabel;

  const FulfillPipelinePayload({
    required this.ok,
    required this.tabs,
    required this.message,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.isPartner,
    required this.zoneLabel,
  });

  static const FulfillPipelinePayload empty = FulfillPipelinePayload(
    ok: false,
    tabs: <FulfillPipelineTab>[],
    message: '',
    emptyTitle: '',
    emptyMessage: '',
    isPartner: false,
    zoneLabel: '',
  );

  bool get hasTabs => tabs.isNotEmpty;

  /// The same payload with a narrower tab list — used when an index-bounded
  /// caller (#307/#528 hand the screen a set of legacy tab indexes) must not
  /// be widened by a stage the backend was happy to send. Everything else,
  /// including the backend's copy, is carried through untouched.
  FulfillPipelinePayload copyWithTabs(List<FulfillPipelineTab> next) =>
      FulfillPipelinePayload(
        ok: ok,
        tabs: next,
        message: message,
        emptyTitle: emptyTitle,
        emptyMessage: emptyMessage,
        isPartner: isPartner,
        zoneLabel: zoneLabel,
      );

  static FulfillPipelinePayload fromJson(Map<String, dynamic> m) {
    final rows = (m['tabs'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => FulfillPipelineTab.fromJson(Map<String, dynamic>.from(e)))
        .where((t) => t.stageKey.isNotEmpty)
        .toList();
    return FulfillPipelinePayload(
      ok: m['ok'] == true,
      tabs: rows,
      message: (m['message'] ?? '').toString(),
      emptyTitle: (m['empty_title'] ?? '').toString(),
      emptyMessage: (m['empty_message'] ?? '').toString(),
      isPartner: m['is_partner'] == true,
      zoneLabel: (m['zone_label'] ?? '').toString(),
    );
  }

  /// The tab a stage key selects, or null when this build has never heard of
  /// it. A caller must skip an unknown stage in silence — that is what lets the
  /// backend add a tenth stage without a deploy.
  FulfillPipelineTab? byStage(String stageKey) {
    for (final t in tabs) {
      if (t.stageKey == stageKey) return t;
    }
    return null;
  }

  int indexOfStage(String stageKey) {
    for (var i = 0; i < tabs.length; i++) {
      if (tabs[i].stageKey == stageKey) return i;
    }
    return -1;
  }

  /// The stage a fresh mount should land on: the first one the backend sent.
  String get firstStage => tabs.isEmpty ? '' : tabs.first.stageKey;
}

/// The horizontally scrollable pipeline bar.
///
/// Nine stages do not fit a 360 px phone and were never going to. The rule from
/// #349 is that scrolling is fine and hiding is not: every tab must be
/// REACHABLE. So the row scrolls, the selected tab is scrolled into view
/// whenever it changes (including when a deep link picks it), and an edge fade
/// on whichever side still has content off-screen says out loud that there is
/// more to scroll to.
class FulfillPipelineTabBar extends StatefulWidget {
  final List<FulfillPipelineTab> tabs;
  final String selectedStage;
  final ValueChanged<String> onSelect;

  /// Colours come from the screen that hosts the bar so this widget stays
  /// import-light (and testable) — it defines no palette of its own.
  final Color selectedColor;
  final Color unselectedColor;
  final Color badgeColor;
  final Color surfaceColor;

  const FulfillPipelineTabBar({
    super.key,
    required this.tabs,
    required this.selectedStage,
    required this.onSelect,
    required this.selectedColor,
    required this.unselectedColor,
    required this.badgeColor,
    required this.surfaceColor,
  });

  @override
  State<FulfillPipelineTabBar> createState() => _FulfillPipelineTabBarState();
}

class _FulfillPipelineTabBarState extends State<FulfillPipelineTabBar> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{};

  /// Whether there is content past the left / right edge right now. Drives the
  /// fades, so "there are more tabs that way" is visible rather than guessed.
  bool _moreLeft = false;
  bool _moreRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncEdges);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncEdges();
      _revealSelected();
    });
  }

  @override
  void didUpdateWidget(FulfillPipelineTabBar old) {
    super.didUpdateWidget(old);
    if (old.selectedStage != widget.selectedStage ||
        old.tabs.length != widget.tabs.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncEdges();
        _revealSelected();
      });
    }
  }

  @override
  void dispose() {
    _scroll.removeListener(_syncEdges);
    _scroll.dispose();
    super.dispose();
  }

  void _syncEdges() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    final left = p.pixels > 2;
    final right = p.pixels < (p.maxScrollExtent - 2);
    if (left != _moreLeft || right != _moreRight) {
      setState(() {
        _moreLeft = left;
        _moreRight = right;
      });
    }
  }

  /// The #349 guarantee, made mechanical: whatever is selected is on screen.
  void _revealSelected() {
    final key = _keys[widget.selectedStage];
    final ctx = key?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.5,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c537_pipeline_tabs', '${widget.tabs.length}');
    RenderLog.write(
        'c537_pipeline_order', widget.tabs.map((t) => t.stageKey).join(','));

    final row = SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in widget.tabs) ...[
            Padding(
              key: _keys.putIfAbsent(t.stageKey, () => GlobalKey()),
              padding: EdgeInsets.only(
                  right: Ds.space.x8, top: Ds.space.x4, bottom: Ds.space.x4),
              child: _PipelineTabChip(
                tab: t,
                selected: t.stageKey == widget.selectedStage,
                onTap: () => widget.onSelect(t.stageKey),
                selectedColor: widget.selectedColor,
                unselectedColor: widget.unselectedColor,
                badgeColor: widget.badgeColor,
              ),
            ),
          ],
        ],
      ),
    );

    return SizedBox(
      height: Ds.touch.minTarget + Ds.space.x8,
      child: Stack(children: [
        Positioned.fill(child: row),
        if (_moreLeft)
          Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: _EdgeFade(color: widget.surfaceColor, toRight: false)),
        if (_moreRight)
          Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: _EdgeFade(color: widget.surfaceColor, toRight: true)),
      ]),
    );
  }
}

/// One stage chip. Label and badge are printed exactly as they arrived.
class _PipelineTabChip extends StatelessWidget {
  final FulfillPipelineTab tab;
  final bool selected;
  final VoidCallback onTap;
  final Color selectedColor;
  final Color unselectedColor;
  final Color badgeColor;

  const _PipelineTabChip({
    required this.tab,
    required this.selected,
    required this.onTap,
    required this.selectedColor,
    required this.unselectedColor,
    required this.badgeColor,
  });

  @override
  Widget build(BuildContext context) {
    final badge = tab.badgeLabel;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Stack(clipBehavior: Clip.none, children: [
          // 44 px minimum touch target, on the grid.
          Container(
            constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
            alignment: Alignment.center,
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x8),
            decoration: BoxDecoration(
              color: selected ? selectedColor : Colors.transparent,
              borderRadius: Ds.r.rButton,
            ),
            child: Text(
              tab.label,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontSize: Ds.t.bodySize,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : unselectedColor,
              ),
            ),
          ),
          if (badge != null)
            Positioned(
              top: 0,
              right: -2,
              child: Container(
                padding:
                    EdgeInsets.symmetric(
                        horizontal: Ds.space.x4, vertical: Ds.space.x4 / 2),
                decoration: BoxDecoration(
                  color: badgeColor,
                  borderRadius: Ds.r.rChip,
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                      fontSize: Ds.t.captionSize - 3,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.2),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

class _EdgeFade extends StatelessWidget {
  final Color color;
  final bool toRight;
  const _EdgeFade({required this.color, required this.toRight});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: Ds.space.x24,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: toRight ? Alignment.centerRight : Alignment.centerLeft,
            end: toRight ? Alignment.centerLeft : Alignment.centerRight,
            colors: [color, color.withValues(alpha: 0)],
          ),
        ),
      ),
    );
  }
}
