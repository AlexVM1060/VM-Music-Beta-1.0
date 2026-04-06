import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/history_page.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/playlist_detail_page.dart';
import 'package:myapp/playlists_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  int _tab = 1;
  Playlist? _selectedPlaylist;
  int _playlistTransitionDirection = 1;

  void _openPlaylist(Playlist playlist) {
    setState(() {
      _playlistTransitionDirection = 1;
      _selectedPlaylist = playlist;
    });
  }

  void _closePlaylist() {
    setState(() {
      _playlistTransitionDirection = -1;
      _selectedPlaylist = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasPlaylistOpen = _tab == 1 && _selectedPlaylist != null;
    return PopScope(
      canPop: !hasPlaylistOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && hasPlaylistOpen) {
          _closePlaylist();
        }
      },
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Mi Cuenta',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontFamily: '.SF Pro Display',
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.all(5),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                        width: 0.6,
                      ),
                    ),
                    child: SizedBox(
                      height: 40,
                      child: Stack(
                        children: [
                          AnimatedAlign(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            alignment: _tab == 0
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: FractionallySizedBox(
                              widthFactor: 0.5,
                              heightFactor: 1,
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(alpha: 0.16),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(
                                      color: Colors.white.withValues(alpha: 0.16),
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Expanded(
                                child: CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  onPressed: () => setState(() => _tab = 0),
                                  child: Center(
                                    child: Text(
                                      'Historial',
                                      style: TextStyle(
                                        fontFamily: '.SF Pro Text',
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                        color: _tab == 0
                                            ? CupertinoColors.label.resolveFrom(context)
                                            : CupertinoColors.secondaryLabel.resolveFrom(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  minimumSize: Size.zero,
                                  onPressed: () => setState(() => _tab = 1),
                                  child: Center(
                                    child: Text(
                                      'Playlists',
                                      style: TextStyle(
                                        fontFamily: '.SF Pro Text',
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14,
                                        color: _tab == 1
                                            ? CupertinoColors.label.resolveFrom(context)
                                            : CupertinoColors.secondaryLabel.resolveFrom(context),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                const HistoryPage(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  reverseDuration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    final beginX = _playlistTransitionDirection > 0 ? 0.14 : -0.14;
                    final slide = Tween<Offset>(
                      begin: Offset(beginX, 0),
                      end: Offset.zero,
                    ).animate(
                      CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
                    );
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: slide, child: child),
                    );
                  },
                  child: _selectedPlaylist == null
                      ? KeyedSubtree(
                          key: const ValueKey('playlists_list'),
                          child: PlaylistsPage(onOpenPlaylist: _openPlaylist),
                        )
                      : KeyedSubtree(
                          key: ValueKey('playlist_detail_${_selectedPlaylist!.name}'),
                          child: PlaylistDetailPage(
                            playlist: _selectedPlaylist!,
                            onBack: _closePlaylist,
                          ),
                        ),
                ),
              ],
            ),
          ),
          ],
        ),
      ),
    );
  }
}
