import 'package:hive/hive.dart';
import 'package:myapp/models/video_history.dart';

class HistoryService {
  static const String _boxName = 'history';

  Future<Box<VideoHistory>> get _box async =>
      await Hive.openBox<VideoHistory>(_boxName);

  Future<void> addVideoToHistory(VideoHistory video) async {
    final box = await _box;
    
    // Busca la clave del video existente, si hay alguno
    dynamic keyToDelete;
    for (var entry in box.toMap().entries) {
      if (entry.value.videoId == video.videoId) {
        keyToDelete = entry.key;
        break;
      }
    }

    // Si el video existe, bórralo primero
    if (keyToDelete != null) {
      await box.delete(keyToDelete);
    }

    // Añade la nueva entrada de vídeo. Esto actualiza efectivamente la marca de tiempo 'watchedAt'
    await box.add(video);
  }

  Future<List<VideoHistory>> getHistory() async {
    final box = await _box;
    // Ordena por fecha de visualización, del más reciente al más antiguo
    final history = box.values.toList();
    history.sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
    return history;
  }

  Future<void> clearHistory() async {
    final box = await _box;
    await box.clear();
  }
}
