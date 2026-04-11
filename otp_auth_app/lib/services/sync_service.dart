import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';

class SyncService {
  late Dio _dio;
  bool _isRefreshing = false;
  
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
  
  Future<bool> _refreshToken() async {
    if (_isRefreshing) return false;
    
    _isRefreshing = true;
    final prefs = await SharedPreferences.getInstance();
    final refreshToken = prefs.getString('refresh_token');
    
    if (refreshToken == null) {
      _isRefreshing = false;
      return false;
    }
    
    try {
      print('Refreshing token...');
      final response = await _dio.post('auth/refresh/', data: {
        'refresh': refreshToken,
      });
      
      if (response.statusCode == 200) {
        final newAccessToken = response.data['access'];
        await prefs.setString('access_token', newAccessToken);
        await _updateAuthHeader();
        print('Token refreshed successfully');
        _isRefreshing = false;
        return true;
      }
      _isRefreshing = false;
      return false;
    } catch (e) {
      print('Token refresh failed: $e');
      _isRefreshing = false;
      return false;
    }
  }
  
  Future<Response> _requestWithRetry(Future<Response> Function() request) async {
    try {
      return await request();
    } on DioError catch (e) {
      if (e.response?.statusCode == 401) {
        print('Token expired, attempting refresh...');
        final refreshed = await _refreshToken();
        if (refreshed) {
          print('Retrying request with new token...');
          return await request();
        }
      }
      rethrow;
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
        await prefs.setString('user_email', email);
        await prefs.setString('user_id', response.data['user']['id'].toString());
        
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
        
        final userEmail = response.data['user']['email'] ?? '';
        await prefs.setString('user_email', userEmail);
        await prefs.setString('user_id', response.data['user']['id'].toString());
        
        print('Saved user data - Username: $username, Email: $userEmail');
        
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
      final response = await _requestWithRetry(() => _dio.get(
        'sync/get-data/',
        queryParameters: {'data_type': 'otp_accounts'},
      ));
      
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
      final response = await _requestWithRetry(() => _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encryptedContent,
        'version': accountsData.length,
      }));
      
      if (response.statusCode == 200) {
        print('Sync successful - ${accountsData.length} accounts synced');
        return true;
      } else {
        print('Sync failed with status: ${response.statusCode}');
        return false;
      }
    } on DioError catch (e) {
      print('Sync error: ${e.message}');
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
    await prefs.remove('user_email');
    await prefs.remove('user_id');
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

  Future<bool> changePassword(String currentPassword, String newPassword) async {
    await _updateAuthHeader();
    
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    
    if (token == null) {
      print('No token available');
      return false;
    }
    
    try {
      final response = await _dio.post(
        'auth/change_password/',  // Note: underscore, not hyphen
        data: {
          'current_password': currentPassword,
          'new_password': newPassword,
        },
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
          },
        ),
      );
      
      if (response.statusCode == 200) {
        print('Password changed successfully');
        return true;
      }
      return false;
    } catch (e) {
      print('Change password error: $e');
      return false;
    }
  }

  Future<bool> sendPasswordResetCode(String email) async {
  try {
    final response = await _dio.post('send-reset-code/', data: {
      'email': email,
    });
    print('Send reset code response: ${response.data}');
    return response.data['success'] == true;
  } catch (e) {
    print('Send reset code error: $e');
    return false;
  }
}

Future<bool> resetPassword(String email, String code, String newPassword) async {
  try {
    final response = await _dio.post('reset-password/', data: {
      'email': email,
      'code': code,
      'new_password': newPassword,
    });
    print('Reset password response: ${response.data}');
    return response.statusCode == 200;
  } catch (e) {
    print('Reset password error: $e');
    return false;
  }
}
}