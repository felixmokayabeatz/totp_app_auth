import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'server_lockdown_service.dart';

class LegalDocument {
  const LegalDocument({
    required this.type,
    required this.title,
    required this.contentHtml,
    required this.lastUpdated,
    required this.webUrl,
    this.comingSoon = false,
  });

  final String type;
  final String title;
  final String contentHtml;
  final DateTime? lastUpdated;
  final String webUrl;

  /// The site answers with a placeholder, rather than a 404, for a document
  /// that has not been written yet. Saying so plainly beats reporting the
  /// missing date as if something had gone wrong.
  final bool comingSoon;

  factory LegalDocument.fromJson(Map<String, dynamic> json) {
    return LegalDocument(
      type: json['type']?.toString() ?? '',
      title: json['title']?.toString() ?? 'Legal Document',
      contentHtml: json['content_html']?.toString() ?? '',
      lastUpdated: DateTime.tryParse(json['last_updated']?.toString() ?? ''),
      webUrl: json['web_url']?.toString() ?? '',
      comingSoon: json['coming_soon'] == true,
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
        ) {
    ServerLockdownService().attachDioInterceptor(
      _dio,
      featureSummary: 'load legal documents from the internet',
    );
  }

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
