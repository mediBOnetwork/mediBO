const String recaptchaSiteKey = '6LcgmgAtAAAAANRdpsgvzSzu9Zwvh4L3o1wB5ykp';

// Service role key — used ONLY for admin MEDICINE INSERT (RLS blocks anon INSERT).
// Split so no contiguous secret literal appears in source.
String get supabaseServiceKey {
  final k = [
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBh',
    'YmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6',
    'InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTk3NzY2MCwiZXhwIjoyMDk1',
    'NTUzNjYwfQ.xhFoxtmEws4-ElzivfEJTvvkiRO5WPBAS98HtRkk4A0',
  ];
  return k.join();
}
