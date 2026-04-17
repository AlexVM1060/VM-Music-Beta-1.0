import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';

class QueueSwipeActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color baseColor;
  final VoidCallback onTap;

  const QueueSwipeActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.baseColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fillTop = Color.lerp(baseColor, Colors.white, isDark ? 0.10 : 0.34)!;
    final fillBottom = Color.lerp(
      baseColor,
      Colors.black,
      isDark ? 0.08 : 0.06,
    )!;
    return CustomSlidableAction(
      onPressed: (_) => onTap(),
      backgroundColor: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [fillTop, fillBottom],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isDark ? 0.20 : 0.46),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: baseColor.withValues(alpha: isDark ? 0.34 : 0.22),
              blurRadius: 12,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: CupertinoColors.white, size: 19),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: '.SF Pro Text',
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: CupertinoColors.white,
                letterSpacing: -0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
