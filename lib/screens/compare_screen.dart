import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/medicine_repository.dart';
import '../design_tokens.dart';
import '../models/compare_table.dart';
import '../utils/render_log.dart';
import '../widgets/notify_control.dart';
import 'product_detail_screen.dart';

/// CMD #2095 — the heading treatment. Headings are the ONE bold thing in the
/// table; every value under them is [Ds.t.body], regular, the same token the
/// product page's Product-overview card prints its right column in.
TextStyle get _headStyle =>
    Ds.t.caption.copyWith(color: Ds.c.text, fontWeight: FontWeight.w700);

/// Where a column sits, as the PAYLOAD says: the frozen product name is left,
/// everything else is centred. An alignment this file does not recognise falls
/// back to left rather than guessing.
Alignment _alignOf(CompareColumn c) => c.isCenter
    ? Alignment.center
    : c.isRight
        ? Alignment.centerRight
        : Alignment.centerLeft;

TextAlign _textAlignOf(CompareColumn c) => c.isCenter
    ? TextAlign.center
    : c.isRight
        ? TextAlign.right
        : TextAlign.left;

/// '#RRGGBB' / '#AARRGGBB' -> Color. The fallback is a COLOUR only, never copy.
Color _hexColor(String hex, Color fallback) {
  if (hex.isEmpty) return fallback;
  final h = hex.startsWith('#') ? hex.substring(1) : hex;
  final v = int.tryParse(h.length == 6 ? 'FF$h' : h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// CMD #2095 — and what opens it is a BOTTOM SHEET, not a push.
///
/// [showCompareSheet] is the product page's door: a modal sheet at the
/// backend's own share of the screen (`compare_layout.sheet_pct`, 85), which
/// slides up, closes on the × in its handle bar and closes on a swipe down.
/// The `/compare/:id` route still exists for a shared link and still draws the
/// SAME body through [CompareScreen] — one table, two doors, no second design.
///
/// CMD #2074 — the compare table, as its own page.
///
/// It was a bottom sheet with products across the top, which works for three
/// ticked packs and not at all for twenty brands of one salt. So: products are
/// ROWS, attributes are COLUMNS, the header row and the product-name column
/// stay put while everything else scrolls sideways under a thumb.
///
/// The screen decides nothing. `pdp_salt_compare()` sends the column order,
/// every heading, every cell string, every tone, both pill colours, the ADD
/// word per row and the table's own geometry; this file zips two lists and
/// prints them. The three things it does own are all motion: the two scroll
/// offsets, which stay alive while a product page is open on top of it, and the
/// cart calls behind the stepper — the same `AppState` calls the product card
/// makes, so a quantity set here is the same quantity there.
/// The product page's compare door. Returns when the sheet is dismissed.
Future<void> showCompareSheet(
  BuildContext context, {
  required String productId,
  Future<CompareTable> Function(String productId)? loader,
  NotifyRequest? notifyRequest,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // The swipe-down close, and the scrim behind it. Both are the sheet's own
    // behaviour — nothing here re-implements a gesture.
    enableDrag: true,
    isDismissible: true,
    backgroundColor: Ds.c.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Ds.r.rCard.topLeft),
    ),
    // The sheet may grow to the whole screen; the share it actually takes is
    // the BACKEND's (`compare_layout.sheet_pct`, 85) and is applied inside,
    // once the payload has arrived — so raising it is an UPDATE, not a deploy.
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height,
    ),
    builder: (_) => _CompareSheet(
        productId: productId, loader: loader, notifyRequest: notifyRequest),
  );
}

/// The sheet's contents: the handle bar with the backend's close caption, then
/// the same body the route draws.
class _CompareSheet extends StatelessWidget {
  final String productId;
  final Future<CompareTable> Function(String productId)? loader;
  final NotifyRequest? notifyRequest;

  const _CompareSheet(
      {required this.productId, this.loader, this.notifyRequest});

  @override
  Widget build(BuildContext context) => CompareScreen(
        key: const ValueKey('compare-sheet'),
        productId: productId,
        loader: loader,
        notifyRequest: notifyRequest,
        asSheet: true,
      );
}

class CompareScreen extends StatefulWidget {
  final String productId;

  /// Test seam. Production goes through [MedicineRepository]; a test supplies a
  /// parsed payload so the table renders with no network and no Supabase.
  final Future<CompareTable> Function(String productId)? loader;

