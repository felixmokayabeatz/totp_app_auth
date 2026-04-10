import 'package:flutter/material.dart';

class AuthProvider extends ChangeNotifier {
  bool _isAuthenticated = false;
  String? _userEmail;
  
  bool get isAuthenticated => _isAuthenticated;
  String? get userEmail => _userEmail;
  
  Future<void> login(String email, String password) async {
    // DEMO MODE - Accept any credentials
    await Future.delayed(Duration(seconds: 1));
    _isAuthenticated = true;
    _userEmail = email;
    notifyListeners();
  }
  
  Future<void> logout() async {
    _isAuthenticated = false;
    _userEmail = null;
    notifyListeners();
  }
}