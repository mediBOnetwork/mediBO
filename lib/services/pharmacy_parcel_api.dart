// CMD #431 — the door to parcel counting.
//
// Computes nothing, and here that matters more than usual: the verdict on a
// counted line ("Short", "Different batch", "Verified"), the tone it is drawn
// in, whether a photo is still needed, whether a claim was raised with mediBO
// and the words of the refusal when one could not be — every one of those is a
// finished string on the payload. A verdict decided in Dart would be a second
// opinion about somebody's money.
//
// The four input methods are one contract. A scanned barcode, a spoken name
// and a typed fragment all go to `pharmacy_parcel_find` as a token, and the
// BACKEND says which line it is. Adding a fifth input method costs no deploy.
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class PharmacyParcelApi {
  PharmacyParcelApi._();

  static Future<Map<String, dynamic>> call(
    String fn,
    Map<String, dynamic> params,
  ) async {
    final raw = await Supabase.instance.client.rpc(
      fn,
      params: params.isEmpty ? null : params,
    );
    final map = (raw is List ? (raw.isEmpty ? null : raw.first) : raw);
    return map is Map ? Map<String, dynamic>.from(map) : <String, dynamic>{};
  }

  /// The two lists of parcels waiting to be counted, plus their empty states.
  static Future<Map<String, dynamic>> home() =>
      call('pharmacy_parcel_home', const {});

  /// The nav card. `show:false` means this login has no pharmacy — the tile is
  /// absent, not greyed out.
  static Future<Map<String, dynamic>> entry() =>
      call('pharmacy_parcel_entry', const {});

  /// Opens a count, or resumes the one already open on this parcel.
  static Future<Map<String, dynamic>> open(String billId) =>
      call('pharmacy_parcel_open', {'p_bill_id': billId});

  /// The chip the ORDER card draws, and the door behind it. A mediBO parcel is
  /// counted from the order it arrived for, so these two are the whole of that
  /// path — the standalone screen never lists a mediBO parcel.
  static Future<Map<String, dynamic>> orderChip(String orderId) =>
      call('pharmacy_parcel_order_chip', {'p_order_id': orderId});

  static Future<Map<String, dynamic>> openOrder(String orderId) =>
      call('pharmacy_parcel_open_order', {'p_order_id': orderId});

  static Future<Map<String, dynamic>> get(String sessionId) =>
      call('pharmacy_parcel_get', {'p_session_id': sessionId});

  /// "I just read this — which line is it?" One question for all four methods.
  static Future<Map<String, dynamic>> find(
    String sessionId,
    String token, {
    String method = 'typed',
  }) => call('pharmacy_parcel_find', {
    'p_session_id': sessionId,
    'p_token': token,
    'p_method': method,
  });

  /// Records what the hands found. The patch is sent as given: an absent key
  /// is left alone, which is how a photo can be added to a line that was
  /// counted five minutes ago without re-counting it.
  static Future<Map<String, dynamic>> mark(
    String lineId,
    Map<String, dynamic> patch,
  ) => call('pharmacy_parcel_mark', {'p_line_id': lineId, 'p_patch': patch});

  /// An item in the box that is on no line of the bill.
  static Future<Map<String, dynamic>> extra(
    String sessionId,
    Map<String, dynamic> patch,
  ) => call('pharmacy_parcel_extra', {
    'p_session_id': sessionId,
    'p_patch': patch,
  });

  static Future<Map<String, dynamic>> finish(String sessionId) =>
      call('pharmacy_parcel_finish', {'p_session_id': sessionId});

  /// Evidence goes to the bucket the BACKEND named on the payload — this file
  /// holds no bucket name of its own. Returns the stored path, or null if the
  /// upload failed, in which case the line keeps saying it still needs a photo.
  static Future<String?> uploadPhoto(
    String bucket,
    String path,
    Uint8List bytes,
  ) async {
    try {
      await Supabase.instance.client.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: true),
          );
      return path;
    } catch (_) {
      return null;
    }
  }
}
