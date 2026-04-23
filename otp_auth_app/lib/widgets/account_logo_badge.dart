import 'package:flutter/material.dart';

class AccountLogoBadge extends StatelessWidget {
  const AccountLogoBadge({
    super.key,
    required this.service,
    this.size = 44,
    this.iconSize = 22,
  });

  final String service;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final brand = _AccountBrandSpec.fromService(service);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: brand.backgroundColor,
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      alignment: Alignment.center,
      child: brand.text != null
          ? Text(
              brand.text!,
              style: TextStyle(
                color: brand.foregroundColor,
                fontSize: iconSize * 0.84,
                fontWeight: FontWeight.w800,
                letterSpacing: brand.text!.length > 1 ? -0.6 : 0,
              ),
            )
          : Icon(
              brand.icon,
              color: brand.foregroundColor,
              size: iconSize,
            ),
    );
  }
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

  factory _AccountBrandSpec.fromService(String service) {
    final lower = service.trim().toLowerCase();

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
      return const _AccountBrandSpec(
        backgroundColor: Color(0xFFEDE9FE),
        foregroundColor: Color(0xFF4F46E5),
        icon: Icons.lock_rounded,
      );
    }

    return _AccountBrandSpec(
      backgroundColor: const Color(0xFFEDE9FE),
      foregroundColor: const Color(0xFF4F46E5),
      text: service.trim().substring(0, 1).toUpperCase(),
    );
  }
}
