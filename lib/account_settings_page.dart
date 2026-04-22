import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Theme;
import 'package:myapp/main.dart' show ThemeProvider;
import 'package:myapp/apple_music_migration_page.dart';
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
    final themeProvider = context.watch<ThemeProvider?>();
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
        automaticBackgroundVisibility: !isDark,
        transitionBetweenRoutes: !isDark,
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
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Live Lyrics',
                      subtitle:
                          'Resalta la letra en tiempo real\nEsto podría consumir mas bateria',
                      value: settings.liveLyrics,
                      onChanged: (value) => settings.setLiveLyrics(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Reproductor YouTube Omni',
                      subtitle:
                          'Usa omni_video_player para reproducir contenido de YouTube\nÚtil si youtube_explode se limita temporalmente',
                      value: settings.useOmniYoutubePlayer,
                      onChanged: (value) =>
                          settings.setUseOmniYoutubePlayer(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'VM Music Sing',
                      subtitle:
                          'Activa modo karaoke con separación instrumental por IA\nSi está apagado, no se carga esa lógica para ahorrar recursos',
                      value: settings.vmMusicSingEnabled,
                      onChanged: (value) =>
                          settings.setVmMusicSingEnabled(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Carátula animada',
                      subtitle:
                          'Activa una animación natural con procesamiento IA en la carátula durante la reproducción',
                      value: settings.animatedCutoutCovers,
                      onChanged: (value) =>
                          settings.setAnimatedCutoutCovers(value),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildSectionTitle(context, 'Apariencia'),
                const SizedBox(height: 10),
                _GlassSection(
                  isDark: isDark,
                  children: [
                    _SettingSwitchRow(
                      title: 'Modo oscuro',
                      subtitle: 'Activa el tema oscuro en toda la app',
                      value: themeProvider?.isDarkMode ?? isDark,
                      onChanged: (value) => themeProvider?.setDarkMode(value),
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
                      subtitle: 'Transición suave entre canciones',
                      selected:
                          settings.transitionMode == TransitionMode.crossfade,
                      onTap: () =>
                          settings.setTransitionMode(TransitionMode.crossfade),
                    ),
                    const _SectionDivider(),
                    _SettingCheckRow(
                      title: 'AutoMix',
                      subtitle:
                          'Mezcla inteligente y más natural entre canciones\nEsto podría consumir mas bateria',
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
                      title: 'Modo ahorro de datos',
                      subtitle:
                          'Reduce resolución de video y carátulas, y limita cargas en segundo plano de YouTube',
                      value: settings.dataSaverMode,
                      onChanged: (value) => settings.setDataSaverMode(value),
                    ),
                    const _SectionDivider(),
                    _SettingSwitchRow(
                      title: 'Permitir contenido explícito',
                      value: settings.allowExplicitContent,
                      onChanged: (value) =>
                          settings.setAllowExplicitContent(value),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildSectionTitle(context, 'Integraciones'),
                const SizedBox(height: 10),
                _GlassSection(
                  isDark: isDark,
                  children: [
                    _SettingActionRow(
                      title: 'Migrar desde Apple Music',
                      subtitle:
                          'Conecta tu cuenta y elige qué playlists quieres importar',
                      trailing: const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                      ),
                      onTap: () {
                        Navigator.of(context).push(
                          CupertinoPageRoute<void>(
                            builder: (_) => const AppleMusicMigrationPage(),
                          ),
                        );
                      },
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
    final result = await showCupertinoModalPopup<AudioQualityPreference>(
      context: context,
      builder: (popupContext) {
        final isDark = Theme.of(popupContext).brightness == Brightness.dark;
        final panelColor = isDark
            ? const Color(0xFF151517)
            : const Color(0xFFF5F5F7);
        final cardColor = isDark
            ? const Color(0xFF1F1F22)
            : CupertinoColors.white;
        final primaryText = isDark
            ? const Color(0xFFF5F5F7)
            : const Color(0xFF111111);
        final secondaryText = isDark
            ? const Color(0xFFA1A1AA)
            : const Color(0xFF6B7280);
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  decoration: BoxDecoration(
                    color: panelColor,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 38,
                        height: 5,
                        decoration: BoxDecoration(
                          color: secondaryText.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Calidad de audio',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                          color: primaryText,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Elige el perfil de reproducción',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: secondaryText,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      const SizedBox(height: 12),
                      ...AudioQualityPreference.values.map((option) {
                        final selected = option == settings.audioQuality;
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                          child: CupertinoButton(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            ),
                            color: cardColor,
                            borderRadius: BorderRadius.circular(16),
                            onPressed: () =>
                                Navigator.of(popupContext).pop(option),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _audioQualityLabel(option),
                                    style: TextStyle(
                                      color: primaryText,
                                      fontSize: 16,
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      decoration: TextDecoration.none,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Icon(
                                  selected
                                      ? CupertinoIcons.check_mark_circled_solid
                                      : CupertinoIcons.circle,
                                  size: 20,
                                  color: selected
                                      ? CupertinoColors.activeBlue
                                      : secondaryText.withValues(alpha: 0.65),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                CupertinoButton(
                  color: panelColor,
                  borderRadius: BorderRadius.circular(18),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  onPressed: () => Navigator.of(popupContext).pop(),
                  child: Text(
                    'Cancelar',
                    style: TextStyle(
                      color: primaryText,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
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
