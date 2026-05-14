import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Colors, Theme, ThemeData;

class AppCircleOutlineIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Widget child;
  final double size;
  final bool forceWhiteIcon;

  const AppCircleOutlineIconButton({
    super.key,
    this.onPressed,
    required this.child,
    this.size = 40,
    this.forceWhiteIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = Theme.of(context).scaffoldBackgroundColor;
    final isLightBackground =
        ThemeData.estimateBrightnessForColor(bgColor) == Brightness.light;
    final iconColor = forceWhiteIcon
        ? Colors.white
        : (isLightBackground ? Colors.black : Colors.white);
    final borderColor = iconColor.withValues(
      alpha: onPressed == null ? 0.2 : 0.35,
    );

    return CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: Size(size, size),
      onPressed: onPressed,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: borderColor, width: 1.4),
          color: CupertinoColors.transparent,
        ),
        alignment: Alignment.center,
        child: IconTheme(
          data: IconThemeData(color: iconColor, size: 21),
          child: child,
        ),
      ),
    );
  }
}

class AppBackCircleButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool forceWhiteIcon;

  const AppBackCircleButton({
    super.key,
    this.onPressed,
    this.forceWhiteIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return AppCircleOutlineIconButton(
      onPressed: onPressed,
      forceWhiteIcon: forceWhiteIcon,
      child: const Icon(CupertinoIcons.back),
    );
  }
}
