import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/search_page.dart';
import '../utils/render_log.dart';
import 'compact_product_card.dart';
import '../models/product.dart';
import 'product_row_card.dart';
import 'scan_mic_search_controls.dart';

/// CMD #1906 — the ONE search surface, drawn the same way on Home and on the
/// Catalogue.
///
/// Home used to wear a solid brand band behind its search field and its
/// category chips; the Catalogue used a white header with a grey field. Same
/// app, two headers, and the chips on one of them were white-on-green while
/// the chips on the other were grey outlines. Everything in this file is what
/// BOTH screens now draw: one header, one chip row, one filter set, one idle
/// rail, one result row and one empty state.
///
/// CMD #2010 — and ONE behaviour: from the second character the results grid
/// under the box IS the answer, debounced and backend-ranked. There is no
/// suggestion list to tap through and nothing about what was typed is kept.
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

  /// Fires on every keystroke — the owner debounces it into the search.
  final ValueChanged<String> onChanged;

  /// Fires on submit, on a voice result and on a scan result. With CMD #2010
  /// the grid has usually answered already; this only settles the last word.
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
        separatorBuilder: (_, _) => SizedBox(width: Ds.space.x8),
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

// ───────────────────────── the idle rail ───────────────────────────────────

/// CMD #2010 — what the search surface offers with the box focused and
/// nothing typed.
///
/// The backend picked the rail and wrote its title: this customer's previously
/// ordered products when there are any, the zone's top sellers when there are
/// none. This widget renders whichever arrived and draws NOTHING when the
/// backend says `has` is false — an anonymous viewer with an empty catalogue
/// and a customer whose past products all went off-sale are both its answer,
/// not a length check made here.
class SearchIdleRail extends StatelessWidget {
  const SearchIdleRail({super.key, required this.rail, this.surface = 'unknown'});

  final SearchRail rail;

  /// Which screen mounted it — the render-log's proof that the rail painted.
  final String surface;

  @override
  Widget build(BuildContext context) {
    if (!rail.has || rail.items.isEmpty) return const SizedBox.shrink();
    RenderLog.write('c2010_rail_$surface', '${rail.kind}:${rail.items.length}');
    return Container(
      color: Ds.c.surface,
      padding: EdgeInsets.only(bottom: Ds.space.x16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x12),
            child: Text(rail.title,
                key: const Key('c2010_rail_title'), style: Ds.t.subtitle),
          ),
          SizedBox(
            height: CompactProductCard.extent,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
              itemCount: rail.items.length,
              itemBuilder: (context, i) {
                final card = rail.items[i];
                return Padding(
                  padding: EdgeInsets.only(right: Ds.space.x12),
                  child: SizedBox(
                    width: CompactProductCard.railWidth,
                    child: CompactProductCard(
                      product: Product.fromHomeCard(card),
                      onTap: () => Navigator.of(context)
                          .pushNamed('/product/${card['id']}'),
                    ),
                  ),
                );
              },
            ),
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
    this.surface = 'unknown',
  });

  final SearchPagePayload payload;
  final ValueChanged<String> onOpenProduct;
  final VoidCallback onLoadMore;
  final ValueChanged<String> onEmptyAction;
  final bool loadingMore;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  /// CMD #1906 — which screen mounted this ONE surface. It exists only so the
  /// render-log can PROVE the shared-surface claim on the live site: a Flutter
  /// canvas cannot be read by Puppeteer and a string in the JS bundle only
  /// proves the code compiled, never that the widget rendered.
  final String surface;

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c1906_rows_$surface', payload.items.length);
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
          separatorBuilder: (_, _) => SizedBox(height: Ds.space.x12),
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

/// Debounces keystrokes into the search. The only client-side behaviour in
/// the box, and it decides nothing about the result — it only decides WHEN to
/// ask the backend, so a four-letter word is one query and not four.
class SearchDebouncer {
  SearchDebouncer({this.delay = const Duration(milliseconds: 250)});

  final Duration delay;
  Timer? _timer;

  void run(VoidCallback fn) {
    _timer?.cancel();
    _timer = Timer(delay, fn);
  }

  void cancel() => _timer?.cancel();
  void dispose() => _timer?.cancel();
}

/// CMD #1906 — THE search header, and the only one in the app.
///
/// Home used to wear a solid `Ds.c.brand` band behind its field and its chips
/// while the Catalogue wore a white header with a grey field: same app, two
/// headers, two behaviours. This is ONE component — white ground, grey rounded
/// field, the backend's placeholder, the suggestion panel, the backend's own
/// filter chips in the backend's own order, and the recent strip — mounted by
/// both screens so they cannot drift apart again.
///
/// It owns the typing machinery (the suggestion controller and the debounce)
/// because that is chrome, not state a screen should have to carry. What it
/// never owns is the SEARCH: the query, the filters and the page live in the
/// screen's [SearchQueryState] and travel in the URL.
class SearchChrome extends StatefulWidget {
  const SearchChrome({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hasQuery,
    required this.onSubmit,
    required this.onFilterPick,
    required this.onClear,
    this.payload,
    this.isLoading = false,
    this.trailing,
    this.repo,
    this.surface = 'unknown',
    this.minChars = 2,
  });

  /// The live `search_page()` answer, when the screen has one. Its filter
  /// groups are what the header draws, so the chips above the list and the
  /// list itself can never be two different answers.
  final SearchPagePayload? payload;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool hasQuery;
  final bool isLoading;
  final Widget? trailing;
  final void Function(String query) onSubmit;
  final void Function(SearchFilterGroup group, SearchOption option) onFilterPick;
  final VoidCallback onClear;
  final MedicineRepository? repo;

  /// CMD #2010 — the character the live grid starts at. Spec: the second.
  final int minChars;

