// CMD #1873 — the route stop check-in sheet.
//
// A rep walking a planned route closes a stop from here: one of FOUR outcomes,
// an optional note, an optional photo proof. Every string on this sheet —
// title, the four button labels, their hints, the note label and hint, the
// photo captions, the submit/cancel copy, the result toast — arrives from
// route_stop_sheet() / route_stop_checkin() and is printed verbatim. Nothing
// below decides what an outcome means, what "skip" writes, or how a storage
// URL is spelled: the backend owns all three.
//
// Distinct from the #446 _CheckInSheet (record_visit, the GPS correction
// engine): that one REQUIRES a fix within 500 m and owns eight statuses of its
// own. This one is the stop's own outcome and needs no GPS.

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../design_tokens.dart';
import '../../utils/file_pick_io.dart' as filepick;
import '../../utils/render_log.dart';
import '../../utils/toast.dart';

/// Maps the backend's `tone` onto the token layer. The backend never sends a
/// colour — it sends a role, and the design tokens decide what that looks
/// like, so `ui_design_set()` restyles these chips with no deploy.
Color routeStopToneColor(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.success;
    case 'warning':
      return Ds.c.warning;
    case 'danger':
      return Ds.c.danger;
    case 'brand':
      return Ds.c.brand;
    case 'info':
      return Ds.c.info;
    default:
      return Ds.c.textSecondary;
  }
}

Color routeStopToneSoft(String? tone) {
  switch (tone) {
    case 'success':
      return Ds.c.successSoft;
    case 'warning':
      return Ds.c.warningSoft;
    case 'danger':
      return Ds.c.dangerSoft;
    case 'brand':
      return Ds.c.brandSoft;
    case 'info':
      return Ds.c.infoSoft;
    default:
      return Ds.c.bg;
  }
}


/// ── The sheet's pure decisions (CMD #1873) ────────────────────────────────
/// Everything the check-in flow decides WITHOUT a BuildContext lives here, so
/// it can be tested on the Dart VM against a mocked payload. The widget below
/// calls exactly these methods — there is no second copy of the logic.
class RouteStopCheckInPlan {
  const RouteStopCheckInPlan._();

  /// The four outcomes, in the BACKEND's order. No client sort, ever.
  static List<Map<String, dynamic>> options(Map<String, dynamic>? sheet) =>
      ((sheet?['options'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

  /// A stop already checked in re-opens on its stored outcome; a fresh stop
  /// opens with nothing selected.
  static String? initialStatus(Map<String, dynamic>? sheet) {
    final v = sheet?['selected'];
    final s = v?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  /// The stored note, pre-filled and editable.
  static String initialNote(Map<String, dynamic>? sheet) {
    final n = sheet?['note'];
    return (n is Map ? n['value'] : null)?.toString() ?? '';
  }

  /// The bucket the SHEET named. Dart never spells a bucket of its own.
  static String bucket(Map<String, dynamic>? sheet) {
    final p = sheet?['photo'];
    return (p is Map ? p['bucket'] : null)?.toString() ?? '';
  }

  /// route_stop_checkin params, or null when no outcome is picked yet — the
  /// caller shows the backend's pick_label instead of guessing a default.
  static Map<String, dynamic>? submitParams({
    required String stopId,
    required String? status,
    String note = '',
    String? photoPath,
  }) {
    if (status == null || status.isEmpty) return null;
    return {
      'p_stop_id': stopId,
      'p_status': status,
      if (note.trim().isNotEmpty) 'p_note': note.trim(),
      if (photoPath != null && photoPath.isNotEmpty) 'p_photo': photoPath,
    };
  }

  /// The one-tap Skip. The status comes from the ACTION the backend sent, so
  /// what "skip" means is a payload change, never a deploy.
  static Map<String, dynamic>? skipParams(
      String stopId, Map<String, dynamic> action) {
    final status = action['status']?.toString() ?? '';
    if (status.isEmpty) return null;
    return {'p_stop_id': stopId, 'p_status': status};
  }

  static bool isSkip(Map<String, dynamic> action) =>
      action['key']?.toString() == 'skip';
}

class RouteStopCheckInSheet extends StatefulWidget {
  final String stopId;

  const RouteStopCheckInSheet({super.key, required this.stopId});

  /// Opens the sheet. Resolves true when a check-in was saved, so the caller
  /// can refetch — it never patches a row in Dart.
  static Future<bool> open(BuildContext context, String stopId) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Ds.c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Ds.r.sheet)),
      ),
      builder: (_) => RouteStopCheckInSheet(stopId: stopId),
    );
    return saved == true;
  }

  @override
  State<RouteStopCheckInSheet> createState() => _RouteStopCheckInSheetState();
}

