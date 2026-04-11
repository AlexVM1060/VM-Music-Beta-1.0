import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:myapp/services/app_settings_service.dart';
import 'package:provider/provider.dart';

class AccountSettingsPage extends StatefulWidget {
  const AccountSettingsPage({super.key});

  @override
  State<AccountSettingsPage> createState() => _AccountSettingsPageState();
}

class _AccountSettingsPageState extends State<AccountSettingsPage> {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettingsService?>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);

    if (settings == null) {
      return const CupertinoPageScaffold(
        navigationBar: CupertinoNavigationBar(middle: Text('Configuración')),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Configuración no disponible. Haz Hot Restart para recargar proveedores.',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      );
    }

    final pageBackground = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final navBackground = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemGroupedBackground.resolveFrom(context);
    final bottomSafeInset = MediaQuery.of(context).padding.bottom;

    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(
          'Configuración',
          style: TextStyle(
            color: primaryTextColor,
            decoration: TextDecoration.none,
          ),
        ),
        backgroundColor: navBackground,
        border: null,
      ),
      child: ColoredBox(
        color: pageBackground,
        child: SafeArea(
          top: false,
          child: DefaultTextStyle.merge(
            style: const TextStyle(decoration: TextDecoration.none),
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                16,
                10,
                16,
                22 + bottomSafeInset + 24,
              ),
              children: [
                _buildSectionTitle(context, 'Reproducción'),
                const SizedBox(height: 10),
                _GlassSection(
                  isDark: isDark,
                  children: [
                    _SettingActionRow(
                      title: 'Calidad de audio',
                      subtitle: _audioQualityLabel(settings.audioQuality),
                      trailing: const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                      ),
                      onTap: () => _showAudioQualityPicker(context, settings),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Normalizar volumen',
                      subtitle:
                          'Mantiene el volumen equilibrado entre canciones',
                      value: settings.normalizeVolume,
                      onChanged: (value) => settings.setNormalizeVolume(value),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildSectionTitle(context, 'Modo de transición'),
                const SizedBox(height: 10),
                _GlassSection(
                  isDark: isDark,
                  children: [
                    _SettingCheckRow(
                      title: 'Desactivado',
                      subtitle: 'Sin transición entre canciones',
                      selected: settings.transitionMode == TransitionMode.off,
                      onTap: () =>
                          settings.setTransitionMode(TransitionMode.off),
                    ),
                    const _SectionDivider(),
                    _SettingCheckRow(
                      title: 'Crossfade',
                      subtitle: 'Transición suave estándar',
                      selected:
                          settings.transitionMode == TransitionMode.crossfade,
                      onTap: () =>
                          settings.setTransitionMode(TransitionMode.crossfade),
                    ),
                    const _SectionDivider(),
                    _SettingCheckRow(
                      title: 'Modo DJ',
                      subtitle:
                          'AutoMix inteligente con mezcla más natural entre canciones',
                      selected: settings.transitionMode == TransitionMode.dj,
                      onTap: () =>
                          settings.setTransitionMode(TransitionMode.dj),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildSectionTitle(context, 'Descargas y contenido'),
                const SizedBox(height: 10),
                _GlassSection(
                  isDark: isDark,
                  children: [
                    _SettingSwitchRow(
                      title: 'Descargar solo con Wi-Fi',
                      subtitle: 'Evita usar datos móviles en descargas',
                      value: settings.downloadOnlyOnWifi,
                      onChanged: (value) =>
                          settings.setDownloadOnlyOnWifi(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Permitir contenido explícito',
                      value: settings.allowExplicitContent,
                      onChanged: (value) =>
                          settings.setAllowExplicitContent(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Carátulas recortadas animadas',
                      subtitle:
                          'Activa el efecto de recorte y movimiento en la portada',
                      value: settings.animatedCutoutCovers,
                      onChanged: (value) =>
                          settings.setAnimatedCutoutCovers(value),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAudioQualityPicker(
    BuildContext context,
    AppSettingsService settings,
  ) async {
    final popupIsDark = Theme.of(context).brightness == Brightness.dark;
    final popupTextColor = popupIsDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);
    final result = await showCupertinoModalPopup<AudioQualityPreference>(
      context: context,
      builder: (popupContext) {
        return CupertinoActionSheet(
          title: Text(
            'Calidad de audio',
            style: TextStyle(
              color: popupTextColor,
              decoration: TextDecoration.none,
            ),
          ),
          actions: AudioQualityPreference.values
              .map((option) {
                final selected = option == settings.audioQuality;
                return CupertinoActionSheetAction(
                  onPressed: () => Navigator.of(popupContext).pop(option),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Flexible(
                        child: Text(
                          _audioQualityLabel(option),
                          style: TextStyle(
                            color: popupTextColor,
                            decoration: TextDecoration.none,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (selected) ...[
                        const SizedBox(width: 10),
                        const Icon(
                          CupertinoIcons.check_mark_circled_solid,
                          size: 18,
                          color: CupertinoColors.activeBlue,
                        ),
                      ],
                    ],
                  ),
                );
              })
              .toList(growable: false),
          cancelButton: CupertinoActionSheetAction(
            isDefaultAction: true,
            onPressed: () => Navigator.of(popupContext).pop(),
            child: Text(
              'Cancelar',
              style: TextStyle(
                color: popupTextColor,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        );
      },
    );
    if (result != null) {
      await settings.setAudioQuality(result);
    }
  }

  Widget _buildSectionTitle(BuildContext context, String label) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w700,
      color: isDark ? const Color(0xFF8E8E93) : const Color(0xFF8A8A8E),
      letterSpacing: 0.2,
      decoration: TextDecoration.none,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(label.toUpperCase(), style: textStyle),
    );
  }

  String _audioQualityLabel(AudioQualityPreference quality) {
    switch (quality) {
      case AudioQualityPreference.automatic:
        return 'Automática';
      case AudioQualityPreference.low:
        return 'Baja (96 kbps)';
      case AudioQualityPreference.normal:
        return 'Normal (160 kbps)';
      case AudioQualityPreference.high:
        return 'Alta (320 kbps)';
      case AudioQualityPreference.veryHigh:
        return 'Muy alta (mejor disponible)';
    }
  }
}

class _GlassSection extends StatelessWidget {
  final bool isDark;
  final List<Widget> children;

  const _GlassSection({required this.isDark, required this.children});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isDark
                ? const Color(0xFF121212)
                : CupertinoColors.systemBackground.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: isDark
                  ? const Color(0xFF2A2A2A)
                  : CupertinoColors.systemGrey5.resolveFrom(context),
              width: 0.9,
            ),
          ),
          child: Column(children: children),
        ),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  const _SectionDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(left: 16),
      height: 0.55,
      color: CupertinoColors.separator,
    );
  }
}

class _SettingActionRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SettingActionRow({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);
    final secondaryTextColor = isDark
        ? const Color(0xFFA1A1AA)
        : const Color(0xFF6B7280);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _SettingSwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SettingSwitchRow({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);
    final secondaryTextColor = isDark
        ? const Color(0xFFA1A1AA)
        : const Color(0xFF6B7280);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          CupertinoSwitch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SettingCheckRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _SettingCheckRow({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryTextColor = isDark
        ? const Color(0xFFF5F5F7)
        : const Color(0xFF111111);
    final secondaryTextColor = isDark
        ? const Color(0xFFA1A1AA)
        : const Color(0xFF6B7280);
    final inactiveCheckColor = isDark
        ? const Color(0xFF4A4A4A)
        : CupertinoColors.systemGrey3.resolveFrom(context);
    return CupertinoButton(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onPressed: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: primaryTextColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    decoration: TextDecoration.none,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: secondaryTextColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            selected
                ? CupertinoIcons.check_mark_circled_solid
                : CupertinoIcons.circle,
            color: selected ? CupertinoColors.activeBlue : inactiveCheckColor,
            size: 22,
          ),
        ],
      ),
    );
  }
}