  /// CMD #1906 — which screen mounted this ONE header. See [SearchResultsView.surface].
  final String surface;

  @override
  State<SearchChrome> createState() => _SearchChromeState();
}

class _SearchChromeState extends State<SearchChrome> {
  final SearchDebouncer _debounce = SearchDebouncer();
  late final MedicineRepository _repo = widget.repo ?? MedicineRepository();

  /// The idle chrome: what the header shows before anything has been searched.
  /// Loaded here rather than by every screen, so a screen that mounts the
  /// header gets the chips and the rail for free.
  SearchPagePayload? _chrome;

  /// CMD #2010 — the rail is the FOCUSED-and-empty state, so the box's focus
  /// is the one thing this widget watches.
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocus);
    _loadChrome();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    _debounce.cancel();
    super.dispose();
  }

  void _onFocus() {
    final f = widget.focusNode.hasFocus;
    if (f != _focused && mounted) setState(() => _focused = f);
  }

  /// CHANGE #497's instant chip row, carried over — with CMD #2010's fix to
  /// the order it runs in.
  ///
  /// The LIVE answer is asked for first and never waits on the device cache:
  /// the cache read was awaited ahead of it, so a storage layer that answers
  /// slowly (or, in a widget test, never) held the entire header — chips,
  /// placeholder and rail — hostage behind it. The cached chrome still paints
  /// the moment it arrives, but only while nothing live has landed, and a
  /// failed refresh still leaves whatever was painted alone.
  Future<void> _loadChrome() async {
    unawaited(() async {
      try {
        final cached = await _repo.cachedSearchChrome();
        if (cached != null && mounted && _chrome == null) {
          setState(() => _chrome = cached);
        }
      } catch (_) {}
    }());
    try {
      final p = await _repo.searchPage(SearchQueryState.blank);
      if (!mounted) return;
      setState(() => _chrome = p);
    } catch (_) {
      // Whatever the cache painted stays; never chips this file invented.
    }
  }

  void _submit(String q) {
    _debounce.cancel();
    widget.onSubmit(q);
  }

  /// CMD #2010 — every keystroke IS the search.
  ///
  /// From [SearchChrome.minChars] the debounce fires the host's own submit,
  /// which is the same path Enter takes: one surface, one ranking, no
  /// intermediate screen. Below that threshold — including an emptied box —
  /// the search is cleared, which puts the browse feed (and the rail) back.
  void _changed(String v) {
    final q = v.trim();
    if (q.length < widget.minChars) {
      _debounce.cancel();
      if (widget.hasQuery) widget.onClear();
      return;
    }
    _debounce.run(() {
      if (!mounted) return;
      RenderLog.write('c2010_live_${widget.surface}', q.length);
      widget.onSubmit(v);
    });
  }

  /// The rail draws only while the box is focused with nothing typed in it,
  /// and only while the screen is not already showing a search.
  bool get _railOpen =>
      _focused &&
      !widget.hasQuery &&
      widget.controller.text.trim().isEmpty;

  @override
  Widget build(BuildContext context) {
    final p = widget.payload ?? _chrome;
    RenderLog.write('c1906_chrome_${widget.surface}', 1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SearchHeaderBar(
          controller: widget.controller,
          focusNode: widget.focusNode,
          placeholder: p?.placeholder ?? '',
          isLoading: widget.isLoading,
          onChanged: _changed,
          onSubmit: _submit,
          onClear: widget.onClear,
          trailing: widget.trailing,
        ),
        SearchFilterChips(
          filters: p?.filters ?? SearchFilters.empty,
          showSheetGroups: widget.hasQuery,
          onPick: widget.onFilterPick,
        ),
        if (_railOpen)
          SearchIdleRail(
            rail: (_chrome ?? p)?.rail ?? SearchRail.empty,
            surface: widget.surface,
          ),
      ],
    );
  }
}

/// CHANGE #440, moved here by CMD #1906 — "type anywhere to search".
///
/// Pressing a letter or a digit with no text field focused seeds the search box
/// with that character and submits, the way Gmail and YouTube do. It lived in
/// the shell, where it was the only piece of search machinery left in a file
/// whose one job is boot and routing; it belongs with the field it types into.
///
/// [enabled] is the shell's own verdict — desktop web, storefront tab, nothing
/// open on top — because only the shell knows that.
bool searchTypeAnywhere(
  KeyEvent event, {
  required bool enabled,
  required TextEditingController controller,
  required FocusNode focusNode,
  required void Function(String query) onSubmit,
}) {
  if (!enabled) return false;
  if (event is! KeyDownEvent) return false;
  if (focusNode.hasFocus) return false;

  final primary = FocusManager.instance.primaryFocus;
  if (primary != null && primary.context?.widget is EditableText) return false;

  final keys = HardwareKeyboard.instance.logicalKeysPressed;
  final hasModifier = keys.contains(LogicalKeyboardKey.controlLeft) ||
      keys.contains(LogicalKeyboardKey.controlRight) ||
      keys.contains(LogicalKeyboardKey.metaLeft) ||
      keys.contains(LogicalKeyboardKey.metaRight) ||
      keys.contains(LogicalKeyboardKey.altLeft) ||
      keys.contains(LogicalKeyboardKey.altRight);
  if (hasModifier) return false;

  final ch = event.character;
  if (ch == null || ch.isEmpty) return false;
  if (!RegExp(r'^[a-zA-Z0-9]$').hasMatch(ch)) return false;

  focusNode.requestFocus();
  controller.text = controller.text + ch;
  controller.selection =
      TextSelection.fromPosition(TextPosition(offset: controller.text.length));
  onSubmit(controller.text);
  return true;
}
