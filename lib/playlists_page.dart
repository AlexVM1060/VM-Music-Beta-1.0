import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:myapp/models/playlist.dart';
import 'package:myapp/services/playlist_service.dart';
import 'package:provider/provider.dart';

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  late Future<List<Playlist>> _playlistsFuture;

  @override
  void initState() {
    super.initState();
    _loadPlaylists();
  }

  void _loadPlaylists() {
    setState(() {
      _playlistsFuture =
          Provider.of<PlaylistService>(context, listen: false).getPlaylists();
    });
  }

  void _createPlaylist() {
    final TextEditingController controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Crear nueva playlist'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(hintText: 'Nombre de la playlist'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancelar'),
            ),
            TextButton(
              onPressed: () async {
                if (controller.text.isNotEmpty) {
                  await Provider.of<PlaylistService>(context, listen: false)
                      .createPlaylist(controller.text);
                  
                  // Comprobación de seguridad
                  if (!context.mounted) return;
                  
                  Navigator.of(context).pop();
                  _loadPlaylists();
                }
              },
              child: const Text('Crear'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Playlist>>(
      future: _playlistsFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return const Center(child: Text('No se pudieron cargar las playlists.'));
        }

        final playlists = snapshot.data ?? const <Playlist>[];
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _createPlaylist,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text(
                    'Nueva playlist',
                    style: TextStyle(
                      fontFamily: '.SF Pro Text',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: playlists.isEmpty
                  ? const Center(child: Text('No tienes playlists.'))
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = playlists[index];
                        final cover = playlist.videos.isNotEmpty
                            ? playlist.videos.first.thumbnailUrl
                            : null;
                        return Card(
                          elevation: 2,
                          margin: const EdgeInsets.symmetric(vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              context
                                  .push('/playlist', extra: playlist)
                                  .then((_) => _loadPlaylists());
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: cover == null || cover.isEmpty
                                        ? Container(
                                            width: 120,
                                            height: 67.5,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .surfaceContainerHighest,
                                            alignment: Alignment.center,
                                            child: const Icon(Icons.queue_music_rounded),
                                          )
                                        : Image.network(
                                            cover,
                                            width: 120,
                                            height: 67.5,
                                            fit: BoxFit.cover,
                                            errorBuilder: (context, error, stackTrace) =>
                                                Container(
                                              width: 120,
                                              height: 67.5,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              alignment: Alignment.center,
                                              child: const Icon(Icons.queue_music_rounded),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          playlist.name,
                                          style: const TextStyle(
                                            fontFamily: '.SF Pro Text',
                                            fontSize: 16,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.1,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '${playlist.videos.length} canciones',
                                          style: TextStyle(
                                            fontFamily: '.SF Pro Text',
                                            fontSize: 13,
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Icon(
                                    Icons.chevron_right_rounded,
                                    color: Theme.of(context).colorScheme.outline,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}