  /// Test seam for the Notify control on an unavailable row. Production calls
  /// `stock_notify_request` through the repository, exactly as the card and
  /// the product page do.
  final NotifyRequest? notifyRequest;

  /// CMD #2095 — true inside [showCompareSheet]: the table wears a handle bar
  /// with the backend's close caption instead of an app bar, and it sizes
  /// itself to the sheet rather than to a route.
  final bool asSheet;

  const CompareScreen({
    super.key,
    required this.productId,
    this.loader,
    this.notifyRequest,
    this.asSheet = false,
  });

  @override
  State<CompareScreen> createState() => _CompareScreenState();
}

class _CompareScreenState extends State<CompareScreen> {
  CompareTable? _data;
  bool _loading = true;

  /// The body's horizontal offset is the real one; the frozen header follows it.
  /// Two controllers, because one ScrollController cannot drive two viewports.
  final ScrollController _hBody = ScrollController();
  final ScrollController _hHead = ScrollController();
  final ScrollController _vBody = ScrollController();

  @override
  void initState() {
    super.initState();
    _hBody.addListener(_syncHeader);
    _load();
  }

  void _syncHeader() {
    if (!_hHead.hasClients || !_hBody.hasClients) return;
    if (_hHead.offset != _hBody.offset) _hHead.jumpTo(_hBody.offset);
  }

  @override
  void dispose() {
    _hBody.removeListener(_syncHeader);
    _hBody.dispose();
    _hHead.dispose();
    _vBody.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    CompareTable res;
    try {
      final load = widget.loader ??
          (id) => MedicineRepository().fetchSaltCompare(id);
      res = await load(widget.productId);
    } catch (_) {
      // A thrown call is indistinguishable from "nothing to compare" as far as
      // this page is concerned: the backend's empty copy, never a crash and
      // never a Dart-authored error string.
      res = CompareTable.failed;
    }
    if (!mounted) return;
    setState(() {
      _data = res;
      _loading = false;
    });

    // REACHABILITY PROOF. Flutter renders to canvas, so no browser tool can
    // read this table — the render log is how a live build proves the rows, the
    // columns and the two trade columns actually reached a real device.
    // CMD #2095 — the sheet's own proof. A sheet changes no URL, so this key
    // is what a live browser journey reads to know the table actually opened
    // over the product page, and in which door.
    RenderLog.write('c2095_compare_sheet',
        'sheet=${widget.asSheet};id=${widget.productId};rows=${res.rows.length}');

    RenderLog.write(
        'c2074_compare',
        'rows=${res.rows.length};cols=${res.columns.length};'
        'locked=${res.rows.where((r) => r.cell(_indexOf(res, 'sale')).locked).length};'
        'priced=${res.rows.where((r) => r.cell(_indexOf(res, 'margin')).has).length};'
        'drugtype=${res.rows.where((r) => r.cell(_indexOf(res, 'drugtype')).has).length};'
        'add=${res.rows.where((r) => r.ctaLabel.isNotEmpty).length}');
  }

  static int _indexOf(CompareTable t, String key) =>
      t.columns.indexWhere((c) => c.key == key);

