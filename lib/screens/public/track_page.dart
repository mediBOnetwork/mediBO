// lib/screens/public/track_page.dart — CHANGE #629 (PART F4)
//
// The public /track/{token} page. The "out for delivery" WhatsApp message links
// to https://medibo.in/track/<qr_token>, and until now that URL resolved to
// nothing — onGenerateRoute had no /track/ guard, so it fell through to the
// storefront.
//
// NO AUTH. The token in the link IS the authorisation, exactly as
// /order/<token>, /inquiry/<token> and /dispute/<token> already work here.
// delivery_track_public() is the only thing that decides what a token may see,
// and it deliberately returns a complete never-null payload — including its own
// 'Tracking link not found' title and message — so this page has no error copy
// of its own to write and no state it could invent.
//
// F4: "Same tracking view" — this renders DeliveryTrackingView, the identical
// widget the signed-in customer's Track sheet uses.

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../fulfill/fulfill_lookups.dart';
import '../../utils/render_log.dart';
import '../delivery/delivery_tracking_view.dart';

class TrackPage extends StatefulWidget {
  final String token;
  const TrackPage({super.key, required this.token});

  @override
  State<TrackPage> createState() => _TrackPageState();
}

class _TrackPageState extends State<TrackPage> {
  DeliveryTrackingData? _data;
  bool _loading = true;

  /// The backend's own not-found copy, held verbatim.
  String _title = '';
  String _message = '';

  @override
  void initState() {
    super.initState();
    FulfillLookups.instance.ensureLoaded();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('delivery_track_public', params: {'p_token': widget.token});
      if (!mounted) return;
      if (res is Map) {
        final m = Map<String, dynamic>.from(res);
        final d = DeliveryTrackingData.fromPublic(m);
        RenderLog.write('c629_track_public', 'found=${d.found};tracking=${d.tracking}');
        setState(() {
          _data = d;
          _title = d.title;
          _message = d.message;
          _loading = false;
        });
        return;
      }
      setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6F8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF111827),
        elevation: 0.5,
        title: Text(_title.isNotEmpty ? _title : ''),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            child: _loading
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 60),
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Card(
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                      side: const BorderSide(color: Color(0xFFE5E7EB)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: d == null
                          // The call itself failed (offline / socket). There is
                          // no backend sentence to print, so nothing is
                          // invented — the page stays blank rather than
                          // claiming the link is invalid.
                          ? const SizedBox.shrink()
                          : (!d.found)
                              // The backend already wrote both lines.
                              ? Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_message.isNotEmpty)
                                      Text(_message,
                                          style: const TextStyle(
                                              fontSize: 13.5, color: Color(0xFF6B7280))),
                                  ],
                                )
                              : DeliveryTrackingView(data: d, onRefetch: _load),
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}
