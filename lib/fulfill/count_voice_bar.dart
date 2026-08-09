// COUNT MODE — the voice strip rendered inside the unified Count screen.
//
// Pure renderer: every string on this bar is either backend copy the tab
// already holds (hint, error, bag label — see CountVoiceStatus) or the live
// interim caption. Nothing is composed, counted or decided here; the mic
// button only calls the tab's own toggle. Extracted to its own file so the
// protected suite can drive it without a camera or a mic.
import 'package:flutter/material.dart';

import 'count_voice_hooks.dart';
import 'fulfill_lookups.dart';

Color get _kGreen => FulfillLookups.instance.color('c_ff1b7a43');
Color get _kText => FulfillLookups.instance.color('c_ff111827');
Color get _kSub => FulfillLookups.instance.color('c_ff6b7280');
Color get _kWrongFg => FulfillLookups.instance.color('c_ffb42318');
Color get _kBorder => FulfillLookups.instance.color('c_ffe5e7eb');

class CountVoiceBar extends StatelessWidget {
  final CountVoiceStatus status;
  final Future<void> Function() onToggle;

  const CountVoiceBar({super.key, required this.status, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    if (!status.supported) return const SizedBox.shrink();
    final listening = status.listening;
    final processing = status.processing;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: _kBorder)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: processing ? null : () => onToggle(),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: listening ? _kWrongFg : _kGreen,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: processing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : Icon(
                    listening ? Icons.stop_rounded : Icons.mic_none_rounded,
                    size: 22,
                    color: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (status.error.isNotEmpty)
                Text(status.error,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _kWrongFg))
              else if (status.hint.isNotEmpty)
                Text(status.hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _kText)),
              if (status.caption.isNotEmpty)
                Text(status.caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: _kSub)),
              if (status.bagLabel.isNotEmpty)
                Text(status.bagLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _kSub)),
            ],
          ),
        ),
      ]),
    );
  }
}
