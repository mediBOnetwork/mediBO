// CMD #411 — the pharmacy counter's one door to the backend.
//
// The counter is the anchor of the free shop-management layer: a mediBO
// pharmacy bills a walk-in patient on its OWN GSTIN and prints its own tax
// invoice. Every rupee, percentage, label and plural on that screen is built in
// Supabase (`pos_price_bill`) and rendered verbatim — this file forwards calls
// and hands back payloads, and computes nothing.
//
// The one thing it owns beyond forwarding is the OFFLINE QUEUE below, and even
// that decides no money: it stores the exact payload the operator confirmed and
// replays it byte-for-byte until the backend acknowledges it.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Signature every POS surface accepts, so a test hands it a payload instead of
/// a network.
typedef PosRpc =
    Future<Map<String, dynamic>> Function(
      String fn,
      Map<String, dynamic> params,
    );

class PosApi {
  PosApi._();

  static Future<Map<String, dynamic>> call(
    String fn,
    Map<String, dynamic> params,
  ) async {
    final raw = await Supabase.instance.client.rpc(
      fn,
      params: params.isEmpty ? null : params,
    );
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    return map is Map ? Map<String, dynamic>.from(map) : <String, dynamic>{};
  }

  /// Is this account a pharmacy, and what does its menu entry say? One cheap
  /// call at boot — the shell holds no label and makes no role test.
  static Future<Map<String, dynamic>> entry() => call('pos_entry', const {});

  static Future<Map<String, dynamic>> home() => call('pos_home', const {});

  static Future<Map<String, dynamic>> search(String q, {int limit = 20}) =>
      call('pos_search', {'p_q': q, 'p_limit': limit});

  static Future<Map<String, dynamic>> scan(String barcode) =>
      call('pos_scan', {'p_barcode': barcode});

  /// The live bill while the operator types. Same engine the commit uses, so
  /// the saved bill can never disagree with the screen.
  static Future<Map<String, dynamic>> quote(
    List<Map<String, dynamic>> lines,
    num billDiscountPct,
  ) => call('pos_quote', {
    'p_lines': lines,
    'p_bill_discount_pct': billDiscountPct,
  });

  static Future<Map<String, dynamic>> commit(Map<String, dynamic> sale) =>
      call('pos_commit_sale', sale);

  static Future<Map<String, dynamic>> saleDetail(String saleId) =>
      call('pos_sale_detail', {'p_sale_id': saleId});

  static Future<Map<String, dynamic>> invoiceRequest(String saleId) =>
      call('pos_invoice_request', {'p_sale_id': saleId});

  static Future<Map<String, dynamic>> invoiceWhatsApp(
    String saleId,
    String phone,
  ) => call('pos_invoice_wa', {'p_sale_id': saleId, 'p_phone': phone});

  static Future<Map<String, dynamic>> dayClose({String? date}) => call(
    'pos_day_close',
    date == null || date.isEmpty ? const {} : {'p_date': date},
  );

  /// The backend names the bucket and the path; this signs it. An empty pair is
  /// an empty URL, never a guessed one.
  static Future<String> signedUrl(
    String bucket,
    String path, {
    int expiresIn = 300,
  }) async {
    if (bucket.isEmpty || path.isEmpty) return '';
    return Supabase.instance.client.storage
        .from(bucket)
        .createSignedUrl(path, expiresIn);
  }
}

/// ONE pending bill, exactly as the operator confirmed it.
///
/// `clientActionId` is minted the moment Save is tapped — BEFORE the app knows
/// whether the network is up — and it is what makes a replay safe: the backend
/// holds a UNIQUE constraint on it, so the second, third and tenth attempt all
/// resolve to the sale the first one wrote. Same invoice number, same PDF,
/// applied once.
class PosPendingSale {
  final String clientActionId;
  final Map<String, dynamic> payload;
  final int queuedAtMs;

  const PosPendingSale({
    required this.clientActionId,
    required this.payload,
    required this.queuedAtMs,
  });

