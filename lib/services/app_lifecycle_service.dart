import 'package:flutter/widgets.dart';

class AppLifecycleService extends ChangeNotifier with WidgetsBindingObserver {
  bool _isForeground = true;

  bool get isForeground => _isForeground;

  AppLifecycleService() {
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _isForeground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final next = state == AppLifecycleState.resumed;
    if (_isForeground == next) return;
    _isForeground = next;
    notifyListeners();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
