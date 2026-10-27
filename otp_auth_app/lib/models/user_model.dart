

class User {
  String id;
  String email;
  String username;
  String? profilePhotoUrl;
  String encryptionKey; 

  User({
    required this.id,
    required this.email,
    required this.username,
    this.profilePhotoUrl,
    required this.encryptionKey,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'username': username,
        'profile_photo_url': profilePhotoUrl,
        'encryption_key': encryptionKey,
      };

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'],
        email: json['email'],
        username: json['username'],
        profilePhotoUrl: json['profile_photo_url'],
        encryptionKey: json['encryption_key'],
      );
}
