import 'package:flutter/cupertino.dart';
import 'package:myapp/services/social_service.dart';
import 'package:provider/provider.dart';

class SocialFriendsPage extends StatefulWidget {
  const SocialFriendsPage({super.key});

  @override
  State<SocialFriendsPage> createState() => _SocialFriendsPageState();
}

class _SocialFriendsPageState extends State<SocialFriendsPage> {
  final TextEditingController _searchController = TextEditingController();
  List<SocialUser> _results = const <SocialUser>[];
  List<SocialUser> _following = const <SocialUser>[];
  Set<String> _followingIds = <String>{};
  bool _loading = true;
  bool _searching = false;
  String? _searchMessage;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final social = context.read<SocialService>();
    setState(() => _loading = true);
    await social.ensureReady();
    final following = await social.getFollowingUsers();
    final ids = await social.getFollowingIds();
    if (!mounted) return;
    setState(() {
      _following = following;
      _followingIds = ids;
      _loading = false;
    });
  }

  Future<void> _search() async {
    final social = context.read<SocialService>();
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const <SocialUser>[];
        _searchMessage = 'Escribe un username para buscar.';
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final users = await social.searchUsersByUsername(query);
      if (!mounted) return;
      setState(() {
        _results = users;
        _searchMessage = users.isEmpty
            ? 'No encontramos usuarios con ese username.'
            : null;
        _searching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _results = const <SocialUser>[];
        _searchMessage = 'Error al buscar: $e';
        _searching = false;
      });
    }
  }

  Future<void> _toggleFollow(SocialUser user) async {
    final social = context.read<SocialService>();
    final isFollowing = _followingIds.contains(user.id);
    if (isFollowing) {
      await social.unfollowUser(user.id);
    } else {
      await social.followUser(user.id);
    }
    await _reload();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final card = CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
      context,
    );

    return CupertinoPageScaffold(
      backgroundColor: bg,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Amigos'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _reload,
          child: const Icon(CupertinoIcons.refresh, size: 20),
        ),
      ),
      child: SafeArea(
        child: _loading
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    decoration: BoxDecoration(
                      color: card,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: CupertinoColors.black.withValues(alpha: 0.04),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            _StatChip(
                              icon: CupertinoIcons.person_2_fill,
                              label: '${_following.length} siguiendo',
                            ),
                            const SizedBox(width: 8),
                            _StatChip(
                              icon: CupertinoIcons.search,
                              label: '${_results.length} resultados',
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Agregar por username',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                            decoration: TextDecoration.none,
                          ),
                        ),
                        const SizedBox(height: 8),
                        CupertinoSearchTextField(
                          controller: _searchController,
                          placeholder: 'Ejemplo: AndreusVM',
                          onSubmitted: (_) => _search(),
                          onSuffixTap: _search,
                        ),
                        const SizedBox(height: 10),
                        SizedBox(
                          width: double.infinity,
                          child: CupertinoButton.filled(
                            color: const Color(0xFFE07A00),
                            borderRadius: BorderRadius.circular(12),
                            onPressed: _searching ? null : _search,
                            child: _searching
                                ? const CupertinoActivityIndicator()
                                : const Text(
                                    'Buscar',
                                    style: TextStyle(
                                      color: CupertinoColors.white,
                                      decoration: TextDecoration.none,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_results.isNotEmpty) ...[
                    const _SectionTitle(
                      title: 'Resultados',
                      subtitle: 'Usuarios que puedes seguir',
                    ),
                    const SizedBox(height: 8),
                    ..._results.map(
                      (u) => _UserTile(
                        user: u,
                        isFollowing: _followingIds.contains(u.id),
                        onTapFollow: () => _toggleFollow(u),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                  if (_searchMessage != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _searchMessage!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                  const _SectionTitle(
                    title: 'Siguiendo',
                    subtitle: 'Lo que están escuchando ahora',
                  ),
                  const SizedBox(height: 8),
                  if (_following.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: card,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        'Aún no sigues a nadie.',
                        style: TextStyle(
                          fontSize: 12.5,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    )
                  else
                    ..._following.map(
                      (u) => _UserTile(
                        user: u,
                        isFollowing: true,
                        onTapFollow: () => _toggleFollow(u),
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String subtitle;

  const _SectionTitle({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: CupertinoColors.label.resolveFrom(context),
            decoration: TextDecoration.none,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 13,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
            decoration: TextDecoration.none,
          ),
        ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 12,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
              decoration: TextDecoration.none,
            ),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final SocialUser user;
  final bool isFollowing;
  final VoidCallback onTapFollow;

  const _UserTile({
    required this.user,
    required this.isFollowing,
    required this.onTapFollow,
  });

  @override
  Widget build(BuildContext context) {
    final photoUrl = (user.photoUrl ?? '').trim();
    final hasPhoto = photoUrl.isNotEmpty;
    final song = user.currentSong.trim();
    final artist = user.currentArtist.trim();
    final note = user.note.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.separator
              .resolveFrom(context)
              .withValues(alpha: 0.16),
          width: 0.7,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: CupertinoColors.tertiarySystemFill.resolveFrom(context),
              image: hasPhoto
                  ? DecorationImage(
                      image: NetworkImage(photoUrl),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: Text(
              hasPhoto
                  ? ''
                  : user.name.trim().isEmpty
                  ? '?'
                  : user.name.trim().substring(0, 1).toUpperCase(),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        user.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: CupertinoColors.label.resolveFrom(context),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    if (user.isPlaying)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGreen
                              .resolveFrom(context)
                              .withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          'En reproducción',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.systemGreen.resolveFrom(
                              context,
                            ),
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                  ],
                ),
                Text(
                  '@${user.username}',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    decoration: TextDecoration.none,
                  ),
                ),
                if (song.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Sonando: $song${artist.isNotEmpty ? ' - $artist' : ''}',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.25,
                      color: CupertinoColors.label.resolveFrom(context),
                      decoration: TextDecoration.none,
                    ),
                  ),
                ],
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: CupertinoColors.tertiarySystemFill.resolveFrom(
                        context,
                      ),
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      note,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.2,
                        color: CupertinoColors.label.resolveFrom(context),
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          CupertinoButton(
            color: isFollowing
                ? CupertinoColors.tertiarySystemFill.resolveFrom(context)
                : CupertinoColors.systemBlue.resolveFrom(context),
            borderRadius: BorderRadius.circular(999),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            onPressed: onTapFollow,
            child: Text(
              isFollowing ? 'Siguiendo' : 'Seguir',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: isFollowing
                    ? CupertinoColors.label.resolveFrom(context)
                    : CupertinoColors.white,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
