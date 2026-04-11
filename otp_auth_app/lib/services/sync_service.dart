import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';

class SyncService {
  late Dio _dio;
  
  SyncService() {
    _dio = Dio(BaseOptions(
      baseUrl: 'http://localhost:8000/api/',
      connectTimeout: Duration(seconds: 30),
      receiveTimeout: Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
      },
    ));
  }
  
  String? _encryptionKey;
  
  Future<void> _updateAuthHeader() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token != null && token.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
      print('Auth header set with token: ${token.substring(0, 20)}...');
    } else {
      print('No token found');
    }
  }
  
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
        final accessToken = response.data['access'];
        await prefs.setString('access_token', accessToken);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        
        await _updateAuthHeader();
        await _initEncryption();
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
        final accessToken = response.data['access'];
        await prefs.setString('access_token', accessToken);
        await prefs.setString('refresh_token', response.data['refresh']);
        await prefs.setString('current_user', username);
        
        await _updateAuthHeader();
        await _initEncryption();
        
        await downloadAndMergeAccounts();
        return true;
      }
      return false;
    } catch (e) {
      print('Login error: $e');
      return false;
    }
  }
  
  Future<void> downloadAndMergeAccounts() async {
    await _updateAuthHeader();
    
    try {
      print('Downloading accounts from cloud...');
      final response = await _dio.get(
        'sync/get-data/',
        queryParameters: {'data_type': 'otp_accounts'},
      );
      
      print('Download response status: ${response.statusCode}');
      
      if (response.statusCode == 200 && response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];
        await _initEncryption();
        final decryptedContent = EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);
        print('Cloud accounts downloaded and decrypted');
        
        final localBox = Hive.box<OTPAccount>('otp_accounts');
        print('Local accounts before merge: ${localBox.length}');
      } else if (response.statusCode == 404) {
        print('No cloud accounts found');
      }
    } on DioError catch (e) {
      print('Download error: ${e.message}');
      if (e.response?.statusCode == 401) {
        print('Token invalid - please login again');
      }
    } catch (e) {
      print('Download error: $e');
    }
  }
  
  Future<bool> syncAccounts() async {
    await _updateAuthHeader();
    
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    
    if (token == null || token.isEmpty) {
      print('No access token found - cannot sync');
      return false;
    }
    
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    final accountsData = otpBox.values.map((a) => ({
      'id': a.id,
      'service': a.service,
      'secret': a.encryptedSecret,
      'issuer': a.issuer,
      'createdAt': a.createdAt.toIso8601String(),
    })).toList();
    
    await _initEncryption();
    final jsonString = accountsData.toString();
    final encryptedContent = EncryptionService.simpleEncrypt(jsonString, _encryptionKey!);
    
    try {
      print('Syncing ${accountsData.length} accounts...');
      final response = await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encryptedContent,
        'version': accountsData.length,
      });
      
      if (response.statusCode == 200) {
        print('Sync successful - ${accountsData.length} accounts synced');
        return true;
      } else {
        print('Sync failed with status: ${response.statusCode}');
        return false;
      }
    } on DioError catch (e) {
      print('Sync error: ${e.message}');
      if (e.response?.statusCode == 401) {
        print('Token expired - please login again');
        await prefs.remove('access_token');
      } else if (e.type == DioErrorType.connectionTimeout) {
        print('Connection timeout - no internet');
      } else if (e.type == DioErrorType.connectionError) {
        print('Connection error - server unreachable');
      }
      return false;
    } catch (e) {
      print('Sync error: $e');
      return false;
    }
  }
  
  Future<bool> send2FACode(String username, String password) async {
    try {
      final response = await _dio.post('send-2fa/', data: {
        'username': username,
        'password': password,
      });
      print('Send 2FA response: ${response.data}');
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
      print('Verify 2FA response: ${response.data}');
      return response.data['success'] == true;
    } catch (e) {
      print('Verify 2FA error: $e');
      return false;
    }
  }
  
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('access_token');
    await prefs.remove('refresh_token');
    await prefs.remove('current_user');
    _encryptionKey = null;
    _dio.options.headers.remove('Authorization');
  }
  
  Future<bool> isLoggedIn() async {
    final prefs = await SharedPreferences.getInstance();
    final token = await prefs.getString('access_token');
    return token != null && token.isNotEmpty;
  }
  
  Future<String?> getCurrentUser() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user');
  }
}