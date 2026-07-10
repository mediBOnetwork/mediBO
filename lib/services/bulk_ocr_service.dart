import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// CHANGE #419: OCR for the Bulk-upload flow now runs as a DB-backed
/// background job (bulk_ocr_jobs / bulk_ocr_enqueue) instead of a direct
/// HTTP call tied to the screen's lifetime — so it survives tab switches
/// and app restarts, and never fires a global error toast on navigation.
class BulkOcrState {
  final String phase; // 'idle' | 'processing' | 'done' | 'error'
  final String? result;
  final String? error;
  const BulkOcrState(this.phase, {this.result, this.error});
}

/// App-level singleton (mirrors FulfillRealtime.instance) — owns the OCR
/// job so it is never disposed when the Bulk screen is popped/rebuilt.
class BulkOcrService extends ChangeNotifier {
  BulkOcrService._();
  static final BulkOcrService instance = BulkOcrService._();

  Timer? _timer;
  String? _jobId;
  BulkOcrState state = const BulkOcrState('idle');

  Future<void> start({
    required String imageBase64,
    required String mimeType,
    String? prompt,
    String? mode,
  }) async {
    _cancel();
    state = const BulkOcrState('processing');
    notifyListeners();
    try {
      _jobId = await Supabase.instance.client.rpc('bulk_ocr_enqueue', params: {
        'p_image_base64': imageBase64,
        'p_mime_type': mimeType,
        'p_prompt': prompt,
        'p_mode': mode,
      }) as String;
    } catch (_) {
      state = const BulkOcrState('error',
          error: 'Could not start. Please sign in again and retry.');
      notifyListeners();
      return;
    }
    _poll();
  }

  // Resume showing an in-flight/finished job when returning to the Bulk tab
  // (covers app-close: the DB is the source of truth).
  Future<void> resumeLatestIfAny() async {
    if (state.phase == 'processing') return; // already tracking
    try {
      final row = await Supabase.instance.client
          .from('bulk_ocr_jobs')
          .select('id,status,result,error')
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row == null) return;
      _jobId = row['id'] as String?;
      _applyRow(row);
      if (row['status'] == 'processing' || row['status'] == 'queued') _poll();
    } catch (_) {
      // Transient network/auth blip on tab mount — not worth surfacing.
    }
  }

  void _poll() {
    _timer?.cancel();
    final startedAt = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 3), (t) async {
      if (_jobId == null) {
        t.cancel();
        return;
      }
      if (DateTime.now().difference(startedAt) > const Duration(minutes: 3)) {
        t.cancel();
        state = const BulkOcrState('error', error: 'Timed out. Please try again.');
        notifyListeners();
        return;
      }
      try {
        final row = await Supabase.instance.client
            .from('bulk_ocr_jobs')
            .select('status,result,error')
            .eq('id', _jobId!)
            .maybeSingle();
        if (row == null) return; // keep waiting
        if (row['status'] == 'done' || row['status'] == 'error') {
          t.cancel();
          _applyRow(row);
        }
      } catch (_) {
        // transient network: keep polling, do NOT error out
      }
    });
  }

  void _applyRow(Map<String, dynamic> row) {
    switch (row['status']) {
      case 'done':
        state = BulkOcrState('done', result: (row['result'] as String?) ?? '');
        break;
      case 'error':
        state = BulkOcrState('error', error: (row['error'] as String?) ?? 'AI failed');
        break;
      default:
        state = const BulkOcrState('processing');
    }
    notifyListeners();
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
    _jobId = null;
  }

  void reset() {
    _cancel();
    state = const BulkOcrState('idle');
    notifyListeners();
  }
}
