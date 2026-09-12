/// CHANGE #176 — the only decisions the Rewards screen is allowed to make.
///
/// The loyalty engine is entirely backend: tiers, points, targets, streaks and
/// referrals are computed in Postgres and arrive as finished sentences with ₹
/// already formatted. What is left on the client is one question — which
/// sections exist in this payload — and that is what this class answers, as
/// pure Dart so `test/protected/loyalty_test.dart` can hold it down without a
/// widget tree or a network.
///
/// The rule everywhere below: absence is explicit. A programme that is off
/// arrives as `{"on": false}` and yields no section; a missing key is treated
/// as off rather than guessed at. Nothing here computes a total, picks a tier,
/// formats a rupee or pluralises a word.
library;

/// One rendered section of the Rewards screen, in payload order.
class RewardsSection {
  /// Stable identifier: tier | points | targets | streak | referral.
  final String key;

  /// The heading, exactly as the backend sent it.
  final String title;

  /// That section's slice of the payload, untouched.
  final Map<String, dynamic> data;

  const RewardsSection({
    required this.key,
    required this.title,
    required this.data,
  });
}

class RewardsView {
  final Map<String, dynamic> payload;
  const RewardsView(this.payload);

  /// The five programmes in the order the screen stacks them. This list is the
  /// only place the order is stated.
  static const List<String> kOrder = <String>[
    'tier',
    'points',
    'targets',
    'streak',
    'referral',
  ];

  static Map<String, dynamic> asMap(Object? raw) => raw is Map
      ? Map<String, dynamic>.from(raw)
      : (raw is List && raw.isNotEmpty && raw.first is Map
          ? Map<String, dynamic>.from(raw.first as Map)
          : <String, dynamic>{});

  /// A string straight out of the payload. Never a Dart default — an absent
  /// string renders as empty, which the screen then omits.
  String str(String key) => (payload[key] ?? '').toString();

  Map<String, dynamic> section(String key) => asMap(payload[key]);

  /// True only when the backend said so. Anything else — false, missing, a
  /// string, a number — is off.
  bool isOn(String key) => section(key)['on'] == true;

  /// The screen's empty state is the backend's, not ours.
  bool get anyOn => payload['any_on'] == true;

  bool get hasAccount => payload['has_account'] == true;

  /// Sections to build, in [kOrder], skipping every programme that is off.
  /// A section whose title is absent still renders — the heading is simply
  /// empty — because hiding a live programme would be worse than a blank
  /// heading, and the backend owns that copy.
  List<RewardsSection> get sections {
    final out = <RewardsSection>[];
    for (final key in kOrder) {
      if (!isOn(key)) continue;
      final data = section(key);
      out.add(RewardsSection(
        key: key,
        title: (data['title'] ?? '').toString(),
        data: data,
      ));
    }
    return out;
  }

  /// Rows inside a list-shaped section (currently only `targets.items`),
  /// in payload order — never re-sorted here.
  static List<Map<String, dynamic>> items(Map<String, dynamic> section) {
    final raw = section['items'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  /// Redeeming is the backend's call: it sends `can_redeem` having already
  /// checked the balance, the minimum and whether points are even running.
  static bool canRedeem(Map<String, dynamic> points) =>
      points['can_redeem'] == true;
}
