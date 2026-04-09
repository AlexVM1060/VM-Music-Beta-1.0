import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:myapp/account_page.dart';
import 'package:myapp/app_tab_state.dart';
import 'package:myapp/audio_handler.dart';
import 'package:myapp/downloads_page.dart';
import 'package:myapp/home_page.dart';
import 'package:myapp/models/downloaded_video.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/router.dart';
import 'package:myapp/search_page.dart';
import 'package:myapp/services/download_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/music_player_page.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicialización de Hive
  final appDocumentDir = await getApplicationDocumentsDirectory();
  await Hive.initFlutter(appDocumentDir.path);
  Hive.registerAdapter(VideoHistoryAdapter());
  Hive.registerAdapter(PlaylistAdapter());
  Hive.registerAdapter(DownloadedVideoAdapter());

  late final dynamic audioHandler;
  try {
    audioHandler = await initAudioService().timeout(const Duration(seconds: 10));
  } catch (_) {
    audioHandler = SilentAudioHandler();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => VideoPlayerManager(audioHandler)),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AppTabState()),
        ChangeNotifierProvider(create: (_) => SearchViewState()),
        Provider(create: (_) => HistoryService()),
        Provider(create: (_) => PlaylistService()),
        ChangeNotifierProvider(create: (_) => DownloadService()),      ],
      child: const MyApp(),
    ),
  );

  unawaited(_configureAudioSessionSafe());
}

Future<void> _configureAudioSessionSafe() async {
  try {
    final session = await AudioSession.instance.timeout(
      const Duration(seconds: 5),
    );
    await session
        .configure(
          const AudioSessionConfiguration(
            avAudioSessionCategory: AVAudioSessionCategory.playback,
            avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.allowAirPlay,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
            avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.music,
              flags: AndroidAudioFlags.none,
              usage: AndroidAudioUsage.media,
            ),
            androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
            androidWillPauseWhenDucked: false,
          ),
        )
        .timeout(const Duration(seconds: 5));
    await session.setActive(true).timeout(const Duration(seconds: 5));
  } catch (_) {
    // No bloqueamos el arranque de la app por configuración de audio.
  }
}

class ThemeProvider with ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  void toggleTheme() {
    _themeMode = _themeMode == ThemeMode.light ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color.fromARGB(255, 207, 21, 21),
        brightness: Brightness.light,
      ),
      cupertinoOverrideTheme: const CupertinoThemeData(
        brightness: Brightness.light,
      ),
      textTheme: GoogleFonts.robotoTextTheme(),
    );

    final darkTheme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: CupertinoColors.systemPink,
        brightness: Brightness.dark,
      ),
      cupertinoOverrideTheme: const CupertinoThemeData(
        brightness: Brightness.dark,
      ),
      textTheme: GoogleFonts.robotoTextTheme(ThemeData(brightness: Brightness.dark).textTheme),
    );

    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp.router(
          routerConfig: router,
          title: 'VM Music',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeProvider.themeMode,
          debugShowCheckedModeBanner: false,
        );
      },
    );
  }
}

class AppShell extends StatelessWidget {
  const AppShell({super.key});

  @override
  Widget build(BuildContext context) {
    return const Stack(
      children: [
        MainTabs(),
        OverlayVideoPlayer(),
      ],
    );
  }
}

class OverlayVideoPlayer extends StatelessWidget {
  const OverlayVideoPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<VideoPlayerManager>(
      builder: (context, manager, child) {
        final hasTrack = manager.currentVideoId != null;
        return IgnorePointer(
          ignoring: !hasTrack,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            reverseDuration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                fit: StackFit.expand,
                alignment: Alignment.bottomCenter,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              final fade = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
              final slide = Tween<Offset>(
                begin: const Offset(0, 0.05),
                end: Offset.zero,
              ).animate(curved);
              return FadeTransition(
                opacity: fade,
                child: SlideTransition(
                  position: slide,
                  child: child,
                ),
              );
            },
            child: hasTrack
                ? const MusicPlayerPage(key: ValueKey('overlay_player'))
                : const SizedBox.shrink(key: ValueKey('overlay_empty')),
          ),
        );
      },
    );
  }
}

class MainTabs extends StatefulWidget {
  const MainTabs({super.key});

  @override
  State<MainTabs> createState() => _MainTabsState();
}

