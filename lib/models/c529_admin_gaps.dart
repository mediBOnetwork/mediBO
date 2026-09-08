/// CHANGE #529 — the decision layer for the eight approved medium/admin
/// feature_gaps rows (13, 16, 21, 22, 36, 37, 38, 39).
///
/// Every one of those gaps was the same shape: the backend knew something the
/// screen never printed, or the screen inferred something the backend already
/// owned. So each view here PARSES a payload and computes nothing — no status
/// derived from a count, no label built from a number, no tone picked in Dart.
/// The only arithmetic in this file is hex-string parsing, because a colour has
/// to become a Color somewhere.
library;

import 'package:flutter/material.dart';

/// Backend-supplied '#RRGGBB' → Color. Falls back rather than inventing a hue.
Color c529Hex(dynamic v, Color fallback) {
  final s = (v ?? '').toString().replaceAll('#', '').trim();
  if (s.length != 6) return fallback;
  final n = int.tryParse(s, radix: 16);
  if (n == null) return fallback;
  return Color.fromARGB(255, (n >> 16) & 0xFF, (n >> 8) & 0xFF, n & 0xFF);
}

/// GAP 16 — `bags.status` was a column nobody advanced: all 500 rows read
/// 'empty' while 293 order_items carried a bag_no. `bags_list()` now PROJECTS
/// the status from what is actually in the bag and sends its own label, tone
/// and count copy. The card prints them; it never counts anything itself.
class BagRowView {
  final int bagNo;
  final String bagCode;
  final String status;
  final String statusLabel;
  final String countLabel;
  final dynamic statusBg;
  final dynamic statusFg;
  final int itemCount;

  const BagRowView({
    required this.bagNo,
    required this.bagCode,
    required this.status,
    required this.statusLabel,
    required this.countLabel,
    required this.statusBg,
    required this.statusFg,
    required this.itemCount,
  });

  factory BagRowView.from(Map<String, dynamic> j) => BagRowView(
        bagNo: (j['bag_no'] as num?)?.toInt() ?? 0,
        bagCode: (j['bag_code'] ?? '').toString(),
        status: (j['status'] ?? '').toString(),
        statusLabel: (j['status_label'] ?? '').toString(),
        countLabel: (j['count_label'] ?? '').toString(),
        statusBg: j['status_bg'],
        statusFg: j['status_fg'],
        itemCount: (j['item_count'] as num?)?.toInt() ?? 0,
      );

  /// A chip is drawn only when the BACKEND sent a label for it — an absent
  /// label is an absence, never a default word.
  bool get hasChip => statusLabel.isNotEmpty;
}

/// GAP 38 — 8 of 35 approved suppliers had no lat/lng, so a collect run could
/// only reach them from memory, and `admin_missing_locations()` covered
/// customers only. The supplier bucket now arrives with its OWN title and note.
class MissingLocationsView {
  final String title;
  final String note;
  final List<Map<String, dynamic>> rows;
  final int supplierMissingCount;
  final String supplierTitle;
  final String supplierNote;
  final List<Map<String, dynamic>> supplierRows;

  const MissingLocationsView({
    required this.title,
    required this.note,
    required this.rows,
    required this.supplierMissingCount,
    required this.supplierTitle,
    required this.supplierNote,
    required this.supplierRows,
  });

  static List<Map<String, dynamic>> _list(dynamic v) => v is List
      ? v.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      : const [];

  factory MissingLocationsView.from(Map<String, dynamic> j) => MissingLocationsView(
        title: (j['title'] ?? '').toString(),
        note: (j['note'] ?? '').toString(),
        rows: _list(j['rows']),
        supplierMissingCount: (j['supplier_missing_count'] as num?)?.toInt() ?? 0,
        supplierTitle: (j['supplier_title'] ?? '').toString(),
        supplierNote: (j['supplier_note'] ?? '').toString(),
        supplierRows: _list(j['supplier_rows']),
      );

