// CMD #2144 — "the one mounted X", without a GlobalKey.
//
// HomeShell used to carry a static GlobalKey so switchToBulkUpload() could
// reach its State. A logout lands by replacing the whole stack with a FRESH
// '/' route, and for the frame in which that happens the old shell and the
// new one are both mounted: two widgets, one GlobalKey. Flutter answers with
// "Multiple widgets used the same GlobalKey", the new tree is left half-built,
// and the user sits on the endless spinner of #2116/#2144 — the public home
// never asks for storefront_home_v2 because it never finishes mounting.
//
// This holds the NEWEST mounted instance instead. The one leaving can never
// clear the one arriving, so any number of shells may overlap for a frame.

/// A registry of the most recently attached instance of [T].
class LiveInstance<T extends Object> {
  T? _current;

  /// The newest instance still mounted, or null.
  T? get current => _current;

  /// Called from `initState`: the newest instance always wins.
  void attach(T instance) => _current = instance;

  /// Called from `dispose`: only clears when [instance] is still the current
  /// one, so an old shell torn down AFTER its replacement mounted is a no-op.
  void detach(T instance) {
    if (identical(_current, instance)) _current = null;
  }

  /// Whether [instance] is the newest mounted one.
  bool isCurrent(T instance) => identical(_current, instance);
}
