import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';
import '../services/apple_intelligence_endpoint.dart';

/// Apple's built-in model (Apple Intelligence) as a choice next to the
/// downloadable on-device models. Hidden where the OS says it can never run
/// (unsupported device / OS); shows a hint when it's only turned off or
/// still downloading.
class AppleIntelligenceCard extends StatefulWidget {
  /// Called after the user switched chat to Apple Intelligence.
  final VoidCallback? onActivated;

  const AppleIntelligenceCard({super.key, this.onActivated});

  /// One OS query per app run; [refresh] re-asks (e.g. after Settings).
  static Future<AppleIntelligenceStatus>? _status;
  static Future<AppleIntelligenceStatus> status({bool refresh = false}) {
    if (refresh || _status == null) {
      _status = AppleIntelligenceEndpoint.status();
    }
    return _status!;
  }

  /// Whether the card would show anything (available, or fixable).
  static bool isOffered(AppleIntelligenceStatus s) =>
      s == AppleIntelligenceStatus.available ||
      s == AppleIntelligenceStatus.appleIntelligenceNotEnabled ||
      s == AppleIntelligenceStatus.modelNotReady;

  @override
  State<AppleIntelligenceCard> createState() => _AppleIntelligenceCardState();
}

class _AppleIntelligenceCardState extends State<AppleIntelligenceCard> {
  late Future<AppleIntelligenceStatus> _future;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _future = AppleIntelligenceCard.status(refresh: true);
  }

  Future<void> _use() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final sp = context.read<SettingsProvider>();
    setState(() => _busy = true);
    try {
      await sp.activateAppleIntelligence();
      messenger?.showSnackBar(
        SnackBar(content: Text(l10n.appleIntelligenceNowUsing)),
      );
      widget.onActivated?.call();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppleIntelligenceStatus>(
      future: _future,
      builder: (context, snap) {
        final status = snap.data;
        if (status == null || !AppleIntelligenceCard.isOffered(status)) {
          return const SizedBox.shrink();
        }
        return _buildCard(context, status);
      },
    );
  }

  Widget _buildCard(BuildContext context, AppleIntelligenceStatus status) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    final active = context.select<SettingsProvider, bool>(
      (sp) => sp.settings.activeProviderKind == 'appleIntelligence',
    );
    final ready = status == AppleIntelligenceStatus.available;
    final subtitle = switch (status) {
      AppleIntelligenceStatus.appleIntelligenceNotEnabled =>
        l10n.appleIntelligenceTurnOn,
      AppleIntelligenceStatus.modelNotReady =>
        l10n.appleIntelligenceGettingReady,
      _ => l10n.appleIntelligenceSubtitle,
    };

    Widget trailing;
    if (active) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_rounded, color: cs.primary, size: 18),
          const SizedBox(width: 4),
          Text(
            l10n.appleIntelligenceInUse,
            style: TextStyle(color: cs.primary, fontWeight: FontWeight.w600),
          ),
        ],
      );
    } else if (ready) {
      trailing = FilledButton.tonal(
        onPressed: _busy ? null : _use,
        child: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(l10n.appleIntelligenceUse),
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return Material(
      color: cs.primaryContainer.withValues(alpha: active ? 0.7 : 0.45),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: ready && !active && !_busy ? _use : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Icon(Icons.apple, color: cs.primary, size: 24),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.appleIntelligenceBadge,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Apple Intelligence',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}