  /// Spec 4 — the name opens the FULL product page, pushed on top of this one,
  /// so coming back lands on this same table with both scroll offsets and every
  /// quantity exactly as they were. Nothing is reloaded on return.
  void _openProduct(String id) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: '/product/$id'),
      builder: (_) => ProductDetailScreen(productId: id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final body = _loading
        ? const _CompareSkeleton()
        : (d == null || !d.ok)
            ? const SizedBox.shrink()
            : _CompareBody(
                data: d,
                hBody: _hBody,
                hHead: _hHead,
                vBody: _vBody,
                onOpen: _openProduct,
                notifyRequest: widget.notifyRequest,
              );

    if (!widget.asSheet) {
      return Scaffold(
        backgroundColor: Ds.c.bg,
        appBar: AppBar(
          backgroundColor: Ds.c.surface,
          surfaceTintColor: Ds.c.surface,
          elevation: Ds.space.hairline / 2,
          title: Text(d?.title ?? '', style: Ds.t.subtitle),
        ),
        body: body,
      );
    }

    // The sheet. A grab handle (the swipe-down target), the backend's title,
    // and the × carrying the backend's own close caption as its tooltip.
    return SizedBox(
      height: (d?.layout ?? CompareLayout.fallback)
          .sheetHeight(MediaQuery.of(context).size.height),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(top: Ds.space.x8),
            child: Container(
              width: Ds.space.x48,
              height: Ds.space.x4,
              decoration: BoxDecoration(
                color: Ds.c.divider,
                borderRadius: Ds.r.rChip,
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x8, Ds.space.x8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(d?.title ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.subtitle),
                ),
                IconButton(
                  key: const ValueKey('compare-close'),
                  tooltip: d?.closeLabel ?? '',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: Icon(Icons.close_rounded, color: Ds.c.textSecondary),
                ),
              ],
            ),
          ),
          Divider(height: Ds.space.hairline, color: Ds.c.divider),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _CompareBody extends StatelessWidget {
  final CompareTable data;
  final ScrollController hBody;
  final ScrollController hHead;
  final ScrollController vBody;
  final void Function(String id) onOpen;
  final NotifyRequest? notifyRequest;

  const _CompareBody({
    required this.data,
    required this.hBody,
    required this.hHead,
    required this.vBody,
    required this.onOpen,
    this.notifyRequest,
  });

  @override
  Widget build(BuildContext context) {
    final note = data.note;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (note.isNotEmpty)
          Padding(
            padding: EdgeInsets.fromLTRB(
                Ds.space.x16, Ds.space.x12, Ds.space.x16, Ds.space.x12),
            child: Text(note, style: Ds.t.caption),
          ),
        if (!data.has)
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: Ds.space.x16, vertical: Ds.space.x24),
            child: Text(data.empty, style: Ds.t.body),
          )
        else
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              // The ONE piece of arithmetic on this screen, and it is layout:
              // the frozen column takes the backend's share of whatever width
              // it is handed, inside the backend's own bounds. A 320px phone
              // and a desktop therefore draw the same table.
              final nameW = data.layout.nameWidth(box.maxWidth);
              final scroll = data.columns.where((c) => !c.frozen).toList();
              final scrollW =
                  scroll.fold<double>(0, (sum, c) => sum + c.width);
              return Column(
                children: [
                  _HeaderBand(
                      data: data,
                      nameW: nameW,
                      scrollW: scrollW,
                      scroll: scroll,
                      hHead: hHead),
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('compare-vscroll'),
                      controller: vBody,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // The frozen product-name column. It rides in the
                          // same vertical scroller as the data, so the two can
                          // never drift apart.
                          SizedBox(
                            width: nameW,
                            child: Column(
                              children: [
                                for (final r in data.rows)
                                  _NameCell(
                                      row: r,
                                      data: data,
                                      width: nameW,
                                      onOpen: onOpen),
                              ],
                            ),
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              key: const ValueKey('compare-hscroll'),
                              controller: hBody,
                              scrollDirection: Axis.horizontal,
                              child: SizedBox(
                                width: scrollW,
                                child: Column(
                                  children: [
                                    for (final r in data.rows)
                                      _DataRow(
                                          row: r,
                                          data: data,
                                          columns: scroll,
                                          notifyRequest: notifyRequest),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
      ],
    );
  }
}

/// The frozen header row. Its horizontal viewport is driven by the body's, and
/// it takes no gestures of its own — one finger, one offset.
class _HeaderBand extends StatelessWidget {
  final CompareTable data;
  final double nameW;
  final double scrollW;
  final List<CompareColumn> scroll;
  final ScrollController hHead;

  const _HeaderBand({
    required this.data,
    required this.nameW,
    required this.scrollW,
    required this.scroll,
    required this.hHead,
  });

  @override
  Widget build(BuildContext context) {
    final name = data.columns.isEmpty ? null : data.columns.first;
    return Container(
      height: data.layout.headH,
      decoration: BoxDecoration(
        color: Ds.c.surface,
        border: Border(bottom: BorderSide(color: Ds.c.divider)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: nameW,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(name?.label ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _headStyle),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: hHead,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: SizedBox(
                width: scrollW,
                child: Row(
                  children: [
                    for (final c in scroll)
                      SizedBox(
                        width: c.width,
                        child: Padding(
                          padding:
                              EdgeInsets.symmetric(horizontal: Ds.space.x8),
                          child: Align(
                            alignment: _alignOf(c),
                            child: Text(c.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: _textAlignOf(c),
                                style: _headStyle),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The frozen cell: the product name, and on the opened pack the backend's own
/// tag. Tapping it opens that product's full page.
class _NameCell extends StatelessWidget {
  final CompareTableRow row;
  final CompareTable data;
  final double width;
  final void Function(String id) onOpen;

  const _NameCell({
    required this.row,
    required this.data,
    required this.width,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) => Container(
        width: width,
        height: data.layout.rowH,
        decoration: BoxDecoration(
          color: row.isCurrent ? Ds.c.brandSoft : Ds.c.surface,
          border: Border(bottom: BorderSide(color: Ds.c.divider)),
        ),
        child: InkWell(
          key: ValueKey('compare-name-${row.id}'),
          onTap: () => onOpen(row.id),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    // CMD #2095 — regular, like every other value.
                    style: Ds.t.body),
                if (row.tag.isNotEmpty)
                  Text(row.tag,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Ds.t.caption),
              ],
            ),
          ),
        ),
      );
}

/// One product's scrolling cells, in column order. Nothing is looked up by
/// name: cell i belongs to column i, which is the contract the payload states.
class _DataRow extends StatelessWidget {
  final CompareTableRow row;
  final CompareTable data;
  final List<CompareColumn> columns;
  final NotifyRequest? notifyRequest;

  const _DataRow({
    required this.row,
    required this.data,
    required this.columns,
    this.notifyRequest,
  });

  @override
  Widget build(BuildContext context) {
    // The frozen column is index 0 of the payload, so a scrolling column's own
    // index is one past its position in this list.
    return Container(
      height: data.layout.rowH,
      decoration: BoxDecoration(
        color: row.isCurrent ? Ds.c.brandSoft : Ds.c.surface,
        border: Border(bottom: BorderSide(color: Ds.c.divider)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            SizedBox(
              width: columns[i].width,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Ds.space.x8),
                child: _Cell(
                    column: columns[i],
                    cell: row.cell(i + 1),
                    row: row,
                    layout: data.layout,
                    notifyRequest: notifyRequest),
              ),
            ),
        ],
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  final CompareColumn column;
  final CompareTableCell cell;
  final CompareTableRow row;
  final CompareLayout layout;
  final NotifyRequest? notifyRequest;

  const _Cell({
    required this.column,
    required this.cell,
    required this.row,
    required this.layout,
    this.notifyRequest,
  });

  /// The tone is a backend word. Anything it does not recognise falls back to
  /// body text — an unknown tone must never crash a table a pharmacy is
  /// reading mid-decision.
  Color _tone(String tone) {
    switch (tone) {
      case 'success':
        return Ds.c.success;
      case 'warning':
        return Ds.c.warning;
      case 'danger':
        return Ds.c.danger;
      case 'info':
        return Ds.c.info;
      default:
        return Ds.c.text;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (column.isAdd) {
      return _AddCell(
          row: row, layout: layout, notifyRequest: notifyRequest);
    }

    final align = _alignOf(column);

    // A pill because the PAYLOAD sent colours for this cell — the sale price
    // always, margin and profit only while they are locked. The app chooses no
    // fill of its own.
    if (cell.isPill) {
      return Align(
        alignment: align,
        child: Container(
          padding: EdgeInsets.symmetric(
              horizontal: Ds.space.x8, vertical: Ds.space.x4),
          decoration: BoxDecoration(
            color: _hexColor(cell.pillBg, Ds.c.bg),
            borderRadius: Ds.r.rChip,
          ),
          child: Text(cell.value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.body
                  .copyWith(color: _hexColor(cell.pillFg, Ds.c.text))),
        ),
      );
    }

    return Align(
      alignment: align,
      child: Text(
        cell.value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: _textAlignOf(column),
        // CMD #2095 — every VALUE is the regular body token, the same one the
        // product page's Product-overview card prints its right column in.
        // Only the headings are bold, so the table has one emphasis and the
        // eye can find the row it wants. The ink still carries the tone.
        style: Ds.t.body.copyWith(
          // has:false is the backend saying "we do not know this". It is drawn
          // in the secondary colour so a dash never reads as a measured value.
          color: cell.has ? _tone(cell.tone) : Ds.c.textSecondary,
        ),
      ),
    );
  }
}

/// The cart control, one per row.
///
/// CMD #2095 — it is ONE box, `compare_layout.ctrl_w` x `ctrl_h`, and all
/// three states draw inside it: the backend's ADD word, the - n + stepper that
/// replaces it, and Notify on a pack this buyer cannot add. ADD used to size
/// itself to its caption and the stepper to its arms, so a row visibly jumped
/// the moment a quantity appeared; the box is fixed now, so nothing moves.
///
/// Availability is the ROW's `can_add`, the backend's verdict — never a count
/// and never this file's opinion. Available -> the cart control. Unavailable
/// -> [NotifyControl], the SAME widget the card and the product page use, so
/// its words, its toast and its subscribed state stay the backend's.
class _AddCell extends StatelessWidget {
  final CompareTableRow row;
  final CompareLayout layout;
  final NotifyRequest? notifyRequest;
  const _AddCell(
      {required this.row, required this.layout, this.notifyRequest});

  @override
  Widget build(BuildContext context) {
    // Not addable: Notify takes the box, and it is the only control the row
    // gets. No word from the backend means no control — never one captioned
    // here.
    if (!row.canAdd) {
      if (row.notifyLabel.isEmpty) return const SizedBox.shrink();
      return Center(
        child: NotifyControl(
          key: ValueKey('compare-notify-${row.id}'),
          productId: row.id,
          initiallySubscribed: row.notifySubscribed,
          width: layout.ctrlW,
          height: layout.ctrlH,
          notifyLabel: row.notifyLabel,
          subscribedLabel: row.notifyDoneLabel,
          request: notifyRequest,
        ),
      );
    }

    if (row.ctaLabel.isEmpty) return const SizedBox.shrink();

    final cart = AppState.of(context);
    final qty = cart.quantityOf(row.id);

    if (qty > 0) {
      return Center(
        child: SizedBox(
          width: layout.ctrlW,
          height: layout.ctrlH,
          child: Material(
            color: Ds.c.brand,
            borderRadius: Ds.r.rChip,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _StepIcon(
                    icon: Icons.remove_rounded,
                    semantic: 'compare-minus-${row.id}',
                    height: layout.ctrlH,
                    onTap: () => cart.decrementId(row.id)),
                Text('$qty',
                    key: ValueKey('compare-qty-${row.id}'),
                    style: Ds.t.body.copyWith(color: Ds.c.surface)),
                _StepIcon(
                    icon: Icons.add_rounded,
                    semantic: 'compare-plus-${row.id}',
                    height: layout.ctrlH,
                    onTap: () => cart.incrementId(row.id)),
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: SizedBox(
        width: layout.ctrlW,
        height: layout.ctrlH,
        child: OutlinedButton(
          key: ValueKey('compare-add-${row.id}'),
          onPressed: () {
            if (cart.isPending(row.id)) return;
            cart.addId(row.id);
          },
          style: OutlinedButton.styleFrom(
            foregroundColor: Ds.c.brand,
            side: BorderSide(color: Ds.c.brand),
            padding: EdgeInsets.symmetric(horizontal: Ds.space.x4),
            shape: RoundedRectangleBorder(borderRadius: Ds.r.rChip),
          ),
          child: Text(row.ctaLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Ds.t.body.copyWith(color: Ds.c.brand)),
        ),
      ),
    );
  }
}

class _StepIcon extends StatelessWidget {
  final IconData icon;
  final String semantic;
  final double height;
  final VoidCallback onTap;
  const _StepIcon({
    required this.icon,
    required this.semantic,
    required this.height,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        key: ValueKey(semantic),
        onTap: onTap,
        child: SizedBox(
          // An arm is a third of the control's own box wide and its full
          // height, so the pair still clears the minimum in the direction a
          // thumb misses and the stepper is exactly as wide as ADD was.
          width: height * 0.75,
          height: height,
          child: Icon(icon, size: Ds.space.x16, color: Ds.c.surface),
        ),
      );
}

/// A skeleton, not a bare spinner (DESIGN.md): the shape of the table the
/// customer is about to read.
class _CompareSkeleton extends StatelessWidget {
  const _CompareSkeleton();

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.all(Ds.space.x16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < 6; i++)
              Padding(
                padding: EdgeInsets.only(bottom: Ds.space.x12),
                child: Container(
                  height: Ds.touch.minTarget,
                  decoration: BoxDecoration(
                    color: Ds.c.divider,
                    borderRadius: Ds.r.rCard,
                  ),
                ),
              ),
          ],
        ),
      );
}
