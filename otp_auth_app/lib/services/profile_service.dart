import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ProfileService {
  final Dio _dio = Dio(BaseOptions(
    baseUrl: 'http://localhost:8000/api/',
  ));
  
  Future<Map<String, dynamic>?> getProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return null;
    
    _dio.options.headers['Authorization'] = 'Bearer $token';
    
    try {
      final response = await _dio.get('profile/my_profile/');
      return response.data;
    } catch (e) {
      print('Get profile error: $e');
      return null;
    }
  }
  
  Future<bool> updateProfilePhoto(String imagePath) async {
    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('access_token');
    if (token == null) return false;
    
    _dio.options.headers['Authorization'] = 'Bearer $token';
    
    try {
      FormData formData = FormData.fromMap({
        'profile_photo': await MultipartFile.fromFile(imagePath),
      });
      
      final response = await _dio.post('profile/update_profile/', data: formData);
      return response.statusCode == 200;
    } catch (e) {
      print('Update photo error: $e');
      return false;
    }
  }
}