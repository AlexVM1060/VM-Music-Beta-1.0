import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:myapp/account_settings_page.dart';
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
            if (!hasPlaylistOpen) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Mi Cuenta',
                        style: Theme.of(context).textTheme.headlineMedium
                            ?.copyWith(
                              fontFamily: '.SF Pro Display',
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Configuración',
                      icon: const Icon(CupertinoIcons.settings),
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const AccountSettingsPage(),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: CupertinoSlidingSegmentedControl<int>(
                  groupValue: _tab,
                  children: const {
                    0: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('Historial'),
                    ),
                    1: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text('Playlists'),
                    ),
                  },
                  onValueChanged: (value) {
                    if (value == null) return;
                    setState(() => _tab = value);
                  },
                  thumbColor: CupertinoColors.systemBackground.resolveFrom(
                    context,
                  ),
                  backgroundColor:
                      CupertinoColors.tertiarySystemFill.resolveFrom(context),
                ),
              ),
            ],
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: CupertinoColors.systemBackground.resolveFrom(context),
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                ),
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
                        final beginX = _playlistTransitionDirection > 0
                            ? 0.14
                            : -0.14;
                        final slide =
                            Tween<Offset>(
                              begin: Offset(beginX, 0),
                              end: Offset.zero,
                            ).animate(
                              CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                              ),
                            );
                        return FadeTransition(
                          opacity: animation,
                          child: SlideTransition(position: slide, child: child),
                        );
                      },
                      child: _selectedPlaylist == null
                          ? KeyedSubtree(
                              key: const ValueKey('playlists_list'),
                              child: PlaylistsPage(
                                onOpenPlaylist: _openPlaylist,
                              ),
                            )
                          : KeyedSubtree(
                              key: ValueKey(
                                'playlist_detail_${_selectedPlaylist!.name}',
                              ),
                              child: PlaylistDetailPage(
                                playlist: _selectedPlaylist!,
                                onBack: _closePlaylist,
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
