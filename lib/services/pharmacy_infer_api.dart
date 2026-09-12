// CHANGE #424 — the consumption inference engine's one door.
//
// Two calls. The screen never knows whether a number came from an estimate, the
// counter or the owner's own count — the payload says so in `method_label`, and
// that is the whole point of the swap being invisible.
import 'pos_api.dart';

class PharmacyInferApi {
  PharmacyInferApi._();

  static Future<Map<String, dynamic>> call(
    String fn,
    Map<String, dynamic> params,
  ) => PosApi.call(fn, params);

  static Future<Map<String, dynamic>> screen({int limit = 50}) =>
      call('pharmacy_inference_screen', {'p_limit': limit});

  /// The one-tap truth. `left` is a quantity the BACKEND offered in
  /// `ask_options` (or the owner's own number) — this layer validates nothing
  /// and rounds nothing.
  static Future<Map<String, dynamic>> correct(String lotId, num left) =>
      call('pharmacy_lot_correct', {'p_lot_id': lotId, 'p_left': left});
}
