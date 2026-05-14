import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:myapp/services/apple_music_library_service.dart';
import 'package:myapp/services/apple_music_playlist_migration_service.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:myapp/widgets/app_back_circle_button.dart';
import 'package:myapp/widgets/ios_notice.dart';
import 'package:provider/provider.dart';

class AppleMusicMigrationPage extends StatefulWidget {
  const AppleMusicMigrationPage({super.key});

  @override
  State<AppleMusicMigrationPage> createState() =>
      _AppleMusicMigrationPageState();
}

class _AppleMusicMigrationPageState extends State<AppleMusicMigrationPage> {
  final AppleMusicLibraryService _appleMusicService =
      AppleMusicLibraryService();
  AppleMusicAuthorizationStatus _authorizationStatus =
      AppleMusicAuthorizationStatus.notDetermined;
  bool _isRequestingAuthorization = false;
  bool _isLoadingPlaylists = false;
  bool _isMigrating = false;
  String _search = '';
  List<AppleMusicLibraryPlaylist> _playlists = const [];
  final Set<String> _selectedPlaylistIds = <String>{};
  AppleMusicPlaylistMigrationProgress? _progress;

  bool get _isAuthorized =>
      _authorizationStatus == AppleMusicAuthorizationStatus.authorized;

  @override
  void initState() {
    super.initState();
    _loadAuthorizationStatus();
  }

  Future<void> _loadAuthorizationStatus() async {
    final status = await _appleMusicService.getAuthorizationStatus();
    if (!mounted) return;
    setState(() {
      _authorizationStatus = status;
    });
  }

  Future<void> _requestAuthorization() async {
    if (_isRequestingAuthorization) return;
    setState(() {
      _isRequestingAuthorization = true;
    });
    final status = await _appleMusicService.requestAuthorization();
    if (!mounted) return;
    setState(() {
      _authorizationStatus = status;
      _isRequestingAuthorization = false;
    });
  }

  Future<void> _loadUserPlaylists() async {
    if (!_isAuthorized || _isLoadingPlaylists || _isMigrating) return;
    setState(() {
      _isLoadingPlaylists = true;
    });
    final playlists = await _appleMusicService.fetchUserPlaylists();
    if (!mounted) return;
    setState(() {
      _playlists = playlists;
      _isLoadingPlaylists = false;
      _selectedPlaylistIds.removeWhere(
        (id) => !playlists.any((playlist) => playlist.id == id),
      );
    });
  }

  List<AppleMusicLibraryPlaylist> _filteredPlaylists() {
    final query = _search.trim().toLowerCase();
    if (query.isEmpty) return _playlists;
    return _playlists
        .where((playlist) => playlist.name.toLowerCase().contains(query))
        .toList(growable: false);
  }

  void _toggleSelection(String playlistId, bool? selected) {
    setState(() {
      if (selected == true) {
        _selectedPlaylistIds.add(playlistId);
      } else {
        _selectedPlaylistIds.remove(playlistId);
      }
    });
  }

  void _toggleSelectAllFiltered() {
    final visible = _filteredPlaylists();
    if (visible.isEmpty) return;
    final allSelected = visible.every(
      (p) => _selectedPlaylistIds.contains(p.id),
    );
    setState(() {
      if (allSelected) {
        for (final playlist in visible) {
          _selectedPlaylistIds.remove(playlist.id);
        }
      } else {
        for (final playlist in visible) {
          _selectedPlaylistIds.add(playlist.id);
        }
      }
    });
  }

  Future<void> _migrateSelectedPlaylists() async {
    if (_isMigrating) return;
    final selected = _playlists
        .where((playlist) => _selectedPlaylistIds.contains(playlist.id))
        .toList(growable: false);
    if (selected.isEmpty) {
      _showSnackBar('Selecciona al menos una playlist.');
      return;
    }

    final playlistService = context.read<PlaylistService>();
    final migrationService = AppleMusicPlaylistMigrationService(
      playlistService: playlistService,
      appleMusicService: _appleMusicService,
    );

    setState(() {
      _isMigrating = true;
      _progress = null;
    });

    AppleMusicPlaylistMigrationResult? result;
    Object? migrationError;
    try {
      result = await migrationService.migrateSelectedPlaylists(
        selectedPlaylists: selected,
        onProgress: (progress) async {
          if (!mounted) return;
          setState(() {
            _progress = progress;
          });
        },
      );
    } catch (e) {
      migrationError = e;
    } finally {
      migrationService.dispose();
    }

    if (!mounted) return;
    setState(() {
      _isMigrating = false;
      _progress = null;
    });

    if (migrationError != null) {
      _showSnackBar(
        'No se pudo completar la migración. Intenta de nuevo en unos minutos.',
      );
      return;
    }
    if (result == null) {
      _showSnackBar('No se pudo completar la migración.');
      return;
    }

    final imported = result.importedTracks;
    final total = result.totalTracks;
    _showSnackBar('Migración lista: $imported/$total canciones importadas.');
  }

