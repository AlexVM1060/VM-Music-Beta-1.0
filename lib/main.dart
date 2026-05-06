import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:myapp/account_page.dart';
import 'package:myapp/account_settings_page.dart';
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
import 'package:myapp/services/library_albums_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/app_lifecycle_service.dart';
import 'package:myapp/services/app_settings_service.dart';
import 'package:myapp/services/app_update_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/push_notification_service.dart';
import 'package:myapp/services/social_presence_sync_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/search_view_state.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/music_player_page.dart';
import 'package:provider/provider.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

const String _defaultSupabaseUrl = 'https://jziefknvztxxllogiwba.supabase.co';
const String _defaultSupabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imp6aWVma252enR4eGxsb2dpd2JhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njk2MjI1MzUsImV4cCI6MjA4NTE5ODUzNX0.uQzvXMfLT4spxhTjerxdarcMR8-f5l2KDpby-9Q1bAg';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _configureImageCacheForMobile();
  await _initSupabase();

  // Inicialización de Hive
  final appDocumentDir = await getApplicationDocumentsDirectory();
  await Hive.initFlutter(appDocumentDir.path);
  Hive.registerAdapter(VideoHistoryAdapter());
  Hive.registerAdapter(PlaylistAdapter());
  Hive.registerAdapter(DownloadedVideoAdapter());
  final appSettingsService = AppSettingsService();
  await appSettingsService.init();

  late final dynamic audioHandler;
  try {
    audioHandler = await initAudioService().timeout(
      const Duration(seconds: 10),
    );
  } catch (_) {
    audioHandler = SilentAudioHandler();
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: appSettingsService),
        ChangeNotifierProvider(
          create: (_) => VideoPlayerManager(audioHandler, appSettingsService),
        ),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => AppLifecycleService()),
        ChangeNotifierProvider(create: (_) => AppTabState()),
        ChangeNotifierProvider(create: (_) => SearchViewState()),
        ChangeNotifierProvider(create: (_) => ProfileService()..init()),
        ChangeNotifierProvider(create: (_) => SocialService()),
        Provider<SocialPresenceSyncService>(
          lazy: false,
          create: (context) {
            final syncService = SocialPresenceSyncService(
              socialService: context.read<SocialService>(),
              playerManager: context.read<VideoPlayerManager>(),
              profileService: context.read<ProfileService>(),
            );
            syncService.start();
            return syncService;
          },
          dispose: (_, service) => service.dispose(),
        ),
        Provider<PushNotificationService>(
          lazy: false,
          create: (context) {
            final pushService = PushNotificationService(
              socialService: context.read<SocialService>(),
            );
            unawaited(pushService.start());
            return pushService;
          },
        ),
        Provider(create: (_) => HistoryService()),
        Provider(create: (_) => PlaylistService()),
        ChangeNotifierProvider(
          create: (_) => DownloadService(appSettingsService),
        ),
        ChangeNotifierProvider(create: (_) => LibraryAlbumsService()..init()),
      ],
      child: const MyApp(),
    ),
  );

  unawaited(_configureAudioSessionSafe());
}

Future<void> _initSupabase() async {
  const supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: _defaultSupabaseUrl,
  );
  const supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: _defaultSupabaseAnonKey,
  );
  if (supabaseUrl.isEmpty || supabaseAnonKey.isEmpty) return;
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
}

