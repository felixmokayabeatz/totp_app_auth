// lib/screens/show_qr_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final otpUrl = 'otpauth://totp/${widget.issuer != null ? "${widget.issuer}:" : ""}${widget.service}?secret=${widget.secret}&issuer=${widget.issuer ?? widget.service}';
    
    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF0F0F1A) : const Color(0xFFF0F2FF),
      appBar: AppBar(
        title: Text(
          'QR Code',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: isDark ? const Color(0xFF1A1A2E) : const Color(0xFF4F46E5),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.help_outline, color: Colors.white),
            onPressed: () => _showHelpDialog(context, isDark),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF1a1a2e), const Color(0xFF16213e)]
                : [const Color(0xFF667eea), const Color(0xFF764ba2)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Service Card - matching home screen card style
                Container(
                  margin: const EdgeInsets.all(20),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF4F46E5).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _getServiceIcon(widget.service),
                          color: const Color(0xFF4F46E5),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.service,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                              ),
                            ),
                            if (widget.issuer != null)
                              Text(
                                widget.issuer!,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Colors.white38 : Colors.grey[500],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                // QR Code Card - matching home screen card style
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    children: [
                      QrImageView(
                        data: otpUrl,
                        version: QrVersions.auto,
                        size: 220.0,
                        eyeStyle: QrEyeStyle(
                          color: const Color(0xFF4F46E5),
                          eyeShape: QrEyeShape.circle,
                        ),
                        dataModuleStyle: QrDataModuleStyle(
                          color: const Color(0xFF4F46E5),
                          dataModuleShape: QrDataModuleShape.circle,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Scan this QR code',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'with your authenticator app',
                        style: TextStyle(
                          color: isDark ? Colors.white38 : Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 24),
                
                // Secret Key Section - matching home screen card style
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 20),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark ? const Color(0xFF1E1E32) : Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.2 : 0.06),
                        blurRadius: 12,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Secret Key',
                            style: TextStyle(
                              color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          // Hide/Reveal toggle button
                          IconButton(
                            icon: Icon(
                              _isSecretRevealed ? Icons.visibility_off : Icons.visibility,
                              color: isDark ? Colors.white70 : Colors.grey[600],
                              size: 20,
                            ),
                            onPressed: () {
                              setState(() {
                                _isSecretRevealed = !_isSecretRevealed;
                              });
                            },
                            tooltip: _isSecretRevealed ? 'Hide secret' : 'Reveal secret',
                          ),
                        ],
                      ),
                      
                      const SizedBox(height: 12),
                      
                      // Secret Display
                      GestureDetector(
                        onTap: () {
                          setState(() {
                            _isSecretRevealed = true;
                          });
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _isSecretRevealed
                                ? (isDark ? Colors.white12 : Colors.grey[50])
                                : (isDark ? Colors.white.withOpacity(0.05) : Colors.grey[50]),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: _isSecretRevealed
                                  ? Colors.green.withOpacity(0.5)
                                  : (isDark ? Colors.white24 : Colors.grey[200]!),
                            ),
                          ),
                          child: Center(
                            child: _isSecretRevealed
                                ? SelectableText(
                                    widget.secret,
                                    style: TextStyle(
                                      color: isDark ? Colors.white : const Color(0xFF1A1A2E),
                                      fontSize: 15,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1,
                                    ),
                                    textAlign: TextAlign.center,
                                  )
                                : Column(
                                    children: [
                                      Icon(
                                        Icons.lock_outline,
                                        color: isDark ? Colors.white54 : Colors.grey[500],
                                        size: 28,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'Tap to reveal',
                                        style: TextStyle(
                                          color: isDark ? Colors.white54 : Colors.grey[500],
                                          fontSize: 12,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '●●●●●●●●●●●●●●●●',
                                        style: TextStyle(
                                          color: isDark ? Colors.white24 : Colors.grey[400],
                                          fontSize: 14,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 16),
                      
                      // Copy button (only when revealed)
                      if (_isSecretRevealed)
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: () {
                              Clipboard.setData(ClipboardData(text: widget.secret));
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text('Secret copied to clipboard!'),
                                  backgroundColor: Colors.green,
                                  duration: const Duration(seconds: 2),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                ),
                              );
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4F46E5),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: const Text('Copy Secret Key'),
                          ),
                        ),
                      
                      const SizedBox(height: 12),
                      
                      // Warning
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Keep this secret safe!',
                                style: TextStyle(
                                  color: isDark ? Colors.white70 : Colors.grey[700],
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                
                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  IconData _getServiceIcon(String service) {
    final lower = service.toLowerCase();
    if (lower.contains('google')) return Icons.g_mobiledata_rounded;
    if (lower.contains('github')) return Icons.code_rounded;
    if (lower.contains('facebook')) return Icons.facebook_rounded;
    if (lower.contains('twitter')) return Icons.alternate_email_rounded;
    if (lower.contains('microsoft')) return Icons.window_rounded;
    if (lower.contains('amazon')) return Icons.cloud_rounded;
    if (lower.contains('apple')) return Icons.apple_rounded;
    if (lower.contains('discord')) return Icons.headset_rounded;
    if (lower.contains('slack')) return Icons.message_rounded;
    return Icons.lock_rounded;
  }
  
  void _showHelpDialog(BuildContext context, bool isDark) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        backgroundColor: isDark ? const Color(0xFF1E1E32) : Colors.white,
        title: Row(
          children: [
            Icon(Icons.help_outline, color: const Color(0xFF4F46E5), size: 24),
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
              '• Never share your secret key\n'
              '• Store it in a secure place\n'
              '• Keep it hidden from others',
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
