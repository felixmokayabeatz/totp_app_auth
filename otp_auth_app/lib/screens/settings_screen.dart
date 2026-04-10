import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/theme_provider.dart';
import 'login_screen.dart';

class SettingsScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: Text('Dark Mode'),
            value: Provider.of<ThemeProvider>(context).isDarkMode,
            onChanged: (_) => Provider.of<ThemeProvider>(context, listen: false).toggleTheme(),
          ),
          ListTile(
            title: Text('Export Accounts'),
            onTap: () {},
          ),
          ListTile(
            title: Text('Import Accounts'),
            onTap: () {},
          ),
          ListTile(
            title: Text('Logout', style: TextStyle(color: Colors.red)),
            onTap: () async {
              await Provider.of<AuthProvider>(context, listen: false).logout();
              Navigator.pushAndRemoveUntil(context,
                MaterialPageRoute(builder: (_) => LoginScreen()),
                (route) => false);
            },
          ),
        ],
      ),
    );
  }
}