import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

class PickedImportFile {
  const PickedImportFile({
    required this.fileName,
    required this.mimeType,
    required this.content,
  });

  final String fileName;
  final String mimeType;
  final String content;
}

class ImportFilePickerService {
  static const MethodChannel _channel = MethodChannel(
    'com.beatzlock.otp/file_picker',
  );

  // Desktop picking used to go through file_selector_windows directly, which
  // is why importing worked on Windows and Android and nowhere else -- a Linux
  // or Fedora user had no way to get accounts in at all. The umbrella
  // file_selector package covers Windows, Linux and macOS with the same call.
  bool get _isSupportedDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  bool get canPickOtpImportFile => Platform.isAndroid || _isSupportedDesktop;

  Future<PickedImportFile?> pickOtpImportFile() async {
    if (Platform.isAndroid) {
      return _pickAndroidImportFile('pickImportFile');
    }
    if (_isSupportedDesktop) {
      return _pickDesktopImportFile();
    }
    return null;
  }

  Future<PickedImportFile?> _pickAndroidImportFile(String methodName) async {
    final payload = await _channel.invokeMapMethod<String, dynamic>(methodName);
    if (payload == null) return null;

    final fileName = payload['fileName']?.toString().trim();
    final mimeType = payload['mimeType']?.toString().trim() ?? '';
    final bytes = _asBytes(payload['bytes']);
    return PickedImportFile(
      fileName:
          (fileName == null || fileName.isEmpty) ? 'import.txt' : fileName,
      mimeType: mimeType,
      content: _decodeText(bytes),
    );
  }

  Future<PickedImportFile?> _pickDesktopImportFile() async {
    // Both of this app's own export formats, plus the plain-text and JSON
    // exports other authenticators produce. Left unfiltered the dialog offers
    // every file on the machine, which is how people end up picking the wrong
    // one and getting a parse error they cannot explain.
    const beatzlockGroup = XTypeGroup(
      label: 'BeatzLock export',
      extensions: <String>['bl', 'txt', 'json'],
    );
    const anyGroup = XTypeGroup(label: 'All files');

    final file = await openFile(
      acceptedTypeGroups: const <XTypeGroup>[beatzlockGroup, anyGroup],
      confirmButtonText: 'Import',
    );
    if (file == null) return null;

    return PickedImportFile(
      fileName: file.name,
      mimeType: '',
      content: await file.readAsString(),
    );
  }

  Uint8List _asBytes(dynamic value) {
    if (value is Uint8List) return value;
    if (value is ByteData) return value.buffer.asUint8List();
    if (value is List) {
      return Uint8List.fromList(value.cast<int>());
    }
    return Uint8List(0);
  }

  String _decodeText(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    var decoded = utf8.decode(bytes, allowMalformed: true);
    if (decoded.isNotEmpty && decoded.codeUnitAt(0) == 0xFEFF) {
      decoded = decoded.substring(1);
    }
    return decoded;
  }
}