  Map<String, dynamic> toJson() => {
    'client_action_id': clientActionId,
    'payload': payload,
    'queued_at_ms': queuedAtMs,
  };

  static PosPendingSale? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['client_action_id'];
    final p = raw['payload'];
    if (id is! String || id.isEmpty || p is! Map) return null;
    final t = raw['queued_at_ms'];
    return PosPendingSale(
      clientActionId: id,
      payload: Map<String, dynamic>.from(p),
      queuedAtMs: t is num ? t.toInt() : 0,
    );
  }
}

/// The offline queue. Billing must not stop when the network drops, so a sale
/// the operator confirmed is written to disk FIRST and posted second.
///
/// Deliberately not optimistic about anything else: the queue stores the
/// payload and the id, never a total, never an invoice number. Those are the
/// backend's to mint, and a replayed sale gets the ones it was given the first
/// time. `shared_preferences`, not `dart:html` — a web-only import in a file
/// the widget tree reaches white-screens the dart2js build.
class PosOfflineQueue {
  PosOfflineQueue._();

  static const String _key = 'pos_pending_sales_v1';

  static Future<List<PosPendingSale>> pending() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(PosPendingSale.fromJson)
          .whereType<PosPendingSale>()
          .toList();
    } catch (_) {
      // A corrupt queue must never brick the counter.
      return const [];
    }
  }

  static Future<void> _write(List<PosPendingSale> rows) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_key, jsonEncode(rows.map((r) => r.toJson()).toList()));
  }

  /// Park a confirmed sale. Re-parking the same id replaces it rather than
  /// queueing it twice.
  static Future<void> enqueue(PosPendingSale sale) async {
    final rows = (await pending()).toList()
      ..removeWhere((r) => r.clientActionId == sale.clientActionId);
    rows.add(sale);
    await _write(rows);
  }

  static Future<void> remove(String clientActionId) async {
    final rows = (await pending()).toList()
      ..removeWhere((r) => r.clientActionId == clientActionId);
    await _write(rows);
  }

  /// Replay everything parked, oldest first. A row is dropped ONLY when the
  /// backend answered — `ok:true` (fresh or replayed) or a refusal it will give
  /// again forever (a validation error). A network failure leaves it queued.
  static Future<PosReplayResult> replay({PosRpc? rpc}) async {
    final call = rpc ?? PosApi.call;
    final rows = (await pending()).toList()
      ..sort((a, b) => a.queuedAtMs.compareTo(b.queuedAtMs));
    var applied = 0, alreadyThere = 0, dropped = 0;
    for (final row in rows) {
      Map<String, dynamic> res;
      try {
        res = await call('pos_commit_sale', row.payload);
      } catch (_) {
        // Still offline (or the server is down) — keep it and stop; the order
        // the operator billed in is the order it must land in.
        break;
      }
      final ok = res['ok'] == true;
      if (ok) {
        if (res['replayed'] == true) {
          alreadyThere++;
        } else {
          applied++;
        }
        await remove(row.clientActionId);
      } else if (PosReplayResult.isPermanent(res['error'])) {
        dropped++;
        await remove(row.clientActionId);
      } else {
        break;
      }
    }
    return PosReplayResult(
      applied: applied,
      alreadyApplied: alreadyThere,
      dropped: dropped,
    );
  }
}

/// What one replay pass did. The counter renders this, it does not infer it.
class PosReplayResult {
  final int applied;
  final int alreadyApplied;
  final int dropped;

  const PosReplayResult({
    required this.applied,
    required this.alreadyApplied,
    required this.dropped,
  });

  bool get didAnything => applied + alreadyApplied + dropped > 0;

  /// Refusals the backend will repeat forever — replaying them is pointless, so
  /// the row leaves the queue instead of blocking every sale behind it. A
  /// transport failure is NOT in this set.
  static const Set<String> _permanent = {
    'no_lines',
    'bad_qty',
    'no_price',
    'unknown_medicine',
    'no_action_id',
    'not_a_pharmacy',
  };

  static bool isPermanent(Object? error) =>
      error is String && _permanent.contains(error);
}
