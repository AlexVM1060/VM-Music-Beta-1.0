import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

class LiveLyricsRecognizerService {
  final SpeechToText _speech = SpeechToText();
  bool _initialized = false;
  bool _active = false;

  bool get isActive => _active;

  Future<bool> start({
    required void Function(String recognizedText) onText,
  }) async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) return false;

    if (!_initialized) {
      _initialized = await _speech.initialize(
        onError: (_) {},
        onStatus: (status) {
          if (status == 'notListening' || status == 'done') {
            _active = false;
          }
        },
      );
    }
    if (!_initialized) return false;

    if (_speech.isListening) {
      await _speech.stop();
    }

    await _speech.listen(
      onResult: (SpeechRecognitionResult result) {
        final words = result.recognizedWords.trim();
        if (words.isNotEmpty) {
          onText(words);
        }
      },
      listenOptions: SpeechListenOptions(
        partialResults: true,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
      ),
    );
    _active = _speech.isListening;
    return _active;
  }

  Future<void> stop() async {
    if (_speech.isListening) {
      await _speech.stop();
    }
    _active = false;
  }
}
