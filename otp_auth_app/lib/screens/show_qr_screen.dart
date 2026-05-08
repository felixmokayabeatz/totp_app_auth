import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../services/app_lock_service.dart';
import '../services/otp_service.dart';
import '../widgets/account_logo_badge.dart';

class ShowQRScreen extends StatefulWidget {
  final String secret;
  final String? advancedSecret;
  final String service;
  final String? issuer;
  final String? accountLabel;

  const ShowQRScreen({
    super.key,
    required this.secret,
    this.advancedSecret,
    required this.service,
    this.issuer,
    this.accountLabel,
  });

  @override
  State<ShowQRScreen> createState() => _ShowQRScreenState();
}

class _ShowQRScreenState extends State<ShowQRScreen> {
  bool _isSecretRevealed = false;
  bool _isAdvancedSecretRevealed = false;
  bool _isOtpHidden = false;
  String _currentOtp = '------';
  int _secondsRemaining = 30;
  Timer? _otpTimer;
  final AppLockService _appLockService = AppLockService();
  final OTPService _otpService = OTPService();

  String get _base32Secret => widget.secret
      .replaceAll(RegExp(r'\s+'), '')
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z2-7]'), '');

  String get _advancedSecret => widget.advancedSecret?.trim() ?? '';

  bool get _hasAdvancedSecret =>
      _advancedSecret.isNotEmpty && _advancedSecret != _base32Secret;

  @override
  void initState() {
    super.initState();
    _refreshOtp();
    _otpTimer = Timer.periodic(const Duration(seconds: 1), (_) => _refreshOtp());
  }

  @override
  void dispose() {
    _otpTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshOtp() async {
    final otp = await _otpService.generateOTP(_base32Secret);
    final seconds = _otpService.secondsRemaining();
    if (!mounted) return;
    setState(() {
      _currentOtp = otp;
      _secondsRemaining = seconds;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final mutedText = isDark ? Colors.white60 : colorScheme.onSurfaceVariant;
    final issuer = (widget.issuer?.trim().isNotEmpty ?? false)
        ? widget.issuer!.trim()
        : widget.service.trim();
    final accountLabel = widget.accountLabel?.trim() ?? '';
    final labelName = accountLabel.isNotEmpty ? accountLabel : widget.service;
    final label = issuer.isNotEmpty ? '$issuer:$labelName' : labelName;
    final accountDescriptor = accountLabel.isNotEmpty
        ? '${accountLabel.contains('@') ? 'Email' : 'Account'}: $accountLabel'
        : widget.issuer ?? 'Authenticator setup';
    final query = Uri(queryParameters: {
      'secret': _base32Secret,
      'issuer': issuer,
    }).query;
    final otpUrl = 'otpauth://totp/${Uri.encodeComponent(label)}?$query';

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
        backgroundColor: colorScheme.primary,
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
                    issuer: widget.issuer,
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
                          accountDescriptor,
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
                  _buildOtpBadge(context, isDark),
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
                    'Enter your BeatzLock PIN to show the QR code, then scan it with another authenticator if you want the same account in more than one app or device.',
                    style: TextStyle(fontSize: 13, color: mutedText),
                  ),
                  const SizedBox(height: 18),
                  Center(
                    child: GestureDetector(
                      onTap: _isSecretRevealed
                          ? null
                          : () {
                              _revealSensitiveInfo();
                            },
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          ImageFiltered(
                            imageFilter: ImageFilter.blur(
                              sigmaX: _isSecretRevealed ? 0 : 7,
                              sigmaY: _isSecretRevealed ? 0 : 7,
                            ),
                            child: Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: colorScheme.outlineVariant
                                      .withValues(alpha: 0.35),
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
                          if (!_isSecretRevealed)
                            Container(
                              width: isWide ? 252 : 232,
                              height: isWide ? 252 : 232,
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.44),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(
                                    Icons.lock_outline_rounded,
                                    color: Colors.white,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 10),
                                  const Text(
                                    'QR code hidden',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  FilledButton.tonalIcon(
                                    onPressed: () {
                                      _revealSensitiveInfo();
                                    },
                                    icon: const Icon(Icons.pin_rounded),
                                    label: const Text('Enter PIN'),
                                  ),
                                ],
                              ),
                            ),
                        ],
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
                          ? Colors.white.withValues(alpha: 0.05)
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
                            'BeatzLock lets you export this setup QR so you can keep the same login in another trusted authenticator too.',
                            style: TextStyle(fontSize: 12, color: mutedText),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.05)
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
                            'If scanning fails, copy the secret key manually after PIN unlock.',
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
                              'Base32 secret',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Reveal this if you need to type the setup key manually.',
                              style: TextStyle(fontSize: 13, color: mutedText),
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
                        onPressed: _isSecretRevealed
                            ? _hideSensitiveInfo
                            : () {
                                _revealSensitiveInfo();
                              },
                        tooltip:
                            _isSecretRevealed ? 'Hide secret' : 'Reveal secret',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _isSecretRevealed
                        ? null
                        : () {
                            _revealSensitiveInfo();
                          },
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.05)
                            : const Color(0xFFF4F5F7),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.08)
                              : colorScheme.outlineVariant
                                  .withValues(alpha: 0.4),
                        ),
                      ),
                      child: _isSecretRevealed
                          ? SelectableText(
                              _formatSecret(_base32Secret),
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
                                  'Enter PIN to reveal',
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
                      label: const Text('Copy Base32 secret'),
                    ),
                  ),
                  if (_hasAdvancedSecret) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _toggleAdvancedSecret,
                        icon: Icon(
                          _isAdvancedSecretRevealed
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                          size: 18,
                        ),
                        label: Text(
                          _isAdvancedSecretRevealed
                              ? 'Hide advanced Base64'
                              : 'Advanced Base64',
                        ),
                      ),
                    ),
                    if (_isSecretRevealed && _isAdvancedSecretRevealed)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(top: 4),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.black.withValues(alpha: 0.18)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: colorScheme.outlineVariant
                                .withValues(alpha: 0.35),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Encrypted storage value',
                                    style: TextStyle(
                                      color: mutedText,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                IconButton(
                                  onPressed: _copyAdvancedSecret,
                                  icon:
                                      const Icon(Icons.copy_rounded, size: 18),
                                  tooltip: 'Copy advanced Base64',
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              _advancedSecret,
                              style: TextStyle(
                                color: colorScheme.onSurface,
                                fontSize: 12,
                                fontFamily: 'monospace',
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF2B2435)
                          : const Color(0xFFFFF6E9),
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
              ? Colors.white.withValues(alpha: 0.06)
              : colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  Widget _buildOtpBadge(BuildContext context, bool isDark) {
    final colorScheme = Theme.of(context).colorScheme;
    final isExpiring = _secondsRemaining <= 5;
    final otpText = _isOtpHidden ? '*** ***' : _formatOtp(_currentOtp);

    return Container(
      constraints: const BoxConstraints(minWidth: 118, maxWidth: 148),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isExpiring
              ? Colors.red.withValues(alpha: 0.28)
              : colorScheme.primary.withValues(alpha: 0.14),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    otpText,
                    style: TextStyle(
                      color: isExpiring ? Colors.red : colorScheme.onSurface,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: () => setState(() => _isOtpHidden = !_isOtpHidden),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(
                    _isOtpHidden
                        ? Icons.visibility_rounded
                        : Icons.visibility_off_rounded,
                    size: 16,
                    color: isDark
                        ? Colors.white60
                        : colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'TOTP',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '${_secondsRemaining}s',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: isExpiring
                      ? Colors.red
                      : (isDark ? Colors.white60 : colorScheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatOtp(String otp) {
    if (otp.length == 6) return '${otp.substring(0, 3)} ${otp.substring(3)}';
    return otp;
  }

  String _maskedSecret() {
    if (_base32Secret.isEmpty) return '**** ****';
    final groupCount = (_base32Secret.length / 4).ceil().clamp(2, 4);
    return List.generate(groupCount, (_) => '****').join(' ');
  }

  String _formatSecret(String value) {
    final chunks = <String>[];
    for (var i = 0; i < value.length; i += 4) {
      final end = i + 4 > value.length ? value.length : i + 4;
      chunks.add(value.substring(i, end));
    }
    return chunks.join(' ');
  }

  Future<bool> _revealSensitiveInfo() async {
    final unlocked = await _appLockService.authenticateWithPinOnly(context);
    if (!mounted) return false;

    if (unlocked) {
      setState(() => _isSecretRevealed = true);
      return true;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('PIN required to show QR code and secret key.'),
        duration: Duration(seconds: 2),
      ),
    );
    return false;
  }

  void _hideSensitiveInfo() {
    setState(() {
      _isSecretRevealed = false;
      _isAdvancedSecretRevealed = false;
    });
  }

  void _copySecret() {
    Clipboard.setData(ClipboardData(text: _base32Secret));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Base32 secret copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _toggleAdvancedSecret() async {
    if (!_isSecretRevealed) {
      final unlocked = await _revealSensitiveInfo();
      if (!unlocked || !mounted) return;
    }

    setState(() => _isAdvancedSecretRevealed = !_isAdvancedSecretRevealed);
  }

  void _copyAdvancedSecret() {
    Clipboard.setData(ClipboardData(text: _advancedSecret));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Advanced Base64 copied to clipboard'),
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
            Icon(Icons.help_outline,
                color: Theme.of(context).colorScheme.primary, size: 24),
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
