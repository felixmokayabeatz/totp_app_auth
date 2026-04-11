import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/otp_account.dart';
import 'encryption_service.dart';

class MigrationService {
  static Future<void> migrateOldAccounts() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = prefs.getString('current_user');
    if (userId == null) return;
    
    final otpBox = Hive.box<OTPAccount>('otp_accounts');
    bool needsMigration = false;
    
    for (var account in otpBox.values) {
      // Check if secret is not encrypted (simple heuristic)
      if (account.encryptedSecret.isNotEmpty && 
          !account.encryptedSecret.contains('=') && 
          account.encryptedSecret.length < 50) {
        // This is likely plain text, migrate it
        final plainSecret = account.encryptedSecret;
        account.setSecret(plainSecret, userId);
        await account.save();
        needsMigration = true;
      }
    }
    
    if (needsMigration) {
      print('Migrated old accounts to encrypted format');
    }
  }
}