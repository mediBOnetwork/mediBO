import 'package:supabase_flutter/supabase_flutter.dart';

// SPN option = one selectable (label, points) pair for a given field.
// field ∈ {'margin','cd_condition','behaviour','payment_term'}.
class SpnOption {
  final String label;
  final int points;
  const SpnOption(this.label, this.points);

  @override
  bool operator ==(Object other) =>
      other is SpnOption && other.label == label && other.points == points;

  @override
  int get hashCode => Object.hash(label, points);

  @override
  String toString() => label;
}

// DB column that stores the points for each SPN field's label column.
// (payment_term UI key writes label to the payment_type column, matching
// the pre-existing label-column mapping used by the inline SPN editor.)
const Map<String, String> spnLabelColumn = {
  'margin': 'margin',
  'cd_condition': 'cd_condition',
  'behaviour': 'behaviour',
  'payment_term': 'payment_type',
};

const Map<String, String> spnPointsColumn = {
  'margin': 'margin_points',
  'cd_condition': 'cd_points',
  'behaviour': 'behaviour_points',
  'payment_term': 'payment_term_points',
};

const Map<String, String> spnFieldDisplayLabel = {
  'margin': 'Margin',
  'cd_condition': 'CD Condition',
  'behaviour': 'Behaviour',
  'payment_term': 'Payment Term',
};

// Process-wide cache of spn_options rows, grouped by field. One RPC call
// populates every SpnDropdown; addSpnOption() updates the cache in place so
// newly-added options show up immediately without a full refetch.
class SpnOptionsCache {
  SpnOptionsCache._();
  static final SpnOptionsCache instance = SpnOptionsCache._();

  Map<String, List<SpnOption>>? _cache;
  Future<Map<String, List<SpnOption>>>? _inFlight;

  Future<Map<String, List<SpnOption>>> fetch({bool forceRefresh = false}) {
    if (!forceRefresh && _cache != null) return Future.value(_cache);
    if (!forceRefresh && _inFlight != null) return _inFlight!;
    final fut = _fetchNow();
    _inFlight = fut;
    return fut;
  }

  Future<Map<String, List<SpnOption>>> _fetchNow() async {
    try {
      final rows = await Supabase.instance.client.rpc('spn_options_list') as List;
      final map = <String, List<SpnOption>>{};
      for (final r in rows) {
        final row = r as Map<String, dynamic>;
        final field = row['field'] as String;
        final label = row['label'] as String;
        final points = (row['points'] as num).toInt();
        (map[field] ??= []).add(SpnOption(label, points));
      }
      _cache = map;
      return map;
    } finally {
      _inFlight = null;
    }
  }

  List<SpnOption> cacheFor(String field) => _cache?[field] ?? const [];

  Future<SpnOption> addSpnOption(String field, String label, int points) async {
    final row = await Supabase.instance.client.rpc('spn_option_add', params: {
      'p_field': field,
      'p_label': label,
      'p_points': points,
    }).single();
    final opt = SpnOption(row['label'] as String, (row['points'] as num).toInt());
    final map = _cache ??= <String, List<SpnOption>>{};
    final list = List<SpnOption>.from(map[field] ?? const []);
    list.removeWhere((o) => o.label == opt.label);
    list.add(opt);
    list.sort((a, b) => a.points.compareTo(b.points));
    map[field] = list;
    return opt;
  }
}
