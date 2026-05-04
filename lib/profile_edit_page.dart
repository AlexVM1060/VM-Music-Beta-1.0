import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/services/profile_frames_service.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:myapp/services/social_service.dart';
import 'package:myapp/video_player_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

class ProfileEditPage extends StatefulWidget {
  final ProfileService profile;

  const ProfileEditPage({super.key, required this.profile});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _usernameController;
  final ImagePicker _picker = ImagePicker();
  bool _isSaving = false;
  bool _isPublishing = false;
  bool _isLoadingFrames = false;
  String? _framesStatusMessage;
  late bool _isPublicProfileEnabled;

  String _stripQuery(String url) {
    final idx = url.indexOf('?');
    if (idx < 0) return url;
    return url.substring(0, idx);
  }

  String _cacheBustUrl(String url) {
    final sep = url.contains('?') ? '&' : '?';
    return '$url${sep}v=${DateTime.now().millisecondsSinceEpoch}';
  }

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _usernameController = TextEditingController(
      text: widget.profile.username.startsWith('@')
          ? widget.profile.username.substring(1)
          : widget.profile.username,
    );
    _isPublicProfileEnabled = widget.profile.isPublicProfile;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile({required bool closeOnSuccess}) async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await widget.profile.updateProfile(
        name: _nameController.text,
        username: _usernameController.text,
        bio: widget.profile.bio,
      );
      if (!mounted || !closeOnSuccess) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _save() async {
    await _saveProfile(closeOnSuccess: true);
  }

