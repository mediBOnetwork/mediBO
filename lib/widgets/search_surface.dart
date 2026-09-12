import 'dart:async';

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import '../models/search_page.dart';
import 'product_row_card.dart';
import 'scan_mic_search_controls.dart';

/// CMD #1906 — the ONE search surface, drawn the same way on Home and on the
/// Catalogue.
///
/// Home used to wear a solid brand band behind its search field and its
/// category chips; the Catalogue used a white header with a grey field. Same
/// app, two headers, and the chips on one of them were white-on-green while
/// the chips on the other were grey outlines. Everything in this file is what
/// BOTH screens now draw: one header, one chip row, one filter set, one
/// recent-search strip, one result row and one empty state.
///
/// Every string here arrives in the `search_page()` payload. There is no
/// label, count, plural or default written in this file.

// ─────────────────────────── the header ────────────────────────────────────

/// The search field. White ground, grey rounded field, scan and voice inside
/// it, and the BACKEND's placeholder.
class SearchHeaderBar extends StatefulWidget {
  const SearchHeaderBar({
    super.key,
    required this.controller,
    required this.placeholder,
    required this.onChanged,
    required this.onSubmit,
    this.focusNode,
    this.isLoading = false,
    this.onClear,
    this.trailing,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// `search_page().placeholder`. Empty means no hint rather than one invented
  /// here.
  final String placeholder;

  /// Fires on every keystroke — the owner debounces and asks for suggestions.
  final ValueChanged<String> onChanged;

  /// Fires on submit, on a voice result and on a scan result.
  final ValueChanged<String> onSubmit;

  final bool isLoading;
  final VoidCallback? onClear;

  /// An extra control on the right of the field (the desktop Search button).
  final Widget? trailing;

  /// One height for both screens, so the two headers cannot drift apart.
  static const double fieldHeight = 46;

  @override
  State<SearchHeaderBar> createState() => _SearchHeaderBarState();
}

class _SearchHeaderBarState extends State<SearchHeaderBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_sync);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final has = widget.controller.text.isNotEmpty;
    if (has != _hasText && mounted) setState(() => _hasText = has);
  }

  void _submit() {
    widget.onSubmit(widget.controller.text);
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x8),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: SearchHeaderBar.fieldHeight,
              decoration: BoxDecoration(
                color: Ds.c.bg,
                borderRadius: Ds.r.rButton,
                border: Border.all(color: Ds.c.divider),
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                    child: Icon(Icons.search,
                        color: Ds.c.textSecondary, size: Ds.space.x16 + 4),
                  ),
                  Expanded(
                    child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      onChanged: widget.onChanged,
                      onSubmitted: (_) => _submit(),
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: Ds.t.body,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        filled: false,
                        contentPadding:
                            EdgeInsets.symmetric(vertical: Ds.space.x12),
                        hintText: widget.placeholder,
                        hintStyle: Ds.t.body
                            .copyWith(color: Ds.c.textSecondary),
                      ),
                    ),
                  ),
                  if (widget.isLoading)
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                      child: SizedBox(
                        width: Ds.space.x16,
                        height: Ds.space.x16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Ds.c.brand),
                      ),
                    )
                  else if (_hasText)
                    IconButton(
                      onPressed: () {
                        widget.controller.clear();
                        widget.onClear?.call();
                        widget.onChanged('');
                      },
                      icon: Icon(Icons.close,
                          size: Ds.space.x16 + 2, color: Ds.c.textSecondary),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: BoxConstraints(
                          minWidth: Ds.touch.minTarget,
                          minHeight: Ds.touch.minTarget),
                    ),
                  // CMD #409's scan and voice, now on BOTH screens rather than
                  // only the one that happened to own the header.
                  ScanSearchButton(color: Ds.c.textSecondary),
                  VoiceSearchButton(
                    color: Ds.c.textSecondary,
                    onQuery: (q) {
                      widget.controller.text = q;
                      _submit();
                    },
                  ),
                ],
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            SizedBox(width: Ds.space.x12),
            widget.trailing!,
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── the chip row ──────────────────────────────────

/// The filter set, in the BACKEND's order.
///
/// The group the payload marked `chip_row` draws its options inline — that is
/// the category row Home has always shown, restyled as outlined grey chips
/// with the selected one in brand green. Every other group draws as ONE chip
/// that opens its own sheet, so pack type, prescription, product flags and
/// sort reach both screens without a second row of forty chips.
class SearchFilterChips extends StatelessWidget {
  const SearchFilterChips({
    super.key,
    required this.filters,
    required this.onPick,
    this.showSheetGroups = true,
  });

  final SearchFilters filters;

  /// Hands back the group and the option the viewer tapped, untouched.
  final void Function(SearchFilterGroup group, SearchOption option) onPick;

  /// The sheet groups narrow RESULTS, so a screen with no query drawn yet
  /// passes false and shows the category row alone.
  final bool showSheetGroups;

  static const double rowHeight = 52;
  static const double _chipHeight = 34;

