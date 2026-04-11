import 'dart:io';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:hive_flutter/hive_flutter.dart';
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
  
  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    
    return Scaffold(
      backgroundColor: isDark ? Color(0xFF1a1a2e) : Color(0xFF667eea),
      appBar: AppBar(
        title: Text(
          'Add Account',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.white), // Always white for visibility
          onPressed: () => Navigator.pop(context),
        ),
        iconTheme: IconThemeData(color: Colors.white), // Force white icons
      ),
      body: _isScanning && _isMobile && !_cameraFailed ? _buildScanner() : _buildForm(),
      floatingActionButton: _isMobile && !_cameraFailed ? FloatingActionButton(
        onPressed: () {
          setState(() {
            _isScanning = !_isScanning;
            if (!_isScanning) {
              _cameraFailed = false;
            }
          });
        },
        child: Icon(_isScanning ? Icons.edit : Icons.qr_code_scanner),
        backgroundColor: Colors.white,
        foregroundColor: Color(0xFF667eea),
      ) : null,
    );
  }
  
  Widget _buildScanner() {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: MobileScanner(
                onDetect: (capture) {
                  final barcodes = capture.barcodes;
                  for (final barcode in barcodes) {
                    if (barcode.rawValue != null) {
                      _parseQRCode(barcode.rawValue!);
                      break;
                    }
                  }
                },
                errorBuilder: (context, error, child) {
                  return Container(
                    color: Colors.black,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.error_outline, color: Colors.red, size: 50),
                          SizedBox(height: 20),
                          Text(
                            'Camera Error',
                            style: TextStyle(color: Colors.white, fontSize: 18),
                          ),
                          SizedBox(height: 10),
                          Text(
                            error.toString(),
                            style: TextStyle(color: Colors.white70),
                            textAlign: TextAlign.center,
                          ),
                          SizedBox(height: 20),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                _isScanning = false;
                                _cameraFailed = true;
                              });
                            },
                            child: Text('Enter Manually'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Color(0xFF667eea),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        Container(
          padding: EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
          ),
          child: Column(
            children: [
              Icon(Icons.qr_code_scanner, color: Colors.white, size: 40),
              SizedBox(height: 10),
              Text(
                'Position QR code in frame',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
              SizedBox(height: 10),
              TextButton(
                onPressed: () {
                  setState(() {
                    _isScanning = false;
                  });
                },
                child: Text(
                  'Enter manually instead',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
  
  void _parseQRCode(String qrData) {
    if (qrData.startsWith('otpauth://')) {
      final uri = Uri.parse(qrData);
      final secret = uri.queryParameters['secret'];
      final issuer = uri.queryParameters['issuer'];
      final accountName = uri.pathSegments.last;
      
      _serviceController.text = issuer ?? accountName.split(':').last;
      _secretController.text = secret ?? '';
      _issuerController.text = issuer ?? '';
      
      setState(() {
        _isScanning = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ QR Code scanned! You can now review and save.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Invalid QR code. Please try again or enter manually.'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  Widget _buildForm() {
    return SingleChildScrollView(
      padding: EdgeInsets.all(24),
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            // Info card for desktop or camera failure
            if (!_isMobile || _cameraFailed)
              Container(
                margin: EdgeInsets.only(bottom: 20),
                padding: EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(_cameraFailed ? Icons.warning : Icons.info_outline, 
                         color: Colors.white, size: 24),
                    SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _cameraFailed 
                          ? 'Camera failed. Please enter the secret key manually below.'
                          : 'On desktop, please enter the secret key manually. You can find the secret key when setting up 2FA on websites.',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            
            // Show retry camera button if camera failed
            if (_isMobile && _cameraFailed)
              Container(
                margin: EdgeInsets.only(bottom: 20),
                child: ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _cameraFailed = false;
                      _isScanning = true;
                    });
                  },
                  icon: Icon(Icons.camera_alt),
                  label: Text('Retry Camera Scan'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Color(0xFF667eea),
                  ),
                ),
              ),
            
            Container(
              padding: EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.1),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                children: [
                  TextFormField(
                    controller: _serviceController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Service Name *',
                      labelStyle: TextStyle(color: Colors.white70),
                      hintText: 'e.g., Google, GitHub, Facebook',
                      hintStyle: TextStyle(color: Colors.white38),
                      prefixIcon: Icon(Icons.business, color: Colors.white70),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white, width: 2),
                      ),
                    ),
                    validator: (value) => value!.isEmpty ? 'Service name is required' : null,
                  ),
                  SizedBox(height: 16),
                  TextFormField(
                    controller: _issuerController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Issuer (Optional)',
                      labelStyle: TextStyle(color: Colors.white70),
                      hintText: 'e.g., Google Inc.',
                      hintStyle: TextStyle(color: Colors.white38),
                      prefixIcon: Icon(Icons.business_center, color: Colors.white70),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white, width: 2),
                      ),
                    ),
                  ),
                  SizedBox(height: 16),
                  TextFormField(
                    controller: _secretController,
                    style: TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Secret Key *',
                      labelStyle: TextStyle(color: Colors.white70),
                      hintText: 'e.g., JBSWY3DPEHPK3PXP',
                      hintStyle: TextStyle(color: Colors.white38),
                      prefixIcon: Icon(Icons.vpn_key, color: Colors.white70),
                      suffixIcon: _isMobile && !_cameraFailed
                          ? IconButton(
                              icon: Icon(Icons.qr_code_scanner, color: Colors.white70),
                              onPressed: () {
                                setState(() {
                                  _isScanning = true;
                                  _cameraFailed = false;
                                });
                              },
                              tooltip: 'Scan QR Code',
                            )
                          : null,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white24),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(15),
                        borderSide: BorderSide(color: Colors.white, width: 2),
                      ),
                    ),
                    validator: (value) {
                      if (value!.isEmpty) return 'Secret key is required';
                      if (value.length < 16) return 'Secret key is too short';
                      return null;
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: 30),
            ElevatedButton(
              onPressed: _saveAccount,
              child: Text('Add Account', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 55),
                backgroundColor: Colors.white,
                foregroundColor: Color(0xFF667eea),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
              ),
            ),
            
            if (!_isMobile)
              Padding(
                padding: EdgeInsets.only(top: 20),
                child: Text(
                  '💡 Tip: You can find the secret key when setting up 2FA on websites.\n'
                  'Look for a code like: JBSWY3DPEHPK3PXP',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            
            if (_isMobile)
              Padding(
                padding: EdgeInsets.only(top: 20),
                child: Text(
                  '💡 Tip: If camera doesn\'t work, you can enter the secret key manually.\n'
                  'The secret key is usually displayed as text below the QR code.',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
        ),
      ),
    );
  }
  
  void _saveAccount() async {
    if (_formKey.currentState!.validate()) {
      final otpBox = Hive.box<OTPAccount>('otp_accounts');
      
      // Check if service already exists
      bool exists = false;
      for (var account in otpBox.values) {
        if (account.service.toLowerCase() == _serviceController.text.toLowerCase()) {
          exists = true;
          break;
        }
      }
      
      if (exists) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('An account with this service name already exists!'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
        return;
      }
      
      final newAccount = OTPAccount(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        service: _serviceController.text,
        secret: _secretController.text.toUpperCase().replaceAll(' ', ''),
        issuer: _issuerController.text.isEmpty ? null : _issuerController.text,
        createdAt: DateTime.now(),
      );
      
      await otpBox.put(newAccount.id, newAccount);
      
      // Try to sync to cloud
      try {
        final syncService = SyncService();
        await syncService.syncAccounts();
      } catch (e) {
        print('Sync error after add: $e');
      }
      
      Navigator.pop(context, true);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✓ Account added successfully!'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
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