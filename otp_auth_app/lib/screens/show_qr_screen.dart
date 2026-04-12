// show_qr_screen.dart

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

class _ShowQRScreenState extends State<ShowQRScreen> with SingleTickerProviderStateMixin {
  bool _isSecretRevealed = false;
  late AnimationController _shakeController;
  
  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
  }
  
  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }
  
  void _revealSecret() {
    setState(() {
      _isSecretRevealed = true;
    });
    _shakeController.forward().then((_) => _shakeController.reset());
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🔓 Secret revealed! Copy it carefully.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
  
  void _copySecret() {
    if (_isSecretRevealed) {
      Clipboard.setData(ClipboardData(text: widget.secret));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.check_circle, color: Colors.white, size: 20),
              SizedBox(width: 8),
              Text('Secret copied to clipboard!'),
            ],
          ),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🔒 Tap the secret to reveal it first'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final otpUrl = 'otpauth://totp/${widget.issuer != null ? "${widget.issuer}:" : ""}${widget.service}?secret=${widget.secret}&issuer=${widget.issuer ?? widget.service}';
    
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'QR Code',
          style: TextStyle(
            color: isDark ? Colors.white : Color(0xFF667eea),
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(
            Icons.arrow_back,
            color: isDark ? Colors.white : Color(0xFF667eea),
          ),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.help_outline, color: isDark ? Colors.white : Color(0xFF667eea)),
            onPressed: () => _showHelpDialog(context),
          ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [Color(0xFF1a1a2e), Color(0xFF16213e)]
                : [Color(0xFF667eea), Color(0xFF764ba2)],
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // QR Code Card
                Card(
                  elevation: 8,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                  color: Colors.white,
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        QrImageView(
                          data: otpUrl,
                          version: QrVersions.auto,
                          size: 250.0,
                          eyeStyle: QrEyeStyle(
                            color: Color(0xFF667eea),
                            eyeShape: QrEyeShape.circle,
                          ),
                          dataModuleStyle: QrDataModuleStyle(
                            color: Color(0xFF667eea),
                            dataModuleShape: QrDataModuleShape.circle,
                          ),
                        ),
                        SizedBox(height: 20),
                        Text(
                          'Scan this QR code',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF667eea),
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'with your authenticator app',
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ),
                
                SizedBox(height: 30),
                
                // Secret Key Section (Hidden by default)
                Container(
                  margin: EdgeInsets.symmetric(horizontal: 20),
                  padding: EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Secret Key',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (!_isSecretRevealed)
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.orange.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.orange),
                              ),
                              child: Text(
                                'Hidden',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          if (_isSecretRevealed)
                            Container(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.green.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: Colors.green),
                              ),
                              child: Text(
                                'Revealed',
                                style: TextStyle(
                                  color: Colors.green,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                      
                      SizedBox(height: 16),
                      
                      // Secret Display Area
                      GestureDetector(
                        onTap: _revealSecret,
                        child: AnimatedContainer(
                          duration: Duration(milliseconds: 300),
                          padding: EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: _isSecretRevealed
                                ? Colors.white.withOpacity(0.2)
                                : Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(
                              color: _isSecretRevealed
                                  ? Colors.green.withOpacity(0.5)
                                  : Colors.white.withOpacity(0.2),
                            ),
                          ),
                          child: Center(
                            child: _isSecretRevealed
                                ? SelectableText(
                                    widget.secret,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 2,
                                    ),
                                    textAlign: TextAlign.center,
                                  )
                                : Column(
                                    children: [
                                      Icon(
                                        Icons.lock_outline,
                                        color: Colors.white70,
                                        size: 32,
                                      ),
                                      SizedBox(height: 8),
                                      Text(
                                        'Tap to reveal secret key',
                                        style: TextStyle(
                                          color: Colors.white70,
                                          fontSize: 14,
                                        ),
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        '●●●●●●●●●●●●●●●●',
                                        style: TextStyle(
                                          color: Colors.white38,
                                          fontSize: 16,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                      
                      SizedBox(height: 16),
                      
                      // Copy Button (only shows when revealed)
                      if (_isSecretRevealed)
                        AnimatedOpacity(
                          opacity: _isSecretRevealed ? 1.0 : 0.0,
                          duration: Duration(milliseconds: 300),
                          child: ElevatedButton.icon(
                            onPressed: _copySecret,
                            icon: Icon(Icons.copy, color: Colors.white),
                            label: Text(
                              'Copy Secret Key',
                              style: TextStyle(color: Colors.white),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Color(0xFF667eea),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                        ),
                      
                      SizedBox(height: 12),
                      
                      // Warning Message
                      Container(
                        padding: EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.red.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.red.withOpacity(0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.warning_amber, color: Colors.orange, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Keep this secret safe! Anyone with this key can generate your OTP codes.',
                                style: TextStyle(
                                  color: Colors.white70,
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
                
                SizedBox(height: 20),
                
                // Info Button
                TextButton.icon(
                  onPressed: () => _showHelpDialog(context),
                  icon: Icon(Icons.info_outline, color: Colors.white70, size: 18),
                  label: Text(
                    'What is this secret key?',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
                
                SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }
  
  void _showHelpDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Icon(Icons.help_outline, color: Color(0xFF667eea), size: 28),
            SizedBox(width: 12),
            Text('About Secret Key'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'What is a Secret Key?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              'The secret key is the foundation of your 2FA codes. It\'s a unique code that generates your time-based one-time passwords.',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 16),
            Text(
              'Important Security Notes:',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            SizedBox(height: 8),
            Text(
              '• Never share your secret key with anyone\n'
              '• Store it in a secure place (like a password manager)\n'
              '• If you lose it, you may lose access to your accounts\n'
              '• Keep it hidden from prying eyes',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Got it', style: TextStyle(color: Color(0xFF667eea))),
          ),
        ],
      ),
    );
  }
}