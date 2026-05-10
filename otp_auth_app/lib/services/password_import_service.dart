import 'dart:convert';

class PasswordImportEntry {
  const PasswordImportEntry({
    required this.title,
    this.type,
    this.email,
    this.username,
    this.password,
    this.note,
    this.totp,
    this.url,
    this.createdAt,
    this.modifiedAt,
    this.vault,
  });

  final String title;
  final String? type;
  final String? email;
  final String? username;
  final String? password;
  final String? note;
  final String? totp;
  final String? url;
  final DateTime? createdAt;
  final DateTime? modifiedAt;
  final String? vault;
}

class PasswordImportService {
  List<PasswordImportEntry> parse(String input, {String? fileName}) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return const [];

    final lowerFileName = (fileName ?? '').toLowerCase();
    if (lowerFileName.endsWith('.json') ||
        trimmed.startsWith('{') ||
        trimmed.startsWith('[')) {
      final jsonEntries = _parseJson(trimmed);
      if (jsonEntries.isNotEmpty) return jsonEntries;
    }

    final csvEntries = _parseDelimitedRows(trimmed);
    return csvEntries;
  }

  List<PasswordImportEntry> _parseJson(String input) {
    try {
      final decoded = jsonDecode(input);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map(_entryFromMap)
            .whereType<PasswordImportEntry>()
            .toList();
      }

      if (decoded is Map) {
        final candidates = <dynamic>[
          decoded['items'],
          decoded['vaults'],
          decoded['entries'],
          decoded['logins'],
          decoded['accounts'],
          decoded['data'],
        ];

        for (final candidate in candidates) {
          if (candidate is List) {
            final entries = candidate
                .whereType<Map>()
                .map(_entryFromMap)
                .whereType<PasswordImportEntry>()
                .toList();
            if (entries.isNotEmpty) return entries;
          }
        }

        final single = _entryFromMap(decoded);
        return single == null ? const [] : [single];
      }
    } catch (_) {}

    return const [];
  }

  PasswordImportEntry? _entryFromMap(Map<dynamic, dynamic> item) {
    final normalized = item.map(
      (key, value) => MapEntry(key.toString().toLowerCase(), value),
    );

    final title = _firstNonEmpty([
      normalized['title'],
      normalized['name'],
      normalized['label'],
      normalized['itemname'],
      normalized['display_name'],
    ]);
    final type = _firstNonEmpty([
      normalized['type'],
      normalized['item_type'],
      normalized['category'],
    ]);
    final email = _firstNonEmpty([
      normalized['email'],
      normalized['login_email'],
    ]);
    final username = _firstNonEmpty([
      normalized['username'],
      normalized['login_username'],
      normalized['account'],
      normalized['login'],
      normalized['email'],
    ]);
    final password = _firstNonEmpty([
      normalized['password'],
      normalized['login_password'],
      normalized['secret'],
    ]);
    final note = _firstNonEmpty([
      normalized['note'],
      normalized['notes'],
      normalized['extra'],
      normalized['details'],
      normalized['description'],
    ]);
    final totp = _firstNonEmpty([
      normalized['totp'],
      normalized['otp'],
      normalized['one_time_password'],
      normalized['totp_secret'],
    ]);
    final url = _firstUrl([
      normalized['url'],
      normalized['urls'],
      normalized['website'],
      normalized['site'],
      normalized['login_uri'],
      normalized['login_url'],
    ]);
    final createdAt = _parseDateTimeValue(
      normalized['createtime'] ?? normalized['created_at'],
    );
    final modifiedAt = _parseDateTimeValue(
      normalized['modifytime'] ??
          normalized['modified_at'] ??
          normalized['updated_at'],
    );
    final vault = _firstNonEmpty([
      normalized['vault'],
      normalized['vault_name'],
      normalized['folder'],
    ]);

    final resolvedTitle =
        (title?.trim().isNotEmpty == true) ? title!.trim() : _titleFromUrl(url);
    if (resolvedTitle == null || resolvedTitle.isEmpty) {
      return null;
    }

    if ((password ?? '').trim().isEmpty &&
        (note ?? '').trim().isEmpty &&
        (totp ?? '').trim().isEmpty) {
      return null;
    }

    return PasswordImportEntry(
      title: resolvedTitle,
      type: _normalizeOptional(type),
      email: _normalizeOptional(email),
      username: _normalizeOptional(username),
      password: _normalizeOptional(password),
      note: _normalizeOptional(note),
      totp: _normalizeOptional(totp),
      url: _normalizeOptional(url),
      createdAt: createdAt,
      modifiedAt: modifiedAt,
      vault: _normalizeOptional(vault),
    );
  }

  List<PasswordImportEntry> _parseDelimitedRows(String input) {
    final lines = input
        .split(RegExp(r'\r?\n'))
        .where((line) => line.trim().isNotEmpty)
        .toList();
    if (lines.isEmpty) return const [];

    final delimiter = _detectDelimiter(input);
    final rows =
        lines.map((line) => _splitDelimitedLine(line, delimiter)).toList();
    if (rows.isEmpty) return const [];

    final headers = rows.first.map((cell) => cell.trim().toLowerCase()).toList();
    final hasHeader = headers.any((cell) => _knownHeaderNames.contains(cell));
    final dataRows = hasHeader ? rows.skip(1) : rows;

    final titleIndex = _findHeaderIndex(headers, {
      'title',
      'name',
      'item',
      'item name',
      'label',
      'account',
      'site name',
    });
    final typeIndex = _findHeaderIndex(headers, {
      'type',
      'item type',
    });
    final emailIndex = _findHeaderIndex(headers, {
      'email',
      'login email',
      'login_email',
    });
    final usernameIndex = _findHeaderIndex(headers, {
      'username',
      'user name',
      'email',
      'login',
      'login_username',
    });
    final passwordIndex = _findHeaderIndex(headers, {
      'password',
      'login_password',
      'secret',
    });
    final noteIndex = _findHeaderIndex(headers, {
      'note',
      'notes',
      'extra',
      'comments',
      'description',
    });
    final totpIndex = _findHeaderIndex(headers, {
      'totp',
      'otp',
      'one_time_password',
      'totp_secret',
    });
    final urlIndex = _findHeaderIndex(headers, {
      'url',
      'urls',
      'website',
      'site',
      'origin',
      'login_uri',
      'login url',
    });
    final createTimeIndex = _findHeaderIndex(headers, {
      'createtime',
      'created_at',
      'created time',
    });
    final modifyTimeIndex = _findHeaderIndex(headers, {
      'modifytime',
      'modified_at',
      'updated_at',
      'modified time',
    });
    final vaultIndex = _findHeaderIndex(headers, {
      'vault',
      'vault_name',
      'folder',
    });

    final result = <PasswordImportEntry>[];
    for (final row in dataRows) {
      final type = _cell(row, typeIndex)?.toLowerCase() ?? '';
      final title = _cell(row, titleIndex) ?? _titleFromUrl(_cell(row, urlIndex));
      final email = _cell(row, emailIndex);
      final username = _cell(row, usernameIndex);
      final password = _cell(row, passwordIndex);
      final note = _cell(row, noteIndex);
      final totp = _cell(row, totpIndex);
      final url = _cell(row, urlIndex);
      final createdAt = _parseDateTimeValue(_cell(row, createTimeIndex));
      final modifiedAt = _parseDateTimeValue(_cell(row, modifyTimeIndex));
      final vault = _cell(row, vaultIndex);

      if ((title ?? '').trim().isEmpty) {
        continue;
      }

      result.add(
        PasswordImportEntry(
          title: title!.trim(),
          type: _normalizeOptional(type),
          email: _normalizeOptional(email),
          username: _normalizeOptional(username),
          password: _normalizeOptional(password),
          note: _normalizeOptional(note),
          totp: _normalizeOptional(totp),
          url: _normalizeOptional(url),
          createdAt: createdAt,
          modifiedAt: modifiedAt,
          vault: _normalizeOptional(vault),
        ),
      );
    }

    return result;
  }

  static const Set<String> _knownHeaderNames = {
    'title',
    'name',
    'username',
    'email',
    'password',
    'url',
    'website',
    'note',
    'notes',
    'totp',
    'vault',
    'createtime',
    'modifytime',
    'login_password',
    'login_username',
    'login_uri',
    'type',
  };

  String _detectDelimiter(String input) {
    final tabs = '\t'.allMatches(input).length;
    final commas = ','.allMatches(input).length;
    final semicolons = ';'.allMatches(input).length;
    if (tabs >= commas && tabs >= semicolons && tabs > 0) return '\t';
    if (semicolons > commas) return ';';
    return ',';
  }

  List<String> _splitDelimitedLine(String line, String delimiter) {
    final cells = <String>[];
    final current = StringBuffer();
    var inQuotes = false;
    var index = 0;

    while (index < line.length) {
      final char = line[index];
      if (char == '"') {
        final nextIsQuote = index + 1 < line.length && line[index + 1] == '"';
        if (inQuotes && nextIsQuote) {
          current.write('"');
          index += 2;
          continue;
        }
        inQuotes = !inQuotes;
      } else if (char == delimiter && !inQuotes) {
        cells.add(current.toString().trim());
        current.clear();
      } else {
        current.write(char);
      }
      index++;
    }

    cells.add(current.toString().trim());
    return cells;
  }

  int? _findHeaderIndex(List<String> row, Set<String> candidates) {
    for (var index = 0; index < row.length; index++) {
      if (candidates.contains(row[index].trim())) {
        return index;
      }
    }
    return null;
  }

  String? _cell(List<String> row, int? index) {
    if (index == null || index < 0 || index >= row.length) return null;
    final value = row[index].trim();
    return value.isEmpty ? null : value;
  }

  String? _firstNonEmpty(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      final stringValue = value.toString().trim();
      if (stringValue.isNotEmpty) return stringValue;
    }
    return null;
  }

  String? _firstUrl(List<dynamic> values) {
    for (final value in values) {
      if (value == null) continue;
      if (value is List && value.isNotEmpty) {
        final stringValue = value.first.toString().trim();
        if (stringValue.isNotEmpty) return stringValue;
      }

      final stringValue = value.toString().trim();
      if (stringValue.isEmpty) continue;

      if (stringValue.startsWith('[') && stringValue.endsWith(']')) {
        try {
          final decoded = jsonDecode(stringValue);
          if (decoded is List && decoded.isNotEmpty) {
            final first = decoded.first.toString().trim();
            if (first.isNotEmpty) return first;
          }
        } catch (_) {}
      }

      if (stringValue.contains(',')) {
        final first = stringValue
            .split(',')
            .map((part) => part.trim())
            .firstWhere((part) => part.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) return first;
      }

      if (stringValue.contains(';')) {
        final first = stringValue
            .split(';')
            .map((part) => part.trim())
            .firstWhere((part) => part.isNotEmpty, orElse: () => '');
        if (first.isNotEmpty) return first;
      }

      return stringValue;
    }
    return null;
  }

  String? _titleFromUrl(String? url) {
    final value = url?.trim() ?? '';
    if (value.isEmpty) return null;
    try {
      final parsed = Uri.parse(value);
      final host = parsed.host.trim();
      if (host.isEmpty) return value;
      return host.replaceFirst(RegExp(r'^www\.'), '');
    } catch (_) {
      return value;
    }
  }

  String? _normalizeOptional(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  DateTime? _parseDateTimeValue(dynamic rawValue) {
    if (rawValue == null) return null;
    final value = rawValue.toString().trim();
    if (value.isEmpty) return null;

    final unixValue = int.tryParse(value);
    if (unixValue != null) {
      if (value.length >= 13) {
        return DateTime.fromMillisecondsSinceEpoch(unixValue);
      }
      return DateTime.fromMillisecondsSinceEpoch(unixValue * 1000);
    }

    return DateTime.tryParse(value);
  }
}
