import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../shell_motion.dart'; // CMD #2187 — one thing animates at a time
import '../models/search_page.dart';
import '../utils/toast.dart';
import '../utils/render_log.dart';
import 'product_card_grid.dart';
import '../models/product.dart';
import '../services/search_chrome_focus.dart';
import '../services/storefront_fast_order.dart';
import 'card_layout.dart';
import 'company_hits_block.dart';
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

/// CMD #2117 §4 — the placeholder that moves.
///
/// "Search" is fixed; the word after it changes every
/// `placeholder_rotate_ms` — medicine, salt, composition, then the medicines
/// this zone actually orders most. The new word slides up from below while the
/// old one carries on up out of the middle and fades out, so the two are one
/// movement rather than a swap.
///
/// NOT ONE OF THOSE WORDS IS WRITTEN HERE. The prefix, the list and the
/// interval all arrive in `search_page().search_bar`; a payload with fewer than
/// two words animates nothing and the box shows a still hint, which is also
/// what an app running from an old cache gets.
///
/// CMD #2187 — AND IT ONLY ROTATES WHEN IT OWNS THE MOTION. The header pill
/// rolls on a 3 s clock ten pixels above this one; two clocks drift into each
/// other and read as broken. `shell_style().search.placeholder_rotate_when`
/// says `header_hidden`, so this word holds still for exactly as long as the
/// header row is on screen and starts only once the row is entirely gone
/// ([placeholderMayRotate]). Nothing moves during the handover slide.
class AnimatedSearchPlaceholder extends StatefulWidget {
  const AnimatedSearchPlaceholder({
    super.key,
    required this.prefix,
    required this.words,
    required this.rotate,
    this.style,
  });

  final String prefix;
  final List<String> words;
  final Duration rotate;
  final TextStyle? style;

  /// The cycling half, addressable so the protected suite can read the word on
  /// screen without reading the whole box.
  static const Key wordKey = Key('c2117_placeholder_word');

  @override
  State<AnimatedSearchPlaceholder> createState() =>
      _AnimatedSearchPlaceholderState();
}

