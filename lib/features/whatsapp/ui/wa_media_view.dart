import 'package:flutter/material.dart';

/// CHANGE #485: the client never signs URLs or picks buckets/paths anymore —
/// it asks the backend (`wa-media-url` edge function) for a ready-to-use
/// signed URL by message id. Both the inline thumbnail and the full-screen
/// viewer take this resolver as a parameter so they're testable without a
/// real Supabase client or network access. Deliberately no `render_log`
/// import here (it pulls in `dart:html`, which breaks `flutter test`'s VM
/// target — see `bag_print_grid.dart` for the same convention).
typedef WaMediaUrlResolver = Future<String?> Function(String messageId);

/// CHANGE #487: `wa-media-url` now also returns the image's aspect ratio, so
/// the inline thumbnail can reserve its final box size before the image
/// loads (see [WaMediaThumbnail]) instead of jumping the chat when the real
/// pixels arrive.
class WaMediaInfo {
  final String url;
  final double? aspectRatio;
  const WaMediaInfo({required this.url, this.aspectRatio});
}

typedef WaMediaInfoResolver = Future<WaMediaInfo?> Function(String messageId);

const _kErrorColor = Color(0xFF9CA3AF);
const _kSpinnerColor = Color(0xFF1B7A43);
const _kPlaceholderBg = Color(0xFFE8ECEF);

// CHANGE #489: a FIXED constant, never derived from the async aspect ratio —
// #487's AspectRatio-from-resolver sizing still resized the box (1:1 -> real
// ratio) the moment the resolver settled, which is the same chat-jump this
// was meant to fix. The box height must be identical on the very first frame
// and forever after, regardless of resolver/image state.
const double _kThumbHeight = 260;

/// Inline media thumbnail shown inside a chat bubble.
///
/// CHANGE #489: fixed-size box (width = bubble content width, height =
/// [_kThumbHeight]) — same before, during, and after loading, so the chat
/// never jumps. A grey placeholder with a spinner fills the box while
/// loading; the loaded image fills it with BoxFit.cover.
class WaMediaThumbnail extends StatefulWidget {
  final String messageId;
  final WaMediaInfoResolver resolver;
  final VoidCallback? onTap;

  const WaMediaThumbnail({
    super.key,
    required this.messageId,
    required this.resolver,
    this.onTap,
  });

  @override
  State<WaMediaThumbnail> createState() => _WaMediaThumbnailState();
}

class _WaMediaThumbnailState extends State<WaMediaThumbnail> {
  late Future<WaMediaInfo?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.resolver(widget.messageId);
  }

  @override
  void didUpdateWidget(WaMediaThumbnail old) {
    super.didUpdateWidget(old);
    if (widget.messageId != old.messageId) {
      _future = widget.resolver(widget.messageId);
    }
  }

  void _retry() {
    if (!mounted) return;
    setState(() => _future = widget.resolver(widget.messageId));
  }

  Widget _placeholder() => Container(
        color: _kPlaceholderBg,
        alignment: Alignment.center,
        child: const CircularProgressIndicator(color: _kSpinnerColor),
      );

  Widget _errorBox() => GestureDetector(
        onTap: _retry,
        child: Container(
          color: _kPlaceholderBg,
          alignment: Alignment.center,
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, size: 28, color: _kErrorColor),
              SizedBox(height: 4),
              Text("Couldn't load — tap to retry",
                  style: TextStyle(fontSize: 12, color: _kErrorColor)),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: double.infinity,
        height: _kThumbHeight,
        child: FutureBuilder<WaMediaInfo?>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return _placeholder();
            }
            final info = snap.data;
            if (info == null) {
              return _errorBox();
            }
            return GestureDetector(
              onTap: widget.onTap,
              child: Image.network(
                info.url,
                width: double.infinity,
                height: _kThumbHeight,
                fit: BoxFit.cover,
                loadingBuilder: (ctx2, child, progress) {
                  if (progress == null) return child;
                  return _placeholder();
                },
                errorBuilder: (ctx2, err, st) => _errorBox(),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Full-screen tap-to-zoom viewer, opened from [WaMediaThumbnail].
class WaFullscreenMediaViewer extends StatefulWidget {
  final String messageId;
  final WaMediaUrlResolver resolver;

  const WaFullscreenMediaViewer({
    super.key,
    required this.messageId,
    required this.resolver,
  });

  @override
  State<WaFullscreenMediaViewer> createState() =>
      _WaFullscreenMediaViewerState();
}

class _WaFullscreenMediaViewerState extends State<WaFullscreenMediaViewer> {
  late Future<String?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.resolver(widget.messageId);
  }

  void _retry() {
    if (!mounted) return;
    setState(() => _future = widget.resolver(widget.messageId));
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: EdgeInsets.zero,
      child: Stack(children: [
        SizedBox.expand(
          child: Center(
            child: FutureBuilder<String?>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const CircularProgressIndicator(color: Colors.white);
                }
                final url = snap.data;
                if (url == null || url.isEmpty) {
                  return GestureDetector(
                    onTap: _retry,
                    child: const Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined,
                            color: Colors.white, size: 48),
                        SizedBox(height: 8),
                        Text("Couldn't load — tap to retry",
                            style: TextStyle(color: Colors.white)),
                      ],
                    ),
                  );
                }
                return InteractiveViewer(
                  child: Image.network(
                    url,
                    fit: BoxFit.contain,
                    loadingBuilder: (ctx2, child, progress) {
                      if (progress == null) return child;
                      return const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      );
                    },
                    errorBuilder: (ctx2, err, st) => GestureDetector(
                      onTap: _retry,
                      child: const Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white, size: 48),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 8,
          child: IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ]),
    );
  }
}
