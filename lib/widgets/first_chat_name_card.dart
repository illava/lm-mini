import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';
import '../providers/settings_provider.dart';

/// Empty chat: until the user has a name (or said "Not now"), asks
/// "What should I call you?" in place of [child]. Saving stores the name in
/// Settings and Memory, so the first reply already uses it.
class FirstChatNameGate extends StatefulWidget {
  final Widget child;

  const FirstChatNameGate({super.key, required this.child});

  static const prefsKey = 'first_chat_name_asked';

  @override
  State<FirstChatNameGate> createState() => _FirstChatNameGateState();
}

class _FirstChatNameGateState extends State<FirstChatNameGate> {
  final _controller = TextEditingController();

  /// null while reading prefs (show [child] meanwhile).
  bool? _asked;
  String? _savedName;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    var asked = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      asked = prefs.getBool(FirstChatNameGate.prefsKey) ?? false;
    } catch (_) {}
    if (mounted) setState(() => _asked = asked);
  }

  Future<void> _markAsked() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(FirstChatNameGate.prefsKey, true);
    } catch (_) {}
  }

  Future<void> _save() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    FocusScope.of(context).unfocus();
    context.read<SettingsProvider>().updatePreferredUserName(name);
    setState(() => _savedName = name);
    unawaited(_markAsked());
    // Memory too, so every model knows the name across chats.
    unawaited(
      MemoryService()
          .upsertItem('Name is $name', category: 'personal')
          .catchError((_) => null),
    );
  }

  void _skip() {
    FocusScope.of(context).unfocus();
    setState(() => _asked = true);
    unawaited(_markAsked());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasName = context.select<SettingsProvider, bool>(
      (sp) => (sp.settings.preferredUserName ?? '').trim().isNotEmpty,
    );
    final Widget content;
    if (_savedName != null) {
      content = _buildSaved(context, _savedName!);
    } else if (_asked == false && !hasName) {
      content = _buildAsk(context);
    } else {
      content = widget.child;
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: KeyedSubtree(
        key: ValueKey(_savedName != null ? 'saved' : content == widget.child),
        child: content,
      ),
    );
  }

  Widget _bubble(BuildContext context, Widget child) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Material(
            color: cs.surfaceContainerHigh.withValues(alpha: 0.92),
            elevation: 1,
            shadowColor: Colors.black.withValues(alpha: 0.2),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomRight: Radius.circular(20),
              bottomLeft: Radius.circular(6),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAsk(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return _bubble(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.firstChatNameQuestion,
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _save(),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: l10n.firstChatNameHint,
              filled: true,
              fillColor: cs.surface.withValues(alpha: 0.6),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _skip,
                child: Text(l10n.firstChatNameSkip),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _controller.text.trim().isEmpty ? null : _save,
                child: Text(l10n.firstChatNameSave),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSaved(BuildContext context, String name) {
    final l10n = AppLocalizations.of(context);
    final cs = Theme.of(context).colorScheme;
    return _bubble(
      context,
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.firstChatNameSaved(name),
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.psychology_alt_outlined,
                    size: 16, color: cs.primary),
                const SizedBox(width: 6),
                Text(
                  l10n.firstChatNameMemoryChip,
                  style: TextStyle(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