class _AnimatedSearchPlaceholderState extends State<AnimatedSearchPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: Ds.motion.standard,
    value: 1,
  );
  Timer? _timer;
  int _i = 0;
  int _prev = 0;

  @override
  void initState() {
    super.initState();
    shellMotion.addListener(_onMotion);
    _start();
    RenderLog.write('c2117_placeholder_words', widget.words.length);
  }

  /// The gate moved — the header row arrived or finished leaving. Only the
  /// clock starts or stops; nothing is rebuilt, because the word on screen is
  /// the word that was already there.
  void _onMotion() => _start();

  @override
  void didUpdateWidget(covariant AnimatedSearchPlaceholder old) {
    super.didUpdateWidget(old);
    // A fresh payload (a new zone, a new best seller) restarts the cycle from
    // the top rather than landing mid-list on a word that has moved.
    if (old.words.length != widget.words.length ||
        old.rotate != widget.rotate) {
      _i = 0;
      _prev = 0;
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    if (widget.words.length < 2) return;
    // CMD #2187 — the pill owns the motion while the header row is showing.
    if (!placeholderMayRotate) {
      RenderLog.write('c2187_placeholder_frozen', 1);
      return;
    }
    RenderLog.write('c2187_placeholder_frozen', 0);
    _timer = Timer.periodic(widget.rotate, (_) {
      if (!mounted || !placeholderMayRotate) return;
      setState(() {
        _prev = _i;
        _i = (_i + 1) % widget.words.length;
      });
      _c.forward(from: 0);
    });
  }

  @override
  void dispose() {
    shellMotion.removeListener(_onMotion);
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  Widget _word(String text, TextStyle? style) => Text(
        text,
        key: AnimatedSearchPlaceholder.wordKey,
        style: style,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      );

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    if (widget.words.isEmpty) return Text(widget.prefix, style: style);
    if (widget.words.length < 2) {
      return Text('${widget.prefix} ${widget.words.first}',
          style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.prefix, style: style, maxLines: 1),
        SizedBox(width: Ds.space.x4),
        Flexible(
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) {
                final t = _c.value;
                return Stack(
                  children: [
                    // The word on its way out: up and away, never downwards.
                    if (t < 1)
                      FractionalTranslation(
                        translation: Offset(0, -t),
                        child: Opacity(
                          opacity: 1 - t,
                          child: _word(widget.words[_prev], style),
                        ),
                      ),
                    // The new word, arriving from below the box.
                    FractionalTranslation(
                      translation: Offset(0, 1 - t),
                      child: Opacity(
                        opacity: t,
                        child: _word(widget.words[_i], style),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

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
    this.bar = SearchBarSpec.fallback,
    this.scanResolver,
    this.leading,
    this.trailingBare,
    this.banded = false,
  });

  final TextEditingController controller;
  final FocusNode? focusNode;

  /// CMD #2175 (Om, on #1521) — is this row the shell's own band, the one
  /// pinned under the header row on every customer tab? Then it ends in the
  /// #2164 hairline that closes the white band; a plain search screen does
  /// not. It replaces #2156's `compact` listenable, which said the same thing
  /// ("the logo row has scrolled away") in order to RESIZE the row — and a
  /// pinned row that resizes as the row above it leaves moves everything
  /// under it, which is the one thing it must never do.
  final bool banded;

  /// CMD #2147 — a control LEFT of the field (the sticky bar's m mark, or ←
  /// on the search screen). It sizes itself, gap included, so an empty one
  /// costs no width.
  final Widget? leading;

  /// CMD #2147 — a control RIGHT of the field that brings its own spacing
  /// (the sticky bell), unlike [trailing] which is always given a gap.
  final Widget? trailingBare;

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

  /// CMD #2026 — `search_page().search_bar`: which buttons sit on the right of
  /// the field in each state, in the backend's own order.
  final SearchBarSpec bar;

  /// Injected only by tests, straight through to [ScanSearchButton].
  final Future<ScanResult> Function(String code)? scanResolver;

  /// One height for both screens, so the two headers cannot drift apart.
  ///
  /// CMD #2175 (Om) — the BOX inside the shell's one row: [Ds.shell.boxHeight]
  /// (40, the logo tile's own size, so the two read as one optical line) with
  /// [Ds.shell.padY] above and below it, which is the row's 56. #2156's
  /// 48 → 40 step-down when the logo row scrolled away is gone: the box is one
  /// size in every state.
  static double get fieldHeight => Ds.shell.boxHeight;

  /// CMD #2117 — the semantics address of the field itself, so a browser
  /// journey taps the search box rather than a rounded rectangle.
  static const String boxId = 'c2117_search_box';

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

  void _clear() {
    widget.controller.clear();
    widget.onClear?.call();
    widget.onChanged('');
  }

  /// CMD #2026 — draws ONE backend-declared button. The icon is a NAME the
  /// backend sent; a name this build does not know is skipped rather than
  /// guessed, so the payload can never draw a blank square. Every label is the
  /// backend's, and every target is the token minimum.
  /// CMD #2175 — the box is [Ds.shell.boxHeight] (40) now, and inside its
  /// border that leaves 37 dp of row: every control in it came out UNDER the
  /// 44 dp floor the phone rule sets, which the search-box gate caught. The
  /// BOX does not grow — Om's redline is 40 beside the 40 logo tile — so the
  /// TARGET grows out of it instead, 2 dp each way into the row's own
  /// [Ds.shell.padY]. Nothing clips it and nothing below it moves: the row is
  /// still the shell's one 56.
  Widget _tapTarget(Widget child) => SizedBox(
        width: Ds.touch.minTarget,
        child: OverflowBox(
          minWidth: Ds.touch.minTarget,
          maxWidth: Ds.touch.minTarget,
          minHeight: Ds.touch.minTarget,
          maxHeight: Ds.touch.minTarget,
          alignment: Alignment.center,
          child: child,
        ),
      );

  Widget _barAction(SearchBarAction a) {
    switch (a.icon) {
      case 'close':
        return IconButton(
          key: const Key('c2026_clear_button'),
          tooltip: a.label,
          onPressed: _clear,
          icon: Icon(Icons.close,
              size: Ds.space.x16 + 2, color: Ds.c.textSecondary),
          // NOT VisualDensity.compact: it subtracts 4 px from the constraints
          // below, and the one control a shopper reaches for mid-search came
          // out 40x40 — under the 44 px floor on the viewport that matters.
          padding: EdgeInsets.zero,
          constraints: BoxConstraints(
              minWidth: Ds.touch.minTarget, minHeight: Ds.touch.minTarget),
        );
      case 'scan':
        return ScanSearchButton(
            color: Ds.c.textSecondary, resolver: widget.scanResolver);
      case 'mic':
        return VoiceSearchButton(
          color: Ds.c.textSecondary,
          onQuery: (q) {
            // A voice result is not typing: the box is SET to what the backend
            // resolved, with the caret after it, and submitted.
            widget.controller.value = TextEditingValue(
              text: q,
              selection: TextSelection.collapsed(offset: q.length),
            );
            _submit();
          },
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) => _row(context);

  /// One row, one size, in every state — see [SearchHeaderBar.banded] for the
  /// only thing that still tells the shell's band from a search screen.
  Widget _row(BuildContext context) {
    // CMD #2175 (Om, on #1521) — 56 dp is the TOTAL of the row, outside edge
    // to outside edge, WITH ITS GAPS INSIDE IT. The first cut read it as "the
    // box is 56" and added the gap outside, which made the search block 76
    // and the box fat beside the 40 dp logo tile. So the row is
    // [Ds.shell.padY] + [Ds.shell.boxHeight] + [Ds.shell.padY] = 56, and the
    // box is the tile's own 40 at radius 20.
    //
    // There is no scrolled variant of it any more, at either end: the row does
    // not change height, does not change its inset and grows nothing beside
    // the field when the header row leaves. A pinned bar that resizes as the
    // row above it goes moves everything under it, which is the one thing it
    // must never do.
    final EdgeInsets pad = EdgeInsets.fromLTRB(
        Ds.shell.inset, Ds.shell.padY, Ds.shell.inset, Ds.shell.padY);
    final double field = SearchHeaderBar.fieldHeight;
    final h = Ds.header;
    final fade = Duration(milliseconds: h.fadeMs.round());
    return AnimatedContainer(
      duration: fade,
      curve: Curves.easeOut,
      // CMD #2164 — the shared header ends in a 1 dp line.
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: widget.banded
            ? Border(bottom: BorderSide(color: h.line, width: h.lineWidth))
            : null,
      ),
      padding: pad,
      child: Row(
        children: [
          if (widget.leading != null) widget.leading!,
          Expanded(
            child: AnimatedContainer(
              duration: fade,
              curve: Curves.easeOut,
              height: field,
              // CMD #2037 — the field is the HEADER's white, not the page's
              // grey, with the same hairline every card uses. The grey fill
              // drew a second block under the header; on one white ground the
              // header and the field read as one piece of chrome and the thin
              // border is all that says "this is a box you can type in".
              // CMD #2164 redline: radius 24 (20 scrolled), 1.5 dp hairline
              // (the divider token — the one every card's hairline uses),
              // 16 inner padding, a 22 dp search icon.
              decoration: BoxDecoration(
                color: Ds.c.surface,
                // CMD #2175 — the BOX's corner (20 = half its 40), not the
                // row's 28. Both are the backend's.
                borderRadius: BorderRadius.circular(Ds.shell.boxRadius),
                border: Border.all(
                    color: Ds.c.divider, width: h.searchBorderWidth),
              ),
              child: Row(
                children: [
                  Padding(
                    padding: EdgeInsets.only(
                        left: h.searchPad, right: h.iconGap),
                    child: Icon(Icons.search,
                        color: h.placeholder, size: h.searchIcon),
                  ),
                  Expanded(
                    child: Semantics(
                      identifier: SearchHeaderBar.boxId,
                      textField: true,
                      child: TextField(
                      controller: widget.controller,
                      focusNode: widget.focusNode,
                      onChanged: widget.onChanged,
                      onSubmitted: (_) => _submit(),
                      textInputAction: TextInputAction.search,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: Ds.t.body,
                      // CMD #2175 (Om) — the typed word and the placeholder sit
                      // on the MIDDLE of the field, not near its top.
                      //
                      // A fixed vertical contentPadding decides where the text
                      // sits by arithmetic, so the moment the field's own
                      // height moved (48 → the shell's 56) the text stopped
                      // being centred in it — visibly high, with the clear "×"
                      // and the search glyph beside it still centred by the
                      // Row. Nothing here should be doing that arithmetic:
                      // textAlignVertical centres the input INSIDE whatever
                      // height the field happens to be, so a backend that
                      // retunes `shell.height` can never knock it off again.
                      // The padding goes to zero for the same reason — it was
                      // the only thing competing with the centring. WHERE it
                      // sits is the backend's own `search.text_align_v`, so
                      // even this is an UPDATE and not a deploy.
                      textAlignVertical: Ds.shell.textAlign,
                      decoration: InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        isDense: true,
                        filled: false,
                        contentPadding: EdgeInsets.zero,
                        // CMD #2117 — the hint is a WIDGET when the backend
                        // sent a prefix and a word list, and the plain string
                        // it always was otherwise.
                        hintText:
                            widget.bar.placeholderAnimates ? null : widget.placeholder,
                        hint: widget.bar.placeholderAnimates
                            ? AnimatedSearchPlaceholder(
                                prefix: widget.bar.placeholderPrefix,
                                words: widget.bar.placeholderWords,
                                rotate: widget.bar.placeholderRotate,
                                style: Ds.t.body.copyWith(
                                    color: h.placeholder,
                                    fontSize: h.searchText),
                              )
                            : null,
                        hintStyle: Ds.t.body.copyWith(
                            color: h.placeholder, fontSize: h.searchText),
                      ),
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
                    ),
                  // CMD #2026 — the right-hand side of the field is the
                  // BACKEND's list for the state the box is in.
                  //
                  // Empty: CMD #409's scan and mic. Any text: they go away and
                  // a single × takes the far right. Before this they were drawn
                  // unconditionally with the × squeezed in BEFORE them, so the
                  // one control a shopper reaches for mid-search sat third from
                  // the edge behind two buttons that cannot help while typing.
                  for (final a in widget.bar.actionsForText(
                      _hasText ? widget.controller.text : ''))
                    _tapTarget(_barAction(a)),
                ],
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            SizedBox(width: Ds.space.x12),
            widget.trailing!,
          ],
          if (widget.trailingBare != null) widget.trailingBare!,
        ],
      ),
    );
  }
}

// ─────────────────────────── the chip row ──────────────────────────────────

/// The filter set, in the BACKEND's order.
///
/// CMD #2037 — the INLINE CATEGORY ROW IS GONE. "All / OTHERS / ANTI
/// INFECTIVES / CARDIAC" sat under the search bar on every home visit, ahead
/// of the feed, duplicating the Shop-by-category tiles a screen below it and
/// the Catalogue's own Browse-by tiles. It is not drawn on any surface any
/// more, and `search_chip_row_surfaces` is empty on the backend so an app
/// running from an old cache does not draw it either.
///
/// What is left is the SHEET groups: each one draws as ONE chip that opens its
/// own sheet, so pack type, prescription, product flags and sort reach both
/// screens without a row of forty chips.
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
    final sheets = showSheetGroups ? filters.sheetGroups : const <SearchFilterGroup>[];
    // CMD #2037 — no inline category row, on any surface. `chipRowGroup` is
    // still parsed (it is the backend's answer, and the model's test holds the
    // contract) but nothing draws it.
    if (sheets.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[
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
          // CMD #2167 — the shared rail: catalogue-width cards, no reserved
          // height, all of them as tall as the tallest.
          ProductCardRail(
            items: rail.items.map(Product.fromHomeCard).toList(),
            onOpen: (p) =>
                Navigator.of(context).pushNamed('/product/${p.id}'),
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
/// CMD #2044 — the rows are GONE. The results are the same
/// [ProductCardGrid] Home draws: the identical card (image with Rx badge,
/// pack chip inside the image, pack-type chip, ADD, name, company, MRP, sale
/// price and PTR), in the column count that fits the width — 2 on a phone, 3
/// on a tablet, 4–5 on a desktop. The count line above it is the backend's
/// `header_label` ("119 products for \"monticope\"").
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

  /// CMD #2165 — the company matches, above whatever the products do next.
  ///
  /// A shopper who types "sun pharma" has named a MAKER, and page 1 of its
  /// molecules is not that answer. The block is the payload's: it appears only
  /// when `companies_has` is true, and it sits above the results AND above the
  /// empty state, because "no medicine matched" is exactly when knowing the
  /// company matched is worth most.
  Widget _companies(BuildContext context) {
    RenderLog.write('c2165_company_rows_$surface', payload.companies.rows.length);
    if (!payload.companies.has) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.fromLTRB(
          Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x24),
      child: CompanyHitsBlock(
        hits: payload.companies,
        onOpen: (h) => Navigator.of(context)
            .pushNamed('/company/${Uri.encodeComponent(h.key)}'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    RenderLog.write('c1906_rows_$surface', payload.items.length);
    if (payload.items.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _companies(context),
          SearchEmptyView(empty: payload.empty, onAction: onEmptyAction),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _companies(context),
        if (payload.headerLabel.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x8, Ds.space.x16, Ds.space.x12),
            child: Text(payload.headerLabel, style: Ds.t.caption),
          ),
        // CMD #2167 — results draw on the 'search' surface.
        CardSurface(
          screen: 'search',
          child: ProductCardGrid(
            items: payload.items,
            shrinkWrap: shrinkWrap,
            physics: physics ?? const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
            onOpen: (p) => onOpenProduct(p.id),
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

  /// How many CARDS to reserve. The name stayed `rows` so every caller that
  /// asked for six placeholders still asks for six.
  final int rows;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        child: ProductCardGridSkeleton(tiles: rows),
      );
}


// ──────────────────── the focused-and-empty screen (CMD #2044) ─────────────

/// CMD #2044 — what the WHOLE screen shows while the box is focused and empty.
///
/// Om: "on tapping search, the screen below goes blank — no Top sellers rail,
/// no suggestions, no history — until the user types." The rail from CMD #2010
/// drew itself under the box inside the header; everything below it was the
/// home feed, shoved off a phone screen by the keyboard. This is the body of
/// that state, and it is `search_idle()` rendered verbatim: the blocks the
/// backend sent, in the order it sent them, with its titles, its chips and its
/// cards. A `kind` this build does not know is SKIPPED, never guessed at — a
/// fourth block ships as an INSERT.
class SearchIdleView extends StatelessWidget {
  const SearchIdleView({
    super.key,
    required this.payload,
    required this.onPickQuery,
    required this.onOpenProduct,
    this.onAction,
    this.loading = false,
    this.surface = 'unknown',
  });

  final SearchIdlePayload payload;

  /// A chip is a QUERY: the surface runs `chip.q`, exactly as it arrived.
  final ValueChanged<String> onPickQuery;
  final ValueChanged<String> onOpenProduct;

  /// The block's own control — 'clear_recent' today.
  final ValueChanged<String>? onAction;
  final bool loading;
  final String surface;

  @override
  Widget build(BuildContext context) {
    if (loading && payload.blocks.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: Ds.space.x16),
        child: const SearchResultsSkeleton(rows: 4),
      );
    }
    RenderLog.write('c2044_idle_$surface', payload.blocks.length);
    if (payload.blocks.isEmpty) {
      return Padding(
        padding: EdgeInsets.all(Ds.space.x24),
        child: Text(payload.emptyLabel,
            key: const Key('c2044_idle_empty'),
            textAlign: TextAlign.center,
            style: Ds.t.caption),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in payload.blocks) _block(context, b),
        SizedBox(height: Ds.space.x24),
      ],
    );
  }

  Widget _block(BuildContext context, SearchIdleBlock b) {
    // Forward compatibility: a block this build cannot draw costs nothing.
    final body = switch (b.kind) {
      'recent' || 'suggest' => _chips(b),
      'rail' => _rail(context, b),
      _ => null,
    };
    if (body == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
              Ds.space.x16, Ds.space.x16, Ds.space.x16, Ds.space.x8),
          child: Row(
            children: [
              Expanded(child: Text(b.title, style: Ds.t.subtitle)),
              if (b.actionLabel.isNotEmpty && b.actionKind.isNotEmpty)
                TextButton(
                  onPressed: () => onAction?.call(b.actionKind),
                  style: TextButton.styleFrom(
                    foregroundColor: Ds.c.brand,
                    minimumSize: Size(Ds.touch.minTarget, Ds.touch.minTarget),
                  ),
                  child: Text(b.actionLabel),
                ),
            ],
          ),
        ),
        body,
      ],
    );
  }

  /// Recent and popular searches are the same control — a query you can tap —
  /// so they are the same widget. They WRAP rather than scroll sideways: a
  /// phone must be able to see every one of them without a gesture.
  Widget _chips(SearchIdleBlock b) => Padding(
        padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
        child: Wrap(
          spacing: Ds.space.x8,
          runSpacing: Ds.space.x8,
          children: [
            for (final ch in b.chips)
              ConstrainedBox(
                constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
                child: ActionChip(
                  key: ValueKey('c2044_chip_${b.kind}_${ch.q}'),
                  onPressed: () => onPickQuery(ch.q),
                  backgroundColor: Ds.c.bg,
                  side: BorderSide(color: Ds.c.divider),
                  shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
                  label: Text(
                    ch.subLabel.isEmpty ? ch.label : '${ch.label} · ${ch.subLabel}',
                    style: Ds.t.body,
                  ),
                ),
              ),
          ],
        ),
      );

  /// The product block: the SAME card every other surface draws, in the same
  /// grid, so the focused search screen and Home cannot disagree about a price.
  Widget _rail(BuildContext context, SearchIdleBlock b) {
    final items = [
      for (final c in b.items) Product.fromHomeCard(c),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: Ds.space.x16),
      child: CardSurface(
        screen: 'search',
        child: ProductCardGrid(
          items: items,
          onOpen: (p) => onOpenProduct(p.id),
        ),
      ),
    );
  }
}

/// CMD #2044 — the host-side wrapper that puts [SearchIdleView] over the page
/// while the box is focused with nothing typed.
///
/// It is an overlay rather than a replacement on purpose: the page underneath
/// (the home feed, the catalogue tree) keeps its scroll position and its state,
/// so dismissing the keyboard puts the shopper back exactly where they were.
class SearchIdleOverlay extends StatefulWidget {
  const SearchIdleOverlay({
    super.key,
    required this.focusNode,
    required this.hasQuery,
    required this.onPickQuery,
    required this.child,
    this.repo,
    this.surface = 'unknown',
  });

  final FocusNode focusNode;
  final bool hasQuery;

  /// Runs the chip's own query through the host's normal search path.
  final ValueChanged<String> onPickQuery;
  final Widget child;
  final MedicineRepository? repo;
  final String surface;

  @override
  State<SearchIdleOverlay> createState() => _SearchIdleOverlayState();
}

class _SearchIdleOverlayState extends State<SearchIdleOverlay> {
  late final MedicineRepository _repo = widget.repo ?? MedicineRepository();
  SearchIdlePayload _idle = SearchIdlePayload.empty;
  bool _loading = false;
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocus);
    if (_open) _load();
  }

  @override
  void didUpdateWidget(covariant SearchIdleOverlay old) {
    super.didUpdateWidget(old);
    // The shopper cleared the box: the idle screen is wanted again, and the
    // history may have grown since it was last asked for.
    if (old.hasQuery && !widget.hasQuery && _focused) _load();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    final f = widget.focusNode.hasFocus;
    if (f == _focused) return;
    if (mounted) setState(() => _focused = f);
    if (_open) _load();
  }

  bool get _open => _focused && !widget.hasQuery;

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    final p = await _repo.searchIdle();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (p.blocks.isNotEmpty || p.ok) _idle = p;
    });
  }

  Future<void> _action(String kind) async {
    if (kind != 'clear_recent') return;
    final toast = await _repo.searchRecentClear();
    if (!mounted) return;
    if (toast.isNotEmpty) showToast(context, toast);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (!_open) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned.fill(
          child: Container(
            color: Ds.c.bg,
            child: SingleChildScrollView(
              // CMD #2117 §2 — THE BUG. `onDrag` read one gesture as two
              // different intentions: scrolling the suggestions to reach the
              // one below the fold dropped the keyboard, and dropping the
              // keyboard unfocuses the box, which closes this overlay — so the
              // list a shopper had just started reading disappeared under
              // their finger and there was nothing to scroll back up to.
              // A drag inside the suggestions is a drag inside the
              // suggestions. The keyboard closes when the shopper closes it.
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.manual,
              key: const Key('c2117_idle_scroll'),
              child: SearchIdleView(
                payload: _idle,
                loading: _loading,
                surface: widget.surface,
                onPickQuery: widget.onPickQuery,
                onOpenProduct: (id) =>
                    Navigator.of(context).pushNamed('/product/$id'),
                onAction: _action,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Debounces keystrokes into the search. The only client-side behaviour in
/// the box, and it decides nothing about the result — it only decides WHEN to
/// ask the backend, so a four-letter word is one query and not four.
class SearchDebouncer {
  SearchDebouncer({this.delay = const Duration(milliseconds: 250)});

  /// The DEFAULT wait. CMD #2026 — the live one is the backend's
  /// (`search_bar.debounce_ms`), handed to [run] with the keystroke, so
  /// retuning the box is an app_settings UPDATE and not a deploy.
  final Duration delay;
  Timer? _timer;

  void run(VoidCallback fn, {Duration? delay}) {
    _timer?.cancel();
    _timer = Timer(delay ?? this.delay, fn);
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
    this.idleInBody = false,
    this.leading,
    this.banded = false,
    this.trailingBare,
  });

  /// CMD #2147 — see [SearchHeaderBar.leading] / [SearchHeaderBar.trailingBare].
  /// CMD #2175 — see [SearchHeaderBar.banded].
  final bool banded;

  final Widget? leading;
  final Widget? trailingBare;

  /// CMD #2044 — the host draws the whole focused-and-empty state in the BODY
  /// ([SearchIdleOverlay]), so the header must not draw the rail a second
  /// time. Left false the header keeps CMD #2010's rail under the box, which
  /// is what a host that mounts the chrome on its own still gets.
  final bool idleInBody;

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

  /// CMD #2010 — the character the live grid starts at. CMD #2026 — this is
  /// now only the value used until the first payload lands: `search_bar`
  /// carries the real floor, so it is one UPDATE.
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

  /// One idle-chrome fetch in flight at a time, and never a second one once
  /// an answer has landed.
  bool _chromeAsked = false;

  @override
  void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocus);
    _maybeLoadChrome();
  }

  @override
  void didUpdateWidget(covariant SearchChrome old) {
    super.didUpdateWidget(old);
    // The shopper cleared the box: the idle chrome is wanted again, and this
    // is the first moment it can be asked for without racing the live search.
    if (old.hasQuery && !widget.hasQuery) _maybeLoadChrome();
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_onFocus);
    _debounce.cancel();
    // Never leave the bottom chrome hidden behind a header that has gone.
    SearchChromeFocus.release();
    super.dispose();
  }

  void _onFocus() {
    final f = widget.focusNode.hasFocus;
    if (f != _focused && mounted) setState(() => _focused = f);
    _reportChromeFocus();
    if (f) _maybeLoadChrome();
  }

  /// CMD #2117 §3 — tell the bottom chrome the keyboard is up.
  ///
  /// The surface only REPORTS; whether the bar and the pill then stand down is
  /// `search_bar.hide_bottom_chrome_on_focus`, so turning this off is an
  /// UPDATE on `app_settings` and not a deploy.
  void _reportChromeFocus() => SearchChromeFocus.report(
        focused: widget.focusNode.hasFocus,
        backendWantsHide: _bar.hideBottomChromeOnFocus,
      );

  /// The idle chrome is `search_page()` with NOTHING typed, so it is asked for
  /// only while the host is not already showing a search. Firing it next to a
  /// live query put a blank `p_q` on the wire AFTER the real one — the screen
  /// still rendered its own payload, but the last thing the backend was asked
  /// was the wrong question. It is asked again the moment the box is focused
  /// or the query is cleared, which is when the rail is actually wanted.
  void _maybeLoadChrome() {
    if (_chromeAsked || widget.hasQuery) return;
    _chromeAsked = true;
    _loadChrome();
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
      // The payload that carries the flag has only just landed: re-answer with
      // it rather than with the fallback the first focus was judged against.
      _reportChromeFocus();
    } catch (_) {
      // Whatever the cache painted stays; never chips this file invented.
      // A failed refresh may be asked again on the next focus.
      _chromeAsked = false;
    }
  }

  void _submit(String q) {
    _debounce.cancel();
    widget.onSubmit(q);
  }

  /// CMD #2010 — every keystroke IS the search. CMD #2026 — and the WHOLE text
  /// is the query.
  ///
  /// The floor and the wait are the backend's (`search_bar.min_chars` /
  /// `debounce_ms`); above the floor the debounce fires the host's own submit,
  /// the same path Enter takes. Below it — an emptied box included — the search
  /// is cleared, which puts the browse feed (and the rail) back.
  ///
  /// Nothing here inspects the words. A space is a character: "telmed ah
  /// tablet" is ONE query, it is sent whole on every keystroke, and no token in
  /// it is ever selected, highlighted or committed on its own.
  void _changed(String v) {
    final bar = _bar;
    if (!bar.shouldSearch(v)) {
      _debounce.cancel();
      if (widget.hasQuery) widget.onClear();
      return;
    }
    _debounce.run(() {
      if (!mounted) return;
      RenderLog.write('c2010_live_${widget.surface}', v.trim().length);
      RenderLog.write('c2026_live_words_${widget.surface}',
          v.trim().split(RegExp(r'\s+')).length);
      widget.onSubmit(v);
    }, delay: bar.debounce);
  }

  /// The bar spec in force: the live payload's, else the idle chrome's, else
  /// the floor this widget was mounted with.
  SearchBarSpec get _bar {
    final p = widget.payload ?? _chrome;
    if (p != null && p.searchBar.actions.isNotEmpty) return p.searchBar;
    if (p != null && p.searchBar != SearchBarSpec.fallback) return p.searchBar;
    return SearchBarSpec(
        minChars: widget.minChars,
        debounceMs: _debounce.delay.inMilliseconds,
        actions: const <SearchBarAction>[],
        chipRowOnResults: true);
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
          banded: widget.banded,
          controller: widget.controller,
          focusNode: widget.focusNode,
          placeholder: p?.placeholder ?? '',
          isLoading: widget.isLoading,
          bar: _bar,
          onChanged: _changed,
          onSubmit: _submit,
          onClear: widget.onClear,
          trailing: widget.trailing,
          leading: widget.leading,
          trailingBare: widget.trailingBare,
        ),
        SearchFilterChips(
          filters: p?.filters ?? SearchFilters.empty,
          // CMD #2026 §3 — above RESULTS nothing sits between the box and the
          // grid: not the category row, and not the filter chips either. That
          // is the shape CMD #2011 gave the Catalogue (both rows removed, the
          // Therapeutic class list further down is the way in) and the spec
          // asks for the same on search. The rule is the payload's
          // (`search_bar.chip_row_on_results`), so putting a row back above
          // results is one app_settings UPDATE.
          //
          // CMD #2037 — and the inline CATEGORY row is gone from every
          // surface, typed-in or not; see [SearchFilterChips].
          showSheetGroups: widget.hasQuery && _bar.chipRowOnResults,
          onPick: widget.onFilterPick,
        ),
        if (_railOpen && !widget.idleInBody)
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
