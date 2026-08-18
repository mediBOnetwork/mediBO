// CHANGE #238 — the customer-order item panel's ONLY decisions, in one pure,
// testable place.
//
// The panel used to build its own list: it parsed `orders.items` JSONB into
// Dart objects, then joined those against a status RPC by lower-cased,
// whitespace-collapsed product NAME. An item whose JSONB name differed by so
// much as a double space lost its status, its supplier and its unfulfillable
// flag — and the panel showed a dash where the answer should have been. That
// join was also the app deciding what the order contains.
//
// `order_item_status_panel(order_id)` now returns one line per order_items row,
// in the backend's own order, with every visible string already decided:
// status_label, supplier_label, next_supplier_label, po_warning, qty_label,
// price_label — plus a reconciliation block saying whether every customer item
// is accounted for. This class does exactly three things:
//
//   • carries the payload through untouched (no sort, no filter, no rename),
//   • answers "is this string present?" so the widget can skip a token the
//     backend withheld instead of printing an empty box or the word "null",
//   • says whether the banner should be drawn at all.
//
// It computes no label, no colour and no count of its own. If you find
// yourself adding an `if` that produces WORDS here, it belongs in the backend.

/// One rendered item row, straight off `lines[]`.
class OrderItemPanelLine {
  final Map<String, dynamic> raw;
  const OrderItemPanelLine(this.raw);

  String _s(String k) => (raw[k] ?? '').toString().trim();

  String get productName => _s('product_name');
  String get imageUrl => _s('image_url');
  String get company => _s('company');
  String get packLabel => _s('pack_label');
  String get qtyLabel => _s('qty_label');
  String get priceLabel => _s('price_label');

  /// The backend's machine key for this line's state:
  /// supplier_assigned | unfulfillable | in_inquiry | cancelled | unaccounted.
  /// Used only to route behaviour — never to pick a word or a colour.
  String get state => _s('state');

  /// The words on the status chip. Already resolves to the unfulfillable
  /// reason, the live inquiry status, or the backend's "not accounted for".
  String get statusLabel => _s('status_label');
  Map<String, dynamic> get statusColors => raw['status_colors'] is Map
      ? (raw['status_colors'] as Map).cast<String, dynamic>()
      : const <String, dynamic>{};

  /// "Accepted by X" once a supplier has taken the line, "Asking X" while the
  /// waterfall is still on X. One backend phrase; the app never assembles it
  /// and never decides which of the two is happening.
  String get supplierLabel => _s('supplier_label');
  bool get hasSupplier => raw['has_supplier'] == true && supplierLabel.isNotEmpty;

  String get nextSupplierLabel => _s('next_supplier_label');
  String get poWarning => _s('po_warning');

  /// The red card. `unaccounted` is the state this whole change exists to make
  /// visible: an item with no supplier, no inquiry and no unfulfillable reason
  /// used to render as an ordinary white row while it was missing from every
  /// purchase order.
  bool get isFlagged => raw['unfulfillable'] == true || state == 'unaccounted';
}

/// The reconciliation banner. Every number and every word is the backend's.
class OrderItemPanelReconcile {
  final Map<String, dynamic> raw;
  const OrderItemPanelReconcile(this.raw);

  String _s(String k) => (raw[k] ?? '').toString().trim();

  String get label => _s('label');
  String get detail => _s('detail');
  bool get balanced => raw['balanced'] == true;

  /// Drawn only when the backend both asked for it and gave it words.
  bool get show => raw['show'] == true && label.isNotEmpty;
}

/// The whole panel payload.
class OrderItemPanelView {
  final List<OrderItemPanelLine> lines;
  final OrderItemPanelReconcile reconcile;

  /// True once a real response has been stored — distinct from "the order has
  /// no items". An expanding row must show a skeleton, not an empty state it is
  /// about to contradict.
  final bool loaded;

  /// The backend's error copy, or empty when there was none. A failure is a
  /// THIRD state: not loading, and emphatically not "this order has no items" —
  /// printing an empty order for an order of eighteen is the same class of lie
  /// this whole change exists to stop.
  final String errorMessage;

  const OrderItemPanelView({
    required this.lines,
    required this.reconcile,
    required this.loaded,
    this.errorMessage = '',
  });

  static const OrderItemPanelView loading = OrderItemPanelView(
    lines: <OrderItemPanelLine>[],
    reconcile: OrderItemPanelReconcile(<String, dynamic>{}),
    loaded: false,
  );

  /// The RPC threw, or answered with an `error` key. `message` is the backend's
  /// copy — the caller passes it in rather than this class inventing words.
  factory OrderItemPanelView.failed(String message) => OrderItemPanelView(
        lines: const <OrderItemPanelLine>[],
        reconcile: const OrderItemPanelReconcile(<String, dynamic>{}),
        loaded: true,
        errorMessage: message,
      );

  bool get hasError => errorMessage.isNotEmpty;

  /// Parse one `order_item_status_panel` reply. Order is the payload's — this
  /// never sorts, never groups and never drops a line.
  factory OrderItemPanelView.fromPayload(Object? payload,
      {String errorFallback = ''}) {
    final one = payload is List
        ? (payload.isEmpty ? null : payload.first)
        : payload;
    if (one is! Map) return loading;
    final map = one.cast<String, dynamic>();
    // `{"error": "not_authorized"}` is a FAILURE, not an empty order. Parsing
    // it as `lines: []` printed "No items recorded" over a full order.
    final err = (map['error'] ?? '').toString().trim();
    if (err.isNotEmpty) {
      return OrderItemPanelView.failed(
          errorFallback.isNotEmpty ? errorFallback : err);
    }
    final raw = (map['lines'] as List<dynamic>?) ?? const <dynamic>[];
    return OrderItemPanelView(
      lines: raw
          .whereType<Map>()
          .map((m) => OrderItemPanelLine(m.cast<String, dynamic>()))
          .toList(growable: false),
      reconcile: OrderItemPanelReconcile(map['reconcile'] is Map
          ? (map['reconcile'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{}),
      loaded: true,
    );
  }

  bool get isEmpty => loaded && !hasError && lines.isEmpty;
}
