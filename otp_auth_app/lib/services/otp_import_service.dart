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
  List<OTPImportEntry> parseCsv(
    String input, {
    bool preserveDuplicates = false,
  }) {
    final entries = _parseDelimitedRows(input, forcedDelimiter: ',');
    return preserveDuplicates ? entries : _dedupe(entries);
  }

  List<OTPImportEntry> parse(String input, {bool preserveDuplicates = false}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];

    final jsonEntries = _parseJson(trimmed);
    if (jsonEntries.isNotEmpty) {
      return preserveDuplicates ? jsonEntries : _dedupe(jsonEntries);
    }

    final tableEntries = _parseDelimitedRows(trimmed);
    if (tableEntries.isNotEmpty) {
      return preserveDuplicates ? tableEntries : _dedupe(tableEntries);
    }

    final entries = <OTPImportEntry>[];
    final uriMatches = RegExp(
      r'(otpauth(?:-migration)?://[^\s]+)',
      caseSensitive: false,
    ).allMatches(trimmed);

    if (uriMatches.isEmpty &&
        (trimmed.startsWith('otpauth://') ||
            trimmed.startsWith('otpauth-migration://'))) {
      entries.addAll(_parseUri(trimmed));
      return preserveDuplicates ? entries : _dedupe(entries);
    }

    for (final match in uriMatches) {
      final rawUri = _trimUri(match.group(1) ?? '');
      entries.addAll(_parseUri(rawUri));
    }

    return preserveDuplicates ? entries : _dedupe(entries);
  }

  List<OTPImportEntry> _parseDelimitedRows(
    String input, {
    String? forcedDelimiter,
  }) {
    final delimiter = forcedDelimiter ?? _detectDelimiter(input);
    final rows = _parseDelimitedRecords(input, delimiter)
        .map((row) => row.map((cell) => cell.trim()).toList())
        .where((row) => row.any((cell) => cell.isNotEmpty))
        .toList();
    if (rows.isEmpty) return const [];

    final firstRow = rows.first.map(_normalizeHeader).toList();
    if (_looksLikePasswordExportHeader(firstRow)) {
      return const [];
    }
    final hasHeader = firstRow.any(
      (cell) =>
          _secretHeaders.contains(cell) ||
          _serviceHeaders.contains(cell) ||
          _accountHeaders.contains(cell) ||
          _uriHeaders.contains(cell),
    );
    final dataRows = hasHeader ? rows.skip(1).toList() : rows;

    int? serviceIndex;
    int? accountIndex;
    int? secretIndex;
    int? issuerIndex;
    int? uriIndex;

    if (hasHeader) {
      serviceIndex = _findHeaderIndex(firstRow, _serviceHeaders);
      accountIndex = _findHeaderIndex(firstRow, _accountHeaders);
      secretIndex = _findHeaderIndex(firstRow, _secretHeaders);
      issuerIndex = _findHeaderIndex(firstRow, _issuerHeaders);
      uriIndex = _findHeaderIndex(firstRow, _uriHeaders);
    }

    final entries = <OTPImportEntry>[];
    for (final row in dataRows) {
      if (row.every((cell) => cell.trim().isEmpty)) {
        continue;
      }

      final uriEntries = _extractUriEntries(row, uriIndex: uriIndex);
      if (uriEntries.isNotEmpty) {
        entries.addAll(uriEntries);
        continue;
      }

      final resolvedSecretIndex =
          secretIndex ??
          row.indexWhere((cell) => _isBase32Secret(_cleanSecret(cell)));
      if (resolvedSecretIndex < 0 || resolvedSecretIndex >= row.length) {
        continue;
      }

      final secret = _cleanSecret(row[resolvedSecretIndex]);
      if (!_isBase32Secret(secret)) continue;

      final service =
          _readCell(row, serviceIndex) ??
          _readCell(row, issuerIndex) ??
          (resolvedSecretIndex == 0 ? null : row.first.trim());
      if (service == null || service.trim().isEmpty) continue;

      final accountLabel =
          _readCell(row, accountIndex) ??
          _guessAccountLabel(row, resolvedSecretIndex, service);

      entries.add(
        OTPImportEntry(
          service: service.trim(),
          secret: secret,
          issuer: service.trim(),
          accountLabel: accountLabel?.trim().isEmpty == true
              ? null
              : accountLabel?.trim(),
        ),
      );
    }

    return entries;
  }

  static const Set<String> _serviceHeaders = {
    'service',
    'service name',
    'issuer',
    'app',
    'site',
    'name',
    'account name',
    'provider',
    'company',
  };

  static const Set<String> _accountHeaders = {
    'account',
    'email',
    'username',
    'label',
    'account label',
    'login',
    'user',
    'user name',
    'account_name',
  };

  static const Set<String> _secretHeaders = {
    'secret',
    'secret key',
    'otp secret',
    'totp secret',
    'key',
    'token',
    'shared secret',
    'twofa secret',
    'authenticator key',
  };

  static const Set<String> _issuerHeaders = {
    'issuer',
    'service',
    'service name',
    'provider',
    'app',
    'site',
    'name',
  };

  static const Set<String> _uriHeaders = {
    'uri',
    'url',
    'otpauth',
    'otpauth url',
    'otpauth_url',
    'otp uri',
    'otp url',
    'migration uri',
    'qr data',
    'qr_data',
  };

  static const Set<String> _passwordExportHeaders = {
    'password',
    'passcode',
    'login password',
    'login_password',
    'login username',
    'login email',
    'login_email',
    'website',
    'site name',
    'site_name',
    'origin',
    'login uri',
    'login_uri',
    'login url',
    'login_url',
    'urls',
    'additional urls',
    'additional_urls',
    'vault',
    'vault name',
    'vault_name',
    'folder',
    'notes',
    'note',
    'type',
    'item type',
    'item_type',
    'username',
    'user name',
    'login_username',
  };

  String _detectDelimiter(String input) {
    final tabs = '\t'.allMatches(input).length;
    final commas = ','.allMatches(input).length;
    final semicolons = ';'.allMatches(input).length;
    if (tabs >= commas && tabs >= semicolons && tabs > 0) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }

  List<List<String>> _parseDelimitedRecords(String input, String delimiter) {
    final records = <List<String>>[];
    final cells = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var index = 0;

    while (index < input.length) {
      final char = input[index];
      if (char == '"') {
        final nextIsQuote = index + 1 < input.length && input[index + 1] == '"';
        if (inQuotes && nextIsQuote) {
          current.write('"');
          index += 2;
          continue;
        }
        inQuotes = !inQuotes;
      } else if (!inQuotes && (char == '\n' || char == '\r')) {
        cells.add(current.toString());
        current.clear();
        if (char == '\r' &&
            index + 1 < input.length &&
            input[index + 1] == '\n') {
          index++;
        }
        records.add(List<String>.from(cells));
        cells.clear();
      } else if (char == delimiter && !inQuotes) {
        cells.add(current.toString());
        current.clear();
      } else {
        current.write(char);
      }
      index++;
    }

    if (current.isNotEmpty || cells.isNotEmpty) {
      cells.add(current.toString());
      records.add(List<String>.from(cells));
    }

    return records;
  }

  int? _findHeaderIndex(List<String> row, Set<String> candidates) {
    for (var index = 0; index < row.length; index++) {
      if (candidates.contains(_normalizeHeader(row[index]))) {
        return index;
      }
    }
    return null;
  }

  String _normalizeHeader(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'[_\s]+'), ' ');
  }

  String? _readCell(List<String> row, int? index) {
    if (index == null || index < 0 || index >= row.length) return null;
    final value = row[index].trim();
    return value.isEmpty ? null : value;
  }

  String? _guessAccountLabel(
    List<String> row,
    int secretIndex,
    String service,
  ) {
    for (var index = 0; index < row.length; index++) {
      if (index == secretIndex) continue;
      final value = row[index].trim();
      if (value.isEmpty || value == service) continue;
      if (value.contains('@')) return value;
    }
    return null;
  }

  bool _looksLikePasswordExportHeader(List<String> headers) {
    if (headers.isEmpty) return false;
    var passwordSignals = 0;
    var otpSignals = 0;
    for (final header in headers) {
      if (_passwordExportHeaders.contains(header)) {
        passwordSignals++;
      }
      if (_secretHeaders.contains(header) || _uriHeaders.contains(header)) {
        otpSignals++;
      }
    }
    if (passwordSignals >= 2) {
      return true;
    }
    return passwordSignals >= 1 && otpSignals == 0;
  }

  List<OTPImportEntry> _extractUriEntries(List<String> row, {int? uriIndex}) {
    final candidates = <String>[];
    if (uriIndex != null && uriIndex >= 0 && uriIndex < row.length) {
      final direct = row[uriIndex].trim();
      if (direct.isNotEmpty) {
        candidates.add(direct);
      }
    }
    for (final cell in row) {
      final value = cell.trim();
      if (value.isEmpty) continue;
      if (value.toLowerCase().contains('otpauth://') ||
          value.toLowerCase().contains('otpauth-migration://')) {
        candidates.add(value);
      }
    }

    final entries = <OTPImportEntry>[];
    for (final candidate in candidates) {
      final trimmed = candidate.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('otpauth://') ||
          trimmed.startsWith('otpauth-migration://')) {
        entries.addAll(_parseUri(trimmed));
        continue;
      }
      final matches = RegExp(
        r'(otpauth(?:-migration)?://[^\s]+)',
        caseSensitive: false,
      ).allMatches(trimmed);
      for (final match in matches) {
        final rawUri = _trimUri(match.group(1) ?? '');
        entries.addAll(_parseUri(rawUri));
      }
    }
    return entries;
  }

  List<OTPImportEntry> _parseJson(String input) {
    try {
      final decoded = jsonDecode(input);
      final rawItems = decoded is List
          ? decoded
          : decoded is Map && decoded['accounts'] is List
          ? decoded['accounts'] as List
          : const [];

      return rawItems
          .whereType<Map>()
          .expand(_entriesFromJsonItem)
          .where(
            (entry) =>
                entry.service.isNotEmpty && _isBase32Secret(entry.secret),
          )
          .toList();
    } catch (_) {
      return const [];
    }
  }

  List<OTPImportEntry> _entriesFromJsonItem(Map<dynamic, dynamic> item) {
    final normalized = item.map(
      (key, value) => MapEntry(_normalizeHeader(key.toString()), value),
    );

    final uriValue = _firstNonEmpty([
      normalized['uri'],
      normalized['otpauth'],
      normalized['otpauth url'],
      normalized['otpauth_url'],
      normalized['otp uri'],
      normalized['otp url'],
      normalized['migration uri'],
    ]);
    if (uriValue != null &&
        (uriValue.contains('otpauth://') ||
            uriValue.contains('otpauth-migration://'))) {
      return _parseUri(uriValue.trim());
    }

    if (_looksLikePasswordExportJson(normalized)) {
      return const [];
    }

    final secret = _cleanSecret(
      _firstNonEmpty([
            normalized['secret'],
            normalized['secret key'],
            normalized['otp secret'],
            normalized['totp secret'],
            normalized['totp_secret'],
          ]) ??
          '',
    );
    final service = _firstNonEmpty([
      normalized['service'],
      normalized['issuer'],
      normalized['name'],
      normalized['account name'],
    ]);

    if (service == null || service.trim().isEmpty || !_isBase32Secret(secret)) {
      return const [];
    }

    return [
      OTPImportEntry(
        service: service.trim(),
        secret: secret,
        issuer: _firstNonEmpty([normalized['issuer']]),
        accountLabel: _firstNonEmpty([
          normalized['account label'],
          normalized['account_label'],
          normalized['label'],
        ]),
      ),
    ];
  }

  bool _looksLikePasswordExportJson(Map<String, dynamic> normalized) {
    var signals = 0;
    for (final key in _passwordExportHeaders) {
      final value = normalized[key];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      signals++;
    }
    return signals >= 2;
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
        accountLabel: parsedAccountLabel.isEmpty ? null : parsedAccountLabel,
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

      final bytes = _decodeMigrationPayload(data);
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

  Uint8List _decodeMigrationPayload(String data) {
    final normalized = data.replaceAll(' ', '+');
    try {
      return base64Url.decode(base64Url.normalize(normalized));
    } catch (_) {
      return base64.decode(base64.normalize(normalized));
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
    return value
        .trim()
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll('-', '')
        .replaceAll(RegExp(r'\s+'), '')
        .toUpperCase();
  }

  bool _isBase32Secret(String value) {
    return RegExp(r'^[A-Z2-7]+=*$').hasMatch(value) && value.length >= 8;
  }

  String _trimUri(String value) {
    return value.replaceAll(RegExp(r'[\]\),.;]+$'), '');
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final stringValue = value.toString().trim();
      if (stringValue.isNotEmpty) {
        return stringValue;
      }
    }
    return null;
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