class _RouteStopCheckInSheetState extends State<RouteStopCheckInSheet> {
  Map<String, dynamic>? _sheet;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  String? _status;
  Uint8List? _photoBytes;
  String? _photoMime;
  final _noteCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Map<String, dynamic> _obj(String key) {
    final v = _sheet?[key];
    return v is Map ? Map<String, dynamic>.from(v) : const {};
  }

  String _s(String key) => _sheet?[key]?.toString() ?? '';

  Future<void> _load() async {
    try {
      final res = await Supabase.instance.client
          .rpc('route_stop_sheet', params: {'p_stop_id': widget.stopId});
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      setState(() {
        _sheet = m;
        _loading = false;
        // A stop already checked in re-opens on its own outcome and its own
        // note; the backend sent both, so "Change" is an edit, not a re-entry.
        _status = RouteStopCheckInPlan.initialStatus(m);
        _noteCtrl.text = RouteStopCheckInPlan.initialNote(m);
      });
      RenderLog.write('c1873_checkin_sheet',
          (m['options'] as List?)?.length ?? 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _takePhoto() async {
    final picked = await filepick.pickCameraPhoto();
    if (picked == null || !mounted) return;
    final ext = picked.name.toLowerCase().split('.').last;
    setState(() {
      _photoBytes = picked.bytes;
      _photoMime = ext == 'png'
          ? 'image/png'
          : (ext == 'webp' ? 'image/webp' : 'image/jpeg');
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (RouteStopCheckInPlan.submitParams(
            stopId: widget.stopId, status: _status) ==
        null) {
      showToast(context, _s('pick_label'), isError: true);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    // The photo is uploaded to the bucket the SHEET named; the public URL is
    // assembled by route_stop_checkin, never here.
    String? photoPath;
    if (_photoBytes != null) {
      try {
        final bucket = RouteStopCheckInPlan.bucket(_sheet);
        final ts = DateTime.now().millisecondsSinceEpoch;
        final rand = Random().nextInt(999999);
        final ext = (_photoMime ?? '').contains('png') ? 'png' : 'jpg';
        final path = '${widget.stopId}/${ts}_$rand.$ext';
        await Supabase.instance.client.storage.from(bucket).uploadBinary(
              path,
              _photoBytes!,
              fileOptions: FileOptions(
                  contentType: _photoMime ?? 'image/jpeg', upsert: true),
            );
        photoPath = path;
      } catch (_) {
        // A failed upload never loses the check-in itself.
        photoPath = null;
      }
    }

    try {
      final res = await Supabase.instance.client.rpc('route_stop_checkin',
          params: RouteStopCheckInPlan.submitParams(
              stopId: widget.stopId,
              status: _status,
              note: _noteCtrl.text,
              photoPath: photoPath)!);
      if (!mounted) return;
      final m = res is Map ? Map<String, dynamic>.from(res) : <String, dynamic>{};
      if (m['ok'] == true) {
        RenderLog.write('c1873_checkin_saved', m['status']?.toString() ?? '');
        // Toast BEFORE the pop: showToast reaches for the root overlay through
        // this context, and a popped sheet's context is already deactivated.
        showToast(context, m['message']?.toString() ?? '');
        if (!mounted) return;
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _submitting = false;
          _error = m['message']?.toString() ?? m['error']?.toString();
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(Ds.space.x24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _body(),
          ),
        ),
      ),
    );
  }

  List<Widget> _body() {
    if (_loading) {
      return [
        Padding(
          padding: EdgeInsets.symmetric(vertical: Ds.space.x32),
          child: Center(
              child: CircularProgressIndicator(
                  color: Ds.c.brand, strokeWidth: Ds.space.hairline * 2)),
        ),
      ];
    }
    if (_sheet?['can_check_in'] == false) {
      return [
        Text(_s('blocked_label'), style: Ds.t.body),
        SizedBox(height: Ds.space.x24),
        _closeButton(),
      ];
    }

    final options = RouteStopCheckInPlan.options(_sheet);
    final note = _obj('note');
    final photo = _obj('photo');
    final existingPhoto = photo['url']?.toString();

    return [
      Center(
        child: Container(
          width: Ds.space.x32,
          height: Ds.space.x4,
          margin: EdgeInsets.only(bottom: Ds.space.x16),
          decoration:
              BoxDecoration(color: Ds.c.divider, borderRadius: Ds.r.rChip),
        ),
      ),
      Text(_s('title'), style: Ds.t.title),
      SizedBox(height: Ds.space.x4),
      Text(_s('subtitle'), style: Ds.t.caption),
      SizedBox(height: Ds.space.x24),

      // ── The four outcomes, in the backend's order ─────────────────────
      for (final o in options) ...[
        _optionRow(o),
        SizedBox(height: Ds.space.x8),
      ],
      SizedBox(height: Ds.space.x16),

      // ── Note ──────────────────────────────────────────────────────────
      Text(note['label']?.toString() ?? '', style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      TextField(
        controller: _noteCtrl,
        maxLines: 3,
        minLines: 2,
        style: Ds.t.body,
        decoration: InputDecoration(hintText: note['hint']?.toString() ?? ''),
      ),
      SizedBox(height: Ds.space.x24),

      // ── Photo proof ───────────────────────────────────────────────────
      Text(photo['label']?.toString() ?? '', style: Ds.t.caption),
      SizedBox(height: Ds.space.x8),
      Row(children: [
        Expanded(
          child: SizedBox(
            height: Ds.touch.minTarget,
            child: OutlinedButton.icon(
              onPressed: _submitting ? null : _takePhoto,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_photoBytes == null
                  ? (photo['take_label']?.toString() ?? '')
                  : (photo['retake_label']?.toString() ?? '')),
            ),
          ),
        ),
        if (_photoBytes != null) ...[
          SizedBox(width: Ds.space.x12),
          ClipRRect(
            borderRadius: Ds.r.rButton,
            child: Image.memory(_photoBytes!,
                width: Ds.touch.minTarget,
                height: Ds.touch.minTarget,
                fit: BoxFit.cover),
          ),
        ] else if (existingPhoto != null && existingPhoto.isNotEmpty) ...[
          SizedBox(width: Ds.space.x12),
          ClipRRect(
            borderRadius: Ds.r.rButton,
            child: Image.network(existingPhoto,
                width: Ds.touch.minTarget,
                height: Ds.touch.minTarget,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => SizedBox(
                    width: Ds.touch.minTarget, height: Ds.touch.minTarget)),
          ),
        ],
      ]),

      if (_error != null) ...[
        SizedBox(height: Ds.space.x16),
        Container(
          width: double.infinity,
          padding: EdgeInsets.all(Ds.space.x12),
          decoration: BoxDecoration(
              color: Ds.c.dangerSoft, borderRadius: Ds.r.rButton),
          child: Text(_error!, style: Ds.t.body),
        ),
      ],

      SizedBox(height: Ds.space.x24),
      SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: ElevatedButton(
          onPressed: _submitting ? null : _submit,
          child: Text(_submitting ? _s('submitting_label') : _s('submit_label')),
        ),
      ),
      SizedBox(height: Ds.space.x8),
      _closeButton(),
    ];
  }

  Widget _closeButton() => SizedBox(
        width: double.infinity,
        height: Ds.touch.minTarget,
        child: TextButton(
          onPressed: _submitting ? null : () => Navigator.of(context).pop(false),
          child: Text(_sheet?['cancel_label']?.toString() ??
              _sheet?['close_label']?.toString() ??
              ''),
        ),
      );

  Widget _optionRow(Map<String, dynamic> o) {
    final key = o['key']?.toString() ?? '';
    final tone = o['tone']?.toString();
    final on = _status == key;
    final hint = o['hint']?.toString() ?? '';
    return InkWell(
      onTap: _submitting ? null : () => setState(() => _status = key),
      borderRadius: Ds.r.rButton,
      child: Container(
        width: double.infinity,
        constraints: BoxConstraints(minHeight: Ds.touch.minTarget),
        padding: EdgeInsets.symmetric(
            horizontal: Ds.space.x16, vertical: Ds.space.x12),
        decoration: BoxDecoration(
          color: on ? routeStopToneSoft(tone) : Ds.c.surface,
          borderRadius: Ds.r.rButton,
          border: Border.all(
              color: on ? routeStopToneColor(tone) : Ds.c.divider,
              width: Ds.space.hairline * (on ? 2 : 1)),
        ),
        child: Row(children: [
          Icon(on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              color: on ? routeStopToneColor(tone) : Ds.c.textSecondary),
          SizedBox(width: Ds.space.x12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(o['label']?.toString() ?? '', style: Ds.t.bodyStrong),
                if (hint.isNotEmpty) ...[
                  SizedBox(height: Ds.space.x4),
                  Text(hint, style: Ds.t.caption),
                ],
              ],
            ),
          ),
        ]),
      ),
    );
  }
}
