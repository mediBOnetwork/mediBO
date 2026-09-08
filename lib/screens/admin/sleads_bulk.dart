// CMD #1869 — the S Leads bulk lane's decisions, extracted from the 14k-line
// admin customer screen so they can be tested on the Dart VM.
//
// There is exactly one rule in this file and every method restates it: the
// BACKEND owns the words. `lead_leads_summary().bulk` carries every label, the
// class list, the class labels and the archive window; this class substitutes
// the selected count into the template the backend sent and hands the string
// back. It never composes a sentence, never pluralises, never names a lead
// class, and never decides what "archived" is called.

/// The `bulk` block of `lead_leads_summary()`, rendered.
class SLeadsBulk {
  final Map<String, dynamic> payload;

  const SLeadsBulk(this.payload);

  /// An absent key is an empty string, never a Dart fallback sentence: a label
  /// the backend did not send is a label that is not drawn.
  String label(String key, {int? n}) {
    final raw = payload[key]?.toString() ?? '';
    if (n == null) return raw;
    return raw.replaceAll('{n}', '$n');
  }

  /// The selected-count line. The backend sends the singular and the plural;
  /// picking between them is the only branch allowed here.
  String selectedLabel(int n) =>
      label(n == 1 ? 'selected_one' : 'selected_many', n: n);

  /// The pickable classes, in the backend's order.
  List<Map<String, String>> get classes {
    final raw = payload['classes'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => {
              'key': e['key']?.toString() ?? '',
              'label': e['label']?.toString() ?? '',
            })
        .where((e) => (e['key'] ?? '').isNotEmpty)
        .toList();
  }

  /// A class the backend did not describe prints as its own key — verbatim,
  /// never invented, never expanded.
  String classLabel(String key) {
    for (final c in classes) {
      if (c['key'] == key) {
        final l = c['label'] ?? '';
        return l.isEmpty ? key : l;
      }
    }
    return key;
  }

  /// The archive window, for the copy that mentions it. 0 when the backend
  /// said nothing — the UI shows the backend's own sentence either way.
  int get archiveDays => (payload['archive_days'] as num?)?.toInt() ?? 0;

  int get archivedCount => (payload['archived_count'] as num?)?.toInt() ?? 0;

  /// Archive and Restore are the same button in two states. The UI can never
  /// hard-delete a lead, so 'delete' is not one of the options.
  String primaryActionKey(bool archivedView) =>
      archivedView ? 'restore' : 'archive';

  String primaryActionLabel(bool archivedView, int n) =>
      label(archivedView ? 'restore_label' : 'archive_label', n: n);

  String reclassifyLabel(int n) => label('reclassify_label', n: n);

  /// The confirm sheet's title carries the count, its body the day window —
  /// both already substituted server-side except for {n}.
  String confirmTitle(int n) => label('confirm_title', n: n);

  /// The filter-state key the Archived view lives under. It is a FILTER, not
  /// a screen mode: it normalises, pages, counts and saves into a view like
  /// every other filter, and `sleads_page` turns it into
  /// `get_scraped_leads(p_status => 'archived')`. Every other call hides
  /// archived leads, so this key is the only way to see them.
  static const String archivedKey = 'archived';

  static bool isArchivedView(Map<String, dynamic> filters) =>
      filters[archivedKey] == true;

  /// Whether THIS row is archived — the backend flags it per row, so a card
  /// never infers it from which filter happens to be on.
  static bool rowArchived(Map<String, dynamic> row) => row['archived'] == true;
}

/// Multi-select on the lead grid: long-press enters it, a tap toggles inside
/// it, and clearing the last lead leaves it.
class SLeadsSelection {
  final Set<int> ids = <int>{};
  bool mode = false;

  bool get isActive => mode || ids.isNotEmpty;
  int get length => ids.length;
  bool contains(int id) => ids.contains(id);

  /// Long-press: enter select mode with this lead picked. Repeating it on an
  /// already-picked lead is a no-op, never a deselect.
  void enter(int id) {
    mode = true;
    ids.add(id);
  }

  /// Tap while selecting. Removing the last lead leaves select mode, so one
  /// stray tap cannot strand an empty toolbar over the grid.
  void toggle(int id) {
    if (ids.remove(id)) {
      if (ids.isEmpty) mode = false;
      return;
    }
    mode = true;
    ids.add(id);
  }

  void selectAll(Iterable<int> all) {
    mode = true;
    ids.addAll(all);
  }

  void clear() {
    ids.clear();
    mode = false;
  }

  /// After a successful bulk call: the rows that moved leave the selection.
  void removeAll(Iterable<int> done) {
    ids.removeAll(done);
    if (ids.isEmpty) mode = false;
  }
}
