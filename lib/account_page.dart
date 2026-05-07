import 'dart:io';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/account_settings_page.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/models/video_history.dart';
import 'package:myapp/playlist_detail_page.dart';
import 'package:myapp/playlists_page.dart';
import 'package:myapp/profile_edit_page.dart';
import 'package:myapp/services/profile_frames_service.dart';
import 'package:myapp/services/history_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:myapp/widgets/square_thumbnail.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

enum _FrameFilter { all, stickers, live }

class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  static const String _pinnedPlaylistsBoxName = 'library_pinned_playlists';
  static const String _pinnedPlaylistsKey = 'names';
  late Future<List<Playlist>> _playlistsFuture;
  late Future<List<VideoHistory>> _historyFuture;
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _noteController = TextEditingController();
  final FocusNode _noteFocusNode = FocusNode();
  bool _isEditingNoteInline = false;
  bool _isLoadingFrames = false;
  bool _showAllPlaylists = false;
  Playlist? _selectedPlaylist;
  int _playlistTransitionDirection = 1;
  List<String> _pinnedPlaylistNames = const <String>[];
  StreamSubscription<BoxEvent>? _pinnedPlaylistsSub;

  @override
  void initState() {
    super.initState();
    _refreshData();
    _loadPinnedPlaylists();
  }

  void _refreshData() {
    _playlistsFuture = context.read<PlaylistService>().getPlaylists();
    _historyFuture = context.read<HistoryService>().getHistory();
  }

  Future<Box<dynamic>> get _pinnedPlaylistsBox async =>
      Hive.openBox<dynamic>(_pinnedPlaylistsBoxName);

  Future<void> _loadPinnedPlaylists() async {
    final box = await _pinnedPlaylistsBox;
    _pinnedPlaylistsSub?.cancel();
    _pinnedPlaylistsSub = box.watch(key: _pinnedPlaylistsKey).listen((_) {
      unawaited(_loadPinnedPlaylists());
    });
    final raw = box.get(_pinnedPlaylistsKey);
    final names = raw is List
        ? raw
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList()
        : <String>[];
    if (!mounted) return;
    setState(() {
      _pinnedPlaylistNames = names;
    });
  }

  bool _isPlaylistPinned(Playlist playlist) {
    final normalized = playlist.name.trim().toLowerCase();
    return _pinnedPlaylistNames.any(
      (name) => name.trim().toLowerCase() == normalized,
    );
  }

  Future<void> _togglePinnedPlaylist(Playlist playlist) async {
    final normalized = playlist.name.trim().toLowerCase();
    final alreadyPinned = _pinnedPlaylistNames.any(
      (name) => name.trim().toLowerCase() == normalized,
    );
    final updated = alreadyPinned
        ? _pinnedPlaylistNames
              .where((name) => name.trim().toLowerCase() != normalized)
              .toList(growable: false)
        : <String>[playlist.name, ..._pinnedPlaylistNames];
    setState(() {
      _pinnedPlaylistNames = updated;
    });
    final box = await _pinnedPlaylistsBox;
    await box.put(_pinnedPlaylistsKey, updated);
  }

  Future<void> _changePhoto(ProfileService profile) async {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (dialogContext) => CupertinoActionSheet(
        title: const Text('Foto de perfil'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              final file = await _picker.pickImage(
                source: ImageSource.gallery,
                imageQuality: 88,
                maxWidth: 1200,
              );
              if (file == null) return;
              final docsDir = await getApplicationDocumentsDirectory();
              final fileName =
                  'profile_${DateTime.now().millisecondsSinceEpoch}${p.extension(file.path)}';
              final target = File(p.join(docsDir.path, fileName));
              await File(file.path).copy(target.path);
              await profile.updatePhotoPath(target.path);
              await _syncProfileToSupabase(profile);
            },
            child: const Text('Elegir de galeria'),
          ),
          if ((profile.photoPath ?? '').isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                final oldPath = profile.photoPath;
                await profile.updatePhotoPath(null);
                if (oldPath != null && oldPath.isNotEmpty) {
                  final file = File(oldPath);
                  if (await file.exists()) {
                    await file.delete();
                  }
                }
                await _syncProfileToSupabase(profile);
              },
              child: const Text('Quitar foto'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancelar'),
        ),
      ),
    );
  }

  Future<void> _syncProfileToSupabase(ProfileService profile) async {
    try {
      final social = context.read<SocialService>();
      final player = context.read<VideoPlayerManager>();
      final currentSong = (player.trackTitle ?? '').trim();
      final currentArtist = (player.trackArtist ?? '').trim();
      final currentVideoId = (player.currentVideoId ?? '').trim();
      final isPlaying = currentSong.isNotEmpty && player.isPlaying;
      await social.publishProfile(
        profile: profile,
        currentSong: currentSong,
        currentArtist: currentArtist,
        currentVideoId: currentVideoId,
        isPlaying: isPlaying,
      );
    } catch (_) {
      // Mejor esfuerzo: no bloqueamos cambio de foto por red/supabase.
    }
  }

  String _stripQuery(String url) {
    final idx = url.indexOf('?');
    if (idx < 0) return url;
    return url.substring(0, idx);
  }

  String _cacheBustUrl(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}v=${DateTime.now().millisecondsSinceEpoch}';
  }

  String _urlExtension(String url) {
    final clean = _stripQuery(url).toLowerCase();
    final dot = clean.lastIndexOf('.');
    if (dot < 0 || dot == clean.length - 1) return '';
    return clean.substring(dot);
  }

  bool _isLiveStickerUrl(String url) => _urlExtension(url) == '.gif';

  bool _isStaticStickerUrl(String url) {
    final ext = _urlExtension(url);
    return ext == '.png' || ext == '.jpg' || ext == '.jpeg';
  }

  List<String> _filterFrames(List<String> frames, _FrameFilter filter) {
    switch (filter) {
      case _FrameFilter.all:
        return frames;
      case _FrameFilter.stickers:
        return frames.where(_isStaticStickerUrl).toList(growable: false);
      case _FrameFilter.live:
        return frames.where(_isLiveStickerUrl).toList(growable: false);
    }
  }

  Future<void> _pickFrame(ProfileService profile) async {
    if (_isLoadingFrames) return;
    setState(() => _isLoadingFrames = true);
    List<String> frames = const [];
    try {
      frames = await ProfileFramesService.fetchFrameUrls();
    } catch (_) {
      frames = const [];
    } finally {
      if (mounted) setState(() => _isLoadingFrames = false);
    }
    if (!mounted) return;
    _FrameFilter selectedFilter = _FrameFilter.all;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (dialogContext) => CupertinoActionSheet(
        title: const Text('Selecciona un Sticker'),
        message: StatefulBuilder(
          builder: (context, setModalState) {
            final filteredFrames = _filterFrames(frames, selectedFilter);
            return SizedBox(
              height: 290,
              child: Column(
                children: [
                  CupertinoSlidingSegmentedControl<_FrameFilter>(
                    groupValue: selectedFilter,
                    children: const {
                      _FrameFilter.all: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('Todos'),
                      ),
                      _FrameFilter.stickers: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('Stickers'),
                      ),
                      _FrameFilter.live: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Text('Live Stickers'),
                      ),
                    },
                    onValueChanged: (value) {
                      if (value == null) return;
                      setModalState(() => selectedFilter = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: frames.isEmpty
                        ? const Center(
                            child: Text('No hay Stickers disponibles'),
                          )
                        : filteredFrames.isEmpty
                        ? const Center(
                            child: Text('No hay stickers en este filtro'),
                          )
                        : GridView.builder(
                            itemCount: filteredFrames.length,
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 8,
                                  crossAxisSpacing: 8,
                                ),
                            itemBuilder: (_, index) {
                              final url = filteredFrames[index];
                              final current = (profile.frameUrl ?? '').trim();
                              final isSelected =
                                  _stripQuery(current) == _stripQuery(url);
                              return GestureDetector(
                                onTap: () async {
                                  Navigator.of(dialogContext).pop();
                                  await profile.updateFrameUrl(
                                    _cacheBustUrl(url),
                                  );
                                  await _syncProfileToSupabase(profile);
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: isSelected
                                          ? CupertinoColors.activeBlue
                                          : CupertinoColors.systemGrey4,
                                      width: isSelected ? 2 : 1,
                                    ),
                                  ),
                                  padding: const EdgeInsets.all(6),
                                  child: Image.network(
                                    url,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await profile.updateFrameUrl(null);
              await _syncProfileToSupabase(profile);
            },
            child: const Text('Quitar Sticker'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cerrar'),
        ),
      ),
    );
  }

  void _startInlineNoteEdit(ProfileService profile) {
    _noteController.text = profile.bio.trim();
    setState(() => _isEditingNoteInline = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _noteFocusNode.requestFocus();
    });
  }

  void _cancelInlineNoteEdit() {
    setState(() => _isEditingNoteInline = false);
  }

  void _openPlaylistInline(Playlist playlist) {
    setState(() {
      _playlistTransitionDirection = 1;
      _selectedPlaylist = playlist;
    });
  }

  void _closePlaylistInline() {
    setState(() {
      _playlistTransitionDirection = -1;
      _selectedPlaylist = null;
      _refreshData();
    });
  }

  void _openAllPlaylists() {
    setState(() {
      _playlistTransitionDirection = 1;
      _showAllPlaylists = true;
      _selectedPlaylist = null;
    });
  }

  void _closeAllPlaylists() {
    setState(() {
      _playlistTransitionDirection = -1;
      _showAllPlaylists = false;
      _selectedPlaylist = null;
      _refreshData();
    });
  }

  Future<void> _saveInlineNote(ProfileService profile) async {
    final social = context.read<SocialService>();
    final player = context.read<VideoPlayerManager>();
    await profile.updateProfile(
      name: profile.name,
      username: profile.username,
      bio: _noteController.text,
    );
    try {
      final currentSong = (player.trackTitle ?? '').trim();
      final currentArtist = (player.trackArtist ?? '').trim();
      final currentVideoId = (player.currentVideoId ?? '').trim();
      final isPlaying = currentSong.isNotEmpty && player.isPlaying;
      await social.syncNowPlaying(
        profile: profile,
        currentSong: currentSong,
        currentArtist: currentArtist,
        currentVideoId: currentVideoId,
        isPlaying: isPlaying,
      );
    } catch (_) {
      // Mejor esfuerzo: no bloqueamos guardar nota si falla red/supabase.
    }
    if (!mounted) return;
    setState(() => _isEditingNoteInline = false);
  }

  Duration _estimatePlayedDuration(List<VideoHistory> history) {
    if (history.isEmpty) return Duration.zero;
    return Duration(minutes: history.length * 4);
  }

  String _formatHours(Duration duration) {
    final hours = duration.inMinutes / 60.0;
    return hours.toStringAsFixed(1);
  }

  int _countCreatedPlaylists(List<Playlist> playlists) {
    return playlists
        .where(
          (playlist) =>
              !PlaylistService.isFavoritesPlaylistName(playlist.name.trim()),
        )
        .length;
  }

  Future<void> _handleRefresh() async {
    setState(_refreshData);
    await Future.wait([_playlistsFuture, _historyFuture]);
  }

  @override
  void dispose() {
    _pinnedPlaylistsSub?.cancel();
    _noteController.dispose();
    _noteFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasMiniPlayer = context.select<VideoPlayerManager, bool>(
      (playerManager) =>
          playerManager.currentVideoId != null && playerManager.isMinimized,
    );
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final bottomPadding = 112.0 + (hasMiniPlayer ? 64.0 : 0.0) + bottomInset;

    return Consumer<ProfileService>(
      builder: (context, profile, _) {
        if (!profile.isReady) {
          return const Center(child: CupertinoActivityIndicator());
        }

        return SafeArea(
          bottom: false,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 520),
            reverseDuration: const Duration(milliseconds: 420),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  ...previousChildren,
                  if (currentChild != null) currentChild,
                ],
              );
            },
            transitionBuilder: (child, animation) {
              final beginX = _playlistTransitionDirection > 0 ? 0.22 : -0.18;
              final curved = CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
                reverseCurve: Curves.easeInCubic,
              );
              final slide = Tween<Offset>(
                begin: Offset(beginX, 0),
                end: Offset.zero,
              ).animate(curved);
              final scale = Tween<double>(
                begin: 0.94,
                end: 1.0,
              ).animate(curved);
              return FadeTransition(
                opacity: curved,
                child: ClipRect(
                  child: SlideTransition(
                    position: slide,
                    child: ScaleTransition(scale: scale, child: child),
                  ),
                ),
              );
            },
            child: _selectedPlaylist != null
                ? KeyedSubtree(
                    key: ValueKey('playlist_detail_${_selectedPlaylist!.name}'),
                    child: PlaylistDetailPage(
                      playlist: _selectedPlaylist!,
                      onBack: _closePlaylistInline,
                    ),
                  )
                : _showAllPlaylists
                ? KeyedSubtree(
                    key: const ValueKey('profile_all_playlists'),
                    child: PlaylistsPage(
                      onOpenPlaylist: _openPlaylistInline,
                      onPinPlaylist: (playlist) {
                        _togglePinnedPlaylist(playlist);
                      },
                      onUnpinPlaylist: (playlist) {
                        _togglePinnedPlaylist(playlist);
                      },
                      isPlaylistPinned: _isPlaylistPinned,
                      onBack: _closeAllPlaylists,
                      useSafeArea: false,
                    ),
                  )
                : KeyedSubtree(
                    key: const ValueKey('profile_root'),
                    child: FutureBuilder<List<Playlist>>(
                      future: _playlistsFuture,
                      builder: (context, playlistsSnapshot) {
                        return FutureBuilder<List<VideoHistory>>(
                          future: _historyFuture,
                          builder: (context, historySnapshot) {
                            final playlists =
                                playlistsSnapshot.data ?? const <Playlist>[];
                            final history =
                                historySnapshot.data ?? const <VideoHistory>[];
                            final totalPlayed = _estimatePlayedDuration(
                              history,
                            );
                            final createdPlaylists = _countCreatedPlaylists(
                              playlists,
                            );
                            final bioText = profile.bio.trim().isEmpty
                                ? 'Escribe algo...'
                                : profile.bio.trim();

                            return CustomScrollView(
                              physics: const BouncingScrollPhysics(
                                parent: AlwaysScrollableScrollPhysics(),
                              ),
                              slivers: [
                                CupertinoSliverRefreshControl(
                                  onRefresh: _handleRefresh,
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      0,
                                    ),
                                    child: Row(
                                      children: [
                                        const Expanded(
                                          child: Text(
                                            'Perfil',
                                            style: TextStyle(
                                              fontFamily: '.SF Pro Display',
                                              fontSize: 34,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: -0.6,
                                            ),
                                          ),
                                        ),
                                        CupertinoButton(
                                          padding: EdgeInsets.zero,
                                          minimumSize: const Size(34, 34),
                                          onPressed: () {
                                            Navigator.of(context).push(
                                              CupertinoPageRoute<void>(
                                                builder: (_) => ProfileEditPage(
                                                  profile: profile,
                                                ),
                                              ),
                                            );
                                          },
                                          child: const Icon(
                                            CupertinoIcons.pencil,
                                          ),
                                        ),
                                        CupertinoButton(
                                          padding: EdgeInsets.zero,
                                          minimumSize: const Size(34, 34),
                                          onPressed: () {
                                            Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    const AccountSettingsPage(),
                                              ),
                                            );
                                          },
                                          child: const Icon(
                                            CupertinoIcons.settings,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      16,
                                    ),
                                    child: Column(
                                      children: [
                                        Builder(
                                          builder: (context) {
                                            final frameUrl =
                                                (profile.frameUrl ?? '').trim();
                                            return SizedBox(
                                              width: 260,
                                              height: 188,
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  Align(
                                                    alignment:
                                                        Alignment.bottomCenter,
                                                    child: GestureDetector(
                                                      onTap: () =>
                                                          _changePhoto(profile),
                                                      child: SizedBox(
                                                        width: 164,
                                                        height: 164,
                                                        child: Stack(
                                                          children: [
                                                            CircleAvatar(
                                                              radius: 82,
                                                              backgroundColor:
                                                                  CupertinoColors
                                                                      .tertiarySystemFill
                                                                      .resolveFrom(
                                                                        context,
                                                                      ),
                                                              backgroundImage:
                                                                  (profile.photoPath !=
                                                                          null &&
                                                                      profile
                                                                          .photoPath!
                                                                          .isNotEmpty &&
                                                                      File(
                                                                        profile
                                                                            .photoPath!,
                                                                      ).existsSync())
                                                                  ? FileImage(
                                                                      File(
                                                                        profile
                                                                            .photoPath!,
                                                                      ),
                                                                    )
                                                                  : null,
                                                              child:
                                                                  (profile.photoPath ==
                                                                          null ||
                                                                      profile
                                                                          .photoPath!
                                                                          .isEmpty)
                                                                  ? const Icon(
                                                                      CupertinoIcons
                                                                          .person_crop_circle_fill,
                                                                      size: 78,
                                                                    )
                                                                  : null,
                                                            ),
                                                            Positioned(
                                                              left: 4,
                                                              bottom: -2,
                                                              child: GestureDetector(
                                                                onTap:
                                                                    _isLoadingFrames
                                                                    ? null
                                                                    : () => _pickFrame(
                                                                        profile,
                                                                      ),
                                                                child: _FloatingNoteDrift(
                                                                  child: SizedBox(
                                                                    width: 60,
                                                                    height: 60,
                                                                    child:
                                                                        frameUrl
                                                                            .isNotEmpty
                                                                        ? Container(
                                                                            padding: const EdgeInsets.all(
                                                                              1,
                                                                            ),
                                                                            child: Image.network(
                                                                              frameUrl,
                                                                              key: ValueKey(
                                                                                frameUrl,
                                                                              ),
                                                                              fit: BoxFit.contain,
                                                                            ),
                                                                          )
                                                                        : Container(
                                                                            decoration: BoxDecoration(
                                                                              color: CupertinoColors.systemGrey5.resolveFrom(
                                                                                context,
                                                                              ),
                                                                              shape: BoxShape.circle,
                                                                              border: Border.all(
                                                                                color: CupertinoColors.systemBackground.resolveFrom(
                                                                                  context,
                                                                                ),
                                                                                width: 1.2,
                                                                              ),
                                                                            ),
                                                                            child:
                                                                                _isLoadingFrames
                                                                                ? const CupertinoActivityIndicator(
                                                                                    radius: 12,
                                                                                  )
                                                                                : Icon(
                                                                                    CupertinoIcons.sparkles,
                                                                                    size: 24,
                                                                                    color: CupertinoColors.label.resolveFrom(
                                                                                      context,
                                                                                    ),
                                                                                  ),
                                                                          ),
                                                                  ),
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                  AnimatedAlign(
                                                    duration: const Duration(
                                                      milliseconds: 620,
                                                    ),
                                                    curve:
                                                        Curves.easeInOutCubic,
                                                    alignment:
                                                        _isEditingNoteInline
                                                        ? Alignment.center
                                                        : Alignment.topRight,
                                                    child: AnimatedScale(
                                                      duration: const Duration(
                                                        milliseconds: 620,
                                                      ),
                                                      curve: Curves.easeOutBack,
                                                      scale:
                                                          _isEditingNoteInline
                                                          ? 1.0
                                                          : 0.98,
                                                      child: AnimatedContainer(
                                                        duration:
                                                            const Duration(
                                                              milliseconds: 620,
                                                            ),
                                                        curve: Curves
                                                            .easeInOutCubic,
                                                        width:
                                                            _isEditingNoteInline
                                                            ? 215
                                                            : 190,
                                                        child: Column(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .end,
                                                          children: [
                                                            AnimatedSwitcher(
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        340,
                                                                  ),
                                                              switchInCurve: Curves
                                                                  .easeOutCubic,
                                                              switchOutCurve:
                                                                  Curves
                                                                      .easeInCubic,
                                                              child:
                                                                  _isEditingNoteInline
                                                                  ? _NoteBubble(
                                                                      isEditing:
                                                                          true,
                                                                      child: Column(
                                                                        mainAxisSize:
                                                                            MainAxisSize.min,
                                                                        children: [
                                                                          CupertinoTextField(
                                                                            controller:
                                                                                _noteController,
                                                                            focusNode:
                                                                                _noteFocusNode,
                                                                            placeholder:
                                                                                'Escribe algo...',
                                                                            placeholderStyle: TextStyle(
                                                                              fontFamily: '.SF Pro Text',
                                                                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                                                                context,
                                                                              ),
                                                                            ),
                                                                            decoration:
                                                                                const BoxDecoration(),
                                                                            padding: const EdgeInsets.symmetric(
                                                                              horizontal: 8,
                                                                              vertical: 8,
                                                                            ),
                                                                            style: TextStyle(
                                                                              fontFamily: '.SF Pro Text',
                                                                              fontSize: 15,
                                                                              color: CupertinoColors.label.resolveFrom(
                                                                                context,
                                                                              ),
                                                                            ),
                                                                            maxLines:
                                                                                3,
                                                                            minLines:
                                                                                2,
                                                                          ),
                                                                          const SizedBox(
                                                                            height:
                                                                                8,
                                                                          ),
                                                                          Row(
                                                                            mainAxisAlignment:
                                                                                MainAxisAlignment.end,
                                                                            children: [
                                                                              CupertinoButton(
                                                                                padding: const EdgeInsets.symmetric(
                                                                                  horizontal: 6,
                                                                                  vertical: 2,
                                                                                ),
                                                                                minimumSize: const Size(
                                                                                  1,
                                                                                  1,
                                                                                ),
                                                                                onPressed: _cancelInlineNoteEdit,
                                                                                child: Icon(
                                                                                  CupertinoIcons.xmark_circle_fill,
                                                                                  size: 18,
                                                                                  color: CupertinoColors.systemRed,
                                                                                ),
                                                                              ),
                                                                              const SizedBox(
                                                                                width: 2,
                                                                              ),
                                                                              CupertinoButton(
                                                                                padding: const EdgeInsets.symmetric(
                                                                                  horizontal: 6,
                                                                                  vertical: 2,
                                                                                ),
                                                                                minimumSize: const Size(
                                                                                  1,
                                                                                  1,
                                                                                ),
                                                                                onPressed: () => _saveInlineNote(
                                                                                  profile,
                                                                                ),
                                                                                child: Icon(
                                                                                  CupertinoIcons.checkmark_circle_fill,
                                                                                  size: 18,
                                                                                  color: CupertinoColors.systemBlue,
                                                                                ),
                                                                              ),
                                                                            ],
                                                                          ),
                                                                        ],
                                                                      ),
                                                                    )
                                                                  : GestureDetector(
                                                                      onTap: () =>
                                                                          _startInlineNoteEdit(
                                                                            profile,
                                                                          ),
                                                                      child: _FloatingNoteDrift(
                                                                        child: _NoteBubble(
                                                                          child: Text(
                                                                            bioText,
                                                                            textAlign:
                                                                                TextAlign.center,
                                                                            style: TextStyle(
                                                                              fontFamily: '.SF Pro Text',
                                                                              fontSize: 14,
                                                                              color: CupertinoColors.label.resolveFrom(
                                                                                context,
                                                                              ),
                                                                            ),
                                                                          ),
                                                                        ),
                                                                      ),
                                                                    ),
                                                            ),
                                                            AnimatedOpacity(
                                                              duration:
                                                                  const Duration(
                                                                    milliseconds:
                                                                        260,
                                                                  ),
                                                              curve: Curves
                                                                  .easeOutCubic,
                                                              opacity:
                                                                  _isEditingNoteInline
                                                                  ? 0
                                                                  : 1,
                                                              child: const Padding(
                                                                padding:
                                                                    EdgeInsets.only(
                                                                      top: 2,
                                                                      right: 24,
                                                                    ),
                                                                child: Row(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    _ThoughtDot(
                                                                      size: 8,
                                                                    ),
                                                                    SizedBox(
                                                                      width: 3,
                                                                    ),
                                                                    _ThoughtDot(
                                                                      size: 6,
                                                                    ),
                                                                    SizedBox(
                                                                      width: 3,
                                                                    ),
                                                                    _ThoughtDot(
                                                                      size: 4,
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            );
                                          },
                                        ),
                                        const SizedBox(height: 14),
                                        Text(
                                          profile.name,
                                          style: const TextStyle(
                                            fontFamily: '.SF Pro Display',
                                            fontSize: 28,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.45,
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          profile.username,
                                          style: TextStyle(
                                            fontFamily: '.SF Pro Text',
                                            fontSize: 15,
                                            color: CupertinoColors
                                                .secondaryLabel
                                                .resolveFrom(context),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      16,
                                    ),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: _StatCard(
                                            label: 'Seguidores',
                                            value: '${profile.followersCount}',
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: _StatCard(
                                            label: 'Playlists',
                                            value: '$createdPlaylists',
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: _StatCard(
                                            label: 'Horas',
                                            value: _formatHours(totalPlayed),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      12,
                                      0,
                                      12,
                                      10,
                                    ),
                                    child: CupertinoButton(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 0,
                                      ),
                                      minimumSize: const Size(1, 1),
                                      onPressed: _openAllPlaylists,
                                      alignment: Alignment.centerLeft,
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'Tus Playlist',
                                              style: TextStyle(
                                                fontFamily: '.SF Pro Display',
                                                fontSize: 20,
                                                fontWeight: FontWeight.w700,
                                                color: CupertinoColors.label
                                                    .resolveFrom(context),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Icon(
                                              CupertinoIcons.forward,
                                              size: 18,
                                              color: CupertinoColors
                                                  .secondaryLabel
                                                  .resolveFrom(context),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (playlistsSnapshot.connectionState ==
                                        ConnectionState.waiting &&
                                    playlists.isEmpty)
                                  const SliverToBoxAdapter(
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        vertical: 24,
                                      ),
                                      child: Center(
                                        child: CupertinoActivityIndicator(
                                          radius: 13,
                                        ),
                                      ),
                                    ),
                                  )
                                else if (playlists.isEmpty)
                                  const SliverToBoxAdapter(
                                    child: Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 24,
                                      ),
                                      child: Text('No tienes playlists aún.'),
                                    ),
                                  )
                                else
                                  SliverToBoxAdapter(
                                    child: SizedBox(
                                      height: 222 + bottomPadding,
                                      child: ListView.separated(
                                        padding: EdgeInsets.fromLTRB(
                                          16,
                                          0,
                                          16,
                                          bottomPadding,
                                        ),
                                        scrollDirection: Axis.horizontal,
                                        itemCount: playlists.length,
                                        separatorBuilder: (_, _) =>
                                            const SizedBox(width: 12),
                                        itemBuilder: (context, index) {
                                          final playlist = playlists[index];
                                          return _ProfilePlaylistFeatureCard(
                                            playlist: playlist,
                                            onTap: () =>
                                                _openPlaylistInline(playlist),
                                            fallbackBuilder: _coverFallback,
                                            isPinned: _isPlaylistPinned(
                                              playlist,
                                            ),
                                            onTogglePinned: () {
                                              _togglePinnedPlaylist(playlist);
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
          ),
        );
      },
    );
  }

  Widget _coverFallback(BuildContext context, bool isFavorite) {
    return Container(
      color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
      alignment: Alignment.center,
      child: Icon(
        isFavorite ? CupertinoIcons.star_fill : CupertinoIcons.music_note_list,
      ),
    );
  }
}

class _AppleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _AppleCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  @override
  Widget build(BuildContext context) {
    final border = CupertinoColors.separator
        .resolveFrom(context)
        .withValues(alpha: 0.2);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border, width: 0.6),
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _ProfilePlaylistFeatureCard extends StatelessWidget {
  final Playlist playlist;
  final VoidCallback onTap;
  final bool isPinned;
  final VoidCallback onTogglePinned;
  final Widget Function(BuildContext, bool) fallbackBuilder;

  const _ProfilePlaylistFeatureCard({
    required this.playlist,
    required this.onTap,
    required this.isPinned,
    required this.onTogglePinned,
    required this.fallbackBuilder,
  });

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
    final isFavorite = PlaylistService.isFavoritesPlaylistName(playlist.name);
    final fallback = fallbackBuilder(context, isFavorite);
    final artwork = _resolvePlaylistArtwork(playlist, fallback);
    final subtitle = isFavorite
        ? '${playlist.videos.length} canciones guardadas'
        : '${playlist.videos.length} canciones';

    final tile = SizedBox(
      width: 162,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Material(
          color: cardColor,
          surfaceTintColor: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: cardBorder, width: 0.6),
              ),
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Stack(
                    children: [
                      artwork ??
                          SizedBox(
                            width: 142,
                            height: 142,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: fallback,
                            ),
                          ),
                      if (isFavorite)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemYellow.resolveFrom(
                                context,
                              ),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              CupertinoIcons.star_fill,
                              size: 12,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    playlist.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: CupertinoColors.label.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
          ),
        ),
      ),
    );
    if (!Platform.isIOS) return tile;
    return CupertinoContextMenu(
      enableHapticFeedback: true,
      actions: [
        CupertinoContextMenuAction(
          trailingIcon: isPinned
              ? CupertinoIcons.pin_slash_fill
              : CupertinoIcons.pin_fill,
          onPressed: () {
            Navigator.of(context).pop();
            onTogglePinned();
          },
          child: Text(isPinned ? 'Desanclar Playlist' : 'Anclar Playlist'),
        ),
      ],
      child: tile,
    );
  }

  Widget? _resolvePlaylistArtwork(Playlist playlist, Widget fallback) {
    var cover = playlist.coverUrl?.trim();
    if (cover == null || cover.isEmpty) {
      for (final video in playlist.videos) {
        final thumb = video.thumbnailUrl.trim();
        if (thumb.isNotEmpty) {
          cover = thumb;
          break;
        }
      }
    }

    if (cover == null || cover.isEmpty) return null;
    if (cover.startsWith('/') && File(cover).existsSync()) {
      return SquareThumbnail.file(
        filePath: cover,
        size: 142,
        borderRadius: 10,
        fallback: fallback,
      );
    }
    if (!cover.startsWith('/')) {
      return SquareThumbnail.network(
        imageUrl: cover,
        size: 142,
        borderRadius: 10,
        fallback: fallback,
      );
    }
    return null;
  }
}

class _ThoughtDot extends StatelessWidget {
  final double size;

  const _ThoughtDot({required this.size});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        shape: BoxShape.circle,
        border: Border.all(
          color: CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.2),
          width: 0.5,
        ),
      ),
    );
  }
}

class _NoteBubble extends StatelessWidget {
  final Widget child;
  final bool isEditing;

  const _NoteBubble({required this.child, this.isEditing = false});

  @override
  Widget build(BuildContext context) {
    final bg = isEditing
        ? CupertinoColors.systemBackground.resolveFrom(context)
        : CupertinoColors.secondarySystemGroupedBackground.resolveFrom(context);
    final border = CupertinoColors.separator
        .resolveFrom(context)
        .withValues(alpha: isEditing ? 0.36 : 0.22);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      constraints: BoxConstraints(maxWidth: isEditing ? 242 : 185),
      padding: EdgeInsets.symmetric(
        horizontal: isEditing ? 10 : 12,
        vertical: isEditing ? 10 : 8,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(isEditing ? 18 : 16),
        border: Border.all(color: border, width: isEditing ? 1 : 0.6),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isEditing ? 0.12 : 0.08),
            blurRadius: isEditing ? 26 : 12,
            offset: const Offset(0, 8),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: isEditing ? 0.14 : 0.06),
            blurRadius: isEditing ? 10 : 6,
            offset: const Offset(0, -1),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _FloatingNoteDrift extends StatefulWidget {
  final Widget child;

  const _FloatingNoteDrift({required this.child});

  @override
  State<_FloatingNoteDrift> createState() => _FloatingNoteDriftState();
}

class _FloatingNoteDriftState extends State<_FloatingNoteDrift>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _xAnimation;
  late final Animation<double> _yAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    _xAnimation = Tween<double>(begin: -6, end: 6).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutSine),
    );
    _yAnimation = Tween<double>(
      begin: -2.8,
      end: 2.8,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final wave = 0.9 + (0.1 * math.sin(_controller.value * 2 * math.pi));
        return Transform.translate(
          offset: Offset(_xAnimation.value * wave, _yAnimation.value * wave),
          child: widget.child,
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;

  const _StatCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return _AppleCard(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 11),
      child: Column(
        children: [
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: '.SF Pro Display',
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: '.SF Pro Text',
              fontSize: 12,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}
