// CMD #2056 — where a Dashboard tile lands inside the Customers page.
//
// A registry row's `tab_screen` names a sub-tab ('leads'), and since Routes
// moved to the Dashboard as THREE doors onto ONE screen it may also name a
// SECTION of that sub-tab: `routes:all_plans`, `routes:past_plans`,
// `routes:today`. The pair is the BACKEND's — which doors exist, what each is
// called and which section it opens are all rows, not code. All Dart does is
// split the pair and look up which part of the widget the section names.
//
// Pure: no Flutter, no Supabase, so the protected suite proves it on the VM.

/// The two halves of a registry `tab_screen`.
class CustomerTabTarget {
  /// The sub-tab, matched against `_CustFilter.values` by name.
  final String tab;

  /// The section of that sub-tab, or '' when the row named none.
  final String section;

  const CustomerTabTarget(this.tab, this.section);

  /// Splits `<tab>[:<section>]`. A value with no colon is a plain sub-tab; a
  /// leading colon is not a section (there is no tab to open), and everything
  /// after the FIRST colon is the section, so a key may contain one.
  static CustomerTabTarget parse(String? tabScreen) {
    final raw = (tabScreen ?? '').trim();
    if (raw.isEmpty) return const CustomerTabTarget('', '');
    final i = raw.indexOf(':');
    if (i < 0) return CustomerTabTarget(raw, '');
    // A leading colon names a section with no tab to open it in — nothing.
    if (i == 0) return const CustomerTabTarget('', '');
    return CustomerTabTarget(raw.substring(0, i), raw.substring(i + 1));
  }

  bool get hasSection => section.isNotEmpty;

  @override
  String toString() => hasSection ? '$tab:$section' : tab;
}

/// The sections of the Routes sub-tab a tile may ask for, and which top-level
/// mode of that screen each one is.
///
/// Three keys are the mode row's own — `routes_today().links[]` speaks
/// 'today', 'all_plans' and 'my_route'. 'past_plans' is the collapsible inside
/// the builder where a plan is handed to a worker, which is what "Assign
/// route" opens. A key this build has never heard of resolves to null and is
/// IGNORED, so a fourth door is an INSERT plus one line here.
const Map<String, String> kRoutesSectionModes = {
  'today': 'today',
  'all_plans': 'builder',
  'past_plans': 'builder',
  'my_route': 'myRoute',
};
