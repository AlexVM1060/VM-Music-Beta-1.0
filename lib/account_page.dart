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
  int _tab = 0;
  Playlist? _selectedPlaylist;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
                borderRadius: BorderRadius.circular(14),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGrey6.resolveFrom(context).withValues(alpha: 0.42),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.16),
                        width: 0.6,
                      ),
                    ),
                    child: CupertinoSlidingSegmentedControl<int>(
                      groupValue: _tab,
                      children: const {
                        0: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                          child: Text(
                            'Historial',
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        1: Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                          child: Text(
                            'Playlists',
                            style: TextStyle(
                              fontFamily: '.SF Pro Text',
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      },
                      thumbColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.28),
                      onValueChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _tab = value;
                        });
                      },
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
                _selectedPlaylist == null
                    ? PlaylistsPage(
                        onOpenPlaylist: (playlist) {
                          setState(() {
                            _selectedPlaylist = playlist;
                          });
                        },
                      )
                    : PlaylistDetailPage(
                        playlist: _selectedPlaylist!,
                        onBack: () {
                          setState(() {
                            _selectedPlaylist = null;
                          });
                        },
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
