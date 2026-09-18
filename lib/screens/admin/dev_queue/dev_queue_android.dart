import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../utils/render_log.dart';
import 'dev_queue_common.dart';

/// CHANGE #1802 — the Android release block on a command's detail screen.
///
/// #1801 was asked to build the AAB and publish it to Play. It closed 8/8
/// green as "backend only, nothing to deploy" while `targets_android` was
/// true and every Android column sat at its default, and the only way to
/// notice was to open the Play Console by hand. The backend now refuses that
/// completion; this is the surface that says so BEFORE the refusal — the
/// state of the release, and the sentence that is holding the row open, on
/// the screen Om is already looking at.
///
/// It is a PRINTER. `dev_cmd_get(id).row.android` carries the title, the
/// status label, the tone name, the version-and-time sub-line, the artifact
/// link and its label, and the blocker sentence. Nothing here derives a label
/// from a status, formats a timestamp, or decides a colour from a value: a
/// status this build has never heard of still prints the backend's word for
/// it, and `has: false` (a command that never asked for an Android release)
/// draws nothing at all.
class AndroidRelease {
  final Map<String, dynamic> block;
  const AndroidRelease(this.block);

  /// The block as it arrives on the merged detail row; absent degrades to
  /// `has: false` rather than to an empty card.
  factory AndroidRelease.fromRow(Map<String, dynamic> row) =>
      AndroidRelease(row['android'] is Map
          ? Map<String, dynamic>.from(row['android'] as Map)
          : const <String, dynamic>{});

  bool get has => block['has'] == true;
  String get title => (block['title'] ?? '').toString();
  String get label => (block['label'] ?? '').toString();
  String get tone => (block['tone'] ?? 'neutral').toString();
  String get sub => (block['sub'] ?? '').toString();
  String get url => (block['url'] ?? '').toString();
  String get urlLabel => (block['url_label'] ?? '').toString();

  /// What is stopping this command from closing, in the backend's own words.
  /// Empty means the release is on the record and the gate is clear.
  String get blocker => (block['blocker'] ?? '').toString();
  bool get blocked => blocker.isNotEmpty;
}

class AndroidReleaseCard extends StatelessWidget {
  final Map<String, dynamic> row;

  /// Tapping the artifact line. The screen owns url_launcher, not this widget.
  final void Function(String url)? onOpen;
  const AndroidReleaseCard({super.key, required this.row, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final a = AndroidRelease.fromRow(row);
    if (!a.has) {
      RenderLog.write('c1802_android_block', 0);
      return const SizedBox.shrink();
    }
    // Reachability proof (CLAUDE.md): the live render-log is what says this
    // widget PAINTED — a string in the bundle only says it compiled.
    RenderLog.write('c1802_android_block', 1);
    final t = toneByName(a.tone);
    final hasUrl = a.url.isNotEmpty && a.urlLabel.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.android, size: Ds.space.x16, color: kTextLo),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text(a.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Ds.t.subtitle),
            ),
            ToneChip(label: a.label, tone: t),
          ]),
          if (a.sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(a.sub, style: Ds.t.caption),
          ],
          if (hasUrl) ...[
            SizedBox(height: Ds.space.x12),
            InkWell(
              onTap: onOpen == null ? null : () => onOpen!(a.url),
              borderRadius: Ds.r.rButton,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.download, size: Ds.space.x16, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x8),
                  Flexible(
                    child: Text(a.urlLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.body.copyWith(color: Ds.c.brand)),
                  ),
                ]),
              ),
            ),
          ],
          // The refusal, printed. It is the SAME sentence dev_cmd_complete
          // raises with, so the screen and the gate can never disagree about
          // why a command will not close.
          if (a.blocked) ...[
            SizedBox(height: Ds.space.x12),
            Container(
              padding: EdgeInsets.all(Ds.space.x12),
              decoration: BoxDecoration(
                  color: toneByName('warning').bg, borderRadius: Ds.r.rButton),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.block,
                    size: Ds.space.x16, color: toneByName('warning').fg),
                SizedBox(width: Ds.space.x8),
                Expanded(
                  child: Text(a.blocker,
                      style:
                          Ds.t.body.copyWith(color: toneByName('warning').fg)),
                ),
              ]),
            ),
          ],
        ]),
      ),
    );
  }
}

// ── CMD #2076 — the Firebase Test Lab verdict ────────────────────────────────
//
// The web build never runs the Kotlin plugins, so an Android release is gated
// on one Test Lab matrix (scripts/android_testlab.sh). Everything below is a
// PRINTER of `dev_cmd_get(id).testlab` (the detail block) and of the
// `testlab_chip` / `testlab_tone` pair on the list row: status labels, the
// device line, the per-check labels and their ok/failed words, the proof
// labels and the blocker all arrive from the backend. Nothing is derived from
// the status string here — a status of 'passed' with a label of 'Green,
// allegedly' prints 'Green, allegedly' (test/protected/android_testlab_gate_test.dart).

/// The row's chip text, or '' when the command has no Test Lab verdict.
String testLabChipOf(Map<String, dynamic> row) =>
    (row['testlab_chip'] ?? '').toString();

/// The row's chip tone name; the backend's word, 'neutral' when absent.
String testLabToneOf(Map<String, dynamic> row) =>
    (row['testlab_tone'] ?? 'neutral').toString();

class TestLabRun {
  final Map<String, dynamic> block;
  const TestLabRun(this.block);

  factory TestLabRun.fromRow(Map<String, dynamic> row) => TestLabRun(
      row['testlab'] is Map
          ? Map<String, dynamic>.from(row['testlab'] as Map)
          : const <String, dynamic>{});

