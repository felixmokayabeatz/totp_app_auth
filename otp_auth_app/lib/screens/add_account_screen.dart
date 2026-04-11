import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/otp_account.dart';
import '../services/sync_service.dart';

class AddAccountScreen extends StatefulWidget {
  @override
  _AddAccountScreenState createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serviceController = TextEditingController();
  final _secretController = TextEditingController();
  final _issuerController = TextEditingController();
  bool _isScanning = false;
  bool _cameraFailed = false;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark ? Color(0xFF0F0F1A) : Color(0xFFF0F2FF),
      appBar: AppBar(
        title: Text(
          _isScanning ? 'Scan QR Code' : 'Add Account',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        backgroundColor: _isDark ? Color(0xFF1A1A2E) : Color(0xFF4F46E5),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          if (_isMobile && !_cameraFailed)
            Padding(
              padding: EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _isScanning = !_isScanning;
                  if (!_isScanning) _cameraFailed = false;
                }),
                icon: Icon(
                  _isScanning ? Icons.edit_rounded : Icons.qr_code_scanner_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                label: Text(
                  _isScanning ? 'Manual' : 'Scan',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ),
            ),
        ],
      ),
      body: _isScanning && _isMobile && !_cameraFailed
          ? _buildScanner()
          : _buildForm(),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            for (final barcode in capture.barcodes) {
              if (barcode.rawValue != null) {
                _parseQRCode(barcode.rawValue!);
                break;
              }
            }
          },
          errorBuilder: (context, error, child) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_rounded, color: Colors.red, size: 48),
                  SizedBox(height: 16),
                  Text('Camera unavailable', style: TextStyle(color: Colors.white, fontSize: 16)),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => setState(() {
                      _isScanning = false;
                      _cameraFailed = true;
                    }),
                    child: Text('Enter manually'),
                  ),
                ],
              ),
            );
          },
        ),
        // Overlay with frame
        Positioned.fill(
          child: CustomPaint(painter: _ScannerOverlayPainter()),
        ),
        // Bottom hint
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            padding: EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: Text(
              'Point your camera at the QR code from your authenticator setup page',
              style: TextStyle(color: Colors.white70, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  void _parseQRCode(String qrData) {
    if (qrData.startsWith('otpauth://')) {
      final uri = Uri.parse(qrData);
      final secret = uri.queryParameters['secret'] ?? '';
      // Strip spaces immediately on parse
      final cleanSecret = secret.replaceAll(RegExp(r'\s+'), '');
      final issuer = uri.queryParameters['issuer'];
      final accountName = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';

      _serviceController.text = issuer ?? accountName.split(':').last;
      _secretController.text = cleanSecret;
      _issuerController.text = issuer ?? '';

      setState(() => _isScanning = false);

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('QR code scanned!'),
        backgroundColor: Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ));
    }
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(20),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isMobile || _cameraFailed)
              _infoCard(
                _cameraFailed
                    ? 'Camera failed. Enter the secret key manually.'
                    : 'On desktop, enter the secret key shown during 2FA setup.',
                _cameraFailed ? Icons.warning_rounded : Icons.info_outline_rounded,
                _cameraFailed ? Colors.orange : Color(0xFF4F46E5),
              ),

            SizedBox(height: 8),

            _sectionLabel('Service Details'),
            SizedBox(height: 10),

            _inputField(
              controller: _serviceController,
              label: 'Service Name',
              hint: 'Google, GitHub, Dropbox…',
              icon: Icons.apps_rounded,
              validator: (v) => v!.isEmpty ? 'Required' : null,
            ),
            SizedBox(height: 12),
            _inputField(
              controller: _issuerController,
              label: 'Issuer (optional)',
              hint: 'e.g. Google LLC',
              icon: Icons.business_rounded,
            ),

            SizedBox(height: 20),
            _sectionLabel('Secret Key'),
            SizedBox(height: 10),

            _inputField(
              controller: _secretController,
              label: 'Secret Key',
              hint: 'Paste or type the key — spaces OK',
              icon: Icons.vpn_key_rounded,
              validator: (v) => v!.trim().isEmpty ? 'Required' : null,
              suffix: _isMobile && !_cameraFailed
                  ? IconButton(
                      icon: Icon(Icons.qr_code_scanner_rounded, color: Color(0xFF4F46E5)),
                      onPressed: () => setState(() {
                        _isScanning = true;
                        _cameraFailed = false;
                      }),
                      tooltip: 'Scan QR',
                    )
                  : null,
            ),

            SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _saveAccount,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  elevation: 0,
                ),
                child: Text(
                  'Add Account',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: _isDark ? Colors.white38 : Colors.grey[500],
        letterSpacing: 0.8,
      ),
    );
  }

  Widget _infoCard(String message, IconData icon, Color color) {
    return Container(
      margin: EdgeInsets.only(bottom: 16),
      padding: EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(message, style: TextStyle(fontSize: 13, color: _isDark ? Colors.white70 : Colors.grey[700])),
          ),
        ],
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    Widget? suffix,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _isDark ? Color(0xFF1E1E32) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 8, offset: Offset(0, 2)),
        ],
      ),
      child: TextFormField(
        controller: controller,
        validator: validator,
        style: TextStyle(
          color: _isDark ? Colors.white : Color(0xFF1A1A2E),
          fontSize: 14,
        ),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: _isDark ? Colors.white38 : Colors.grey[500], fontSize: 13),
          hintText: hint,
          hintStyle: TextStyle(color: _isDark ? Colors.white24 : Colors.grey[400], fontSize: 13),
          prefixIcon: Icon(icon, color: Color(0xFF4F46E5), size: 20),
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _isDark ? Colors.white12 : Colors.grey[200]!),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _isDark ? Colors.white12 : Colors.grey[200]!),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Color(0xFF4F46E5), width: 1.5),
          ),
          errorBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: Colors.red, width: 1.5),
          ),
          contentPadding: EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        ),
      ),
    );
  }

  void _saveAccount() async {
    if (_formKey.currentState!.validate()) {
      final otpBox = Hive.box<OTPAccount>('otp_accounts');
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString('current_user') ?? 'default_user';

      final serviceName = _serviceController.text.trim();
      final exists = otpBox.values.any(
        (a) => a.service.toLowerCase() == serviceName.toLowerCase(),
      );

      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('An account for "$serviceName" already exists'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ));
        return;
      }

      // Strip spaces from secret on save
      final rawSecret = _secretController.text.replaceAll(RegExp(r'\s+'), '');

      if (rawSecret.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Invalid secret key'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ));
        return;
      }

      final newAccount = OTPAccount(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        service: serviceName,
        secret: rawSecret,
        issuer: _issuerController.text.trim().isEmpty ? null : _issuerController.text.trim(),
        createdAt: DateTime.now(),
        userId: userId,
      );

      await otpBox.put(newAccount.id, newAccount);

      try {
        await SyncService().syncAccounts();
      } catch (e) {
        debugPrint('Sync error: $e');
      }

      Navigator.pop(context, true);
    }
  }

  @override
  void dispose() {
    _serviceController.dispose();
    _secretController.dispose();
    _issuerController.dispose();
    super.dispose();
  }
}

