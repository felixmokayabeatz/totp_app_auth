// profile_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../services/profile_service.dart';
import '../services/secure_storage_service.dart';
import '../config/app_config.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  final ProfileService _profileService = ProfileService();

  File? _profileImage;
  String? _profileImageUrl;
  String _bio = '';
  bool _isLoading = true;
  bool _isUploading = false;
  String _userEmail = '';
  DateTime? _joinedOn;
  final TextEditingController _bioController = TextEditingController();
  Color get _accent => Theme.of(context).colorScheme.primary;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 500),
    );
    _animationController.forward();
    _loadUserData();
    _loadProfile();
  }

  Future<void> _loadUserData() async {
    final secureStorage = SecureStorageService();
    setState(() {
      _userEmail = 'No email';
    });
    final email = await secureStorage.read(SecureStorageService.userEmailKey) ??
        'No email';
    if (!mounted) return;
    setState(() {
      _userEmail = email;
    });
  }

  Future<void> _loadProfile() async {
    setState(() {
      _isLoading = true;
    });

    final profile = await _profileService.getProfile();
    if (!mounted) return;

    if (profile != null) {
      setState(() {
        _profileImageUrl = profile['profile']?['profile_photo'];
        _bio = profile['profile']?['bio'] ?? '';
        _joinedOn = DateTime.tryParse(profile['joined_on']?.toString() ?? '');
        _bioController.text = _bio;
        _isLoading = false;
      });
    } else {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      if (image != null) {
        if (!mounted) return;
        setState(() {
          _profileImage = File(image.path);
        });

        await _uploadProfilePhoto();
      }
    } catch (e) {
      debugPrint('Image picker error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Select a file to upload'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _uploadProfilePhoto() async {
    if (_profileImage == null) return;

    setState(() {
      _isUploading = true;
    });

    final success = await _profileService.updateProfilePhoto(_profileImage!);
    if (!mounted) return;

    setState(() {
      _isUploading = false;
    });

    if (success) {
      await _loadProfile();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Profile photo updated!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update photo'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _updateBio() async {
    if (_bioController.text == _bio) {
      Navigator.pop(context);
      return;
    }

    setState(() {
      _isUploading = true;
    });

    final success = await _profileService.updateBio(_bioController.text);
    if (!mounted) return;

    setState(() {
      _isUploading = false;
    });

    if (success) {
      setState(() {
        _bio = _bioController.text;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Bio updated!'),
          backgroundColor: Colors.green,
          behavior: SnackBarBehavior.floating,
        ),
      );
      if (!mounted) return;
      Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to update bio'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showEditBioDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('Edit Bio'),
        content: TextField(
          controller: _bioController,
          maxLines: 3,
          decoration: InputDecoration(
            hintText: 'Tell something about yourself...',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: _updateBio,
            style: ElevatedButton.styleFrom(
              backgroundColor: _accent,
              foregroundColor: Colors.white,
            ),
            child: Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatJoinedOn(DateTime dateTime) {
    const monthNames = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    // joined_on is a real timestamp from the API (date_joined), so it carries
    // a time; toLocal turns the server's UTC into whatever this device is set
    // to before any of it is read.
    final local = dateTime.toLocal();
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${monthNames[local.month - 1]} ${local.day}, ${local.year} '
        'at $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Profile',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: _accent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _isLoading
          ? Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(_accent),
              ),
            )
          : SingleChildScrollView(
              child: Column(
                children: [
                  // Profile Photo Section
                  Container(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Stack(
                          children: [
                            // Profile Image
                            Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  // Follows the chosen accent instead of a
                                  // fixed purple, which stayed purple no
                                  // matter which colour was picked.
                                  colors: [
                                    _accent,
                                    Theme.of(context).colorScheme.secondary,
                                  ],
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.2),
                                    blurRadius: 20,
                                    offset: Offset(0, 10),
                                  ),
                                ],
                              ),
                              child: ClipOval(
                                child: _profileImage != null
                                    ? Image.file(
                                        _profileImage!,
                                        fit: BoxFit.cover,
                                        width: 120,
                                        height: 120,
                                      )
                                    : (_profileImageUrl != null &&
                                            _profileImageUrl!.isNotEmpty
                                        ? Image.network(
                                            '${AppConfig.mediaUrl}${_profileImageUrl!.replaceFirst('/media/', '')}',
                                            fit: BoxFit.cover,
                                            width: 120,
                                            height: 120,
                                            errorBuilder:
                                                (context, error, stackTrace) {
                                              return Icon(
                                                Icons.person,
                                                size: 50,
                                                color: Colors.white,
                                              );
                                            },
                                          )
                                        : Icon(
                                            Icons.person,
                                            size: 50,
                                            color: Colors.white,
                                          )),
                              ),
                            ),
                            // Edit Button
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: InkWell(
                                onTap: _pickImage,
                                borderRadius: BorderRadius.circular(20),
                                child: Container(
                                  padding: EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: _accent,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.white,
                                      width: 2,
                                    ),
                                  ),
                                  child: _isUploading
                                      ? SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Icon(
                                          Icons.camera_alt,
                                          size: 16,
                                          color: Colors.white,
                                        ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 16),
                        Text(
                          _userEmail,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: isDark ? Colors.white : Color(0xFF1A1A2E),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Bio Section
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Bio',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color:
                                    isDark ? Colors.white : Color(0xFF1A1A2E),
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.edit, size: 18),
                              color: _accent,
                              onPressed: _showEditBioDialog,
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                        Text(
                          _bio.isEmpty
                              ? 'No bio yet. Tap edit to add one.'
                              : _bio,
                          style: TextStyle(
                            fontSize: 14,
                            color: _bio.isEmpty
                                ? (isDark ? Colors.white38 : Colors.grey[500])
                                : (isDark ? Colors.white70 : Colors.grey[700]),
                            fontStyle: _bio.isEmpty
                                ? FontStyle.italic
                                : FontStyle.normal,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Account Info Section
                  Container(
                    margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    padding: EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Account Information',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: isDark ? Colors.white : Color(0xFF1A1A2E),
                          ),
                        ),
                        SizedBox(height: 12),
                        _infoRow(Icons.email, 'Email', _userEmail, isDark),
                        if (_joinedOn != null)
                          _infoRow(
                            Icons.event_rounded,
                            'Joined on',
                            _formatJoinedOn(_joinedOn!),
                            isDark,
                          ),
                        _infoRow(
                          Icons.security,
                          '2FA Status',
                          'Enabled',
                          isDark,
                        ),
                      ],
                    ),
                  ),

                  SizedBox(height: 30),
                ],
              ),
            ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value, bool isDark) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _accent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 16, color: _accent),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white60 : Colors.grey[600],
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isDark ? Colors.white : Color(0xFF1A1A2E),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    _bioController.dispose();
    super.dispose();
  }
}
