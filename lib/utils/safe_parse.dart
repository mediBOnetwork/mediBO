// Shared defensive parsers for JSON numeric/bool fields from Supabase RPC responses.
// Use these instead of (v as num?) — PostgREST may serialise numeric JSONB as string
// depending on client configuration, so tryParse on toString() is the safe path.

double safeParseDouble(dynamic v) =>
    (num.tryParse(v?.toString() ?? ''))?.toDouble() ?? 0.0;

int safeParseInt(dynamic v) =>
    num.tryParse(v?.toString() ?? '')?.toInt() ?? 0;

// PostgreSQL booleans in JSONB arrive as Dart bool, but guard the string variant too.
bool parseBoolField(dynamic v) => v == true || v?.toString() == 'true';
