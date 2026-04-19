import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:provider/provider.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late Future<List<VideoHistory>> _historyFuture;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  void _loadHistory() {
    setState(() {
      _historyFuture = Provider.of<HistoryService>(
        context,
        listen: false,
      ).getHistory();
    });
  }

  Future<void> _refreshHistory() async {
    final refreshed = await Provider.of<HistoryService>(
      context,
      listen: false,
    ).getHistory();
    if (!mounted) return;
    setState(() {
      _historyFuture = Future.value(refreshed);
    });
  }

  Future<void> _clearHistory() async {
    await Provider.of<HistoryService>(context, listen: false).clearHistory();
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final playerManager = context.watch<VideoPlayerManager>();
    final hasMiniPlayer =
        playerManager.currentVideoId != null && playerManager.isMinimized;
    return FutureBuilder<List<VideoHistory>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CupertinoActivityIndicator(radius: 14));
        }
        if (snapshot.hasError) {
          return const Center(child: Text('No se pudo cargar el historial.'));
        }
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refreshHistory,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: const [
                SizedBox(height: 180),
                Center(child: Text('No hay historial de canciones.')),
              ],
            ),
          );
        }

        final history = snapshot.data!;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: _GlassActionButton(
                  icon: Icons.delete_sweep_rounded,
                  label: 'Eliminar historial',
                  onTap: _clearHistory,
                ),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _refreshHistory,
                child: ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.fromLTRB(
                    12,
                    8,
                    12,
                    _accountBottomOverlayReserve(
                      context,
                      hasMiniPlayer: hasMiniPlayer,
                    ),
                  ),
                  itemCount: history.length,
                  itemBuilder: (context, index) {
                    final video = history[index];
                    return _HistoryCard(video: video);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  double _accountBottomOverlayReserve(
    BuildContext context, {
    required bool hasMiniPlayer,
  }) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    const baseReserve = 108.0;
    const miniPlayerReserve = 64.0;
    return baseReserve +
        (hasMiniPlayer ? miniPlayerReserve : 0) +
        bottomInset;
  }
}

class _HistoryCard extends StatelessWidget {
  final VideoHistory video;

  const _HistoryCard({required this.video});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardColor = isDark
        ? Colors.black
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final cardBorder = isDark
        ? Colors.white.withValues(alpha: 0.12)
        : CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.12);
    final card = ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Material(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        child: InkWell(
          onTap: () async {
            await Provider.of<VideoPlayerManager>(
              context,
              listen: false,
            ).playFromUserSelection(
              context,
              video.videoId,
              preferredThumbnailUrl: video.thumbnailUrl,
              preferredTitle: video.title,
              preferredArtist: video.channelTitle,
            );
          },
          borderRadius: BorderRadius.circular(14),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: cardBorder, width: 0.5),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 5.0,
            ),
            child: Row(
              children: [
                SquareThumbnail.network(
                  imageUrl: video.thumbnailUrl,
                  size: 64,
                  borderRadius: 10,
                  fallback: Container(
                    width: 64,
                    height: 64,
                    color: CupertinoColors.tertiarySystemFill.resolveFrom(
                      context,
                    ),
                    alignment: Alignment.center,
                    child: const Icon(CupertinoIcons.music_note),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        video.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.1,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        video.channelTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: '.SF Pro Text',
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Dismissible(
        key: ObjectKey(video),
        direction: DismissDirection.startToEnd,
        dismissThresholds: const {DismissDirection.startToEnd: 0.28},
        confirmDismiss: (_) async {
          final manager = Provider.of<VideoPlayerManager>(
            context,
            listen: false,
          );
          final added = manager.addOnlineTrackToPlaybackQueue(
            videoId: video.videoId,
            title: video.title,
            thumbnailUrl: video.thumbnailUrl,
            artist: video.channelTitle,
          );
          if (context.mounted) {
            _showQueueIosToast(
              context,
              message: added
                  ? 'Se ha añadido a la cola'
                  : 'Esta canción ya está en cola',
              icon: added
                  ? CupertinoIcons.check_mark_circled_solid
                  : CupertinoIcons.info_circle_fill,
            );
          }
          return false;
        },
        background: Container(
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: CupertinoColors.systemGreen.withValues(alpha: 0.18),
            border: Border.all(
              color: CupertinoColors.systemGreen.withValues(alpha: 0.36),
              width: 0.8,
            ),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                CupertinoIcons.add_circled_solid,
                color: CupertinoColors.systemGreen,
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                'Añadir a la cola',
                style: TextStyle(
                  fontFamily: '.SF Pro Text',
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: CupertinoColors.systemGreen,
                ),
              ),
            ],
          ),
        ),
        child: card,
      ),
    );
  }
}

class _GlassActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Future<void> Function() onTap;

  const _GlassActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      minimumSize: const Size(30, 30),
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      borderRadius: BorderRadius.circular(12),
      onPressed: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: CupertinoColors.systemPink.resolveFrom(context),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontFamily: '.SF Pro Text',
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

void _showQueueIosToast(
  BuildContext context, {
  required String message,
  required IconData icon,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);

  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (overlayContext) {
      final bottomInset = MediaQuery.of(overlayContext).padding.bottom;
      return IgnorePointer(
        ignoring: true,
        child: SizedBox.expand(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset + 130),
              child: _QueueIosToast(message: message, icon: icon),
            ),
          ),
        ),
      );
    },
  );
  overlay.insert(entry);
  Timer(const Duration(milliseconds: 1900), () {
    entry.remove();
  });
}

class _QueueIosToast extends StatefulWidget {
  final String message;
  final IconData icon;

  const _QueueIosToast({required this.message, required this.icon});

  @override
  State<_QueueIosToast> createState() => _QueueIosToastState();
}

class _QueueIosToastState extends State<_QueueIosToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      reverseDuration: const Duration(milliseconds: 220),
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.06),
      end: Offset.zero,
    ).animate(_opacity);
    unawaited(_run());
  }

  Future<void> _run() async {
    await _controller.forward();
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    if (!mounted) return;
    await _controller.reverse();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final background = CupertinoDynamicColor.resolve(
      CupertinoColors.systemGrey6.withValues(alpha: 0.96),
      context,
    );
    final border = CupertinoDynamicColor.resolve(
      CupertinoColors.separator.withValues(alpha: 0.32),
      context,
    );
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: border, width: 0.6),
            boxShadow: [
              BoxShadow(
                color: CupertinoColors.black.withValues(alpha: 0.18),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.icon,
                  size: 18,
                  color: CupertinoColors.systemPink.resolveFrom(context),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.message,
                  style: const TextStyle(
                    fontFamily: '.SF Pro Text',
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
