import 'package:flutter/material.dart';

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  String? _userEmail;
  String? _username;
  String? _userId;
  
  bool get isAuthenticated => _isAuthenticated;
  String? get userEmail => _userEmail;
  String? get username => _username;
  String? get userId => _userId;
  
  Future<void> setUserData(String username, String email, String id) async {
    _username = username;
    _userEmail = email;
    _userId = id;
    _isAuthenticated = true;
    notifyListeners();
  }
  
  Future<void> login(String email, String password) async {
    // This will be called after successful login from sync service
    _userEmail = email;
    _isAuthenticated = true;
    notifyListeners();
  }
  
  Future<void> updateProfile(String email, String username) async {
    _userEmail = email;
    _username = username;
    notifyListeners();
  }
  
  Future<void> logout() async {
    _isAuthenticated = false;
    _userEmail = null;
    _username = null;
    _userId = null;
    notifyListeners();
  }
}