  void _showSnackBar(String message) => showIosNotice(context, message);

  Uint8List? _decodeArtwork(String? rawBase64) {
    final input = (rawBase64 ?? '').trim();
    if (input.isEmpty) return null;
    try {
      return base64Decode(input);
    } catch (_) {
      return null;
    }
  }

  String _authorizationText() {
    switch (_authorizationStatus) {
      case AppleMusicAuthorizationStatus.authorized:
        return 'Autorizado';
      case AppleMusicAuthorizationStatus.denied:
        return 'Denegado';
      case AppleMusicAuthorizationStatus.restricted:
        return 'Restringido';
      case AppleMusicAuthorizationStatus.notDetermined:
        return 'Sin autorización';
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);
    final pageBackground = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final navBackground = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final bottomSafeInset = MediaQuery.of(context).padding.bottom;

    if (!_appleMusicService.isSupportedPlatform) {
      return CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(
          automaticallyImplyLeading: false,
          leading: Navigator.of(context).canPop()
              ? AppBackCircleButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                )
              : null,
          middle: Text(
            'Migrar Apple Music',
            style: TextStyle(color: textPrimary),
          ),
          backgroundColor: navBackground,
          automaticBackgroundVisibility: !isDark,
          transitionBetweenRoutes: !isDark,
          border: null,
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Este asistente está disponible solo en iPhone/iOS.',
                style: TextStyle(color: textPrimary),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final visiblePlaylists = _filteredPlaylists();
    final allVisibleSelected =
        visiblePlaylists.isNotEmpty &&
        visiblePlaylists.every((p) => _selectedPlaylistIds.contains(p.id));

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        automaticallyImplyLeading: false,
        leading: Navigator.of(context).canPop()
            ? AppBackCircleButton(
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        middle: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Migrar',
              style: TextStyle(
                color: textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 16,
              ),
            ),
            Text(
              'Apple Music',
              style: TextStyle(
                color: CupertinoColors.systemGrey.resolveFrom(context),
                fontSize: 12,
              ),
            ),
          ],
        ),
        backgroundColor: navBackground,
        automaticBackgroundVisibility: false,
        border: null,
      ),
      child: ColoredBox(
        color: pageBackground,
        child: SafeArea(
          top: true,
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 28 + bottomSafeInset),
            children: [
              _buildSectionTitle(context, 'Conexión'),
              const SizedBox(height: 10),
              _GlassSection(
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Conecta tu Apple Music',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: textPrimary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Estado: ${_authorizationText()}',
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 10),
                    CupertinoButton(
                      onPressed: _isAuthorized
                          ? null
                          : (_isRequestingAuthorization
                                ? null
                                : _requestAuthorization),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      color: _isAuthorized
                          ? CupertinoColors.systemGreen
                          : CupertinoColors.systemBlue,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.person_crop_circle_badge_checkmark,
                            size: 18,
                            color: CupertinoColors.white,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _isAuthorized
                                ? 'Conectado'
                                : (_isRequestingAuthorization
                                      ? 'Solicitando...'
                                      : 'Conectar Apple Music'),
                            style: TextStyle(
                              color: CupertinoColors.white,
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle(context, 'Playlists'),
              const SizedBox(height: 10),
              _GlassSection(
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Selecciona playlists a migrar',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: textPrimary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            color: isDark
                                ? const Color(0xFF1F1F22)
                                : CupertinoColors.white,
                            borderRadius: BorderRadius.circular(12),
                            onPressed:
                                _isAuthorized &&
                                    !_isLoadingPlaylists &&
                                    !_isMigrating
                                ? _loadUserPlaylists
                                : null,
                            child: Text(
                              _isLoadingPlaylists
                                  ? 'Cargando...'
                                  : 'Cargar playlists',
                              style: TextStyle(
                                color: textPrimary,
                                decoration: TextDecoration.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        CupertinoButton(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          color: isDark
                              ? const Color(0xFF1F1F22)
                              : CupertinoColors.white,
                          borderRadius: BorderRadius.circular(12),
                          onPressed: visiblePlaylists.isEmpty || _isMigrating
                              ? null
                              : _toggleSelectAllFiltered,
                          child: Text(
                            allVisibleSelected ? 'Limpiar' : 'Todas',
                            style: TextStyle(
                              color: textPrimary,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    CupertinoSearchTextField(
                      onChanged: (value) {
                        setState(() {
                          _search = value;
                        });
                      },
                      placeholder: 'Buscar playlist',
                    ),
                    const SizedBox(height: 10),
                    if (visiblePlaylists.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        child: Text(
                          _isAuthorized
                              ? 'No hay playlists cargadas.'
                              : 'Autoriza Apple Music y toca "Cargar playlists".',
                          style: TextStyle(
                            fontSize: 13,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                            decoration: TextDecoration.none,
                          ),
                        ),
                      )
                    else
                      ...visiblePlaylists.map((playlist) {
                        final selected = _selectedPlaylistIds.contains(
                          playlist.id,
                        );
                        return _PlaylistSelectionTile(
                          key: ValueKey('am_playlist_${playlist.id}'),
                          playlist: playlist,
                          artworkBytes: _decodeArtwork(playlist.artworkBase64),
                          selected: selected,
                          isDark: isDark,
                          isMigrating: _isMigrating,
                          textPrimary: textPrimary,
                          onToggle: (value) =>
                              _toggleSelection(playlist.id, value),
                        );
                      }),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              _buildSectionTitle(context, 'Migración'),
              const SizedBox(height: 10),
              _GlassSection(
                isDark: isDark,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Importar a VM Music',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: textPrimary,
                        decoration: TextDecoration.none,
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_progress != null)
                      Text(
                        'Migrando ${_progress!.playlistName} '
                        '(${_progress!.playlistIndex}/${_progress!.playlistTotal}) · '
                        '${_progress!.trackIndex}/${_progress!.trackTotal}\n'
                        '${_progress!.trackTitle}',
                        style: TextStyle(
                          fontSize: 13,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    if (_progress != null) const SizedBox(height: 10),
                    CupertinoButton(
                      onPressed: _isMigrating
                          ? null
                          : _migrateSelectedPlaylists,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      borderRadius: BorderRadius.circular(16),
                      color: CupertinoColors.systemPink,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(CupertinoIcons.arrow_2_squarepath, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            _isMigrating
                                ? 'Migrando...'
                                : 'Migrar ${_selectedPlaylistIds.length} playlists',
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(BuildContext context, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: isDark ? const Color(0xFF8E8E93) : const Color(0xFF8A8A8E),
      letterSpacing: 0.2,
      decoration: TextDecoration.none,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(label.toUpperCase(), style: textStyle),
    );
  }
}

class _GlassSection extends StatelessWidget {
  final bool isDark;
  final Widget child;

  const _GlassSection({required this.isDark, required this.child});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF1C1C1E).withValues(alpha: 0.85)
                : CupertinoColors.systemBackground.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF2C2C2E)
                  : CupertinoColors.systemGrey4.resolveFrom(context),
              width: 0.6,
            ),
          ),
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    );
  }
}

class _PlaylistSelectionTile extends StatelessWidget {
  final AppleMusicLibraryPlaylist playlist;
  final Uint8List? artworkBytes;
  final bool selected;
  final bool isDark;
  final bool isMigrating;
  final Color textPrimary;
  final ValueChanged<bool> onToggle;

  const _PlaylistSelectionTile({
    super.key,
    required this.playlist,
    required this.artworkBytes,
    required this.selected,
    required this.isDark,
    required this.isMigrating,
    required this.textPrimary,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final tileBackground = isDark
        ? const Color(0xFF2C2C2E)
        : CupertinoColors.systemGrey5.resolveFrom(context);
    final tileBorder = selected
        ? CupertinoColors.systemPink
        : (isDark ? const Color(0xFF2A2A2F) : const Color(0xFFE0E2E8));

    return GestureDetector(
      onTap: isMigrating ? null : () => onToggle(!selected),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
        decoration: BoxDecoration(
          color: tileBackground,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: tileBorder, width: selected ? 1.3 : 1),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: CupertinoColors.systemPink.withValues(alpha: 0.25),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 54,
                height: 54,
                child: _buildArtwork(context),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.name,
                    style: TextStyle(
                      color: textPrimary,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.2,
                      decoration: TextDecoration.none,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${playlist.trackCount} canciones',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(
                        context,
                      ),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            CupertinoSwitch(
              value: selected,
              onChanged: isMigrating ? null : onToggle,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArtwork(BuildContext context) {
    if (artworkBytes != null) {
      return Image.memory(artworkBytes!, fit: BoxFit.cover);
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? const [Color(0xFF30343B), Color(0xFF17191E)]
              : const [Color(0xFFF5F7FA), Color(0xFFD9DEE7)],
        ),
      ),
      child: Center(
        child: Icon(
          CupertinoIcons.music_note_list,
          size: 20,
          color: isDark ? const Color(0xFFE6E8EC) : const Color(0xFF626775),
        ),
      ),
    );
  }
}
