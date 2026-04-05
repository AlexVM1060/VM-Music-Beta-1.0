import 'package:flutter/material.dart';
import 'package:myapp/history_page.dart';
import 'package:myapp/playlists_page.dart';

class AccountPage extends StatelessWidget {
  const AccountPage({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          title: const Text(
            'Mi Cuenta',
            style: TextStyle(
              fontFamily: '.SF Pro Display',
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          bottom: const TabBar(
            labelStyle: TextStyle(
              fontFamily: '.SF Pro Text',
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
            unselectedLabelStyle: TextStyle(
              fontFamily: '.SF Pro Text',
              fontWeight: FontWeight.w500,
              fontSize: 15,
            ),
            tabs: [
              Tab(text: 'Historial'),
              Tab(text: 'Playlists'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            HistoryPage(),
            PlaylistsPage(),
          ],
        ),
      ),
    );
  }
}
