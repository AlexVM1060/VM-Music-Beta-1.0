import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ScaffoldMessenger, SnackBar, Theme;
import 'package:myapp/services/apple_music_library_service.dart';
import 'package:myapp/services/apple_music_playlist_migration_service.dart';
import 'package:myapp/services/playlist_service.dart';
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

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        middle: Text(
          'Migrar Apple Music',
          style: TextStyle(color: textPrimary, decoration: TextDecoration.none),
        ),
        backgroundColor: navBackground,
        automaticBackgroundVisibility: !isDark,
        transitionBetweenRoutes: !isDark,
        border: null,
      ),
      child: ColoredBox(
        color: pageBackground,
        child: SafeArea(
          top: false,
          child: ListView(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 22 + bottomSafeInset + 24),
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
                      onPressed: _isRequestingAuthorization
                          ? null
                          : _requestAuthorization,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                      color: isDark
                          ? const Color(0xFF1F1F22)
                          : CupertinoColors.white,
                      borderRadius: BorderRadius.circular(14),
                      child: Text(
                        _isRequestingAuthorization
                            ? 'Solicitando permiso...'
                            : 'Autorizar acceso',
                        style: TextStyle(
                          color: textPrimary,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
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
                        return GestureDetector(
                          onTap: _isMigrating
                              ? null
                              : () => _toggleSelection(playlist.id, !selected),
                          child: Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF1C1C1E)
                                  : CupertinoColors.systemGrey6.resolveFrom(
                                      context,
                                    ),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        playlist.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: textPrimary,
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '${playlist.trackCount} canciones',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: CupertinoColors.secondaryLabel
                                              .resolveFrom(context),
                                          decoration: TextDecoration.none,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                CupertinoSwitch(
                                  value: selected,
                                  onChanged: _isMigrating
                                      ? null
                                      : (value) => _toggleSelection(
                                          playlist.id,
                                          value,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                  ],
                ),
              ),
              const SizedBox(height: 18),
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
                    CupertinoButton.filled(
                      onPressed: _isMigrating
                          ? null
                          : _migrateSelectedPlaylists,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      child: Text(
                        _isMigrating
                            ? 'Migrando...'
                            : 'Migrar ${_selectedPlaylistIds.length} playlists seleccionadas',
                        style: const TextStyle(decoration: TextDecoration.none),
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
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF121212)
                : CupertinoColors.systemBackground.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF2A2A2A)
                  : CupertinoColors.systemGrey5.resolveFrom(context),
              width: 0.9,
            ),
          ),
          child: Padding(padding: const EdgeInsets.all(12), child: child),
        ),
      ),
    );
  }
}
