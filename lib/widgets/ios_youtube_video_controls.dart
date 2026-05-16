import 'dart:async';

import 'package:chewie/chewie.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class IosYoutubeVideoControls extends StatefulWidget {
  final String? title;
  final VoidCallback? onMinimize;
  final VoidCallback? onClose;
  final VoidCallback? onQualityPressed;

  const IosYoutubeVideoControls({
    super.key,
    this.title,
    this.onMinimize,
    this.onClose,
    this.onQualityPressed,
  });

  @override
  State<IosYoutubeVideoControls> createState() => _IosYoutubeVideoControlsState();
}

class _IosYoutubeVideoControlsState extends State<IosYoutubeVideoControls> {
  bool _visible = true;
  Timer? _hideTimer;

  ChewieController get _chewie => ChewieController.of(context);
  VideoPlayerController get _video => _chewie.videoPlayerController;

  @override
  void initState() {
    super.initState();
    _scheduleAutoHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _toggleOverlay() {
    setState(() {
      _visible = !_visible;
    });
    _scheduleAutoHide();
  }

  void _scheduleAutoHide() {
    _hideTimer?.cancel();
    if (!_video.value.isPlaying || !_visible) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _visible = false;
      });
    });
  }

  Future<void> _seekRelative(Duration delta) async {
    final value = _video.value;
    final duration = value.duration;
    if (duration <= Duration.zero) return;
    final targetMs = (value.position.inMilliseconds + delta.inMilliseconds)
        .clamp(0, duration.inMilliseconds);
    final target = Duration(milliseconds: targetMs);
    await _video.seekTo(target);
    _scheduleAutoHide();
  }

  Future<void> _togglePlayPause() async {
    if (_video.value.isPlaying) {
      await _video.pause();
      setState(() => _visible = true);
    } else {
      await _video.play();
      _scheduleAutoHide();
    }
  }

  void _toggleFullScreen() {
    if (_chewie.isFullScreen) {
      _chewie.exitFullScreen();
    } else {
      _chewie.enterFullScreen();
    }
    _scheduleAutoHide();
  }

  String _fmt(Duration d) {
    final totalSeconds = d.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final value = _video.value;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleOverlay,
      child: Stack(
        children: [
          AnimatedOpacity(
            duration: const Duration(milliseconds: 180),
            opacity: _visible ? 1 : 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.58),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.68),
                  ],
                  stops: const [0.0, 0.26, 0.58, 1.0],
                ),
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        if (widget.onMinimize != null)
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(30, 30),
                            onPressed: widget.onMinimize,
                            child: const Icon(
                              CupertinoIcons.chevron_down,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            widget.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (widget.onQualityPressed != null)
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(30, 30),
                            onPressed: widget.onQualityPressed,
                            child: const Icon(
                              CupertinoIcons.slider_horizontal_3,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                        if (widget.onClose != null)
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(30, 30),
                            onPressed: widget.onClose,
                            child: const Icon(
                              CupertinoIcons.xmark,
                              color: Colors.white,
                              size: 19,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _overlayButton(
                        icon: CupertinoIcons.gobackward_10,
                        onTap: () => _seekRelative(const Duration(seconds: -10)),
                      ),
                      const SizedBox(width: 16),
                      _overlayButton(
                        icon: value.isPlaying
                            ? CupertinoIcons.pause_circle_fill
                            : CupertinoIcons.play_circle_fill,
                        size: 62,
                        onTap: _togglePlayPause,
                      ),
                      const SizedBox(width: 16),
                      _overlayButton(
                        icon: CupertinoIcons.goforward_10,
                        onTap: () => _seekRelative(const Duration(seconds: 10)),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        VideoProgressIndicator(
                          _video,
                          allowScrubbing: true,
                          colors: VideoProgressColors(
                            playedColor: CupertinoColors.systemRed,
                            bufferedColor: Colors.white.withValues(alpha: 0.35),
                            backgroundColor: Colors.white.withValues(alpha: 0.2),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Text(
                              _fmt(value.position),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              _fmt(value.duration),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(width: 10),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(24, 24),
                              onPressed: _toggleFullScreen,
                              child: Icon(
                                _chewie.isFullScreen
                                    ? CupertinoIcons.fullscreen_exit
                                    : CupertinoIcons.fullscreen,
                                color: Colors.white,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlayButton({
    required IconData icon,
    required VoidCallback onTap,
    double size = 42,
  }) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size(size, size),
      onPressed: onTap,
      child: Icon(icon, color: Colors.white, size: size),
    );
  }
}
