import 'package:hive/hive.dart';

part 'password_entry.g.dart';

@HiveType(typeId: 1)
class PasswordEntry {
  @HiveField(0)
  String id;
  
  @HiveField(1)
  String title;
  
  @HiveField(2)
  String username;
  
  @HiveField(3)
  String password;
  
  @HiveField(4)
  String? serverIP;
  
  @HiveField(5)
  DateTime createdAt;
  
  PasswordEntry({
    required this.id,
    required this.title,
    required this.username,
    required this.password,
    this.serverIP,
    required this.createdAt,
  });
}