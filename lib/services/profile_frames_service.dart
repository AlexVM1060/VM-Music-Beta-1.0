import 'package:supabase_flutter/supabase_flutter.dart';

class ProfileFramesService {
  ProfileFramesService._();

  static const String bucket = 'profile-frames';
  static const List<String> _candidatePaths = ['public', 'frames', 'marcos', ''];

  static Future<List<String>> fetchFrameUrls() async {
    final client = Supabase.instance.client;
    final urls = <String>{};
    final errors = <String>[];
    for (final path in _candidatePaths) {
      try {
        final objects = await client.storage.from(bucket).list(path: path);
        for (final item in objects) {
          final name = (item.name).trim();
          if (name.isEmpty) continue;
          final lower = name.toLowerCase();
          final isImage =
              lower.endsWith('.png') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg');
          if (!isImage) continue;
          final objectPath = path.isEmpty ? name : '$path/$name';
          urls.add(client.storage.from(bucket).getPublicUrl(objectPath));
        }
      } catch (e) {
        errors.add('${path.isEmpty ? "<root>" : path}: $e');
      }
    }
    if (urls.isEmpty && errors.isNotEmpty) {
      throw Exception(errors.join(' | '));
    }
    return urls.toList(growable: false);
  }
}