  /// The banner opens on EITHER bucket: a supplier with no pin is exactly as
  /// unroutable as a customer with none.
  bool get hasAnything => rows.isNotEmpty || supplierRows.isNotEmpty;
  bool get hasSupplierBucket => supplierRows.isNotEmpty;

  /// Which RPC a row saves through, and under which id key. The screen must
  /// never guess this from the shape of the row.
  static String rpcFor({required bool isSupplier}) =>
      isSupplier ? 'admin_supplier_set_location' : 'pharmacy_set_location';
  static String idKeyFor({required bool isSupplier}) =>
      isSupplier ? 'p_supplier_id' : 'p_pharmacy_id';
}

/// GAP 21 — a bill was tied to its supplier by a lowercased NAME string even
/// though `pending_bills.supplier_id` exists, so 6 of 18 bills (and one with a
/// NULL name) could never be scoped to a zone and a zone-scoped admin never
/// counted them. They are now their own bucket, carrying the backend's label.
class UnresolvedBillsTile {
  final int count;
  final String label;

  const UnresolvedBillsTile({required this.count, required this.label});

  factory UnresolvedBillsTile.from(Map<String, dynamic> j) => UnresolvedBillsTile(
        count: (j['unresolved_bills'] as num?)?.toInt() ?? 0,
        label: (j['unresolved_bills_label'] ?? '').toString(),
      );

  /// Shown only when the backend both counted something AND named it. A count
  /// with no label would mean writing the word here, which is the bug.
  bool get show => count > 0 && label.isNotEmpty;
}

/// GAP 13 / GAP 22 — a zone-scoped list used to just be shorter, with nothing
/// saying so. Every scoped payload now reports what it hid, in the backend's
/// own words.
class ScopeHiddenNote {
  final int hidden;
  final String note;

  const ScopeHiddenNote({required this.hidden, required this.note});

  factory ScopeHiddenNote.from(Map<String, dynamic> j) => ScopeHiddenNote(
        hidden: (j['hidden_by_scope'] as num?)?.toInt() ?? 0,
        note: (j['hidden_note'] ?? '').toString(),
      );

  bool get show => hidden > 0 && note.isNotEmpty;
}

/// GAP 36 / GAP 37 — a dispute could sit unanswered for weeks with no ageing,
/// no reminder and no escalation, and the short-supply reminder RPC had ZERO
/// callers. Ageing, the reminder sentence and the reminder ACTION now all
/// arrive on the dispute payload.
class DisputeAgeView {
  final int waitedHours;
  final String waitedLabel;
  final bool breached;
  final bool escalate;
  final String reminderLabel;
  final Map<String, dynamic>? ageChip;
  final List<Map<String, dynamic>> adminActions;

  const DisputeAgeView({
    required this.waitedHours,
    required this.waitedLabel,
    required this.breached,
    required this.escalate,
    required this.reminderLabel,
    required this.ageChip,
    required this.adminActions,
  });

  factory DisputeAgeView.from(Map<String, dynamic> j) => DisputeAgeView(
        waitedHours: (j['waited_hours'] as num?)?.toInt() ?? 0,
        waitedLabel: (j['waited_label'] ?? '').toString(),
        breached: j['breached'] == true,
        escalate: j['escalate'] == true,
        reminderLabel: (j['reminder_label'] ?? '').toString(),
        ageChip: j['age_chip'] is Map
            ? Map<String, dynamic>.from(j['age_chip'] as Map)
            : null,
        adminActions: j['admin_actions'] is List
            ? (j['admin_actions'] as List)
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList()
            : const [],
      );

  /// The reminder button exists only because the BACKEND put the action on the
  /// row — it is never synthesised from `is_active` here.
  Map<String, dynamic>? get shortReminderAction {
    for (final a in adminActions) {
      if ((a['code'] ?? '').toString() == 'short_reminder') return a;
    }
    return null;
  }

  bool get hasShortReminder => shortReminderAction != null;
  String get shortReminderLabel =>
      (shortReminderAction?['label'] ?? '').toString();
}
