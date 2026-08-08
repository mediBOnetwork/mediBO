/// Supabase connection settings.
///
/// The anon key is a public, client-side key protected by Row Level Security
/// policies on the database — it is safe to ship in the bundle.
///
/// The service_role key was REMOVED from the client (2026-08-06). It bypassed
/// RLS and must never ship in a distributable app. Its one use (admin medicine
/// insert/update) now runs server-side via the SECURITY DEFINER RPC
/// admin_write_medicines. Any future privileged write must be a backend RPC.
class SupabaseConfig {
  static const String url = 'https://swojhmarmaijkshsbeih.supabase.co';
  static const String anonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InN3b2pobWFybWFpamtzaHNiZWloIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzk5Nzc2NjAsImV4cCI6MjA5NTU1MzY2MH0.KREJQV_VLVwZqHmDA96qt-Bi0naUkuSPo4uyLyur7xQ';
}