class _MainTabsState extends State<MainTabs> {
  int _fallbackSelectedIndex = 0;
  PageController? _pageController;
  int _displayedPageIndex = 0;

  static const List<Widget> _pages = <Widget>[
    _KeepAlivePage(child: HomePage()),
    _KeepAlivePage(child: SearchPage()),
    _KeepAlivePage(child: DownloadsPage()),
    _KeepAlivePage(child: AccountPage()),
  ];

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: _displayedPageIndex);
  }

  @override
  void dispose() {
    _pageController?.dispose();
    super.dispose();
  }

  void _onItemTapped(int index) {
    final tabState = context.read<AppTabState?>();
    if (tabState != null) {
      tabState.setIndex(index);
      return;
    }
    if (_fallbackSelectedIndex == index) return;
    setState(() {
      _fallbackSelectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabState = context.watch<AppTabState?>();
    final selectedIndex = tabState?.selectedIndex ?? _fallbackSelectedIndex;
    _pageController ??= PageController(initialPage: _displayedPageIndex);
    final controller = _pageController!;
    final isFullScreen = context.watch<VideoPlayerManager>().isFullScreen;
    final searchViewState = context.watch<SearchViewState>();
    final themeProvider = Provider.of<ThemeProvider>(context);
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shellBackground = isDark
        ? Colors.black
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final hideMainAppBar =
        selectedIndex == 3 || (selectedIndex == 1 && searchViewState.isArtistFullscreen);

    if (_displayedPageIndex != selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted || !controller.hasClients) return;
        _displayedPageIndex = selectedIndex;
        await controller.animateToPage(
          selectedIndex,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      });
    }

    return Stack(
      children: [
        Scaffold(
          extendBody: false,
          backgroundColor: shellBackground,
          appBar: hideMainAppBar
              ? null
              : CupertinoNavigationBar(
                  transitionBetweenRoutes: false,
                  backgroundColor: shellBackground,
                  border: Border(
                    bottom: BorderSide(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.12)
                          : colorScheme.outlineVariant.withValues(alpha: 0.35),
                      width: 0.0,
                    ),
                  ),
                  middle: const Text(
                    'VM Music',
                    style: TextStyle(
                      fontFamily: '.SF Pro Display',
                      fontWeight: FontWeight.w700,
                      fontSize: 20,
                      letterSpacing: -0.2,
                    ),
                  ),
                  trailing: CupertinoButton(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(28, 28),
                    onPressed: () => themeProvider.toggleTheme(),
                    child: Icon(
                      themeProvider.themeMode == ThemeMode.dark
                          ? CupertinoIcons.sun_max_fill
                          : CupertinoIcons.moon_fill,
                      size: 20,
                      color: CupertinoColors.systemPink.resolveFrom(context),
                    ),
                  ),
                ),
          body: PageView(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            children: _pages,
          ),
          bottomNavigationBar: isFullScreen
              ? null
              : _CupertinoRootTabBar(
                  currentIndex: selectedIndex,
                  onTap: _onItemTapped,
                ),
        ),
      ],
    );
  }
}

class _KeepAlivePage extends StatefulWidget {
  final Widget child;

  const _KeepAlivePage({
    required this.child,
  });

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _CupertinoRootTabBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onTap;

  const _CupertinoRootTabBar({
    required this.currentIndex,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shellBackground = isDark
        ? Colors.black
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    const items = <({IconData icon, String label})>[
      (icon: CupertinoIcons.home, label: 'Inicio'),
      (icon: CupertinoIcons.search, label: 'Buscar'),
      (icon: CupertinoIcons.arrow_down_circle, label: 'Descargas'),
      (icon: CupertinoIcons.person_crop_circle, label: 'Cuenta'),
    ];

    return CupertinoTabBar(
      currentIndex: currentIndex,
      onTap: onTap,
      iconSize: 24,
      activeColor: CupertinoColors.systemPink.resolveFrom(context),
      inactiveColor: CupertinoColors.secondaryLabel.resolveFrom(context),
      border: Border(
        top: BorderSide(
          color: isDark
              ? Colors.white.withValues(alpha: 0.12)
              : colorScheme.outlineVariant.withValues(alpha: 0.35),
          width: 0.0,
        ),
      ),
      backgroundColor: shellBackground,
      items: List.generate(
        items.length,
        (index) => BottomNavigationBarItem(
          icon: Icon(items[index].icon),
          label: items[index].label,
        ),
      ),
    );
  }
}
