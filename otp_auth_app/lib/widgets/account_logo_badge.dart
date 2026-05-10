import 'package:flutter/material.dart';

class AccountLogoBadge extends StatelessWidget {
  const AccountLogoBadge({
    super.key,
    required this.service,
    this.issuer,
    this.size = 44,
    this.iconSize = 22,
  });

  final String service;
  final String? issuer;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final brand = _AccountBrandSpec.fromService(
      service,
      fallbackColor: Theme.of(context).colorScheme.primary,
    );
    final domain = _resolveLogoDomain(service, issuer);
    final useRemoteLogo = domain != null && _shouldUseRemoteLogo(domain);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: brand.backgroundColor,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: useRemoteLogo
          ? Padding(
              padding: EdgeInsets.all(size * 0.16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(size * 0.18),
                child: Image.network(
                  _faviconUrl(domain),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _fallbackContent(brand),
                ),
              ),
            )
          : _fallbackContent(brand),
    );
  }

  Widget _fallbackContent(_AccountBrandSpec brand) {
    if (brand.text != null) {
      return Text(
        brand.text!,
        style: TextStyle(
          color: brand.foregroundColor,
          fontSize: iconSize * 0.84,
          fontWeight: FontWeight.w800,
          letterSpacing: brand.text!.length > 1 ? -0.6 : 0,
        ),
      );
    }

    return Icon(
      brand.icon,
      color: brand.foregroundColor,
      size: iconSize,
    );
  }

  String? _resolveLogoDomain(String service, String? issuer) {
    final values = [service, if (issuer != null) issuer];
    for (final value in values) {
      final cleaned = value.trim().toLowerCase();
      if (cleaned.isEmpty) continue;

      final mapped = _knownDomains[cleaned];
      if (mapped != null) return mapped;

      if (cleaned.contains('@')) {
        final emailDomain = cleaned.split('@').last;
        if (emailDomain.contains('.')) return emailDomain;
      }

      final withoutProtocol = cleaned
          .replaceFirst('https://', '')
          .replaceFirst('http://', '')
          .replaceFirst('www.', '');
      final firstSegment = withoutProtocol.split('/').first;
      if (firstSegment.contains('.')) return firstSegment;

      for (final entry in _knownDomains.entries) {
        if (cleaned.contains(entry.key)) return entry.value;
      }
    }
    return null;
  }

  bool _shouldUseRemoteLogo(String domain) {
    final normalized = domain.trim().toLowerCase();
    if (normalized.isEmpty) return false;
    if (normalized == 'localhost') return false;
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(normalized)) {
      return false;
    }
    return _knownDomains.values.contains(normalized);
  }

  String _faviconUrl(String domain) {
    return 'https://www.google.com/s2/favicons?sz=128&domain_url=$domain';
  }

  static const Map<String, String> _knownDomains = {
    'google': 'google.com',
    'gmail': 'google.com',
    'github': 'github.com',
    'facebook': 'facebook.com',
    'x': 'x.com',
    'twitter': 'x.com',
    'x.com': 'x.com',
    'microsoft': 'microsoft.com',
    'outlook': 'outlook.com',
    'office': 'office.com',
    'apple': 'apple.com',
    'amazon': 'amazon.com',
    'aws': 'aws.amazon.com',
    'discord': 'discord.com',
    'slack': 'slack.com',
    'instagram': 'instagram.com',
    'linkedin': 'linkedin.com',
    'dropbox': 'dropbox.com',
    'tiktok': 'tiktok.com',
    'paypal': 'paypal.com',
    'reddit': 'reddit.com',
    'notion': 'notion.so',
    'cloudflare': 'cloudflare.com',
    'spotify': 'spotify.com',
    'netflix': 'netflix.com',
    'airbnb': 'airbnb.com',
    'uber': 'uber.com',
    'yahoo': 'yahoo.com',
    'proton': 'proton.me',
    'binance': 'binance.com',
    'coinbase': 'coinbase.com',
    'telegram': 'telegram.org',
  };
}

class _AccountBrandSpec {
  const _AccountBrandSpec({
    required this.backgroundColor,
    required this.foregroundColor,
    this.icon,
    this.text,
  });

  final Color backgroundColor;
  final Color foregroundColor;
  final IconData? icon;
  final String? text;

  factory _AccountBrandSpec.fromService(
    String service, {
    Color? fallbackColor,
  }) {
    final lower = service.trim().toLowerCase();
    final resolvedFallbackColor = fallbackColor ?? const Color(0xFF4F46E5);

    if (lower.contains('twitter') || lower == 'x' || lower.contains('x.com')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFF111111),
        foregroundColor: Colors.white,
        text: 'X',
      );
    }
    if (lower.contains('google') || lower.contains('gmail')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFE8F0FE),
        foregroundColor: Color(0xFF1A73E8),
        text: 'G',
      );
    }
    if (lower.contains('github')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFEEF2FF),
        foregroundColor: Color(0xFF24292F),
        icon: Icons.code_rounded,
      );
    }
    if (lower.contains('facebook')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFE7F0FF),
        foregroundColor: Color(0xFF1877F2),
        icon: Icons.facebook_rounded,
      );
    }
    if (lower.contains('microsoft') ||
        lower.contains('outlook') ||
        lower.contains('office')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFE8F2FF),
        foregroundColor: Color(0xFF2563EB),
        icon: Icons.window_rounded,
      );
    }
    if (lower.contains('apple')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFEFEFEF),
        foregroundColor: Color(0xFF111827),
        icon: Icons.apple_rounded,
      );
    }
    if (lower.contains('amazon') || lower.contains('aws')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFFFF1E8),
        foregroundColor: Color(0xFFEA580C),
        text: 'a',
      );
    }
    if (lower.contains('discord')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFEEF0FF),
        foregroundColor: Color(0xFF5865F2),
        icon: Icons.headset_mic_rounded,
      );
    }
    if (lower.contains('slack')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFF9E8FF),
        foregroundColor: Color(0xFF7C3AED),
        text: 'S',
      );
    }
    if (lower.contains('instagram')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFFFE7F1),
        foregroundColor: Color(0xFFE11D48),
        icon: Icons.camera_alt_rounded,
      );
    }
    if (lower.contains('linkedin')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFE6F4FF),
        foregroundColor: Color(0xFF0A66C2),
        text: 'in',
      );
    }
    if (lower.contains('dropbox')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFE6F0FF),
        foregroundColor: Color(0xFF2563EB),
        icon: Icons.inventory_2_rounded,
      );
    }
    if (lower.contains('tiktok')) {
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFFFE6EF),
        foregroundColor: Color(0xFF111111),
        icon: Icons.music_note_rounded,
      );
    }
    if (service.trim().isEmpty) {
      return _AccountBrandSpec(
        backgroundColor: resolvedFallbackColor.withValues(alpha: 0.12),
        foregroundColor: resolvedFallbackColor,
        icon: Icons.lock_rounded,
      );
    }

    return _AccountBrandSpec(
      backgroundColor: resolvedFallbackColor.withValues(alpha: 0.12),
      foregroundColor: resolvedFallbackColor,
      text: service.trim().substring(0, 1).toUpperCase(),
    );
  }
}