  bool get has => block['has'] == true;
  String get title => (block['title'] ?? '').toString();
  String get status => (block['status'] ?? '').toString();
  String get label => (block['label'] ?? '').toString();
  String get tone => (block['tone'] ?? 'neutral').toString();
  String get sub => (block['sub'] ?? '').toString();
  String get detail => (block['detail'] ?? '').toString();
  String get url => (block['url'] ?? '').toString();
  String get urlLabel => (block['url_label'] ?? '').toString();
  String get checksTitle => (block['checks_title'] ?? '').toString();
  String get proofsTitle => (block['proofs_title'] ?? '').toString();

  List<Map<String, dynamic>> _list(String key) =>
      ((block[key] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => Map<String, dynamic>.from(m))
          .toList();

  /// [{key,label,ok,status,tone,detail}] — one row per check, payload order.
  List<Map<String, dynamic>> get checks => _list('checks');

  /// [{kind,label,path,bucket}] — the evidence pulled off the device.
  List<Map<String, dynamic>> get proofs => _list('proofs');
}

/// Turns a private-bucket object into a URL the screen can open. The screen
/// owns Supabase; the card only knows a bucket and a path.
typedef ProofSigner = Future<String> Function(String bucket, String path);

class TestLabCard extends StatelessWidget {
  final Map<String, dynamic> row;
  final void Function(String url)? onOpen;
  final ProofSigner? signer;
  const TestLabCard({super.key, required this.row, this.onOpen, this.signer});

  IconData _proofIcon(String kind) {
    switch (kind) {
      case 'video':
        return Icons.videocam_outlined;
      case 'logcat':
        return Icons.receipt_long_outlined;
      case 'screenshot':
        return Icons.image_outlined;
      default:
        return Icons.data_object;
    }
  }

  IconData _checkIcon(Map<String, dynamic> c) {
    final ok = c['ok'];
    if (ok == true) return Icons.check_circle_outline;
    if (ok == false) return Icons.cancel_outlined;
    return Icons.radio_button_unchecked;
  }

  Future<void> _openProof(Map<String, dynamic> p) async {
    final path = (p['path'] ?? '').toString();
    final bucket = (p['bucket'] ?? 'dev-cmd-proofs').toString();
    if (path.isEmpty || onOpen == null) return;
    if (signer == null) return;
    final url = await signer!(bucket, path);
    if (url.isNotEmpty) onOpen!(url);
  }

  @override
  Widget build(BuildContext context) {
    final t = TestLabRun.fromRow(row);
    if (!t.has) {
      RenderLog.write('c2076_testlab_block', 0);
      return const SizedBox.shrink();
    }
    RenderLog.write('c2076_testlab_block', 1);
    final tone = toneByName(t.tone);
    final hasUrl = t.url.isNotEmpty && t.urlLabel.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(top: Ds.space.x12),
      child: DqCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.science_outlined, size: Ds.space.x16, color: kTextLo),
            SizedBox(width: Ds.space.x8),
            Expanded(
              child: Text(t.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: Ds.t.subtitle),
            ),
            ToneChip(label: t.label, tone: tone),
          ]),
          if (t.sub.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(t.sub, style: Ds.t.caption),
          ],
          if (t.detail.isNotEmpty) ...[
            SizedBox(height: Ds.space.x8),
            Text(t.detail, style: Ds.t.body),
          ],
          if (t.checks.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            if (t.checksTitle.isNotEmpty)
              Text(t.checksTitle,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            for (final c in t.checks)
              Padding(
                padding: EdgeInsets.only(top: Ds.space.x8),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(_checkIcon(c),
                      size: Ds.space.x16,
                      color: toneByName((c['tone'] ?? 'neutral').toString()).fg),
                  SizedBox(width: Ds.space.x8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text((c['label'] ?? '').toString(), style: Ds.t.body),
                      if ((c['detail'] ?? '').toString().isNotEmpty) ...[
                        SizedBox(height: Ds.space.x4),
                        Text((c['detail'] ?? '').toString(), style: Ds.t.caption),
                      ],
                    ]),
                  ),
                  SizedBox(width: Ds.space.x8),
                  ToneChip(
                      label: (c['status'] ?? '').toString(),
                      tone: toneByName((c['tone'] ?? 'neutral').toString())),
                ]),
              ),
          ],
          if (t.proofs.isNotEmpty) ...[
            SizedBox(height: Ds.space.x16),
            if (t.proofsTitle.isNotEmpty)
              Text(t.proofsTitle,
                  style: Ds.t.caption.copyWith(color: Ds.c.textSecondary)),
            SizedBox(height: Ds.space.x4),
            Wrap(spacing: Ds.space.x8, runSpacing: Ds.space.x8, children: [
              for (final p in t.proofs)
                InkWell(
                  onTap: () => _openProof(p),
                  borderRadius: Ds.r.rButton,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                        vertical: Ds.space.x8, horizontal: Ds.space.x4),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(_proofIcon((p['kind'] ?? '').toString()),
                          size: Ds.space.x16, color: Ds.c.brand),
                      SizedBox(width: Ds.space.x4),
                      Text((p['label'] ?? '').toString(),
                          style: Ds.t.body.copyWith(color: Ds.c.brand)),
                    ]),
                  ),
                ),
            ]),
          ],
          if (hasUrl) ...[
            SizedBox(height: Ds.space.x8),
            InkWell(
              onTap: onOpen == null ? null : () => onOpen!(t.url),
              borderRadius: Ds.r.rButton,
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: Ds.space.x8),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.open_in_new, size: Ds.space.x16, color: Ds.c.brand),
                  SizedBox(width: Ds.space.x8),
                  Flexible(
                    child: Text(t.urlLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Ds.t.body.copyWith(color: Ds.c.brand)),
                  ),
                ]),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
