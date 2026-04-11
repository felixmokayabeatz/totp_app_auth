import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';
import '../config/app_config.dart';
import 'dart:convert';

class SyncService {
  late Dio _dio;
  bool _isRefreshing = false;
  
  SyncService() {
    _dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiUrl,
      connectTimeout: Duration(seconds: 30),
      receiveTimeout: Duration(seconds: 30),
      headers: {
        'Content-Type': 'application/json',
      },
    ));
  }
  
  String? _encryptionKey;
  
  Future<String> _getUserBoxName() async {
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString('current_user');
    if (username == null || username.isEmpty) {
      return 'otp_accounts_default';
    }
    return 'otp_accounts_$username';
  }
  
  Future<Box<OTPAccount>> _getUserBox() async {
    final boxName = await _getUserBoxName();
    if (!Hive.isBoxOpen(boxName)) {
      await Hive.openBox<OTPAccount>(boxName);
    }
    return Hive.box<OTPAccount>(boxName);
  }
  
  Future<void> _updateAuthHeader() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token != null && token.isNotEmpty) {
      _dio.options.headers['Authorization'] = 'Bearer $token';
      print('Auth header set');
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
      final response = await _dio.post('token/refresh/', data: {
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
      if (username == null || username.isEmpty) {
        print('No username found for encryption - using default');
        _encryptionKey = EncryptionService.generateKey('default_user', 'otp_auth_salt_2024');
      } else {
        _encryptionKey = EncryptionService.generateKey(username, 'otp_auth_salt_2024');
      }
      print('Encryption key initialized for user: $username');
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
        
        // Get user box (will be empty for new users)
        final userBox = await _getUserBox();
        print('User box: ${await _getUserBoxName()} has ${userBox.length} accounts');
        
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
    
    await _initEncryption();
    
    if (_encryptionKey == null) {
      print('Encryption key is null - cannot download');
      return;
    }
    
    final prefs = await SharedPreferences.getInstance();
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }
    
    try {
      print('Downloading accounts from cloud...');
      final response = await _requestWithRetry(() => _dio.get(
        'sync/get-data/',
        queryParameters: {
          'data_type': 'otp_accounts',
          'device_id': deviceId,
        },
      ));
      
      print('Download response status: ${response.statusCode}');
      
      if (response.statusCode == 200 && response.data['encrypted_content'] != null) {
        final encryptedContent = response.data['encrypted_content'];
        final decryptedContent = EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);
        
        final List<dynamic> cloudAccounts = jsonDecode(decryptedContent);
        print('Cloud accounts: ${cloudAccounts.length}');
        
        final userBox = await _getUserBox();
        
        // MERGE: Add cloud accounts that don't exist locally
        int addedCount = 0;
        for (var cloudAccount in cloudAccounts) {
          if (!userBox.containsKey(cloudAccount['id'])) {
            final newAccount = OTPAccount(
              id: cloudAccount['id'],
              service: cloudAccount['service'],
              secret: cloudAccount['secret'],
              issuer: cloudAccount['issuer'],
              createdAt: DateTime.parse(cloudAccount['createdAt']),
              userId: await _getCurrentUserId(),
            );
            await userBox.put(newAccount.id, newAccount);
            addedCount++;
            print('Added cloud account: ${cloudAccount['service']}');
          }
        }
        print('Added $addedCount new accounts from cloud');
        print('Total local accounts: ${userBox.length}');
        
        // After merging, upload to cloud to ensure cloud has everything
        await syncAccounts();
        
      } else if (response.statusCode == 404) {
        print('No cloud accounts found - will upload local on first sync');
      }
    } on DioError catch (e) {
      print('Download error: ${e.message}');
    } catch (e) {
      print('Download error: $e');
    }
  }
  
  Future<String> _getCurrentUserId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('current_user') ?? 'default_user';
  }
  
  Future<bool> syncAccounts() async {
    await _updateAuthHeader();
    
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    
    if (token == null || token.isEmpty) {
      print('No access token found - cannot sync');
      return false;
    }
    
    final userBox = await _getUserBox();
    
    await _initEncryption();
    
    if (_encryptionKey == null) {
      print('Encryption key is null - cannot sync');
      return false;
    }
    
    // Get device ID
    String deviceId = prefs.getString('device_id') ?? '';
    if (deviceId.isEmpty) {
      deviceId = DateTime.now().millisecondsSinceEpoch.toString();
      await prefs.setString('device_id', deviceId);
    }
    
    try {
      // STEP 1: DOWNLOAD cloud accounts first
      print('Downloading cloud accounts...');
      final downloadResponse = await _requestWithRetry(() => _dio.get(
        'sync/get-data/',
        queryParameters: {
          'data_type': 'otp_accounts',
          'device_id': deviceId,
        },
      ));
      
      Map<String, dynamic> cloudAccountsMap = {};
      int cloudVersion = 0;
      
      if (downloadResponse.statusCode == 200 && downloadResponse.data['encrypted_content'] != null) {
        final encryptedContent = downloadResponse.data['encrypted_content'];
        final decryptedContent = EncryptionService.simpleDecrypt(encryptedContent, _encryptionKey!);
        final List<dynamic> cloudAccounts = jsonDecode(decryptedContent);
        cloudVersion = downloadResponse.data['version'] ?? 0;
        
        for (var account in cloudAccounts) {
          cloudAccountsMap[account['id']] = account;
        }
        print('Cloud has ${cloudAccounts.length} accounts');
      }
      
      // STEP 2: Get local accounts
      final localAccountsMap = <String, dynamic>{};
      for (var account in userBox.values) {
        localAccountsMap[account.id] = {
          'id': account.id,
          'service': account.service,
          'secret': account.encryptedSecret,
          'issuer': account.issuer,
          'createdAt': account.createdAt.toIso8601String(),
          'lastModified': account.createdAt.toIso8601String(),
        };
      }
      print('Local has ${localAccountsMap.length} accounts');
      
      // STEP 3: MERGE - combine both, cloud wins on conflicts
      final mergedAccounts = <String, dynamic>{};
      int addedFromCloud = 0;
      int addedFromLocal = 0;
      
      // Add all local accounts first
      for (var entry in localAccountsMap.entries) {
        mergedAccounts[entry.key] = entry.value;
        addedFromLocal++;
      }
      
      // Add/overwrite with cloud accounts
      for (var entry in cloudAccountsMap.entries) {
        if (!mergedAccounts.containsKey(entry.key)) {
          mergedAccounts[entry.key] = entry.value;
          addedFromCloud++;
        } else {
          // Cloud account exists - update local later
          mergedAccounts[entry.key] = entry.value;
        }
      }
      
      print('Merge result: ${mergedAccounts.length} total accounts ($addedFromCloud from cloud, $addedFromLocal from local)');
      
      // STEP 4: UPDATE LOCAL with merged data
      int updatedLocally = 0;
      for (var entry in mergedAccounts.entries) {
        if (!userBox.containsKey(entry.key)) {
          // Add new account to local
          final accountData = entry.value;
          final newAccount = OTPAccount(
            id: accountData['id'],
            service: accountData['service'],
            secret: accountData['secret'],
            issuer: accountData['issuer'],
            createdAt: DateTime.parse(accountData['createdAt']),
            userId: await _getCurrentUserId(),
          );
          await userBox.put(newAccount.id, newAccount);
          updatedLocally++;
        }
      }
      print('Updated local with $updatedLocally new accounts');
      
      // STEP 5: UPLOAD merged data to cloud (backup)
      final finalAccountsData = userBox.values.map((a) => ({
        'id': a.id,
        'service': a.service,
        'secret': a.encryptedSecret,
        'issuer': a.issuer,
        'createdAt': a.createdAt.toIso8601String(),
      })).toList();
      
      final jsonString = jsonEncode(finalAccountsData);
      final encryptedContent = EncryptionService.simpleEncrypt(jsonString, _encryptionKey!);
      final newVersion = cloudVersion + 1;
      
      print('Uploading ${finalAccountsData.length} accounts to cloud...');
      final uploadResponse = await _dio.post('sync/sync/', data: {
        'data_type': 'otp_accounts',
        'encrypted_content': encryptedContent,
        'version': newVersion,
        'device_id': deviceId,
      });
      
      if (uploadResponse.statusCode == 200) {
        print('Sync successful - ${finalAccountsData.length} accounts synced');
        return true;
      } else {
        print('Sync upload failed: ${uploadResponse.statusCode}');
        return false;
      }
      
    } on DioError catch (e) {
      print('Sync error: ${e.message}');
      if (e.response?.data != null) {
        print('Response: ${e.response?.data}');
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
    await prefs.remove('user_email');
    await prefs.remove('user_id');
    _encryptionKey = null;
    _dio.options.headers.remove('Authorization');
    
    print('Logged out successfully');
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
        'auth/change_password/',
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

  Future<Box<OTPAccount>> getUserBox() async {
    return await _getUserBox();
  }

  Future<String> getCurrentUserBoxName() async {
    return await _getUserBoxName();
  }

  
}