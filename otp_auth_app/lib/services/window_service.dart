import 'package:bitsdojo_window/bitsdojo_window.dart';

class WindowService {
  static bool _alwaysOnTop = false;
  
  static bool get alwaysOnTop => _alwaysOnTop;
  
  static Future<void> setAlwaysOnTop(bool value) async {
    _alwaysOnTop = value;
    // Use native method channel for always on top
    await _setWindowAlwaysOnTop(value);
  }
  
  static Future<void> _setWindowAlwaysOnTop(bool value) async {
    // This is a placeholder - actual implementation requires native code
    print('Always on top set to: $value');
    // For now, we'll just store the value
  }
}