  Future<void> _changePhoto() async {
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
              await widget.profile.updatePhotoPath(target.path);
              await _syncProfilePhotoToSupabase();
              if (mounted) setState(() {});
            },
            child: const Text('Elegir de galeria'),
          ),
          if ((widget.profile.photoPath ?? '').isNotEmpty)
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                final oldPath = widget.profile.photoPath;
                await widget.profile.updatePhotoPath(null);
                if (oldPath != null && oldPath.isNotEmpty) {
                  final file = File(oldPath);
                  if (await file.exists()) {
                    await file.delete();
                  }
                }
                await _syncProfilePhotoToSupabase();
                if (mounted) setState(() {});
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

  Future<void> _syncProfilePhotoToSupabase() async {
    try {
      final social = context.read<SocialService>();
      final player = context.read<VideoPlayerManager>();
      final currentSong = (player.trackTitle ?? '').trim();
      final currentArtist = (player.trackArtist ?? '').trim();
      final currentVideoId = (player.currentVideoId ?? '').trim();
      final isPlaying = currentSong.isNotEmpty && player.isPlaying;
      await social.publishProfile(
        profile: widget.profile,
        currentSong: currentSong,
        currentArtist: currentArtist,
        currentVideoId: currentVideoId,
        isPlaying: isPlaying,
      );
    } catch (_) {
      // Mejor esfuerzo: no bloqueamos cambio de foto por red/supabase.
    }
  }

  Future<void> _publishProfile() async {
    if (_isPublishing) return;
    setState(() => _isPublishing = true);
    try {
      final social = context.read<SocialService>();
      final player = context.read<VideoPlayerManager>();
      final currentSong = (player.trackTitle ?? '').trim();
      final currentArtist = (player.trackArtist ?? '').trim();
      final currentVideoId = (player.currentVideoId ?? '').trim();
      final isPlaying = currentSong.isNotEmpty && player.isPlaying;
      await social.publishProfile(
        profile: widget.profile,
        currentSong: currentSong,
        currentArtist: currentArtist,
        currentVideoId: currentVideoId,
        isPlaying: isPlaying,
      );
      if (!mounted) return;
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Perfil publicado'),
          content: const Text('Tu perfil ahora es público.'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('No se pudo publicar'),
          content: Text(e.toString()),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _isPublishing = false);
    }
  }

  Future<void> _pickFrame() async {
    if (_isLoadingFrames) return;
    setState(() => _isLoadingFrames = true);
    List<String> frames = const [];
    try {
      frames = await ProfileFramesService.fetchFrameUrls();
    } catch (e) {
      frames = const [];
      _framesStatusMessage = 'Error marcos: $e';
    } finally {
      if (mounted) setState(() => _isLoadingFrames = false);
    }
    if (!mounted) return;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (dialogContext) => CupertinoActionSheet(
        title: const Text('Selecciona un Sticker'),
        message: SizedBox(
          height: 220,
          child: frames.isEmpty
              ? const Center(child: Text('No hay marcos disponibles'))
              : GridView.builder(
                  itemCount: frames.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemBuilder: (_, index) {
                    final url = frames[index];
                    final current = (widget.profile.frameUrl ?? '').trim();
                    final isSelected = _stripQuery(current) == _stripQuery(url);
                    return GestureDetector(
                      onTap: () async {
                        Navigator.of(dialogContext).pop();
                        await widget.profile.updateFrameUrl(_cacheBustUrl(url));
                        await _syncProfilePhotoToSupabase();
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
                        child: Image.network(url, fit: BoxFit.contain),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          CupertinoActionSheetAction(
            isDestructiveAction: true,
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await widget.profile.updateFrameUrl(null);
              await _syncProfilePhotoToSupabase();
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

  Future<void> _onTogglePublicProfile(bool enabled) async {
    if (_isPublishing || _isSaving) return;
    setState(() {
      _isPublicProfileEnabled = enabled;
    });
    try {
      if (enabled) {
        // Primero guardamos exactamente como el botón "Guardar", sin cerrar.
        await _saveProfile(closeOnSuccess: false);
      }
      await widget.profile.setPublicProfileEnabled(enabled);
      if (!enabled) return;
      await _publishProfile();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isPublicProfileEnabled = !enabled;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final photoPath = (widget.profile.photoPath ?? '').trim();
    final frameUrl = (widget.profile.frameUrl ?? '').trim();
    final hasLocalPhoto = photoPath.isNotEmpty && File(photoPath).existsSync();
    final cardColor = CupertinoColors.secondarySystemGroupedBackground
        .resolveFrom(context);
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        context,
      ),
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Editar perfil'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _isSaving ? null : _save,
          child: _isSaving
              ? const CupertinoActivityIndicator(radius: 10)
              : const Text(
                  'Guardar',
                  style: TextStyle(color: CupertinoColors.systemBlue),
                ),
        ),
      ),
      child: SafeArea(
        top: true,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          children: [
            Column(
              children: [
                SizedBox(
                  width: 138,
                  height: 138,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 138,
                        height: 138,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: cardColor,
                        ),
                        alignment: Alignment.center,
                        child: GestureDetector(
                          onTap: _changePhoto,
                          child: SizedBox(
                            width: 108,
                            height: 108,
                            child: Stack(
                              clipBehavior: Clip.none,
                              children: [
                                CircleAvatar(
                                  radius: 54,
                                  backgroundColor: CupertinoColors
                                      .tertiarySystemFill
                                      .resolveFrom(context),
                                  backgroundImage: hasLocalPhoto
                                      ? FileImage(File(photoPath))
                                      : null,
                                  child: hasLocalPhoto
                                      ? null
                                      : const Icon(
                                          CupertinoIcons
                                              .person_crop_circle_fill,
                                          size: 48,
                                        ),
                                ),
                                Positioned(
                                  left: -2,
                                  bottom: -6,
                                  child: GestureDetector(
                                    onTap: _isLoadingFrames ? null : _pickFrame,
                                    child: SizedBox(
                                      width: 42,
                                      height: 42,
                                      child: frameUrl.isNotEmpty
                                          ? Container(
                                              padding: const EdgeInsets.all(1),
                                              child: Image.network(
                                                frameUrl,
                                                key: ValueKey(frameUrl),
                                                fit: BoxFit.contain,
                                              ),
                                            )
                                          : Container(
                                              decoration: BoxDecoration(
                                                color: CupertinoColors.systemGrey5
                                                    .resolveFrom(context),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: CupertinoColors
                                                      .systemBackground
                                                      .resolveFrom(context),
                                                  width: 1.2,
                                                ),
                                              ),
                                              child: _isLoadingFrames
                                                  ? const CupertinoActivityIndicator(
                                                      radius: 9,
                                                    )
                                                  : Icon(
                                                      CupertinoIcons.sparkles,
                                                      size: 20,
                                                      color: CupertinoColors
                                                          .label
                                                          .resolveFrom(context),
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
                      Positioned(
                        right: 8,
                        bottom: 8,
                        child: GestureDetector(
                          onTap: _changePhoto,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemGrey5.resolveFrom(
                                context,
                              ),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: CupertinoColors.systemBackground
                                    .resolveFrom(context),
                                width: 1.4,
                              ),
                            ),
                            child: Icon(
                              CupertinoIcons.pencil,
                              size: 16,
                              color: CupertinoColors.label.resolveFrom(context),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),
            if ((_framesStatusMessage ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 6),
                child: Text(
                  _framesStatusMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 6, bottom: 8),
              child: Text(
                'INFORMACION PUBLICA',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.3,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  decoration: TextDecoration.none,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                children: [
                  CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Nombre',
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    decoration: const BoxDecoration(),
                  ),
                  Container(
                    height: 0.5,
                    color: CupertinoColors.separator.resolveFrom(context),
                  ),
                  CupertinoTextField(
                    controller: _usernameController,
                    placeholder: 'Nombre de usuario',
                    autocorrect: false,
                    enableSuggestions: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 12,
                    ),
                    prefix: const Padding(
                      padding: EdgeInsets.only(left: 2, right: 2),
                      child: Text(
                        '@',
                        style: TextStyle(
                          fontSize: 22,
                          color: CupertinoColors.label,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    decoration: const BoxDecoration(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(14),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Perfil publico',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.label.resolveFrom(context),
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isPublicProfileEnabled
                              ? 'Tu perfil ahora es público.'
                              : 'Activalo para compartir tu perfil.',
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
                  if (_isPublishing)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: CupertinoActivityIndicator(radius: 10),
                    ),
                  CupertinoSwitch(
                    value: _isPublicProfileEnabled,
                    onChanged: _isPublishing ? null : _onTogglePublicProfile,
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