// Scanner frame overlay painter
class _ScannerOverlayPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.black54
      ..style = PaintingStyle.fill;

    const frameSize = 240.0;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final left = cx - frameSize / 2;
    final top = cy - frameSize / 2;
    final frame = Rect.fromLTWH(left, top, frameSize, frameSize);

    final path = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
      ..addRRect(RRect.fromRectAndRadius(frame, Radius.circular(16)));

    canvas.drawPath(path, paint..blendMode = BlendMode.srcOver);

    // Corner marks
    final cornerPaint = Paint()
      ..color = Color(0xFF4F46E5)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cLen = 24.0;
    const r = 16.0;

    // top-left
    canvas.drawLine(Offset(left + r, top), Offset(left + r + cLen, top), cornerPaint);
    canvas.drawLine(Offset(left, top + r), Offset(left, top + r + cLen), cornerPaint);
    // top-right
    canvas.drawLine(Offset(left + frameSize - r, top), Offset(left + frameSize - r - cLen, top), cornerPaint);
    canvas.drawLine(Offset(left + frameSize, top + r), Offset(left + frameSize, top + r + cLen), cornerPaint);
    // bottom-left
    canvas.drawLine(Offset(left + r, top + frameSize), Offset(left + r + cLen, top + frameSize), cornerPaint);
    canvas.drawLine(Offset(left, top + frameSize - r), Offset(left, top + frameSize - r - cLen), cornerPaint);
    // bottom-right
    canvas.drawLine(Offset(left + frameSize - r, top + frameSize), Offset(left + frameSize - r - cLen, top + frameSize), cornerPaint);
    canvas.drawLine(Offset(left + frameSize, top + frameSize - r), Offset(left + frameSize, top + frameSize - r - cLen), cornerPaint);
  }

  @override
  bool shouldRepaint(_) => false;
}