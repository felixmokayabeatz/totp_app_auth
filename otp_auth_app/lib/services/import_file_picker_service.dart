import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_windows/file_selector_windows.dart';
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
  static const MethodChannel _channel =
      MethodChannel('com.beatzlock.otp/file_picker');

  bool get canPickOtpImportFile => Platform.isAndroid || Platform.isWindows;
  bool get canPickPasswordImportFile =>
      Platform.isAndroid || Platform.isWindows;

  Future<PickedImportFile?> pickOtpImportFile() async {
    if (Platform.isAndroid) {
      return _pickAndroidImportFile('pickImportFile');
    }
    if (Platform.isWindows) {
      return _pickWindowsImportFile(
        confirmButtonText: 'Choose Import File',
      );
    }
    return null;
  }

  Future<PickedImportFile?> pickPasswordImportFile() async {
    if (Platform.isAndroid) {
      return _pickAndroidImportFile('pickPasswordImportFile');
    }
    if (Platform.isWindows) {
      return _pickWindowsImportFile(
        confirmButtonText: 'Import passwords',
      );
    }
    return null;
  }

  Future<PickedImportFile?> _pickAndroidImportFile(String methodName) async {
    final payload =
        await _channel.invokeMapMethod<String, dynamic>(methodName);
    if (payload == null) return null;

    final fileName = payload['fileName']?.toString().trim();
    final mimeType = payload['mimeType']?.toString().trim() ?? '';
    final bytes = _asBytes(payload['bytes']);
    return PickedImportFile(
      fileName: (fileName == null || fileName.isEmpty) ? 'import.txt' : fileName,
      mimeType: mimeType,
      content: _decodeText(bytes),
    );
  }

  Future<PickedImportFile?> _pickWindowsImportFile({
    required String confirmButtonText,
  }) async {
    final file = await FileSelectorWindows().openFile(
      confirmButtonText: confirmButtonText,
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
