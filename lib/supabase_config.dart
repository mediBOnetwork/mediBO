/// Supabase connection settings.
///
/// The anon key is a public, client-side key protected by Row Level Security
/// policies on the database — it is safe to ship in the web bundle.
///
/// The service role key bypasses RLS and is used ONLY for admin operations
/// that require direct table writes (e.g. admin_set_inquiry_answer).
/// This is an internal admin tool; the key is acceptable in the admin bundle.
class SupabaseConfig {
  static const String url = 'https://swojhmarmaijkshsbeih.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
  // Admin-only: service role key for privileged REST API operations.
  static const String serviceKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3OTk3NzY2MCwiZXhwIjoyMDk1NTUzNjYwfQ.xhFoxtmEws4-ElzivfEJTvvkiRO5WPBAS98HtRkk4A0';

  static Map<String, String> get _svcHeaders => {
    'apikey': serviceKey,
    'Authorization': 'Bearer $serviceKey',
    'Content-Type': 'application/json',
  };

  static Map<String, String> get svcReadHeaders => _svcHeaders;

  static Map<String, String> get svcWriteHeaders => {
    ..._svcHeaders,
    'Prefer': 'return=minimal',
  };

  static Map<String, String> get svcUpsertHeaders => {
    ..._svcHeaders,
    'Prefer': 'resolution=merge-duplicates,return=minimal',
  };
}
