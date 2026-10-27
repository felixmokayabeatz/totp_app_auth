import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_config.dart';
import '../services/legal_document_service.dart';
import '../services/server_lockdown_service.dart';

String _formatReadableDate(DateTime value) {
  const monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final local = value.toLocal();
  return '${monthNames[local.month - 1]} ${local.day}, ${local.year}';
}



String _formatReadableTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatUpdatedAt(DateTime? value) {
  if (value == null) return '';


  return 'Last updated ${_formatReadableDate(value)} '
      'at ${_formatReadableTime(value)}';
}

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
  Color get _accent => Theme.of(context).colorScheme.primary;
  Color get _bgColor => Theme.of(context).scaffoldBackgroundColor;
  Color get _cardColor => Theme.of(context).colorScheme.surface;
  Color get _textPrimary => _isDark ? Colors.white : const Color(0xFF1A1A2E);
  Color get _textSecondary => _isDark ? Colors.white60 : Colors.grey.shade600;

  Future<void> _openWebVersion(String url) async {
    if (await ServerLockdownService().isEnabled()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            ServerLockdownService().blockedMessageFor(
              'open legal pages in a browser',
            ),
          ),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final uri = Uri.tryParse(
      url.isNotEmpty ? url : AppConfig.legalDocumentWebUrl(widget.type),
    );
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
        backgroundColor: _accent,
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
                      color: Colors.black.withValues(
                        alpha: _isDark ? 0.2 : 0.05,
                      ),
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
                    if (document.comingSoon)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: _accent.withValues(alpha: 0.28),
                          ),
                        ),
                        child: Text(
                          'Not yet published',
                          style: TextStyle(
                            color: _accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.4,
                          ),
                        ),
                      )
                    else if (_formatUpdatedAt(document.lastUpdated).isNotEmpty)
                      Text(
                        _formatUpdatedAt(document.lastUpdated),
                        style: TextStyle(color: _textSecondary, fontSize: 12),
                      ),
                    const SizedBox(height: 16),
                    _LegalHtmlContent(
                      html: document.contentHtml,
                      baseUrl: document.webUrl.isNotEmpty
                          ? document.webUrl
                          : AppConfig.legalDocumentWebUrl(widget.type),
                      onOpenLink: _openWebVersion,
                      accent: _accent,
                      textPrimary: _textPrimary,
                      textSecondary: _textSecondary,
                      surfaceColor:
                          _isDark ? Colors.white10 : Colors.grey.shade50,
                      borderColor:
                          _isDark ? Colors.white12 : Colors.grey.shade200,
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

class _LegalHtmlContent extends StatefulWidget {
  const _LegalHtmlContent({
    required this.html,
    required this.baseUrl,
    required this.onOpenLink,
    required this.accent,
    required this.textPrimary,
    required this.textSecondary,
    required this.surfaceColor,
    required this.borderColor,
  });

  final String html;
  final String baseUrl;
  final Future<void> Function(String url) onOpenLink;
  final Color accent;
  final Color textPrimary;
  final Color textSecondary;
  final Color surfaceColor;
  final Color borderColor;

  @override
  State<_LegalHtmlContent> createState() => _LegalHtmlContentState();
}

class _LegalHtmlContentState extends State<_LegalHtmlContent> {
  final List<TapGestureRecognizer> _linkRecognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final recognizer in _linkRecognizers) {
      recognizer.dispose();
    }
    _linkRecognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();

    final blocks = _HtmlParser.parseBlocks(widget.html);
    if (blocks.isEmpty) {
      return Text(
        'This document is currently unavailable.',
        style: TextStyle(color: widget.textPrimary, fontSize: 14, height: 1.55),
      );
    }

    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (final block in blocks) _buildBlock(block)],
      ),
    );
  }

  Widget _buildBlock(_HtmlBlock block) {
    if (block.tag == 'hr') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Divider(height: 1, color: widget.borderColor),
      );
    }

    if (block.tag == 'pre') {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: widget.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: widget.borderColor),
        ),
        child: Text(
          _HtmlParser.plainText(block.html),
          style: TextStyle(
            color: widget.textPrimary,
            fontSize: 13,
            height: 1.5,
            fontFamily: 'monospace',
          ),
        ),
      );
    }

    if (block.tag == 'blockquote') {
      return Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: widget.surfaceColor,
          borderRadius: BorderRadius.circular(10),
          border: Border(left: BorderSide(color: widget.accent, width: 3)),
        ),
        child: RichText(
          text: TextSpan(
            style: TextStyle(
              color: widget.textSecondary,
              fontSize: 14,
              height: 1.55,
              fontStyle: FontStyle.italic,
            ),
            children: _buildInlineSpans(
              block.html,
              TextStyle(
                color: widget.textSecondary,
                fontSize: 14,
                height: 1.55,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ),
      );
    }

    if (block.isListItem) {
      final style = TextStyle(
        color: widget.textPrimary,
        fontSize: 14,
        height: 1.55,
      );
      final marker =
          block.orderedIndex == null ? '-' : '${block.orderedIndex}.';

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 30,
              child: Text(
                marker,
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: widget.accent,
                  fontSize: 14,
                  height: 1.55,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: style,
                  children: _buildInlineSpans(block.html, style),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final style = _styleForTag(block.tag);
    return Padding(
      padding: EdgeInsets.only(bottom: _bottomPaddingForTag(block.tag)),
      child: RichText(
        text: TextSpan(
          style: style,
          children: _buildInlineSpans(block.html, style),
        ),
      ),
    );
  }

  List<InlineSpan> _buildInlineSpans(String html, TextStyle baseStyle) {
    final fragments = _HtmlParser.inlineFragments(
      html,
      baseStyle,
      widget.accent,
      widget.textPrimary,
    );
    return fragments.map<InlineSpan>(_buildInlineSpan).toList();
  }

  InlineSpan _buildInlineSpan(_InlineTextFragment fragment) {
    final href = fragment.href?.trim();
    if (href == null || href.isEmpty) {
      return TextSpan(text: fragment.text, style: fragment.style);
    }

    final recognizer = TapGestureRecognizer()
      ..onTap = () => _openResolvedLink(href);
    _linkRecognizers.add(recognizer);

    return TextSpan(
      text: fragment.text,
      style: fragment.style,
      recognizer: recognizer,
      mouseCursor: SystemMouseCursors.click,
    );
  }

  Future<void> _openResolvedLink(String href) async {
    final uri = _resolveLinkUri(href);
    if (uri == null) return;
    await widget.onOpenLink(uri.toString());
  }

  Uri? _resolveLinkUri(String href) {
    final trimmed = href.trim();
    if (trimmed.isEmpty) return null;

    final direct = Uri.tryParse(trimmed);
    if (direct != null && direct.hasScheme) {
      return direct;
    }

    if (trimmed.startsWith('//')) {
      return Uri.tryParse('https:$trimmed');
    }

    final baseUri = Uri.tryParse(widget.baseUrl);
    if (baseUri != null) {
      return baseUri.resolve(trimmed);
    }

    return direct;
  }

  TextStyle _styleForTag(String tag) {
    if (tag == 'h1') {
      return TextStyle(
        color: widget.textPrimary,
        fontSize: 21,
        height: 1.25,
        fontWeight: FontWeight.w800,
      );
    }
    if (tag == 'h2') {
      return TextStyle(
        color: widget.textPrimary,
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w800,
      );
    }
    if (tag == 'h3') {
      return TextStyle(
        color: widget.textPrimary,
        fontSize: 16,
        height: 1.35,
        fontWeight: FontWeight.w700,
      );
    }
    if (tag == 'h4' || tag == 'h5' || tag == 'h6') {
      return TextStyle(
        color: widget.textSecondary,
        fontSize: 14,
        height: 1.4,
        fontWeight: FontWeight.w800,
      );
    }
    return TextStyle(color: widget.textPrimary, fontSize: 14, height: 1.55);
  }

  double _bottomPaddingForTag(String tag) {
    if (tag.startsWith('h')) return 12;
    return 14;
  }
}

class _HtmlBlock {
  const _HtmlBlock({required this.tag, required this.html, this.orderedIndex});

  final String tag;
  final String html;
  final int? orderedIndex;

  bool get isListItem => tag == 'li';
}

class _InlineTextFragment {
  const _InlineTextFragment({
    required this.text,
    required this.style,
    this.href,
  });

  final String text;
  final TextStyle style;
  final String? href;
}

class _InlineStyleFrame {
  const _InlineStyleFrame(this.tag, this.style, {this.href});

  final String tag;
  final TextStyle style;
  final String? href;
}




@visibleForTesting
class LegalHtmlTestHooks {
  const LegalHtmlTestHooks._();

  static String plainText(String html) => _HtmlParser.plainText(html);



  static String updatedAt(DateTime? value) => _formatUpdatedAt(value);

  static String inlineText(String html, TextStyle baseStyle) =>
      _HtmlParser.inlineFragments(
        html,
        baseStyle,
        const Color(0xFF000000),
        const Color(0xFF000000),
      ).map((fragment) => fragment.text).join();
}

class _HtmlParser {
  static final RegExp _scriptOrStylePattern = RegExp(
    r'<(script|style)[\s\S]*?</\1>',
    caseSensitive: false,
  );
  static final RegExp _commentPattern = RegExp(
    r'<!--[\s\S]*?-->',
    caseSensitive: false,
  );
  static final RegExp _blockPattern = RegExp(
    r'<(h[1-6]|p|div|blockquote|pre|ul|ol)[^>]*>([\s\S]*?)</\1>|<hr\s*/?>',
    caseSensitive: false,
  );
  static final RegExp _liPattern = RegExp(
    r'<li[^>]*>([\s\S]*?)</li>',
    caseSensitive: false,
  );
  static final RegExp _tagPattern = RegExp(r'<[^>]+>');

  static List<_HtmlBlock> parseBlocks(String rawHtml) {
    final cleaned = _clean(rawHtml);
    final blocks = <_HtmlBlock>[];
    var cursor = 0;

    void addLooseText(String chunk) {
      if (_isBlankHtml(chunk)) return;
      blocks.add(_HtmlBlock(tag: 'p', html: chunk));
    }

    for (final match in _blockPattern.allMatches(cleaned)) {
      addLooseText(cleaned.substring(cursor, match.start));

      final tag = match.group(1)?.toLowerCase();
      if (tag == null) {
        blocks.add(const _HtmlBlock(tag: 'hr', html: ''));
      } else {
        final content = match.group(2) ?? '';
        if (tag == 'ul' || tag == 'ol') {
          var index = 1;
          for (final itemMatch in _liPattern.allMatches(content)) {
            final itemHtml = itemMatch.group(1) ?? '';
            if (_isBlankHtml(itemHtml)) continue;
            blocks.add(
              _HtmlBlock(
                tag: 'li',
                html: itemHtml,
                orderedIndex: tag == 'ol' ? index : null,
              ),
            );
            index++;
          }
        } else if (!_isBlankHtml(content)) {
          blocks.add(_HtmlBlock(tag: tag, html: content));
        }
      }

      cursor = match.end;
    }

    addLooseText(cleaned.substring(cursor));
    return blocks;
  }

  static List<_InlineTextFragment> inlineFragments(
    String html,
    TextStyle baseStyle,
    Color accent,
    Color textPrimary,
  ) {
    final normalized = html
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>|</div>', caseSensitive: false), '\n');
    final fragments = <_InlineTextFragment>[];
    final stack = <_InlineStyleFrame>[_InlineStyleFrame('root', baseStyle)];
    var cursor = 0;

    void addText(String text) {
      final decoded = _decode(text)
          .replaceAll(RegExp(r'[ \t\f\v\u00A0]+'), ' ')
          .replaceAll(RegExp(r'\n{3,}'), '\n\n');
      if (decoded.isEmpty) return;
      fragments.add(
        _InlineTextFragment(
          text: decoded,
          style: stack.last.style,
          href: stack.last.href,
        ),
      );
    }

    for (final match in _tagPattern.allMatches(normalized)) {
      addText(normalized.substring(cursor, match.start));
      final tag = match.group(0) ?? '';
      _applyTag(tag, stack, accent, textPrimary);
      cursor = match.end;
    }

    addText(normalized.substring(cursor));
    return fragments;
  }

  static String plainText(String html) {
    return _decode(
      _clean(html)
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(
            RegExp(r'</p>|</div>|</li>|</tr>', caseSensitive: false),
            '\n',
          )
          .replaceAll(RegExp(r'</td>|</th>', caseSensitive: false), '  ')
          .replaceAll(_tagPattern, ' '),
    )
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[\s\u00A0]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
  }

  static String _clean(String html) {
    return html
        .replaceAll(_scriptOrStylePattern, ' ')
        .replaceAll(_commentPattern, ' ')
        .replaceAll(RegExp(r'</tr>', caseSensitive: false), '</tr>\n')
        .replaceAll(RegExp(r'</td>|</th>', caseSensitive: false), ' ');
  }

  static bool _isBlankHtml(String value) {
    final text = _decode(
      value
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '')
          .replaceAll(_tagPattern, ' ')
          .replaceAll('&nbsp;', ' '),
    ).trim();
    return text.isEmpty;
  }

  static void _applyTag(
    String rawTag,
    List<_InlineStyleFrame> stack,
    Color accent,
    Color textPrimary,
  ) {
    final lower = rawTag.toLowerCase();
    final closingMatch = RegExp(r'^</\s*([a-z0-9]+)').firstMatch(lower);
    if (closingMatch != null) {
      final closingTag = _normalizeTag(closingMatch.group(1) ?? '');
      final index = stack.lastIndexWhere((frame) => frame.tag == closingTag);
      if (index > 0) {
        stack.removeRange(index, stack.length);
      }
      return;
    }

    if (RegExp(r'^<\s*br\b').hasMatch(lower)) {
      stack.add(_InlineStyleFrame('__break__', stack.last.style));
      stack.removeLast();
      return;
    }

    final openMatch = RegExp(r'^<\s*([a-z0-9]+)').firstMatch(lower);
    if (openMatch == null || lower.endsWith('/>')) return;

    final tag = _normalizeTag(openMatch.group(1) ?? '');
    var nextStyle = stack.last.style;

    String? nextHref = stack.last.href;

    if (tag == 'strong') {
      nextStyle = nextStyle.merge(const TextStyle(fontWeight: FontWeight.w800));
    } else if (tag == 'em') {
      nextStyle = nextStyle.merge(const TextStyle(fontStyle: FontStyle.italic));
    } else if (tag == 'u') {
      nextStyle = nextStyle.merge(
        const TextStyle(decoration: TextDecoration.underline),
      );
    } else if (tag == 'a') {
      nextHref = _extractHref(rawTag) ?? nextHref;
      nextStyle = nextStyle.merge(
        TextStyle(
          color: accent,
          decoration: TextDecoration.underline,
          decorationColor: accent,
        ),
      );
    } else if (tag == 'code') {
      nextStyle = nextStyle.merge(
        TextStyle(
          color: textPrimary,
          fontFamily: 'monospace',
          backgroundColor: accent.withValues(alpha: 0.08),
        ),
      );
    } else if (tag == 's') {
      nextStyle = nextStyle.merge(
        TextStyle(
          color: nextStyle.color?.withValues(alpha: 0.65),
          decoration: TextDecoration.lineThrough,
        ),
      );
    }

    nextStyle = _mergeInlineCss(rawTag, nextStyle, textPrimary);
    if (tag != 'span' &&
        tag != 'strong' &&
        tag != 'em' &&
        tag != 'u' &&
        tag != 'a' &&
        tag != 'code' &&
        tag != 's') {
      return;
    }

    stack.add(_InlineStyleFrame(tag, nextStyle, href: nextHref));
  }

  static String _normalizeTag(String tag) {
    if (tag == 'b') return 'strong';
    if (tag == 'i') return 'em';
    if (tag == 'strike' || tag == 'del') return 's';
    return tag;
  }

  static TextStyle _mergeInlineCss(
    String rawTag,
    TextStyle style,
    Color textPrimary,
  ) {
    final styleMatch = RegExp(
      r'''style\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(rawTag);
    if (styleMatch == null) return style;

    final css = styleMatch.group(1)?.toLowerCase() ?? '';
    var merged = style;

    if (css.contains('font-weight: bold') ||
        css.contains('font-weight:bold') ||
        RegExp(r'font-weight\s*:\s*[6-9]00').hasMatch(css)) {
      merged = merged.merge(const TextStyle(fontWeight: FontWeight.w800));
    }
    if (css.contains('font-style: italic') ||
        css.contains('font-style:italic')) {
      merged = merged.merge(const TextStyle(fontStyle: FontStyle.italic));
    }
    if (css.contains('underline')) {
      merged = merged.merge(
        const TextStyle(decoration: TextDecoration.underline),
      );
    }

    final color = _parseCssColor(css, textPrimary);
    if (color != null) {
      merged = merged.merge(TextStyle(color: color));
    }

    return merged;
  }

  static String? _extractHref(String rawTag) {
    final hrefMatch = RegExp(
      r'''href\s*=\s*["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(rawTag);
    final href = _decode(hrefMatch?.group(1) ?? '').trim();
    return href.isEmpty ? null : href;
  }

  static Color? _parseCssColor(String css, Color textPrimary) {
    final match = RegExp(
      r'(?:^|;)\s*color\s*:\s*([^;]+)',
      caseSensitive: false,
    ).firstMatch(css);
    if (match == null) return null;

    final value = (match.group(1) ?? '').trim();
    if (value.contains('rgb(0, 0, 0)') ||
        value.contains('rgb(0,0,0)') ||
        value == '#000' ||
        value == '#000000' ||
        value == 'black') {
      return textPrimary;
    }

    final hexMatch = RegExp(r'#([0-9a-f]{3}|[0-9a-f]{6})').firstMatch(value);
    if (hexMatch != null) {
      var hex = hexMatch.group(1) ?? '';
      if (hex.length == 3) {
        hex = hex.split('').map((char) => '$char$char').join();
      }
      return Color(int.parse('FF$hex', radix: 16));
    }

    final rgbMatch = RegExp(
      r'rgb\(\s*(\d+),\s*(\d+),\s*(\d+)\s*\)',
    ).firstMatch(value);
    if (rgbMatch != null) {
      final red = int.parse(rgbMatch.group(1)!);
      final green = int.parse(rgbMatch.group(2)!);
      final blue = int.parse(rgbMatch.group(3)!);
      return Color.fromARGB(255, red, green, blue);
    }

    return null;
  }





  static const List<String> _latin1EntityNames = [
    'nbsp',
    'iexcl',
    'cent',
    'pound',
    'curren',
    'yen',
    'brvbar',
    'sect',
    'uml',
    'copy',
    'ordf',
    'laquo',
    'not',
    'shy',
    'reg',
    'macr',
    'deg',
    'plusmn',
    'sup2',
    'sup3',
    'acute',
    'micro',
    'para',
    'middot',
    'cedil',
    'sup1',
    'ordm',
    'raquo',
    'frac14',
    'frac12',
    'frac34',
    'iquest',
    'Agrave',
    'Aacute',
    'Acirc',
    'Atilde',
    'Auml',
    'Aring',
    'AElig',
    'Ccedil',
    'Egrave',
    'Eacute',
    'Ecirc',
    'Euml',
    'Igrave',
    'Iacute',
    'Icirc',
    'Iuml',
    'ETH',
    'Ntilde',
    'Ograve',
    'Oacute',
    'Ocirc',
    'Otilde',
    'Ouml',
    'times',
    'Oslash',
    'Ugrave',
    'Uacute',
    'Ucirc',
    'Uuml',
    'Yacute',
    'THORN',
    'szlig',
    'agrave',
    'aacute',
    'acirc',
    'atilde',
    'auml',
    'aring',
    'aelig',
    'ccedil',
    'egrave',
    'eacute',
    'ecirc',
    'euml',
    'igrave',
    'iacute',
    'icirc',
    'iuml',
    'eth',
    'ntilde',
    'ograve',
    'oacute',
    'ocirc',
    'otilde',
    'ouml',
    'divide',
    'oslash',
    'ugrave',
    'uacute',
    'ucirc',
    'uuml',
    'yacute',
    'thorn',
    'yuml',
  ];



  static const Map<String, int> _extraEntities = {
    'amp': 0x26,
    'lt': 0x3C,
    'gt': 0x3E,
    'quot': 0x22,
    'apos': 0x27,
    'ensp': 0x2002,
    'emsp': 0x2003,
    'thinsp': 0x2009,
    'zwnj': 0x200C,
    'zwj': 0x200D,
    'ndash': 0x2013,
    'mdash': 0x2014,
    'minus': 0x2212,
    'lsquo': 0x2018,
    'rsquo': 0x2019,
    'sbquo': 0x201A,
    'ldquo': 0x201C,
    'rdquo': 0x201D,
    'bdquo': 0x201E,
    'lsaquo': 0x2039,
    'rsaquo': 0x203A,
    'dagger': 0x2020,
    'Dagger': 0x2021,
    'bull': 0x2022,
    'hellip': 0x2026,
    'permil': 0x2030,
    'prime': 0x2032,
    'Prime': 0x2033,
    'trade': 0x2122,
    'euro': 0x20AC,
    'larr': 0x2190,
    'uarr': 0x2191,
    'rarr': 0x2192,
    'darr': 0x2193,
    'harr': 0x2194,
    'le': 0x2264,
    'ge': 0x2265,
    'ne': 0x2260,
    'asymp': 0x2248,
    'infin': 0x221E,
    'radic': 0x221A,
    'sum': 0x2211,
    'prod': 0x220F,
    'part': 0x2202,
    'int': 0x222B,
  };

  static final Map<String, int> _namedEntities = <String, int>{
    for (var i = 0; i < _latin1EntityNames.length; i++)
      _latin1EntityNames[i]: 160 + i,
    ..._extraEntities,
  };

  static final RegExp _entityPattern = RegExp(
    r'&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z][a-zA-Z0-9]{1,31});',
  );







  static String _decode(String value) {
    if (!value.contains('&')) return value;

    return value.replaceAllMapped(_entityPattern, (match) {
      final token = match.group(1)!;
      int? code;
      if (token.startsWith('#x') || token.startsWith('#X')) {
        code = int.tryParse(token.substring(2), radix: 16);
      } else if (token.startsWith('#')) {
        code = int.tryParse(token.substring(1));
      } else {
        code = _namedEntities[token];
      }




      if (code == null ||
          code < 0 ||
          code > 0x10FFFF ||
          (code >= 0xD800 && code <= 0xDFFF)) {
        return match.group(0)!;
      }
      return String.fromCharCode(code);
    });
  }
}
