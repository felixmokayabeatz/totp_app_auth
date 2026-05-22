import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/otp_account.dart';
import '../services/import_file_picker_service.dart';
import '../services/otp_import_service.dart';
import '../services/secure_storage_service.dart';
import '../services/sync_service.dart';

class AddAccountScreen extends StatefulWidget {
  const AddAccountScreen({super.key, this.startScanning = false});

  final bool startScanning;

  @override
  State<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends State<AddAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serviceController = TextEditingController();
  final _accountLabelController = TextEditingController();
  final _secretController = TextEditingController();
  final _issuerController = TextEditingController();
  bool _isScanning = false;
  bool _cameraFailed = false;
  bool _isProcessingQR = false;
  MobileScannerController? _scannerController;

  bool get _isMobile => Platform.isAndroid || Platform.isIOS;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController();
    _isScanning = widget.startScanning;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _isDark ? Color(0xFF0F0F1A) : Color(0xFFF0F2FF),
      appBar: AppBar(
        title: Text(
          _isScanning ? 'Scan QR Code' : 'Add Account',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
        ),
        backgroundColor: _accent,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: TextButton.icon(
              onPressed: _importOtpFile,
              icon: const Icon(
                Icons.upload_file_rounded,
                color: Colors.white,
                size: 18,
              ),
              label: const Text(
                'Import',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (_isMobile && !_cameraFailed)
            Padding(
              padding: EdgeInsets.only(right: 8),
              child: TextButton.icon(
                onPressed: () async {
                  if (_isScanning) {
                    await _switchToManualEntry();
                    return;
                  }
                  setState(() {
                    _isScanning = true;
                    _cameraFailed = false;
                    _isProcessingQR = false;
                  });
                },
                icon: Icon(
                  _isScanning
                      ? Icons.edit_rounded
                      : Icons.qr_code_scanner_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                label: Text(
                  _isScanning ? 'Manual' : 'Scan',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
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
          controller: _scannerController,
          onDetect: (capture) {
            // Prevent multiple rapid scans
            if (_isProcessingQR) return;

            final barcode = capture.barcodes.first;
            final String? code = barcode.rawValue;
            if (code != null && mounted) {
              _parseQRCode(code);
            }
          },
          errorBuilder: (context, error) {
            String errorMessage = 'Camera unavailable';
            // Check for permission error
            if (error.toString().contains('Permission')) {
              errorMessage =
                  'Camera permission denied. Please grant permission in settings.';
            }
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.camera_alt_rounded, color: Colors.red, size: 48),
                  SizedBox(height: 16),
                  Text(
                    errorMessage,
                    style: TextStyle(color: Colors.white, fontSize: 14),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => _switchToManualEntry(cameraFailed: true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text('Enter manually'),
                  ),
                ],
              ),
            );
          },
        ),
        // Overlay with frame
        Positioned.fill(
          child: CustomPaint(painter: _ScannerOverlayPainter(color: _accent)),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Point your camera at the QR code from your authenticator setup page',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () => _switchToManualEntry(cameraFailed: true),
                  icon: Icon(Icons.edit_rounded, color: Colors.white, size: 18),
                  label: Text(
                    'Enter manually instead',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // Back button hint
        Positioned(
          top: 16,
          left: 16,
          child: IconButton(
            icon: Icon(Icons.arrow_back, color: Colors.white, size: 24),
            onPressed: _switchToManualEntry,
            style: IconButton.styleFrom(
              backgroundColor: Colors.black54,
              shape: CircleBorder(),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _parseQRCode(String qrData) async {
    if (_isProcessingQR) return;
    _isProcessingQR = true;
    await _stopScanner();

    try {
      final importedEntries = OTPImportService().parse(qrData);
      if (importedEntries.isNotEmpty) {
        final confirmed = await _confirmScannedEntries(importedEntries);
        if (confirmed != true) {
          if (mounted) {
            setState(() {
              _isProcessingQR = false;
            });
            await _restartScanner();
          } else {
            _isProcessingQR = false;
          }
          return;
        }

        await _saveImportedEntries(importedEntries, sourceLabel: 'scanned QR');
      } else {
        // Not a valid OTP auth QR code
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  Icon(Icons.warning_rounded, color: Colors.white, size: 20),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Invalid QR code. Please scan a valid OTP setup QR.',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.orange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          );
        }
        _isProcessingQR = false;
        await _restartScanner();
      }
    } catch (e) {
      debugPrint('QR parse error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to parse QR code'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      _isProcessingQR = false;
      await _restartScanner();
    }
  }

  Future<void> _importOtpFile() async {
    await _stopScanner();
    final filePicker = ImportFilePickerService();
    if (!filePicker.canPickOtpImportFile) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'OTP file import is available on Android and Windows right now.',
            ),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      await _restartScanner();
      return;
    }

    try {
      final pickedFile = await filePicker.pickOtpImportFile();
      if (!mounted || pickedFile == null) {
        return;
      }

      final importedEntries = OTPImportService().parse(
        pickedFile.content,
        preserveDuplicates: true,
      );
      if (importedEntries.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'No supported OTP accounts were found in ${pickedFile.fileName}.',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final confirmed = await _confirmScannedEntries(importedEntries);
      if (confirmed == true) {
        await _saveImportedEntries(
          importedEntries,
          sourceLabel: pickedFile.fileName,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not read that import file.'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      await _restartScanner();
    }
  }

  Future<void> _switchToManualEntry({bool cameraFailed = false}) async {
    await _stopScanner();
    if (!mounted) return;

    setState(() {
      _isScanning = false;
      _cameraFailed = cameraFailed;
      _isProcessingQR = false;
    });
  }

  Future<void> _stopScanner() async {
    try {
      await _scannerController?.stop();
    } catch (e) {
      debugPrint('Scanner stop error: $e');
    }
  }

  Future<void> _restartScanner() async {
    if (!mounted || !_isMobile || !_isScanning || _cameraFailed) return;

    try {
      await _scannerController?.start();
    } catch (e) {
      debugPrint('Scanner restart error: $e');
    }
  }

  Future<bool?> _confirmScannedEntries(List<OTPImportEntry> entries) {
    final title = entries.length == 1
        ? 'Confirm addition'
        : 'Confirm ${entries.length} additions';
    final content = entries.length == 1
        ? _formatEntrySummary(entries.first)
        : entries.take(5).map(_formatEntrySummary).join('\n');
    final overflow =
        entries.length > 5 ? '\n...and ${entries.length - 5} more' : '';

    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text('$content$overflow'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Confirm addition'),
          ),
        ],
      ),
    );
  }

  String _formatEntrySummary(OTPImportEntry entry) {
    final label = entry.accountLabel?.trim();
    if (label == null || label.isEmpty) return entry.service;
    return '${entry.service} - $label';
  }

  Future<void> _saveImportedEntries(
    List<OTPImportEntry> entries, {
    String? sourceLabel,
  }) async {
    final userId = await SecureStorageService().read(
          SecureStorageService.currentUserKey,
        ) ??
        await SecureStorageService().read(
          SecureStorageService.localVaultUserKey,
        ) ??
        'default_user';
    final syncService = SyncService();
    final userBox = await syncService.getUserBox();
    final isSignedIn = await syncService.isLoggedIn();
    final shouldSync = isSignedIn && await syncService.isSyncEnabled();
    final existingKeys = userBox.values
        .map(
          (account) =>
              _accountIdentityKey(account.service, account.accountLabel),
        )
        .toSet();
    var importedCount = 0;
    var skippedCount = 0;

    for (final entry in entries) {
      final identityKey = _accountIdentityKey(
        entry.service,
        entry.accountLabel,
      );
      if (existingKeys.contains(identityKey)) {
        skippedCount++;
        continue;
      }

      final account = OTPAccount(
        id: '${DateTime.now().millisecondsSinceEpoch}_$importedCount',
        service: entry.service,
        secret: entry.secret,
        issuer: entry.issuer,
        accountLabel: entry.accountLabel,
        createdAt: DateTime.now(),
        userId: userId,
      );
      await userBox.put(account.id, account);
      importedCount++;
    }

    if (isSignedIn && importedCount > 0) {
      try {
        await syncService.logAccountsImportedNotification(
          importedCount: importedCount,
          skippedCount: skippedCount,
          sourceLabel: sourceLabel,
        );
      } catch (e) {
        debugPrint('Imported accounts notification log error: $e');
      }
    }

    if (shouldSync) {
      try {
        await syncService.syncAccounts();
      } catch (e) {
        debugPrint('Imported account sync error: $e');
      }
    }

    if (!mounted) return;

    if (importedCount == 0) {
      final message =
          'No new accounts added${skippedCount > 0 ? '. Duplicate skipped.' : '.'}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }

    Navigator.pop(context, importedCount > 0);
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
                _cameraFailed
                    ? Icons.warning_rounded
                    : Icons.info_outline_rounded,
                _cameraFailed ? Colors.orange : _accent,
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
              controller: _accountLabelController,
              label: 'Account Email / Label',
              hint: 'you@example.com',
              icon: Icons.alternate_email_rounded,
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
                      icon: Icon(Icons.qr_code_scanner_rounded, color: _accent),
                      onPressed: () => setState(() {
                        _isScanning = true;
                        _cameraFailed = false;
                        _isProcessingQR = false;
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
                  backgroundColor: _accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
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
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: _isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
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
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
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
          labelStyle: TextStyle(
            color: _isDark ? Colors.white38 : Colors.grey[500],
            fontSize: 13,
          ),
          hintText: hint,
          hintStyle: TextStyle(
            color: _isDark ? Colors.white24 : Colors.grey[400],
            fontSize: 13,
          ),
          prefixIcon: Icon(icon, color: _accent, size: 20),
          suffixIcon: suffix,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: _isDark ? Colors.white12 : Colors.grey[200]!,
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(
              color: _isDark ? Colors.white12 : Colors.grey[200]!,
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: _accent, width: 1.5),
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
      final userId = await SecureStorageService().read(
            SecureStorageService.currentUserKey,
          ) ??
          await SecureStorageService().read(
            SecureStorageService.localVaultUserKey,
          ) ??
          'default_user';
      final syncService = SyncService();
      final isSignedIn = await syncService.isLoggedIn();
      final shouldSync = isSignedIn && await syncService.isSyncEnabled();

      // Get the USER-SPECIFIC box, not the generic one
      final userBox = await syncService.getUserBox();
      if (!mounted) return;

      final serviceName = _serviceController.text.trim();
      final accountLabel = _accountLabelController.text.trim();
      final exists = _hasDuplicateAccount(
        userBox.values,
        serviceName,
        accountLabel.isEmpty ? null : accountLabel,
      );

      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              accountLabel.isEmpty
                  ? 'An account for "$serviceName" already exists'
                  : 'An account for "$serviceName" and "$accountLabel" already exists',
            ),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
        return;
      }

      // Strip spaces from secret on save
      final rawSecret = _secretController.text.replaceAll(RegExp(r'\s+'), '');

      if (rawSecret.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Invalid secret key'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }

      final newAccount = OTPAccount(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        service: serviceName,
        secret: rawSecret,
        issuer: _issuerController.text.trim().isEmpty
            ? null
            : _issuerController.text.trim(),
        accountLabel: accountLabel.isEmpty ? null : accountLabel,
        createdAt: DateTime.now(),
        userId: userId,
      );

      // Save to USER-SPECIFIC box
      await userBox.put(newAccount.id, newAccount);

      if (shouldSync) {
        try {
          await syncService.syncAccounts();
        } catch (e) {
          debugPrint('Sync error: $e');
        }
      }

      if (isSignedIn) {
        try {
          await syncService.logAccountAddedNotification(
            serviceName: serviceName,
            accountLabel: newAccount.accountLabel,
          );
        } catch (e) {
          debugPrint('Notification log error: $e');
        }
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    }
  }

  bool _hasDuplicateAccount(
    Iterable<OTPAccount> accounts,
    String service,
    String? accountLabel,
  ) {
    final identityKey = _accountIdentityKey(service, accountLabel);

    return accounts.any((account) {
      return _accountIdentityKey(account.service, account.accountLabel) ==
          identityKey;
    });
  }

  String _accountIdentityKey(String service, String? accountLabel) {
    return [
      _normalizeComparableText(service),
      _normalizeComparableText(accountLabel ?? ''),
    ].join('|');
  }

  String _normalizeComparableText(String value) {
    return value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
  }

  @override
  void dispose() {
    _scannerController?.dispose();
    _serviceController.dispose();
    _accountLabelController.dispose();
    _secretController.dispose();
    _issuerController.dispose();
    super.dispose();
  }
}

// Scanner frame overlay painter
class _ScannerOverlayPainter extends CustomPainter {
  const _ScannerOverlayPainter({required this.color});

  final Color color;

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
      ..color = color
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    const cLen = 24.0;
    const r = 16.0;

    // top-left
    canvas.drawLine(
      Offset(left + r, top),
      Offset(left + r + cLen, top),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(left, top + r),
      Offset(left, top + r + cLen),
      cornerPaint,
    );
    // top-right
    canvas.drawLine(
      Offset(left + frameSize - r, top),
      Offset(left + frameSize - r - cLen, top),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(left + frameSize, top + r),
      Offset(left + frameSize, top + r + cLen),
      cornerPaint,
    );
    // bottom-left
    canvas.drawLine(
      Offset(left + r, top + frameSize),
      Offset(left + r + cLen, top + frameSize),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(left, top + frameSize - r),
      Offset(left, top + frameSize - r - cLen),
      cornerPaint,
    );
    // bottom-right
    canvas.drawLine(
      Offset(left + frameSize - r, top + frameSize),
      Offset(left + frameSize - r - cLen, top + frameSize),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(left + frameSize, top + frameSize - r),
      Offset(left + frameSize, top + frameSize - r - cLen),
      cornerPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScannerOverlayPainter oldDelegate) =>
      oldDelegate.color != color;
}
