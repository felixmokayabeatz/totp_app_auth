// onboarding_screen.dart

import 'package:flutter/material.dart';
import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  final bool isFirstLaunch;

  const OnboardingScreen({Key? key, required this.isFirstLaunch})
      : super(key: key);

  @override
  _OnboardingScreenState createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen>
    with TickerProviderStateMixin {
  late PageController _pageController;
  int _currentPage = 0;

  // Full onboarding for first-time users
  final List<OnboardingData> _fullPages = [
    OnboardingData(
      title: 'BeatzLock Authenticator',
      subtitle: 'Secure 2FA Codes',
      description:
          'Store and manage your two-factor authentication codes securely with military-grade encryption',
      icon: Icons.security,
      gradientColors: [Color(0xFF667eea), Color(0xFF764ba2)],
      isNewUser: true,
    ),
    OnboardingData(
      title: 'Cloud Sync',
      subtitle: 'Never Lose Access',
      description:
          'Sync your codes across all your devices with end-to-end encryption. Never lose access again.',
      icon: Icons.cloud_sync,
      gradientColors: [Color(0xFF00b4db), Color(0xFF0083b0)],
      isNewUser: true,
    ),
    OnboardingData(
      title: 'QR Scanner',
      subtitle: 'Quick Setup',
      description:
          'Quickly add new accounts by scanning QR codes. Fast, secure, and hassle-free setup.',
      icon: Icons.qr_code_scanner,
      gradientColors: [Color(0xFF11998e), Color(0xFF38ef7d)],
      isNewUser: true,
    ),
    OnboardingData(
      title: 'Get Started',
      subtitle: 'Join BeatzLock',
      description:
          'Create an account or login to start securing your 2FA codes',
      icon: Icons.rocket_launch,
      gradientColors: [Color(0xFFf12711), Color(0xFFf5af19)],
      isNewUser: true,
    ),
  ];

  // Simplified onboarding for returning/logged out users
  final List<OnboardingData> _returningPages = [
    OnboardingData(
      title: 'Welcome Back to',
      subtitle: 'BeatzLock Authenticator',
      description:
          'Login to access your secure 2FA codes and continue protecting your accounts',
      icon: Icons.fingerprint,
      gradientColors: [Color(0xFF667eea), Color(0xFF764ba2)],
      isNewUser: false,
    ),
  ];

  List<OnboardingData> get _pages =>
      widget.isFirstLaunch ? _fullPages : _returningPages;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gradientColors = _currentGradientColors(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: gradientColors,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Only show skip button for first-time users on first pages
              if (widget.isFirstLaunch && _currentPage < _pages.length - 1)
                Padding(
                  padding: EdgeInsets.all(16),
                  child: Align(
                    alignment: Alignment.topRight,
                    child: TextButton(
                      onPressed: () {
                        _pageController.jumpToPage(_pages.length - 1);
                      },
                      child: Text(
                        'Skip',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ),

              Expanded(
                child: PageView.builder(
                  controller: _pageController,
                  onPageChanged: (index) {
                    setState(() {
                      _currentPage = index;
                    });
                  },
                  itemCount: _pages.length,
                  itemBuilder: (context, index) {
                    return OnboardingPage(
                      data: _pages[index],
                      isLastPage: index == _pages.length - 1,
                    );
                  },
                ),
              ),

              _buildBottomBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    final gradientColors = _currentGradientColors(context);

    return Container(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          // Page indicators (only for first-time users with multiple pages)
          if (widget.isFirstLaunch && _pages.length > 1)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _pages.length,
                (index) => AnimatedContainer(
                  duration: Duration(milliseconds: 300),
                  margin: EdgeInsets.symmetric(horizontal: 6),
                  width: _currentPage == index ? 32 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _currentPage == index
                        ? Colors.white
                        : Colors.white.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),

          SizedBox(height: 32),

          // Next/Login button
          AnimatedSwitcher(
            duration: Duration(milliseconds: 300),
            child: ElevatedButton(
              key: ValueKey(_currentPage),
              onPressed: () {
                if (_currentPage == _pages.length - 1) {
                  // Last page - go to login
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (_) => LoginScreen()),
                  );
                } else {
                  _pageController.nextPage(
                    duration: Duration(milliseconds: 500),
                    curve: Curves.easeInOutCubic,
                  );
                }
              },
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                child: Text(
                  _currentPage == _pages.length - 1
                      ? (widget.isFirstLaunch
                          ? 'Get Started'
                          : 'Continue to Login')
                      : 'Next',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              style: ElevatedButton.styleFrom(
                minimumSize: Size(200, 50),
                backgroundColor: Colors.white,
                foregroundColor: gradientColors[0],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25),
                ),
                elevation: 5,
              ),
            ),
          ),

          SizedBox(height: 16),

          // Register link for returning users (instead of "Already have an account? Login")
          if (!widget.isFirstLaunch)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  "Don't have an account? ",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    // Navigate to register (which is login screen with isLogin = false)
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => LoginScreen()),
                    );
                  },
                  child: Text(
                    'Register',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  List<Color> _currentGradientColors(BuildContext context) {
    if (_currentPage == 0 || !widget.isFirstLaunch) {
      final colorScheme = Theme.of(context).colorScheme;
      return [colorScheme.primary, colorScheme.secondary];
    }

    return _pages[_currentPage].gradientColors;
  }
}

class OnboardingData {
  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
  final List<Color> gradientColors;
  final bool isNewUser;

  OnboardingData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.gradientColors,
    required this.isNewUser,
  });
}

class OnboardingPage extends StatelessWidget {
  final OnboardingData data;
  final bool isLastPage;

  const OnboardingPage({required this.data, this.isLastPage = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder(
            tween: Tween<double>(begin: 0, end: 1),
            duration: Duration(milliseconds: 800),
            builder: (context, double value, child) {
              return Transform.scale(
                scale: value,
                child: Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withOpacity(0.3),
                        Colors.white.withOpacity(0.1),
                      ],
                    ),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.2),
                        blurRadius: 20,
                        spreadRadius: 5,
                      ),
                    ],
                  ),
                  child: Icon(
                    data.icon,
                    size: 70,
                    color: Colors.white,
                  ),
                ),
              );
            },
          ),

          SizedBox(height: 40),

          // Title with BeatzLock branding
          Text(
            data.title,
            style: TextStyle(
              fontSize: data.isNewUser ? 32 : 28,
              fontWeight: FontWeight.bold,
              color: Colors.white,
              letterSpacing: 1,
            ),
            textAlign: TextAlign.center,
          ),

          SizedBox(height: 8),

          // Subtitle
          Text(
            data.subtitle,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white70,
              letterSpacing: 0.5,
            ),
            textAlign: TextAlign.center,
          ),

          SizedBox(height: 20),

          // Description
          Text(
            data.description,
            style: TextStyle(
              fontSize: 15,
              color: Colors.white70,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),

          if (isLastPage && data.isNewUser) ...[
            SizedBox(height: 30),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    '100% Free & Secure',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
