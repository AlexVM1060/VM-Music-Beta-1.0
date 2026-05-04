import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:myapp/services/profile_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _usernameController = TextEditingController(
      text: widget.profile.username.startsWith('@')
          ? widget.profile.username.substring(1)
          : widget.profile.username,
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await widget.profile.updateProfile(
        name: _nameController.text,
        username: _usernameController.text,
        bio: widget.profile.bio,
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
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

  @override
  Widget build(BuildContext context) {
    final photoPath = (widget.profile.photoPath ?? '').trim();
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
                          child: CircleAvatar(
                            radius: 54,
                            backgroundColor: CupertinoColors.tertiarySystemFill
                                .resolveFrom(context),
                            backgroundImage: hasLocalPhoto
                                ? FileImage(File(photoPath))
                                : null,
                            child: hasLocalPhoto
                                ? null
                                : const Icon(
                                    CupertinoIcons.person_crop_circle_fill,
                                    size: 48,
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
          ],
        ),
      ),
    );
  }
}
