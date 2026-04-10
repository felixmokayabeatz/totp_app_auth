import 'package:hive/hive.dart';

part 'otp_account.g.dart';

@HiveType(typeId: 0)
class OTPAccount {
  @HiveField(0)
  String id;
  
  @HiveField(1)
  String service;
  
  @HiveField(2)
  String secret;
  
  @HiveField(3)
  String? issuer;
  
  @HiveField(4)
  DateTime createdAt;
  
  OTPAccount({
    required this.id,
    required this.service,
    required this.secret,
    this.issuer,
    required this.createdAt,
  });
}