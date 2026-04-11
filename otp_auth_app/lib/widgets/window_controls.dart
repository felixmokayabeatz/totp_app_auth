import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class WindowControls extends StatelessWidget {
  final bool isDark;
  
  const WindowControls({required this.isDark});
  
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          icon: Icon(Icons.minimize, size: 18),
          color: isDark ? Colors.white70 : Color(0xFF667eea),
          onPressed: () => windowManager.minimize(),
          tooltip: 'Minimize',
        ),
        IconButton(
          icon: Icon(Icons.crop_square, size: 16),
          color: isDark ? Colors.white70 : Color(0xFF667eea),
          onPressed: () => windowManager.maximize(),
          tooltip: 'Maximize',
        ),
        IconButton(
          icon: Icon(Icons.close, size: 18),
          color: Colors.red,
          onPressed: () => _confirmClose(context),
          tooltip: 'Close',
        ),
      ],
    );
  }
  
  void _confirmClose(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Exit App'),
        content: Text('Are you sure you want to exit?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('Exit', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await windowManager.close();
    }
  }
}