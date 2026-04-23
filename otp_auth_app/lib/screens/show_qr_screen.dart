import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../widgets/account_logo_badge.dart';

class ShowQRScreen extends StatefulWidget {
  final String secret;
  final String service;
  final String? issuer;

  const ShowQRScreen({
    Key? key,
    required this.secret,
    required this.service,
    this.issuer,
  }) : super(key: key);

  @override
  _ShowQRScreenState createState() => _ShowQRScreenState();
}

class _ShowQRScreenState extends State<ShowQRScreen> {
  bool _isSecretRevealed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final mutedText =
        isDark ? Colors.white60 : colorScheme.onSurfaceVariant;
    final otpUrl =
        'otpauth://totp/${widget.issuer != null ? "${widget.issuer}:" : ""}${widget.service}?secret=${widget.secret}&issuer=${widget.issuer ?? widget.service}';

    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF),
      appBar: AppBar(
        title: const Text(
          'QR Code',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor:
            isDark ? const Color(0xFF1A1A2E) : const Color(0xFF4F46E5),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline, color: Colors.white),
            onPressed: () => _showHelpDialog(context, isDark),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 720;
            final outerPadding = constraints.maxWidth >= 1200
                ? 32.0
                : constraints.maxWidth >= 700
                    ? 24.0
                    : 16.0;

            final serviceCard = _buildPanel(
              context,
              child: Row(
                children: [
                  AccountLogoBadge(
                    service: widget.service,
                    size: 48,
                    iconSize: 24,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.service,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.issuer ?? 'Authenticator setup',
                          style: TextStyle(
                            fontSize: 13,
                            color: mutedText,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.06)
                          : const Color(0xFFF1F3F7),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      'TOTP',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: isDark
                            ? colorScheme.primary
                            : const Color(0xFF475569),
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            );

            final qrPanel = _buildPanel(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Scan to add this account',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Use any authenticator app that supports time-based one-time passwords.',
                    style: TextStyle(fontSize: 13, color: mutedText),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: colorScheme.outlineVariant.withOpacity(0.35),
                        ),
                      ),
                      child: QrImageView(
                        data: otpUrl,
                        version: QrVersions.auto,
                        size: isWide ? 220 : 200,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          color: Colors.black,
                          eyeShape: QrEyeShape.square,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          color: Colors.black,
                          dataModuleShape: QrDataModuleShape.square,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.05)
                          : const Color(0xFFF4F5F7),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.qr_code_scanner_rounded,
                            size: 18, color: colorScheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'If scanning fails, reveal and copy the secret key manually.',
                            style: TextStyle(fontSize: 12, color: mutedText),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );

            final secretPanel = _buildPanel(
              context,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Secret key',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Reveal this only if you need to type it in manually.',
                              style:
                                  TextStyle(fontSize: 13, color: mutedText),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _isSecretRevealed
                              ? Icons.visibility_off_rounded
                              : Icons.visibility_rounded,
                          color: mutedText,
                        ),
                        onPressed: () {
                          setState(() {
                            _isSecretRevealed = !_isSecretRevealed;
                          });
                        },
                        tooltip:
                            _isSecretRevealed ? 'Hide secret' : 'Reveal secret',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: () {
                      if (!_isSecretRevealed) {
                        setState(() {
                          _isSecretRevealed = true;
                        });
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withOpacity(0.05)
                          : const Color(0xFFF4F5F7),
                      borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withOpacity(0.08)
                              : colorScheme.outlineVariant.withOpacity(0.4),
                        ),
                      ),
                      child: _isSecretRevealed
                          ? SelectableText(
                              widget.secret,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 16,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.1,
                              ),
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(Icons.lock_outline_rounded,
                                    color: mutedText, size: 22),
                                const SizedBox(height: 10),
                                Text(
                                  'Tap to reveal',
                                  style: TextStyle(
                                    color: colorScheme.onSurface,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _maskedSecret(),
                                  style: TextStyle(
                                    color: mutedText,
                                    fontSize: 14,
                                    letterSpacing: 2,
                                  ),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _isSecretRevealed ? _copySecret : null,
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('Copy secret key'),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color:
                          isDark ? const Color(0xFF2B2435) : const Color(0xFFFFF6E9),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isDark
                            ? const Color(0xFF4B3D20)
                            : const Color(0xFFF3DFC1),
                      ),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Color(0xFFF59E0B), size: 18),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Keep this secret private. Anyone with it can generate your verification codes.',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: colorScheme.onSurface,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );

            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [
                          const Color(0xFF141629),
                          const Color(0xFF0F0F1A),
                        ]
                      : [
                          const Color(0xFFF7F8FA),
                          const Color(0xFFEDEFF3),
                        ],
                ),
              ),
              child: SingleChildScrollView(
                padding:
                    EdgeInsets.fromLTRB(outerPadding, 20, outerPadding, 28),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1100),
                    child: Column(
                      children: [
                        serviceCard,
                        const SizedBox(height: 18),
                        if (isWide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: qrPanel),
                              const SizedBox(width: 18),
                              Expanded(child: secretPanel),
                            ],
                          )
                        else
                          Column(
                            children: [
                              qrPanel,
                              const SizedBox(height: 16),
                              secretPanel,
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildPanel(BuildContext context, {required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E32) : Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isDark
              ? Colors.white.withOpacity(0.06)
              : colorScheme.outlineVariant.withOpacity(0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.18 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  String _maskedSecret() {
    if (widget.secret.isEmpty) return '**** ****';
    final groupCount = (widget.secret.length / 4).ceil().clamp(2, 4);
    return List.generate(groupCount, (_) => '****').join(' ');
  }

  void _copySecret() {
    Clipboard.setData(ClipboardData(text: widget.secret));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Secret copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showHelpDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? const Color(0xFF1E1E32) : Colors.white,
        title: Row(
          children: [
            const Icon(Icons.help_outline,
                color: Color(0xFF4F46E5), size: 24),
            const SizedBox(width: 10),
            const Text('About Secret Key'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'What is a Secret Key?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              'The secret key is the foundation of your 2FA codes. It generates your time-based one-time passwords.',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Security Notes:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              '- Never share your secret key\n'
              '- Store it in a secure place\n'
              '- Keep it hidden from others',
              style: TextStyle(
                fontSize: 13,
                color: isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}
