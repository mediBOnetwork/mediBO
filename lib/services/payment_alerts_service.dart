// CMD #1930 — the payment-alerts door.
//
// Six RPCs, no logic. Every screen in this feature takes a [PayAlertRpc] so it
// can be pumped on the Dart VM against a payload instead of a network; the
// live implementation is the only thing that knows Supabase exists.
import 'package:supabase_flutter/supabase_flutter.dart';

typedef PayAlertRpc =
    Future<Map<String, dynamic>> Function(String fn, Map<String, dynamic> args);

Future<Map<String, dynamic>> payAlertLiveRpc(
  String fn,
  Map<String, dynamic> args,
) async {
  final raw = await Supabase.instance.client.rpc(
    fn,
    params: args.isEmpty ? null : args,
  );
  final one = raw is List ? (raw.isEmpty ? null : raw.first) : raw;
  return one is Map ? Map<String, dynamic>.from(one) : <String, dynamic>{};
}
