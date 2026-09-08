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
