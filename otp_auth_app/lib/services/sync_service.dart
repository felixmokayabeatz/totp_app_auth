import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';

class SyncService {
  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://localhost:8000/api/',
    connectTimeout: Duration(seconds: 30),
    receiveTimeout: Duration(seconds: 30),
  ));
  
  String? _encryptionKey;
  
  Future<void> _initEncryption() async {
    if (_encryptionKey == null) {
      final prefs = await SharedPreferences.getInstance();
      final username = prefs.getString('current_user');
      _encryptionKey = EncryptionService.generateKey(
        username ?? 'default',
        'otp_auth_salt_2024'
      );
    }
  }
  
  Future<bool> register(String username, String email, String password) async {
    try {
      final response = await _dio.post('auth/register/', data: {
        'username': username,
        'email': email,
        'password': password,
      });
      
      if (response.statusCode == 200 || response.statusCode == 201) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', response.data['access']);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        
        await _initEncryption();
        await _clearLocalAccounts();
        return true;
      }
      return false;
    } catch (e) {
      print('Register error: $e');
      return false;
    }
  }
  
  Future<bool> login(String username, String password) async {
    try {
      final response = await _dio.post('auth/login/', data: {
        'username': username,
        'password': password,
      });
      
      if (response.statusCode == 200) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('access_token', response.data['access']);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        
        await _initEncryption();
        await _clearLocalAccounts();
        await downloadAccounts();
        return true;
      }
      return false;
    } catch (e) {
      print('Login error: $e');
      return false;
    }
  }
  
  Future<void> _clearLocalAccounts() async {
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    await otpBox.clear();
  }
  
  Future<void> downloadAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return;
    
    await _initEncryption();
    _dio.options.headers['Authorization'] = 'Bearer $token';
    
    try {
      final response = await _dio.get('sync/get_data/', queryParameters: {
        'data_type': 'otp_accounts',
      });
      
      if (response.statusCode == 200 && response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];
        final decryptedContent = EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);
        
        // Parse and load accounts
        final List<dynamic> accountsList = [];
        // Parse decrypted content and add to Hive
        print('Downloaded and decrypted ${accountsList.length} accounts');
      }
    } catch (e) {
      print('Download error: $e');
    }
  }
  
  Future<void> syncAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return;
    
    await _initEncryption();
    _dio.options.headers['Authorization'] = 'Bearer $token';
    
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    final accountsData = otpBox.values.map((a) => ({
      'id': a.id,
      'service': a.service,
      'secret': a.secret,
      'issuer': a.issuer,
      'createdAt': a.createdAt.toIso8601String(),
    })).toList();
    
    // Encrypt before sending
    final jsonString = accountsData.toString();
    final encryptedContent = EncryptionService.simpleEncrypt(jsonString, _encryptionKey!);
    
    try {
      await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encryptedContent,
        'version': accountsData.length,
      });
      print('Sync successful - ${accountsData.length} accounts synced (encrypted)');
    } catch (e) {
      print('Sync error: $e');
    }
  }
  
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    await prefs.remove('current_user');
    await _clearLocalAccounts();
    _encryptionKey = null;
  }
  
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await prefs.getString('access_token');
    return token != null;
  }
  
  Future<String?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user');
  }
  
  Future<bool> send2FACode(String username) async {
    try {
      final response = await _dio.post('send-2fa/', data: {
        'username': username,
      });
      return response.data['success'] == true;
    } catch (e) {
      print('Send 2FA error: $e');
      return false;
    }
  }
  
  Future<bool> verify2FACode(String username, String code) async {
    try {
      final response = await _dio.post('verify-2fa/', data: {
        'username': username,
        'code': code,
      });
      return response.data['success'] == true;
    } catch (e) {
      print('Verify 2FA error: $e');
      return false;
    }
  }
}