  @override
  Widget build(BuildContext context) {
    final row = filters.chipRowGroup;
    final sheets = showSheetGroups ? filters.sheetGroups : const <SearchFilterGroup>[];
    if (row == null && sheets.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[
      if (row != null)
        for (final o in row.options)
          _chip(
            label: o.label,
            selected: o.selected,
            onTap: () => onPick(row, o),
          ),
      for (final g in sheets)
        _chip(
          label: _sheetChipLabel(g),
          selected: g.selected.isNotEmpty,
          trailing: Icons.expand_more,
          onTap: () => _openSheet(context, g),
        ),
    ];

    return Container(
      color: Ds.c.surface,
      height: rowHeight,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(
            Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x12),
        itemCount: children.length,
        separatorBuilder: (_, __) => SizedBox(width: Ds.space.x8),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }

  /// A group's chip prints the group's label until something is chosen, and
  /// then it prints what was chosen — both are the backend's own words.
  static String _sheetChipLabel(SearchFilterGroup g) {
    final sel = g.selected;
    if (sel.isEmpty) return g.label;
    if (sel.length == 1) return sel.first.label;
    return '${g.label} (${sel.length})';
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    IconData? trailing,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: _chipHeight,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
          decoration: BoxDecoration(
            color: selected ? Ds.c.brand : Ds.c.surface,
            borderRadius: Ds.r.rChip,
            border:
                Border.all(color: selected ? Ds.c.brand : Ds.c.divider),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style: Ds.t.caption.copyWith(
                    color: selected ? Ds.c.surface : Ds.c.text,
                    fontWeight: FontWeight.w600,
                  )),
              if (trailing != null) ...[
                SizedBox(width: Ds.space.x4),
                Icon(trailing,
                    size: Ds.space.x16,
                    color: selected ? Ds.c.surface : Ds.c.textSecondary),
              ],
            ],
          ),
        ),
      );

  void _openSheet(BuildContext context, SearchFilterGroup g) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(borderRadius: Ds.r.rSheet),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.all(Ds.space.x16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(g.label, style: Ds.t.subtitle),
              SizedBox(height: Ds.space.x12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final o in g.options)
                      InkWell(
                        onTap: () {
                          Navigator.of(ctx).pop();
                          onPick(g, o);
                        },
                        child: Container(
                          constraints:
                              BoxConstraints(minHeight: Ds.touch.minTarget),
                          padding: EdgeInsets.symmetric(
                              vertical: Ds.space.x8),
                          child: Row(
                            children: [
                              Icon(
                                o.selected
                                    ? (g.isMulti
                                        ? Icons.check_box
                                        : Icons.radio_button_checked)
                                    : (g.isMulti
                                        ? Icons.check_box_outline_blank
                                        : Icons.radio_button_unchecked),
                                size: Ds.space.x16 + 4,
                                color: o.selected
                                    ? Ds.c.brand
                                    : Ds.c.textSecondary,
                              ),
                              SizedBox(width: Ds.space.x12),
                              Expanded(child: Text(o.label, style: Ds.t.body)),
                              if (o.n != null)
                                Text('${o.n}', style: Ds.t.caption),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── the recent strip ────────────────────────────────

/// The recent-search strip, under the box, on both screens.
///
/// It draws only when the BACKEND says `has` — an anonymous viewer and an
/// empty history both arrive as `has:false`, and neither is decided here.
class SearchRecentStrip extends StatelessWidget {
  const SearchRecentStrip({
    super.key,
    required this.recent,
    required this.onPick,
    this.onClear,
  });

  final SearchRecent recent;
  final ValueChanged<String> onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    if (!recent.has || recent.items.isEmpty) return const SizedBox.shrink();
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x4, Ds.space.x16, Ds.space.x12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(recent.title, style: Ds.t.caption)),
              if (onClear != null && recent.clearLabel.isNotEmpty)
                GestureDetector(
                  onTap: onClear,
                  child: Container(
                    constraints:
                        BoxConstraints(minHeight: Ds.touch.minTarget),
                    alignment: Alignment.centerRight,
                    padding: EdgeInsets.only(left: Ds.space.x12),
                    child: Text(recent.clearLabel,
                        style: Ds.t.caption.copyWith(color: Ds.c.brand)),
                  ),
                ),
            ],
          ),
          SizedBox(height: Ds.space.x8),
          Wrap(
            spacing: Ds.space.x8,
            runSpacing: Ds.space.x8,
            children: [
              for (final r in recent.items)
                GestureDetector(
                  onTap: () => onPick(r.q),
                  child: Container(
                    height: Ds.space.x32,
                    alignment: Alignment.center,
                    padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
                    decoration: BoxDecoration(
                      color: Ds.c.bg,
                      borderRadius: Ds.r.rChip,
                      border: Border.all(color: Ds.c.divider),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.history,
                            size: Ds.space.x16, color: Ds.c.textSecondary),
                        SizedBox(width: Ds.space.x4),
                        Text(r.label, style: Ds.t.caption),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── the empty state ───────────────────────────────

/// The empty state, identical on both screens: the backend's sentence, its
/// hint, and its buttons in the order and tone it sent them.
class SearchEmptyView extends StatelessWidget {
  const SearchEmptyView({
    super.key,
    required this.empty,
    required this.onAction,
  });

  final SearchEmpty empty;

  /// Hands back the button's own `kind` — 'clear_filters' or 'request'.
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    if (empty.label.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: Ds.space.x16, vertical: Ds.space.x32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(empty.label, textAlign: TextAlign.center, style: Ds.t.subtitle),
          if (empty.hint.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(empty.hint, textAlign: TextAlign.center, style: Ds.t.caption),
          ],
          for (final b in empty.buttons) ...[
            SizedBox(height: Ds.space.x16),
            SizedBox(
              height: Ds.touch.minTarget,
              child: b.tone == 'primary'
                  ? FilledButton(
                      onPressed: () => onAction(b.kind),
                      style: FilledButton.styleFrom(
                        backgroundColor: Ds.c.brand,
                        shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton),
                      ),
                      child: Text(b.label),
                    )
                  : OutlinedButton(
                      onPressed: () => onAction(b.kind),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Ds.c.brand,
                        side: BorderSide(color: Ds.c.brand),
                        shape: RoundedRectangleBorder(
                            borderRadius: Ds.r.rButton),
                      ),
                      child: Text(b.label),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────── the result list ───────────────────────────────

/// The header line, the rows and the load-more control — the whole result
/// body, so Home and the Catalogue cannot lay the same rows out differently.
///
/// The rows are [ProductRowCard] verbatim: image, name, company, pack, the
/// struck MRP, `price_display` and ADD.
class SearchResultsView extends StatelessWidget {
  const SearchResultsView({
    super.key,
    required this.payload,
    required this.onOpenProduct,
    required this.onLoadMore,
    required this.onEmptyAction,
    this.loadingMore = false,
    this.shrinkWrap = true,
    this.physics,
  });

  final SearchPagePayload payload;
  final ValueChanged<String> onOpenProduct;
  final VoidCallback onLoadMore;
  final ValueChanged<String> onEmptyAction;
  final bool loadingMore;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    if (payload.items.isEmpty) {
      return SearchEmptyView(empty: payload.empty, onAction: onEmptyAction);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (payload.headerLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x12),
            child: Text(payload.headerLabel, style: Ds.t.caption),
          ),
        ListView.separated(
          shrinkWrap: shrinkWrap,
          physics: physics ?? const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
          itemCount: payload.items.length,
          separatorBuilder: (_, __) => SizedBox(height: Ds.space.x12),
          itemBuilder: (context, i) => ProductRowCard(
            key: ValueKey(payload.items[i].id),
            product: payload.items[i],
            onTap: () => onOpenProduct(payload.items[i].id),
          ),
        ),
        SizedBox(height: Ds.space.x16),
        if (payload.paging.hasMore && payload.paging.moreLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: SizedBox(
              height: Ds.touch.minTarget,
              child: OutlinedButton(
                onPressed: loadingMore ? null : onLoadMore,
                style: OutlinedButton.styleFrom(
                  foregroundColor: Ds.c.brand,
                  side: BorderSide(color: Ds.c.brand),
                  shape:
                      RoundedRectangleBorder(borderRadius: Ds.r.rButton),
                ),
                child: Text(payload.paging.moreLabel),
              ),
            ),
          )
        else if (payload.paging.endLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            child: Text(payload.paging.endLabel,
                textAlign: TextAlign.center, style: Ds.t.caption),
          ),
        SizedBox(height: Ds.space.x24),
      ],
    );
  }
}

/// The list's loading state — the row's own boxes at the row's own height.
/// A skeleton, never a bare spinner (design QA rule six).
class SearchResultsSkeleton extends StatelessWidget {
  const SearchResultsSkeleton({super.key, this.rows = 6});

  final int rows;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        child: Column(
          children: [
            for (int i = 0; i < rows; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                  height: ProductRowCard.rowHeight,
                  decoration: BoxDecoration(
                      color: Ds.c.surface, borderRadius: Ds.r.rCard),
                  padding: EdgeInsets.all(Ds.space.x12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _bone(ProductRowCard.imageSize, ProductRowCard.imageSize),
                      SizedBox(width: Ds.space.x12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _bone(double.infinity, Ds.space.x16),
                            SizedBox(height: Ds.space.x8),
                            _bone(double.infinity, Ds.space.x12),
                          ],
                        ),
                      ),
                      SizedBox(width: Ds.space.x12),
                      _bone(ProductRowCard.priceColW, ProductRowCard.addH),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );

  Widget _bone(double w, double h) => Container(
        width: w,
        height: h,
        decoration:
            BoxDecoration(color: Ds.c.bg, borderRadius: Ds.r.rChip),
      );
}

/// Debounces keystrokes for the suggestion popup. The only client-side
/// behaviour in the search box, and it decides nothing about the result.
class SearchDebouncer {
  SearchDebouncer({this.delay = const Duration(milliseconds: 180)});

  final Duration delay;
  Timer? _timer;

  void run(VoidCallback fn) {
    _timer?.cancel();
    _timer = Timer(delay, fn);
  }

  void cancel() => _timer?.cancel();
  void dispose() => _timer?.cancel();
}
