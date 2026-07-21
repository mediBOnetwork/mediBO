import 'package:flutter/material.dart';

/// CHANGE #485: the client never signs URLs or picks buckets/paths anymore —
/// it asks the backend (`wa-media-url` edge function) for a ready-to-use
/// signed URL by message id. Both the inline thumbnail and the full-screen
/// viewer take this resolver as a parameter so they're testable without a
/// real Supabase client or network access. Deliberately no `render_log`
/// import here (it pulls in `dart:html`, which breaks `flutter test`'s VM
/// target — see `bag_print_grid.dart` for the same convention).
typedef WaMediaUrlResolver = Future<String?> Function(String messageId);

const _kErrorColor = Color(0xFF9CA3AF);
const _kSpinnerColor = Color(0xFF1B7A43);

Widget _errorContent(VoidCallback onRetry) => GestureDetector(
      onTap: onRetry,
      child: const SizedBox(
        height: 80,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, size: 28, color: _kErrorColor),
              SizedBox(height: 4),
              Text("Couldn't load — tap to retry",
                  style: TextStyle(fontSize: 12, color: _kErrorColor)),
            ],
          ),
        ),
      ),
    );

/// Inline media thumbnail shown inside a chat bubble.
class WaMediaThumbnail extends StatefulWidget {
  final String messageId;
  final WaMediaUrlResolver resolver;
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
  late Future<String?> _future;

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

  @override
  Widget build(BuildContext context) {
    final maxHeight = MediaQuery.of(context).size.height * 0.55;
    return FutureBuilder<String?>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return SizedBox(
            height: maxHeight.clamp(120, 220),
            child: const Center(
              child: CircularProgressIndicator(color: _kSpinnerColor),
            ),
          );
        }
        final url = snap.data;
        if (url == null || url.isEmpty) {
          return _errorContent(_retry);
        }
        return GestureDetector(
          onTap: widget.onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: Image.network(
                url,
                width: double.infinity,
                fit: BoxFit.cover,
                loadingBuilder: (ctx2, child, progress) {
                  if (progress == null) return child;
                  return SizedBox(
                    height: maxHeight.clamp(120, 220),
                    child: const Center(
                      child: CircularProgressIndicator(color: _kSpinnerColor),
                    ),
                  );
                },
                errorBuilder: (ctx2, err, st) => _errorContent(_retry),
              ),
            ),
          ),
        );
      },
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
