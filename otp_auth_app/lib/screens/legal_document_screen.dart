import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../services/legal_document_service.dart';

class LegalDocumentScreen extends StatefulWidget {
  const LegalDocumentScreen({
    super.key,
    required this.type,
    required this.fallbackTitle,
  });

  final String type;
  final String fallbackTitle;

  @override
  State<LegalDocumentScreen> createState() => _LegalDocumentScreenState();
}

class _LegalDocumentScreenState extends State<LegalDocumentScreen> {
  final LegalDocumentService _service = LegalDocumentService();
  late Future<LegalDocument> _documentFuture;

  @override
  void initState() {
    super.initState();
    _documentFuture = _service.fetchDocument(widget.type);
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => const Color(0xFF4F46E5);
  Color get _bgColor =>
      _isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF);
  Color get _cardColor => _isDark ? const Color(0xFF1E1E32) : Colors.white;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white60 : Colors.grey.shade600;

  Future<void> _openWebVersion(String url) async {
    final uri = Uri.tryParse(url.isNotEmpty
        ? url
        : AppConfig.legalDocumentWebUrl(widget.type));
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _plainTextFromHtml(String html) {
    var text = html
        .replaceAll(
          RegExp(r'<(script|style)[\s\S]*?</\1>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(
          RegExp(r'</p>|</div>|</li>|</h[1-6]>', caseSensitive: false),
          '\n',
        )
        .replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '- ')
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>');

    text = text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n\n');
    return text;
  }

  String _formatUpdatedAt(DateTime? value) {
    if (value == null) return 'Last updated unavailable';
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return 'Last updated ${local.year}-$month-$day';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bgColor,
      appBar: AppBar(
        title: Text(
          widget.fallbackTitle,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        backgroundColor: _isDark ? const Color(0xFF1A1A2E) : _accent,
        foregroundColor: Colors.white,
      ),
      body: FutureBuilder<LegalDocument>(
        future: _documentFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return Center(child: CircularProgressIndicator(color: _accent));
          }

          if (snapshot.hasError || !snapshot.hasData) {
            return _messageState(
              icon: Icons.error_outline_rounded,
              title: 'Could not load document',
              message:
                  'Open the web version if the app cannot reach the document source right now.',
              actionLabel: 'Open Web Version',
              onAction: () => _openWebVersion(''),
            );
          }

          final document = snapshot.data!;
          final plainText = _plainTextFromHtml(document.contentHtml);

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: _cardColor,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(_isDark ? 0.2 : 0.05),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _formatUpdatedAt(document.lastUpdated),
                      style: TextStyle(color: _textSecondary, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    SelectableText(
                      plainText.isEmpty
                          ? 'This document is currently unavailable.'
                          : plainText,
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 14,
                        height: 1.55,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => _openWebVersion(document.webUrl),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Open Web Version'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _messageState({
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _accent, size: 42),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                color: _textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: _textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
  }
}
