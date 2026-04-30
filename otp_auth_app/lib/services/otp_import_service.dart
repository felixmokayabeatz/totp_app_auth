import 'dart:convert';
import 'dart:typed_data';

class OTPImportEntry {
  const OTPImportEntry({
    required this.service,
    required this.secret,
    this.issuer,
    this.accountLabel,
  });

  final String service;
  final String secret;
  final String? issuer;
  final String? accountLabel;
}

class OTPImportService {
  List<OTPImportEntry> parse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];

    final jsonEntries = _parseJson(trimmed);
    if (jsonEntries.isNotEmpty) return jsonEntries;

    final entries = <OTPImportEntry>[];
    final uriMatches = RegExp(
      r'(otpauth(?:-migration)?://[^\s]+)',
      caseSensitive: false,
    ).allMatches(trimmed);

    if (uriMatches.isEmpty &&
        (trimmed.startsWith('otpauth://') ||
            trimmed.startsWith('otpauth-migration://'))) {
      entries.addAll(_parseUri(trimmed));
      return _dedupe(entries);
    }

    for (final match in uriMatches) {
      final rawUri = _trimUri(match.group(1) ?? '');
      entries.addAll(_parseUri(rawUri));
    }

    return _dedupe(entries);
  }

  List<OTPImportEntry> _parseJson(String input) {
    try {
      final decoded = jsonDecode(input);
      final rawItems = decoded is List
          ? decoded
          : decoded is Map && decoded['accounts'] is List
              ? decoded['accounts'] as List
              : const [];

      return rawItems.whereType<Map>().map((item) {
        final secret = item['secret']?.toString() ?? '';
        final service = item['service']?.toString() ??
            item['issuer']?.toString() ??
            item['name']?.toString() ??
            '';
        return OTPImportEntry(
          service: service.trim(),
          secret: _cleanSecret(secret),
          issuer: item['issuer']?.toString(),
          accountLabel:
              item['account_label']?.toString() ?? item['accountLabel']?.toString(),
        );
      }).where((entry) {
        return entry.service.isNotEmpty && _isBase32Secret(entry.secret);
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  List<OTPImportEntry> _parseUri(String rawUri) {
    if (rawUri.toLowerCase().startsWith('otpauth-migration://')) {
      return _parseMigrationUri(rawUri);
    }

    if (rawUri.toLowerCase().startsWith('otpauth://')) {
      final entry = _parseOtpAuthUri(rawUri);
      return entry == null ? const [] : [entry];
    }

    return const [];
  }

  OTPImportEntry? _parseOtpAuthUri(String rawUri) {
    try {
      final uri = Uri.parse(rawUri);
      if (uri.host.toLowerCase() == 'hotp') return null;

      final secret = _cleanSecret(uri.queryParameters['secret'] ?? '');
      if (!_isBase32Secret(secret)) return null;

      final issuer = uri.queryParameters['issuer']?.trim();
      final label = Uri.decodeComponent(uri.path.replaceFirst('/', ''));
      final labelParts = label.split(':');
      final parsedService = issuer?.isNotEmpty == true
          ? issuer!
          : (labelParts.isNotEmpty ? labelParts.first.trim() : '');
      final parsedAccountLabel = labelParts.length > 1
          ? labelParts.sublist(1).join(':').trim()
          : label.trim();

      return OTPImportEntry(
        service: parsedService.isEmpty ? 'Imported Account' : parsedService,
        secret: secret,
        issuer: issuer?.isEmpty == true ? null : issuer,
        accountLabel:
            parsedAccountLabel.isEmpty ? null : parsedAccountLabel,
      );
    } catch (_) {
      return null;
    }
  }

  List<OTPImportEntry> _parseMigrationUri(String rawUri) {
    try {
      final uri = Uri.parse(rawUri);
      final data = uri.queryParameters['data'];
      if (data == null || data.isEmpty) return const [];

      final bytes = base64Url.decode(base64Url.normalize(data));
      final messages = _readLengthDelimitedFields(bytes, 1);
      final entries = <OTPImportEntry>[];

      for (final message in messages) {
        final parsed = _parseMigrationOtp(message);
        if (parsed != null) entries.add(parsed);
      }

      return entries;
    } catch (_) {
      return const [];
    }
  }

  OTPImportEntry? _parseMigrationOtp(Uint8List bytes) {
    var index = 0;
    Uint8List? secretBytes;
    String? name;
    String? issuer;
    var otpType = 2;

    while (index < bytes.length) {
      final tagRead = _readVarint(bytes, index);
      final tag = tagRead.value;
      index = tagRead.nextIndex;
      final field = tag >> 3;
      final wireType = tag & 7;

      if (field == 1 && wireType == 2) {
        final value = _readLengthDelimited(bytes, index);
        secretBytes = value.value;
        index = value.nextIndex;
      } else if (field == 2 && wireType == 2) {
        final value = _readLengthDelimited(bytes, index);
        name = utf8.decode(value.value, allowMalformed: true);
        index = value.nextIndex;
      } else if (field == 3 && wireType == 2) {
        final value = _readLengthDelimited(bytes, index);
        issuer = utf8.decode(value.value, allowMalformed: true);
        index = value.nextIndex;
      } else if (field == 6 && wireType == 0) {
        final value = _readVarint(bytes, index);
        otpType = value.value;
        index = value.nextIndex;
      } else {
        index = _skipField(bytes, index, wireType);
      }
    }

    if (secretBytes == null || secretBytes.isEmpty || otpType == 1) {
      return null;
    }

    final labelParts = (name ?? '').split(':');
    final service = issuer?.trim().isNotEmpty == true
        ? issuer!.trim()
        : labelParts.first.trim();
    final accountLabel = labelParts.length > 1
        ? labelParts.sublist(1).join(':').trim()
        : (name ?? '').trim();

    final secret = _base32Encode(secretBytes);
    if (!_isBase32Secret(secret)) return null;

    return OTPImportEntry(
      service: service.isEmpty ? 'Imported Account' : service,
      secret: secret,
      issuer: issuer?.trim().isEmpty == true ? null : issuer?.trim(),
      accountLabel: accountLabel.isEmpty ? null : accountLabel,
    );
  }

  List<Uint8List> _readLengthDelimitedFields(Uint8List bytes, int fieldNumber) {
    final values = <Uint8List>[];
    var index = 0;

    while (index < bytes.length) {
      final tagRead = _readVarint(bytes, index);
      final tag = tagRead.value;
      index = tagRead.nextIndex;
      final field = tag >> 3;
      final wireType = tag & 7;

      if (field == fieldNumber && wireType == 2) {
        final value = _readLengthDelimited(bytes, index);
        values.add(value.value);
        index = value.nextIndex;
      } else {
        index = _skipField(bytes, index, wireType);
      }
    }

    return values;
  }

  _VarintRead _readVarint(Uint8List bytes, int startIndex) {
    var result = 0;
    var shift = 0;
    var index = startIndex;

    while (index < bytes.length) {
      final byte = bytes[index++];
      result |= (byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) {
        return _VarintRead(result, index);
      }
      shift += 7;
    }

    throw FormatException('Invalid protobuf varint.');
  }

  _BytesRead _readLengthDelimited(Uint8List bytes, int startIndex) {
    final lengthRead = _readVarint(bytes, startIndex);
    final end = lengthRead.nextIndex + lengthRead.value;
    if (end > bytes.length) {
      throw FormatException('Invalid protobuf length.');
    }
    return _BytesRead(
      Uint8List.fromList(bytes.sublist(lengthRead.nextIndex, end)),
      end,
    );
  }

  int _skipField(Uint8List bytes, int index, int wireType) {
    switch (wireType) {
      case 0:
        return _readVarint(bytes, index).nextIndex;
      case 1:
        return index + 8;
      case 2:
        return _readLengthDelimited(bytes, index).nextIndex;
      case 5:
        return index + 4;
      default:
        throw FormatException('Unsupported protobuf wire type.');
    }
  }

  String _base32Encode(List<int> bytes) {
    const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    final buffer = StringBuffer();
    var value = 0;
    var bits = 0;

    for (final byte in bytes) {
      value = (value << 8) | byte;
      bits += 8;
      while (bits >= 5) {
        buffer.write(alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }

    if (bits > 0) {
      buffer.write(alphabet[(value << (5 - bits)) & 31]);
    }

    return buffer.toString();
  }

  String _cleanSecret(String value) {
    return value.replaceAll(RegExp(r'\s+'), '').toUpperCase();
  }

  bool _isBase32Secret(String value) {
    return RegExp(r'^[A-Z2-7]+=*$').hasMatch(value) && value.length >= 8;
  }

  String _trimUri(String value) {
    return value.replaceAll(RegExp(r'[\]\),.;]+$'), '');
  }

  List<OTPImportEntry> _dedupe(List<OTPImportEntry> entries) {
    final seen = <String>{};
    final result = <OTPImportEntry>[];
    for (final entry in entries) {
      final key = [
        entry.service.toLowerCase(),
        entry.accountLabel?.toLowerCase() ?? '',
        entry.secret,
      ].join('|');
      if (seen.add(key)) result.add(entry);
    }
    return result;
  }
}

class _VarintRead {
  const _VarintRead(this.value, this.nextIndex);

  final int value;
  final int nextIndex;
}

class _BytesRead {
  const _BytesRead(this.value, this.nextIndex);

  final Uint8List value;
  final int nextIndex;
}
