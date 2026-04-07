import 'dart:io';

import 'package:flutter/material.dart';
import 'package:myapp/utils/thumbnail_quality.dart';

class SquareThumbnail extends StatelessWidget {
  final double size;
  final double borderRadius;
  final double zoom;
  final String? imageUrl;
  final String? filePath;
  final Widget fallback;

  const SquareThumbnail.network({
    super.key,
    required this.imageUrl,
    required this.size,
    this.borderRadius = 10,
    this.zoom = 1.30,
    required this.fallback,
  }) : filePath = null;

  const SquareThumbnail.file({
    super.key,
    required this.filePath,
    required this.size,
    this.borderRadius = 10,
    this.zoom = 1.34,
    required this.fallback,
  }) : imageUrl = null;

  @override
  Widget build(BuildContext context) {
    final hasFile = filePath != null && filePath!.isNotEmpty;
    final hasUrl = imageUrl != null && imageUrl!.isNotEmpty;

    Widget image;
    if (hasFile) {
      image = Image.file(
        File(filePath!),
        width: size,
        height: size,
        fit: BoxFit.cover,
        alignment: Alignment.center,
        filterQuality: FilterQuality.high,
        errorBuilder: (context, error, stackTrace) => fallback,
      );
    } else if (hasUrl) {
      image = _NetworkThumbnailWithFallback(
        urls: buildThumbnailCandidates(thumbnailUrl: imageUrl),
        size: size,
        fallback: fallback,
      );
    } else {
      image = fallback;
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: SizedBox(
        width: size,
        height: size,
        child: Transform.scale(
          scale: zoom,
          child: image,
        ),
      ),
    );
  }
}

class _NetworkThumbnailWithFallback extends StatefulWidget {
  final List<String> urls;
  final double size;
  final Widget fallback;

  const _NetworkThumbnailWithFallback({
    required this.urls,
    required this.size,
    required this.fallback,
  });

  @override
  State<_NetworkThumbnailWithFallback> createState() => _NetworkThumbnailWithFallbackState();
}

class _NetworkThumbnailWithFallbackState extends State<_NetworkThumbnailWithFallback> {
  int _index = 0;

  @override
  void didUpdateWidget(covariant _NetworkThumbnailWithFallback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.urls != widget.urls) {
      _index = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.urls.isEmpty || _index >= widget.urls.length) {
      return widget.fallback;
    }
    final currentUrl = widget.urls[_index];
    return Image.network(
      currentUrl,
      width: widget.size,
      height: widget.size,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      filterQuality: FilterQuality.high,
      errorBuilder: (context, error, stackTrace) {
        if (_index < widget.urls.length - 1) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            setState(() {
              _index += 1;
            });
          });
          return const SizedBox.expand();
        }
        return widget.fallback;
      },
    );
  }
}
