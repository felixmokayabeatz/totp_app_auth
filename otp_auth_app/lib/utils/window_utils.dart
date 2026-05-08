import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowUtils {
  static const double minWidth = 900;
  static const double minHeight = 700;

  static Future<void> setMinWindowSize() async {
    if (Platform.isWindows) {
      try {
        await MethodChannel('flutter/window').invokeMethod(
          'setMinimumSize',
          {'width': minWidth, 'height': minHeight},
        );
      } catch (e) {
        debugPrint('Error setting min window size: $e');
      }
    }
  }

  static Future<void> setWindowTitle(String title) async {
    if (Platform.isWindows) {
      try {
        await MethodChannel('flutter/window').invokeMethod(
          'setTitle',
          {'title': title},
        );
      } catch (e) {
        debugPrint('Error setting window title: $e');
      }
    }
  }
}
