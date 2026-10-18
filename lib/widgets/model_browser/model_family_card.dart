import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../l10n/app_localizations.dart';
import '../../models/pickable_model.dart';

/// One model family (Qwen, Google, Mistral…) in the grouped on-device list.
/// Tapping opens the family's models on their own screen.
class ModelFamilyCard extends StatelessWidget {
  final String family;

  /// Bold first line; defaults to [family]. On-device: the model line
  /// ("Gemma 4"), with the company in [subtitle].
  final String? title;
  final Widget? leading;
  final String? subtitle;
  final List<PickableModel> models;
  final VoidCallback onTap;

  const ModelFamilyCard({
    super.key,
    required this.family,
    required this.models,
    required this.onTap,
    this.title,
    this.leading,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final onDevice = models.where((m) => m.statusKey == 'downloaded').length;
    final recommended = models.any((m) => m.isRecommended);
    final sizes = models
        .map((m) => m.sizeLabel)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort((a, b) => _sizeMb(a).compareTo(_sizeMb(b)));
    final sizeHint = sizes.isEmpty
        ? null
        : sizes.length == 1
            ? sizes.first
            : '${sizes.first} – ${sizes.last}';

    return Material(
      color: isDark ? cs.surfaceContainerHigh : cs.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: leading ?? BrandLogo.monogram(context, family),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title ?? family,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle ?? l10n.aiModelsCount(models.length),
                      style: TextStyle(
                        fontSize: 13,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                    if (sizeHint != null || onDevice > 0 || recommended) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (sizeHint != null)
                            Text(
                              sizeHint,
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    cs.onSurfaceVariant.withValues(alpha: 0.85),
                              ),
                            ),
                          if (onDevice > 0)
                            _Tag(
                              label: l10n.modelFamilyOnDevice(onDevice),
                              color: const Color(0xFF00B894),
                            ),
                          if (recommended)
                            _Tag(
                              label: l10n.modelRecommended,
                              color: cs.primary,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: cs.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// "1.2 GB" / "500 MB" → MB, for sorting the size range small → large.
double _sizeMb(String label) {
  final m = RegExp(r'([\d.]+)\s*(GB|MB)').firstMatch(label);
  if (m == null) return 0;
  final v = double.tryParse(m.group(1)!) ?? 0;
  return m.group(2) == 'GB' ? v * 1024 : v;
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

/// Brand logos for model families (assets/icons/brands, from LobeHub's
/// MIT-licensed icon set). Families without a logo get a letter badge.
class BrandLogo {
  BrandLogo._();

  /// Single-color logos follow the text color; the rest keep their colors.
  static const _monochrome = {
    'apple.svg',
    'ibm.svg',
    'liquid.svg',
    'prismml.png',
  };

  static Widget forAsset(BuildContext context, String? file, String family) {
    if (file == null) return monogram(context, family);
    final mono = _monochrome.contains(file);
    if (file.endsWith('.png')) {
      return Image.asset(
        'assets/icons/brands/$file',
        color: mono ? Theme.of(context).colorScheme.onSurface : null,
        colorBlendMode: mono ? BlendMode.srcIn : null,
        errorBuilder: (_, __, ___) => monogram(context, family),
      );
    }
    return SvgPicture.asset(
      'assets/icons/brands/$file',
      colorFilter: mono
          ? ColorFilter.mode(
              Theme.of(context).colorScheme.onSurface,
              BlendMode.srcIn,
            )
          : null,
      placeholderBuilder: (_) => monogram(context, family),
    );
  }

  static Widget monogram(BuildContext context, String family) {
    final cs = Theme.of(context).colorScheme;
    final letter = family.isEmpty ? '?' : family.characters.first.toUpperCase();
    return FittedBox(
      child: Text(
        letter,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: cs.primary,
          fontSize: 20,
        ),
      ),
    );
  }
}
