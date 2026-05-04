import 'package:flutter/material.dart';

import 'login_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.isFirstLaunch,
    this.onFinished,
  });

  final bool isFirstLaunch;
  final Future<void> Function()? onFinished;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final PageController _pageController;
  int _currentPage = 0;
  bool _isFinishing = false;

  final List<OnboardingData> _fullPages = [
    const OnboardingData(
      title: 'Offline-First Security',
      subtitle: 'Use BeatzLock without an account',
      description:
          'BeatzLock works offline first, so your 2FA codes stay on this device from the start. Sign in only when you want backup and sync across devices.',
      icon: Icons.security,
      gradientColors: [Color(0xFF667eea), Color(0xFF764ba2)],
      isNewUser: true,
    ),
    const OnboardingData(
      title: 'Cloud Sync',
      subtitle: 'Backup when you want it',
      description:
          'Sign in whenever you want end-to-end encrypted backup and sync across your devices, without changing how your local vault works.',
      icon: Icons.cloud_sync,
      gradientColors: [Color(0xFF00b4db), Color(0xFF0083b0)],
      isNewUser: true,
    ),
    const OnboardingData(
      title: 'QR Scanner',
      subtitle: 'Quick Setup',
      description:
          'Quickly add new accounts by scanning QR codes. Fast, secure, and hassle-free setup.',
      icon: Icons.qr_code_scanner,
      gradientColors: [Color(0xFF11998e), Color(0xFF38ef7d)],
      isNewUser: true,
    ),
    const OnboardingData(
      title: 'Get Started',
      subtitle: 'Your vault is ready',
      description:
          'Add codes now and keep using BeatzLock offline, or sign in later when you want cross-platform sync.',
      icon: Icons.rocket_launch,
      gradientColors: [Color(0xFFf12711), Color(0xFFf5af19)],
      isNewUser: true,
    ),
  ];

  final List<OnboardingData> _returningPages = [
    const OnboardingData(
      title: 'Welcome Back to',
      subtitle: 'BeatzLock Authenticator',
      description:
          'Login to access your secure 2FA codes and continue protecting your accounts.',
      icon: Icons.fingerprint,
      gradientColors: [Color(0xFF667eea), Color(0xFF764ba2)],
      isNewUser: false,
    ),
  ];

  List<OnboardingData> get _pages =>
      widget.isFirstLaunch ? _fullPages : _returningPages;

  bool get _isLastPage => _currentPage == _pages.length - 1;

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

  Future<void> _goToPage(int page) async {
    if (!_pageController.hasClients || page == _currentPage) return;
    await _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeInOutCubic,
    );
  }

  Future<void> _handlePrimaryAction() async {
    if (_isLastPage) {
      await _finishOnboarding();
      return;
    }
    await _goToPage(_currentPage + 1);
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    if (_currentPage > 0)
                      TextButton.icon(
                        onPressed:
                            _isFinishing ? null : () => _goToPage(_currentPage - 1),
                        icon: const Icon(
                          Icons.arrow_back_rounded,
                          color: Colors.white,
                        ),
                        label: const Text(
                          'Back',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 84),
                    const Spacer(),
                    if (widget.isFirstLaunch && !_isLastPage)
                      TextButton(
                        onPressed:
                            _isFinishing ? null : () => _goToPage(_pages.length - 1),
                        child: const Text(
                          'Skip',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
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
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      child: Column(
        children: [
          if (widget.isFirstLaunch && _pages.length > 1)
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 12,
              children: List.generate(
                _pages.length,
                (index) => InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: _isFinishing ? null : () => _goToPage(index),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(vertical: 4),
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
            ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Row(
              children: [
                Expanded(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _currentPage > 0 ? 1 : 0,
                    child: IgnorePointer(
                      ignoring: _currentPage == 0 || _isFinishing,
                      child: OutlinedButton(
                        onPressed: () => _goToPage(_currentPage - 1),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          side: const BorderSide(color: Colors.white70),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(26),
                          ),
                        ),
                        child: const Text(
                          'Back',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _isFinishing ? null : _handlePrimaryAction,
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(0, 52),
                      backgroundColor: Colors.white,
                      foregroundColor: gradientColors.first,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(26),
                      ),
                      elevation: 5,
                    ),
                    child: Text(
                      _isFinishing
                          ? 'Starting...'
                          : _isLastPage
                              ? (widget.isFirstLaunch
                                  ? 'Start Using BeatzLock'
                                  : 'Continue to Login')
                              : 'Next',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (!widget.isFirstLaunch)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "Don't have an account? ",
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(builder: (_) => LoginScreen()),
                    );
                  },
                  child: const Text(
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
    final colorScheme = Theme.of(context).colorScheme;
    return [colorScheme.primary, colorScheme.secondary];
  }

  Future<void> _finishOnboarding() async {
    if (widget.onFinished != null) {
      setState(() => _isFinishing = true);
      try {
        await widget.onFinished!();
      } finally {
        if (mounted) {
          setState(() => _isFinishing = false);
        }
      }
      return;
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => LoginScreen()),
    );
  }
}

class OnboardingData {
  const OnboardingData({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.icon,
    required this.gradientColors,
    required this.isNewUser,
  });

  final String title;
  final String subtitle;
  final String description;
  final IconData icon;
  final List<Color> gradientColors;
  final bool isNewUser;
}

class OnboardingPage extends StatelessWidget {
  const OnboardingPage({
    super.key,
    required this.data,
    this.isLastPage = false,
  });

  final OnboardingData data;
  final bool isLastPage;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 900;

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight - 36),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: 1),
                      duration: const Duration(milliseconds: 800),
                      builder: (context, value, child) {
                        return Transform.scale(
                          scale: value,
                          child: Container(
                            width: isWide ? 160 : 140,
                            height: isWide ? 160 : 140,
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
                              size: isWide ? 76 : 70,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 40),
                    Text(
                      data.title,
                      style: TextStyle(
                        fontSize: data.isNewUser ? (isWide ? 38 : 32) : 28,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      data.subtitle,
                      style: TextStyle(
                        fontSize: isWide ? 18 : 16,
                        fontWeight: FontWeight.w500,
                        color: Colors.white70,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      data.description,
                      style: TextStyle(
                        fontSize: isWide ? 17 : 15,
                        color: Colors.white70,
                        height: 1.6,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    if (isLastPage && data.isNewUser) ...[
                      const SizedBox(height: 30),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(30),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.verified, color: Colors.white, size: 20),
                            SizedBox(width: 8),
                            Text(
                              '100% Free & Secure',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
