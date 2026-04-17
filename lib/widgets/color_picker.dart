import 'package:flutter/material.dart';

/// Colour swatches offered to the user. `null` means "use theme default".
const List<int?> kChatPalette = [
  null,
  // Light
  0xFFFFFFFF, // White
  0xFFF5F5F5, // Light grey
  0xFFECEFF1, // Blue-grey 50
  0xFFE3F2FD, // Blue 50
  0xFFE8F5E9, // Green 50
  0xFFFCE4EC, // Pink 50
  0xFFFFF8E1, // Amber 50
  0xFFEDE7F6, // Deep Purple 50
  0xFFE0F7FA, // Cyan 50
  // Dark
  0xFF263238, // Blue-grey 900
  0xFF1A237E, // Indigo 900
  0xFF1B5E20, // Green 900
  0xFF4A148C, // Deep Purple 900
  0xFF37474F, // Blue-grey 800
  0xFF212121, // Grey 900
];

/// Returns a legible foreground colour for [bg].
Color onColor(Color bg) =>
    bg.computeLuminance() > 0.45 ? Colors.black87 : Colors.white;

/// A wrap of circular colour swatches.
class ColorGrid extends StatelessWidget {
  final int? current;
  final ValueChanged<int?> onPick;
  final double swatchSize;

  const ColorGrid({
    super.key,
    required this.current,
    required this.onPick,
    this.swatchSize = 44,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: kChatPalette.map((value) {
        final isSelected = value == current;
        final isDefault = value == null;
        final bg = value == null ? cs.surfaceContainerHigh : Color(value);
        return GestureDetector(
          onTap: () => onPick(value),
          child: Container(
            width: swatchSize,
            height: swatchSize,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? cs.primary : cs.outlineVariant,
                width: isSelected ? 3 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: isDefault
                ? Icon(Icons.format_color_reset_rounded,
                    size: swatchSize * 0.42, color: cs.onSurfaceVariant)
                : isSelected
                    ? Icon(Icons.check_rounded,
                        size: swatchSize * 0.42, color: onColor(bg))
                    : null,
          ),
        );
      }).toList(),
    );
  }
}

/// Opens an [AlertDialog] with a [ColorGrid].
Future<void> showColorPickerDialog({
  required BuildContext context,
  required String title,
  required int? current,
  required ValueChanged<int?> onPick,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: ColorGrid(
          current: current,
          onPick: (c) {
            onPick(c);
            Navigator.pop(ctx);
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
