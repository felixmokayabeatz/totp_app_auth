import 'package:dio/dio.dart';

import '../config/app_config.dart';

class LegalDocument {
  const LegalDocument({
    required this.type,
    required this.title,
    required this.contentHtml,
    required this.lastUpdated,
    required this.webUrl,
  });

  final String type;
  final String title;
  final String contentHtml;
  final DateTime? lastUpdated;
  final String webUrl;

  factory LegalDocument.fromJson(Map<String, dynamic> json) {
    return LegalDocument(
      type: json['type']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Legal Document',
      contentHtml: json['content_html']?.toString() ?? '',
      lastUpdated: DateTime.tryParse(json['last_updated']?.toString() ?? ''),
      webUrl: json['web_url']?.toString() ?? '',
    );
  }
}

class LegalDocumentService {
  LegalDocumentService()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 20),
          receiveTimeout: const Duration(seconds: 20),
        ),
      );

  final Dio _dio;

  Future<LegalDocument> fetchDocument(String type) async {
    final response = await _dio.get(AppConfig.legalDocumentApiUrl(type));
    if (response.statusCode == 200 && response.data is Map) {
      return LegalDocument.fromJson(
        Map<String, dynamic>.from(response.data as Map),
      );
    }
    throw StateError('Could not load legal document.');
  }
}