void _configureImageCacheForMobile() {
  if (kIsWeb) return;
  if (defaultTargetPlatform != TargetPlatform.iOS &&
      defaultTargetPlatform != TargetPlatform.android) {
    return;
  }
  final imageCache = PaintingBinding.instance.imageCache;
  // Reduce picos de memoria/decodificación para bajar presión térmica.
  imageCache.maximumSize = 180;
  imageCache.maximumSizeBytes = 70 << 20; // 70 MiB
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
            avAudioSessionCategoryOptions:
                AVAudioSessionCategoryOptions.allowAirPlay,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            avAudioSessionRouteSharingPolicy:
                AVAudioSessionRouteSharingPolicy.defaultPolicy,
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
  bool get isDarkMode => _themeMode == ThemeMode.dark;

  void toggleTheme() {
    _themeMode = _themeMode == ThemeMode.light
        ? ThemeMode.dark
        : ThemeMode.light;
    notifyListeners();
  }

  void setDarkMode(bool enabled) {
    _themeMode = enabled ? ThemeMode.dark : ThemeMode.light;
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
      textTheme: GoogleFonts.robotoTextTheme(
        ThemeData(brightness: Brightness.dark).textTheme,
      ),
    );

    return Consumer2<ThemeProvider, AppLifecycleService>(
      builder: (context, themeProvider, lifecycleService, child) {
        return MaterialApp.router(
          routerConfig: router,
          title: 'Music',
          theme: lightTheme,
          darkTheme: darkTheme,
          themeMode: themeProvider.themeMode,
          debugShowCheckedModeBanner: false,
          builder: (context, child) => TickerMode(
            enabled: lifecycleService.isForeground,
            child: child ?? const SizedBox.shrink(),
          ),
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
      children: [MainTabs(), _StartupSplashOverlay(), _AppUpdateGate()],
    );
  }
}

class _AppUpdateGate extends StatefulWidget {
  const _AppUpdateGate();

  @override
  State<_AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<_AppUpdateGate> {
  bool _didCheck = false;
  bool _isChecking = false;
  final AppUpdateService _updateService = AppUpdateService();
  AppLifecycleService? _lifecycleService;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextLifecycle = context.read<AppLifecycleService?>();
    if (!identical(_lifecycleService, nextLifecycle)) {
      _lifecycleService?.removeListener(_handleLifecycleChanged);
      _lifecycleService = nextLifecycle;
      _lifecycleService?.addListener(_handleLifecycleChanged);
    }
    if (_didCheck) return;
    _didCheck = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkAndPromptUpdate());
    });
  }

  void _handleLifecycleChanged() {
    if (!mounted) return;
    final lifecycle = _lifecycleService;
    if (lifecycle == null || !lifecycle.isForeground) return;
    unawaited(_checkAndPromptUpdate());
  }

  Future<void> _checkAndPromptUpdate() async {
    if (_isChecking) return;
    _isChecking = true;
    await Future<void>.delayed(const Duration(milliseconds: 900));
    try {
      if (!mounted) return;
      final info = await _updateService.checkForUpdate();
      if (!mounted || info == null) return;
      await _showUpdateDialog(info);
    } finally {
      _isChecking = false;
    }
  }

  Future<void> _showUpdateDialog(AppUpdateInfo info) async {
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      barrierDismissible: !info.force,
      builder: (dialogContext) {
        return PopScope(
          canPop: !info.force,
          child: CupertinoAlertDialog(
            title: Text(info.title),
            content: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${info.message}\n\nVersión actual: ${info.currentVersion}\nNueva versión: ${info.latestVersion}',
              ),
            ),
            actions: [
              if (!info.force)
                CupertinoDialogAction(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Más tarde'),
                ),
              ...info.actions.asMap().entries.map((entry) {
                final index = entry.key;
                final action = entry.value;
                return CupertinoDialogAction(
                  isDefaultAction: index == 0,
                  onPressed: () async {
                    final uri = Uri.tryParse(action.url);
                    if (uri != null) {
                      await launchUrl(
                        uri,
                        mode: LaunchMode.externalApplication,
                      );
                    }
                    if (!dialogContext.mounted) return;
                    if (!info.force) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: Text(action.label),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.shrink();
  }

  @override
  void dispose() {
    _lifecycleService?.removeListener(_handleLifecycleChanged);
    super.dispose();
  }
}

class _StartupSplashOverlay extends StatefulWidget {
  const _StartupSplashOverlay();

  @override
  State<_StartupSplashOverlay> createState() => _StartupSplashOverlayState();
}

class _StartupSplashOverlayState extends State<_StartupSplashOverlay>
    with TickerProviderStateMixin {
  late final AnimationController _entryController;
  late final AnimationController _exitController;
  late final AnimationController _loopController;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1150),
    )..forward();
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
    );
    _loopController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2100),
    )..repeat(reverse: true);

    unawaited(() async {
      await Future<void>.delayed(const Duration(milliseconds: 1650));
      if (!mounted) return;
      await _exitController.forward();
      if (!mounted) return;
      setState(() {
        _visible = false;
      });
    }());
  }

  @override
  void dispose() {
    _entryController.dispose();
    _exitController.dispose();
    _loopController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = Theme.of(context).colorScheme.primary;
    final backgroundA = isDark
        ? const Color(0xFF060708)
        : CupertinoColors.systemBackground.resolveFrom(context);
    final backgroundB = isDark
        ? const Color(0xFF0F1218)
        : CupertinoColors.systemGrey6.resolveFrom(context);

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([
          _entryController,
          _exitController,
          _loopController,
        ]),
        builder: (context, _) {
          final intro = Curves.easeOutCubic.transform(_entryController.value);
          final fadeOut = Curves.easeInCubic.transform(_exitController.value);
          final opacity = (1.0 - fadeOut).clamp(0.0, 1.0);
          final titleLift = 14.0 * (1.0 - intro);
          final titleScale = 0.94 + (0.06 * intro);
          final wave = Curves.easeInOutSine.transform(_loopController.value);

          return Opacity(
            opacity: opacity,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    backgroundA,
                    Color.lerp(backgroundA, base, 0.06) ?? backgroundA,
                    backgroundB,
                  ],
                ),
              ),
              child: Center(
                child: Transform.translate(
                  offset: Offset(0, titleLift),
                  child: Transform.scale(
                    scale: titleScale,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.scale(
                          scale: 1.0 + (0.10 * (1.0 - wave)),
                          child: SizedBox(
                            width: 108,
                            height: 108,
                            child: Image.asset(
                              'assets/iconloadscreen.png',
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) =>
                                  Icon(
                                    CupertinoIcons.music_note_2,
                                    color: base,
                                    size: 42,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 18),
                        ShaderMask(
                          blendMode: BlendMode.srcIn,
                          shaderCallback: (bounds) {
                            final shimmerCenter = (0.2 + (0.6 * wave)).clamp(
                              0.0,
                              1.0,
                            );
                            return LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                base.withValues(alpha: 0.62),
                                base.withValues(alpha: 0.96),
                                Colors.white.withValues(alpha: 0.95),
                                base.withValues(alpha: 0.96),
                                base.withValues(alpha: 0.62),
                              ],
                              stops: [
                                0.0,
                                (shimmerCenter - 0.20).clamp(0.0, 1.0),
                                shimmerCenter,
                                (shimmerCenter + 0.20).clamp(0.0, 1.0),
                                1.0,
                              ],
                            ).createShader(bounds);
                          },
                          child: Text(
                            'Music',
                            style: Theme.of(context).textTheme.headlineMedium
                                ?.copyWith(
                                  fontFamily: '.SF Pro Display',
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: -0.2,
                                ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        const CupertinoActivityIndicator(radius: 11),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class OverlayVideoPlayer extends StatelessWidget {
  const OverlayVideoPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final hasTrack = context.select<VideoPlayerManager, bool>(
      (manager) => manager.currentVideoId != null,
    );
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
            child: SlideTransition(position: slide, child: child),
          );
        },
        child: hasTrack
            ? const MusicPlayerPage(key: ValueKey('overlay_player'))
            : const SizedBox.shrink(key: ValueKey('overlay_empty')),
      ),
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
  final Set<int> _visitedTabIndexes = <int>{0};

  Widget _buildTabPage(int index) {
    switch (index) {
      case 0:
        return const _KeepAlivePage(child: HomePage());
      case 1:
        return const _KeepAlivePage(child: SearchPage());
      case 2:
        return const _KeepAlivePage(child: DownloadsPage());
      case 3:
        return const _KeepAlivePage(child: AccountPage());
      default:
        return const SizedBox.shrink();
    }
  }

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
      _visitedTabIndexes.add(index);
      tabState.setIndex(index);
      return;
    }
    if (_fallbackSelectedIndex == index) return;
    setState(() {
      _fallbackSelectedIndex = index;
      _visitedTabIndexes.add(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tabState = context.watch<AppTabState?>();
    final selectedIndex = tabState?.selectedIndex ?? _fallbackSelectedIndex;
    _visitedTabIndexes.add(selectedIndex);
    final isSearchFullscreen = context.select<SearchViewState, bool>(
      (state) => state.isArtistFullscreen,
    );
    final isLibraryAlbumFullscreen = context.select<SearchViewState, bool>(
      (state) => state.isLibraryAlbumFullscreen,
    );
    _pageController ??= PageController(initialPage: _displayedPageIndex);
    final controller = _pageController!;
    final playerState = context
        .select<
          VideoPlayerManager,
          ({String? currentVideoId, bool isMinimized, bool isFullScreen})
        >(
          (manager) => (
            currentVideoId: manager.currentVideoId,
            isMinimized: manager.isMinimized,
            isFullScreen: manager.isFullScreen,
          ),
        );
    final isFullScreen = playerState.isFullScreen;
    final isExpandedPlayerVisible =
        playerState.currentVideoId != null && !playerState.isMinimized;
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shellBackground = isDark
        ? Colors.black
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final hideMainAppBar =
        selectedIndex == 3 ||
        (selectedIndex == 1 && isSearchFullscreen) ||
        (selectedIndex == 2 && isLibraryAlbumFullscreen);
    final pagesWithTickerMode = List<Widget>.generate(
      4,
      (index) => TickerMode(
        enabled: index == selectedIndex,
        child: _visitedTabIndexes.contains(index)
            ? _buildTabPage(index)
            : const SizedBox.shrink(),
      ),
      growable: false,
    );

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
          resizeToAvoidBottomInset: false,
          extendBody: true,
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
                  automaticallyImplyLeading: false,
                  leading: Align(
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Transform.translate(
                          offset: const Offset(0, 5),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.asset(
                              'assets/iconloadscreen.png',
                              width: 45,
                              height: 35,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Music',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(
                                fontFamily: '.SF Pro Display',
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.2,
                              ),
                        ),
                      ],
                    ),
                  ),
                  trailing: IconButton(
                    tooltip: 'Configuración',
                    iconSize: 24,
                    icon: const Icon(CupertinoIcons.settings),
                    onPressed: () {
                      Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          builder: (_) => const AccountSettingsPage(),
                        ),
                      );
                    },
                  ),
                ),
          body: PageView(
            controller: controller,
            physics: const NeverScrollableScrollPhysics(),
            children: pagesWithTickerMode,
          ),
        ),
        const Positioned.fill(child: OverlayVideoPlayer()),
        if (!isFullScreen && !isExpandedPlayerVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _CupertinoRootTabBar(
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

  const _KeepAlivePage({required this.child});

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

  const _CupertinoRootTabBar({required this.currentIndex, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inactive = CupertinoColors.secondaryLabel.resolveFrom(context);
    final active = CupertinoColors.systemPink.resolveFrom(context);
    final lightweightEffects =
        defaultTargetPlatform == TargetPlatform.iOS ||
        context.select<AppLifecycleService, bool>((s) => !s.isForeground) ||
        (context.select<AppSettingsService?, bool>(
          (s) => s?.dataSaverMode ?? false,
        ));
    const items = <({IconData icon, String label})>[
      (icon: CupertinoIcons.home, label: 'Inicio'),
      (icon: CupertinoIcons.search, label: 'Buscar'),
      (icon: CupertinoIcons.double_music_note, label: 'Biblioteca'),
      (icon: CupertinoIcons.person_crop_circle, label: 'Perfil'),
    ];
    final photoPath = context.select<ProfileService, String?>(
      (service) => service.photoPath,
    );
    final cleanPhotoPath = (photoPath ?? '').trim();
    final hasLocalPhoto =
        cleanPhotoPath.isNotEmpty && File(cleanPhotoPath).existsSync();

    final barContent = Container(
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 0.11),
                  Colors.white.withValues(alpha: 0.06),
                ]
              : [
                  const Color(0xFFE5E7EB).withValues(alpha: 0.88),
                  const Color(0xFFD1D5DB).withValues(alpha: 0.70),
                ],
        ),
        border: Border.all(
          color: isDark
              ? Colors.white.withValues(alpha: 0.16)
              : const Color(0xFFCBD5E1).withValues(alpha: 0.92),
          width: 0.9,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.14),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: List.generate(items.length, (index) {
          final selected = index == currentIndex;
          return Expanded(
            child: _LiquidTabButton(
              icon: items[index].icon,
              iconWidget: index == items.length - 1 && hasLocalPhoto
                  ? ClipOval(
                      child: Image.file(
                        File(cleanPhotoPath),
                        width: 22,
                        height: 22,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Icon(
                          items[index].icon,
                          size: 22,
                          color: selected ? active : inactive,
                        ),
                      ),
                    )
                  : null,
              label: items[index].label,
              selected: selected,
              activeColor: active,
              inactiveColor: inactive,
              onPressed: () => onTap(index),
            ),
          );
        }),
      ),
    );

    return SafeArea(
      top: false,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: lightweightEffects
              ? barContent
              : BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: barContent,
                ),
        ),
      ),
    );
  }
}

class _LiquidTabButton extends StatelessWidget {
  final IconData icon;
  final Widget? iconWidget;
  final String label;
  final bool selected;
  final Color activeColor;
  final Color inactiveColor;
  final VoidCallback onPressed;

  const _LiquidTabButton({
    required this.icon,
    this.iconWidget,
    required this.label,
    required this.selected,
    required this.activeColor,
    required this.inactiveColor,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final selectedBg = isDark
        ? Colors.white.withValues(alpha: 0.13)
        : const Color(0xFFD1D5DB).withValues(alpha: 0.72);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: selected ? selectedBg : Colors.transparent,
        border: selected
            ? Border.all(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.20)
                    : const Color(0xFFCBD5E1).withValues(alpha: 0.94),
                width: 0.7,
              )
            : null,
      ),
      child: CupertinoButton(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
        minimumSize: Size.zero,
        onPressed: onPressed,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            iconWidget ??
                Icon(
                  icon,
                  size: 22,
                  color: selected ? activeColor : inactiveColor,
                ),
            const SizedBox(height: 3),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: '.SF Pro Text',
                fontSize: 11.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? activeColor : inactiveColor,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
