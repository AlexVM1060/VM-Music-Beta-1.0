import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/widgets/square_thumbnail.dart';

Future<String?> showGlassPlaylistPickerSheet({
  required BuildContext context,
  required List<Playlist> playlists,
  String? subtitle,
}) async {
  if (playlists.isEmpty) return null;
  final cleanSubtitle = subtitle?.trim();

  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(sheetContext).size.height * 0.78,
                ),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6
                      .resolveFrom(sheetContext)
                      .withValues(alpha: 0.82),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(
                    color: CupertinoColors.white.withValues(alpha: 0.24),
                    width: 0.7,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey3
                            .resolveFrom(sheetContext)
                            .withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          Text(
                            'Añadir a playlist',
                            style: CupertinoTheme.of(sheetContext)
                                .textTheme
                                .navTitleTextStyle
                                .copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(34, 34),
                            onPressed: () => Navigator.of(sheetContext).pop(),
                            child: Icon(
                              CupertinoIcons.xmark_circle_fill,
                              size: 24,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                sheetContext,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (cleanSubtitle != null && cleanSubtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            cleanSubtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: CupertinoTheme.of(sheetContext)
                                .textTheme
                                .textStyle
                                .copyWith(
                                  color: CupertinoColors.secondaryLabel
                                      .resolveFrom(sheetContext),
                                  fontSize: 13,
                                ),
                          ),
                        ),
                      ),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
                        itemCount: playlists.length,
                        itemBuilder: (context, index) {
                          final playlist = playlists[index];
                          final cover = playlist.videos.isNotEmpty
                              ? playlist.videos.first.thumbnailUrl
                              : null;
                          final isFavorites =
                              PlaylistService.isFavoritesPlaylistName(
                                playlist.name,
                              );
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: _GlassPlaylistPickerRow(
                              name: playlist.name,
                              songsCount: playlist.videos.length,
                              coverUrl: cover,
                              isFavorites: isFavorites,
                              onTap: () =>
                                  Navigator.of(sheetContext).pop(playlist.name),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _GlassPlaylistPickerRow extends StatelessWidget {
  final String name;
  final int songsCount;
  final String? coverUrl;
  final bool isFavorites;
  final VoidCallback onTap;

  const _GlassPlaylistPickerRow({
    required this.name,
    required this.songsCount,
    required this.coverUrl,
    required this.isFavorites,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      color: CupertinoColors.systemGrey4.resolveFrom(context),
      alignment: Alignment.center,
      child: Icon(
        isFavorites ? CupertinoIcons.star_fill : CupertinoIcons.music_note_list,
        size: 20,
        color: CupertinoColors.white,
      ),
    );
    final trimmedCover = coverUrl?.trim();
    final localFile =
        trimmedCover != null &&
        trimmedCover.startsWith('/') &&
        File(trimmedCover).existsSync();

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Material(
          color: Colors.white.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: CupertinoColors.white.withValues(alpha: 0.18),
                  width: 0.6,
                ),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: SizedBox(
                      width: 52,
                      height: 52,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (trimmedCover == null || trimmedCover.isEmpty)
                            fallback
                          else if (localFile)
                            SquareThumbnail.file(
                              filePath: trimmedCover,
                              size: 52,
                              borderRadius: 0,
                              fallback: fallback,
                            )
                          else
                            SquareThumbnail.network(
                              imageUrl: trimmedCover,
                              size: 52,
                              borderRadius: 0,
                              zoom: 1.24,
                              fallback: fallback,
                            ),
                          if (isFavorites)
                            Align(
                              alignment: Alignment.topRight,
                              child: Container(
                                margin: const EdgeInsets.all(3),
                                width: 15,
                                height: 15,
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.42),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  CupertinoIcons.star_fill,
                                  size: 9,
                                  color: Color(0xFFFFD24A),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$songsCount canciones',
                          style: TextStyle(
                            fontFamily: '.SF Pro Text',
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    CupertinoIcons.chevron_right,
                    size: 17,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
