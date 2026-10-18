import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lm_mini_premium/lm_mini_premium.dart';
import 'package:provider/provider.dart';

import '../utils/fllama_cpu_support.dart';
import '../l10n/app_localizations.dart';
import '../models/local_model_spec.dart';
import '../models/server_profile.dart';
import '../pro/pro_features.dart';
import '../providers/settings_provider.dart';
import '../services/device_capability_service.dart';
import '../services/download_progress_activity.dart';
import '../services/lm_studio_discovery_service.dart';
import '../services/local_model_catalog.dart';
import '../services/apple_intelligence_endpoint.dart';
import '../services/deep_link_service.dart';
import '../services/local_model_download_service.dart';
import '../utils/chat_font_helper.dart';
import '../utils/client_platform.dart';
import '../widgets/apple_intelligence_card.dart';
import '../widgets/glass_page_header.dart';
import '../widgets/onboarding_provider_connect_sheet.dart';
import 'subscription_screen.dart';
import '../widgets/glass_blur.dart';

/// First-run (and admin re-test) onboarding: Setup → Look.
/// The user's name is asked in the first chat instead (see FirstChatNameCard).
class WelcomeWizardScreen extends StatefulWidget {
  const WelcomeWizardScreen({super.key});

  @override
  State<WelcomeWizardScreen> createState() => _WelcomeWizardScreenState();
}

class _WelcomeWizardScreenState extends State<WelcomeWizardScreen> {
  static const _totalPages = 2;
  final PageController _pageController = PageController();
  final _downloads = LocalModelDownloadService.instance;

  int _currentPage = 0;
  OnboardingModelPicks? _picks;

  /// Set when the user taps an on-device model. Nothing is pre-selected.
  String? _chosenOnDeviceId;
  bool _scanning = false;
  bool _localNetworkPrompted = false;

  /// iOS/Android: no LAN probes until the user confirms our explanation dialog.
  bool _localNetworkAllowed = false;
  List<DiscoveredLmStudioServer> _discovered = const [];
  final Set<OnboardingProviderKind> _linkedProviders = {};
  final Map<OnboardingProviderKind, int> _modelCounts = {};

  @override
  void initState() {
    super.initState();
    _downloads.addListener(_onDownloadTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Wizard always starts from the system theme; user can change on Look.
      context.read<SettingsProvider>().updateThemeMode(ThemeMode.system);
      unawaited(_bootstrapDevice());
      unawaited(_enterSetupPage());
    });
  }

  @override
  void dispose() {
    _downloads.removeListener(_onDownloadTick);
    _pageController.dispose();
    super.dispose();
  }

  void _onDownloadTick() {
    if (mounted) setState(() {});
  }

  /// Apple's built-in model is offered first when it can be used right now.
  bool _appleReady = false;

  /// Setup page: the two choice cards start collapsed to keep it simple.
  bool _modelsExpanded = false;
  bool _serversExpanded = false;

  /// Chat look picked on the Name page (true = full-width replies).
  bool? _fullWidthChoice;

  Future<void> _bootstrapDevice() async {
    await _downloads.init();
    final cap = await DeviceCapabilityService.instance.get();
    if (!mounted) return;
    final freeOnly = !SubscriptionService().isPremium;
    final picks =
        LocalModelCatalog.onboardingPicks(cap, freeTierOnly: freeOnly);
    setState(() {
      _picks = picks;
    });
    final apple = await AppleIntelligenceCard.status(refresh: true);
    if (!mounted) return;
    setState(() => _appleReady = apple == AppleIntelligenceStatus.available);
  }

  Future<void> _startNetworkScan() async {
    if (ClientPlatform.isIos || ClientPlatform.isAndroid) {
      if (!_localNetworkAllowed) return;
    }
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final servers =
          await LmStudioDiscoveryService.instance.scanLocalNetwork();
      if (!mounted) return;
      setState(() => _discovered = servers);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _goTo(int page) {
    return _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeInOut,
    );
  }

  void _resetLookAndFeel() {
    final settings = context.read<SettingsProvider>();
    settings.updateChatFontSize(14);
    settings.updateChatIconSize(14);
  }

  void _next() {
    if (_currentPage >= _totalPages - 1) {
      _finish();
      return;
    }
    unawaited(_goTo(_currentPage + 1));
  }

  Future<void> _enterSetupPage() async {
    if ((ClientPlatform.isIos || ClientPlatform.isAndroid) &&
        !_localNetworkPrompted) {
      _localNetworkPrompted = true;
      await _promptLocalNetworkAccess();
      if (!mounted) return;
      _localNetworkAllowed = true;
      // Let our sheet finish dismissing so the OS prompt is not covered.
      await Future<void>.delayed(const Duration(milliseconds: 350));
    } else {
      _localNetworkAllowed = true;
    }

    if (!mounted) return;
    unawaited(_startNetworkScan());
  }

  Future<void> _promptLocalNetworkAccess() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => const _LocalNetworkAccessDialog(),
    );
  }

  void _back() {
    if (_currentPage == 0) {
      Navigator.of(context).maybePop();
      return;
    }
    unawaited(_goTo(_currentPage - 1));
  }

  void _finish() {
    final settings = context.read<SettingsProvider>();
    // No "beginner or power user?" question any more: start everyone on the
    // simpler Settings (Settings → Advanced turns the rest on).
    if (settings.settings.aiExperienceLevel == null) {
      settings.updateAiExperienceLevel('beginner');
    }
    unawaited(_completeWizard(settings));
  }

  Future<void> _completeWizard(SettingsProvider settings) async {
    final openChat = await _settleOnAppleIntelligence(settings);
    if (!openChat) await settings.preferReadyDesktopServer();
    if (!mounted) return;
    settings.completeOnboarding();
    Navigator.of(context).pop();
    // Apple's model needs no download, so go straight to a chat.
    if (openChat) DeepLinkService().dispatch(DeepLinkAction.newChat);
  }

  /// True when chat should open on Apple Intelligence: the user picked it,
  /// or it's available and nothing else was set up (no model downloaded or
  /// downloading, no computer or cloud provider connected) — then pick it.
  Future<bool> _settleOnAppleIntelligence(SettingsProvider settings) async {
    final kind = settings.settings.activeProviderKind;
    if (kind == 'appleIntelligence') return true;
    if (!_appleReady) return false;
    final hasModel = _downloads.readyEntries.isNotEmpty ||
        _downloads.entries.any((e) => e.status == LocalModelStatus.downloading);
    final isOnDevice = kind == 'onDeviceGguf' || kind == 'onDeviceMlx';
    final hasRemote = !isOnDevice && settings.isProviderConfigured();
    if (_chosenOnDeviceId != null ||
        hasModel ||
        _linkedProviders.isNotEmpty ||
        hasRemote) {
      return false;
    }
    await settings.activateAppleIntelligence();
    return true;
  }

  Future<void> _downloadPick(LocalModelSpec spec) async {
    if (spec.engine == LocalEngine.fllama && !FllamaCpuSupport.isSupported) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(FllamaCpuSupport.unsupportedMessage),
        duration: Duration(seconds: 6),
      ));
      return;
    }
    if (!SubscriptionService().isPremium && !spec.isFreeSlot) {
      // Public builds have no upgrade path; free-slot picks are offered instead.
      if (!ProFeatures.showUpsell) return;
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SubscriptionScreen(highlight: PaywallFeature.onDeviceModels)),
      );
      return;
    }
    final settings = context.read<SettingsProvider>();
    final linkedDesktop =
        _linkedProviders.contains(OnboardingProviderKind.lmStudio) ||
            _linkedProviders.contains(OnboardingProviderKind.ollama) ||
            _linkedProviders.contains(OnboardingProviderKind.omlx) ||
            _linkedProviders.contains(OnboardingProviderKind.jan) ||
            _linkedProviders.contains(OnboardingProviderKind.unsloth);
    final currentKind = settings.settings.activeProviderKind;
    final keepRemoteSelected = linkedDesktop ||
        ((currentKind == 'lmStudio' ||
                currentKind == 'ollama' ||
                currentKind == 'omlx' ||
                currentKind == 'jan' ||
                currentKind == 'unsloth' ||
                SettingsProvider.isCloudProviderKind(currentKind)) &&
            settings.isProviderConfigured());
    if (keepRemoteSelected) {
      await settings.updateSettings(
        settings.settings.copyWith(selectedLocalModelId: spec.id),
      );
    } else {
      final kind =
          spec.engine == LocalEngine.mlx ? 'onDeviceMlx' : 'onDeviceGguf';
      await settings.updateSettings(
        settings.settings.copyWith(
          activeProviderKind: kind,
          selectedLocalModelId: spec.id,
          selectedModel: spec.displayName,
        ),
      );
      await settings.activateServerProfile(ServerProfile.onDeviceId);
    }
    final entry = _downloads.entryById(spec.id);
    if (entry?.status != LocalModelStatus.ready &&
        entry?.status != LocalModelStatus.downloading) {
      await DownloadProgressActivity.instance.prepareAndroidPermission();
      unawaited(_downloads.download(spec));
    }
    if (!mounted) return;
    setState(() {});
  }

  List<({String label, LocalModelSpec spec})> _visibleOnDevicePicks(
    OnboardingModelPicks picks,
  ) {
    final all = picks.labeled;
    if (all.isEmpty) return all;

    final chosenId = _chosenOnDeviceId;
    if (chosenId != null) {
      final chosen = all.where((e) => e.spec.id == chosenId).toList();
      if (chosen.isNotEmpty) return chosen;
    }

    final ready = all
        .where(
          (e) =>
              _downloads.entryById(e.spec.id)?.status == LocalModelStatus.ready,
        )
        .toList();
    if (ready.isNotEmpty) return ready;

    final inFlight = all.where((e) {
      final status = _downloads.entryById(e.spec.id)?.status;
      return status == LocalModelStatus.downloading ||
          status == LocalModelStatus.failed;
    }).toList();
    if (inFlight.isNotEmpty) return inFlight;

    return all;
  }

  bool _collapseOnDeviceSection(
    List<({String label, LocalModelSpec spec})> visible,
  ) {
    if (visible.length != 1) return false;
    final status = _downloads.entryById(visible.first.spec.id)?.status;
    return _chosenOnDeviceId != null ||
        status == LocalModelStatus.ready ||
        status == LocalModelStatus.downloading ||
        status == LocalModelStatus.failed;
  }

  void _onPickOnDevice(({String label, LocalModelSpec spec}) item) {
    setState(() {
      _chosenOnDeviceId = item.spec.id;
      _modelsExpanded = true;
    });
    unawaited(_downloadPick(item.spec));
  }

  Future<void> _stopOnDeviceDownload(LocalModelSpec spec) async {
    await _downloads.cancel(spec.id);
    if (!mounted) return;
    setState(() => _chosenOnDeviceId = null);
  }

  LocalModelEntry? get _followOnDeviceDownload {
    for (final e in _downloads.entries) {
      if (e.status == LocalModelStatus.downloading) return e;
    }
    final chosenId = _chosenOnDeviceId;
    if (chosenId == null) return null;
    final entry = _downloads.entryById(chosenId);
    if (entry?.status == LocalModelStatus.failed) return entry;
    return null;
  }

  Widget _followOnDeviceDownloadCard(AppLocalizations l10n) {
    final entry = _followOnDeviceDownload!;
    final failed = entry.status == LocalModelStatus.failed;
    return _ModelPickCard(
      label: '',
      blurb: '',
      spec: entry.spec,
      entry: entry,
      highlighted: true,
      footer: failed
          ? l10n.welcomeWizardDownloadFailed
          : l10n.welcomeWizardAiDownloadingBody,
      onTap: failed
          ? () {
              setState(() => _chosenOnDeviceId = entry.spec.id);
              unawaited(_downloadPick(entry.spec));
            }
          : () {},
      onStop:
          failed ? null : () => unawaited(_stopOnDeviceDownload(entry.spec)),
    );
  }

  Widget _followOnDeviceDownloadOverlay({
    required AppLocalizations l10n,
    required double bottom,
  }) {
    if (_followOnDeviceDownload == null) return const SizedBox.shrink();
    return Positioned(
      left: 20,
      right: 20,
      bottom: bottom,
      child: _followOnDeviceDownloadCard(l10n),
    );
  }

  Future<void> _openProvider(OnboardingProviderKind kind) async {
    final ok = await showOnboardingProviderConnectSheet(
      context: context,
      kind: kind,
      discovered: _discovered,
    );
    if (ok == true && mounted) {
      setState(() => _linkedProviders.add(kind));
      unawaited(_refreshModelCount(kind));
    }
  }

  Future<void> _refreshModelCount(OnboardingProviderKind kind) async {
    try {
      final settings = context.read<SettingsProvider>();
      await settings.loadAvailableModels(silent: true);
      if (!mounted) return;
      setState(() {
        _modelCounts[kind] = settings.availableModels.length;
      });
    } catch (_) {}
  }

  String _pageTitle(AppLocalizations l10n) => switch (_currentPage) {
        0 => l10n.welcomeWizardTitleYourSetup,
        1 => l10n.welcomeWizardTitleLookAndFeel,
        _ => l10n.welcomeWizardTitleSetup,
      };

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;

  /// Sheet content (below the navy top) — matches home duo-tone + add dark.
  bool get _sheetLight => !_isDark;

  Color get _topBg =>
      _isDark ? const Color(0xFF1A202E) : const Color(0xFF243044);

  Color get _sheetBg =>
      _isDark ? const Color(0xFF080A0F) : Theme.of(context).colorScheme.surface;

  Color get _fg =>
      _sheetLight ? Colors.black.withValues(alpha: 0.88) : Colors.white;

  static const _okGreen = Color(0xFF00B894);

  Color get _fgMuted => _fg.withValues(alpha: _sheetLight ? 0.55 : 0.65);

  @override
  Widget build(BuildContext context) {
    final headerH = GlassPageHeader.heightFor(context);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: _topBg,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: Size.fromHeight(headerH),
        child: GlassPageHeader(
          title: _pageTitle(l10n),
          onBack: _back,
          // Always on the dark navy top zone (home-style).
          onLightCanvas: false,
          actions: [
            if (_currentPage == 0) _languageButton(context),
            TextButton(
              onPressed: _currentPage == _totalPages - 1 ? _finish : _next,
              child: Text(
                l10n.welcomeWizardSkip,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          SizedBox(height: headerH),
          _ProgressDots(
            current: _currentPage,
            total: _totalPages,
            color: Colors.white,
          ),
          const SizedBox(height: 10),
          Expanded(
            child: Material(
              color: _sheetBg,
              elevation: 2,
              shadowColor: Colors.black.withValues(alpha: 0.14),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
              clipBehavior: Clip.antiAlias,
              child: _WizardTone(
                fg: _fg,
                light: _sheetLight,
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (p) => setState(() => _currentPage = p),
                  children: [
                    _buildSetupPage(context),
                    _buildLookPage(context),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Header language switch (first page only), e.g. "English ▾".
  Widget _languageButton(BuildContext context) {
    context.watch<SettingsProvider>();
    final languageName =
        _wizardLanguageName(_effectiveWizardLanguageCode(context));
    return TextButton(
      onPressed: () => _showLanguageSheet(context),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            languageName,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(width: 2),
          const Icon(
            Icons.expand_more_rounded,
            size: 16,
            color: Colors.white60,
          ),
        ],
      ),
    );
  }

  String _effectiveWizardLanguageCode(BuildContext context) {
    final stored = context.read<SettingsProvider>().settings.locale;
    if (stored != null && stored.isNotEmpty) return stored;
    final device = Localizations.localeOf(context).languageCode.toLowerCase();
    for (final lang in _wizardLanguages) {
      if (lang.code == device) return device;
    }
    return 'en';
  }

  Future<void> _showLanguageSheet(BuildContext context) async {
    final selected = _effectiveWizardLanguageCode(context);
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      useRootNavigator: true,
      builder: (ctx) => _WizardLanguageSheet(selectedCode: selected),
    );
    if (!mounted || picked == null || picked == selected) return;
    final settings = context.read<SettingsProvider>();
    await settings.updateSettings(
      settings.settings.copyWith(locale: picked),
    );
  }

  // ── Page 1: Setup ────────────────────────────────────────────────

  Widget _buildSetupPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final picks = _picks;
    final accentHint = l10n.welcomeWizardSetupSubtitleBeginner;

    final lmServers = _discovered
        .where((s) => s.kind == DiscoveredServerKind.lmStudio)
        .toList();
    final ollamaServers = _discovered
        .where((s) => s.kind == DiscoveredServerKind.ollama)
        .toList();
    final unslothServers = _discovered
        .where((s) => s.kind == DiscoveredServerKind.unsloth)
        .toList();
    final lmLinked = _linkedProviders.contains(OnboardingProviderKind.lmStudio);
    final ollamaLinked =
        _linkedProviders.contains(OnboardingProviderKind.ollama);
    final unslothLinked =
        _linkedProviders.contains(OnboardingProviderKind.unsloth);
    context.watch<SettingsProvider>();

    String lanSubtitle({
      required bool linked,
      required List<DiscoveredLmStudioServer> matches,
      required String idle,
    }) {
      if (linked) return l10n.welcomeWizardConnected;
      if (matches.isNotEmpty) return l10n.welcomeWizardServerFound;
      return idle;
    }

    String? lanBadge({
      required bool linked,
      required List<DiscoveredLmStudioServer> matches,
    }) {
      if (linked || matches.isEmpty) return null;
      if (matches.any((s) => s.requiresApiKey)) {
        return l10n.welcomeWizardRequiresApiKey;
      }
      return null;
    }

    // One short line under each choice: what's already happening there.
    ({String text, Color color})? downloadStatus;
    if (picks != null) {
      for (final item in picks.labeled) {
        final entry = _downloads.entryById(item.spec.id);
        final name = item.spec.displayName;
        if (entry?.status == LocalModelStatus.ready) {
          downloadStatus = (
            text: l10n.onboardingModelReady(name),
            color: _okGreen,
          );
          break;
        }
        if (entry?.status == LocalModelStatus.downloading) {
          downloadStatus = (
            text: l10n.onboardingModelDownloading(
              name,
              (entry!.progress * 100).round(),
            ),
            color: _fg,
          );
        }
      }
    }
    String? serverStatus;
    if (_linkedProviders.isNotEmpty) {
      serverStatus = l10n.welcomeWizardConnected;
    } else if (_discovered.isNotEmpty) {
      serverStatus = l10n.onboardingServersFound(_discovered.length);
    }

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 108),
          children: [
            Text(
              l10n.welcomeWizardSetupTitleBeginner,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: _fg,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              accentHint,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _fgMuted,
                  ),
            ),
            const SizedBox(height: 20),
            if (_appleReady) ...[
              const AppleIntelligenceCard(),
              const SizedBox(height: 12),
            ],
            _SetupChoiceCard(
              icon: Icons.download_rounded,
              title: l10n.onboardingDownloadModelTitle,
              subtitle: l10n.onboardingDownloadModelSubtitle,
              status: downloadStatus?.text,
              statusColor: downloadStatus?.color,
              expanded: _modelsExpanded,
              onTap: () => setState(() => _modelsExpanded = !_modelsExpanded),
              child: picks == null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: CircularProgressIndicator(color: _fgMuted),
                      ),
                    )
                  : _buildOnDevicePicks(context, picks, l10n),
            ),
            const SizedBox(height: 12),
            _SetupChoiceCard(
              icon: Icons.desktop_windows_outlined,
              title: l10n.onboardingConnectComputerTitle,
              subtitle: l10n.onboardingConnectComputerSubtitle,
              status: serverStatus,
              statusColor: _okGreen,
              busy: _scanning && serverStatus == null,
              expanded: _serversExpanded,
              onTap: () => setState(() => _serversExpanded = !_serversExpanded),
              child: Column(
                children: [
                  _ProviderCard(
                    title: 'LM Studio',
                    subtitle: lanSubtitle(
                      linked: lmLinked,
                      matches: lmServers,
                      idle: l10n.welcomeWizardLmStudioSubtitle,
                    ),
                    icon: Icons.desktop_windows_outlined,
                    badge: lanBadge(linked: lmLinked, matches: lmServers),
                    modelCount: lmLinked
                        ? _modelCounts[OnboardingProviderKind.lmStudio]
                        : null,
                    scanning: _scanning,
                    connected: lmLinked,
                    onTap: () => _openProvider(OnboardingProviderKind.lmStudio),
                  ),
                  const SizedBox(height: 10),
                  _ProviderCard(
                    title: 'Ollama',
                    subtitle: lanSubtitle(
                      linked: ollamaLinked,
                      matches: ollamaServers,
                      idle: l10n.welcomeWizardOllamaSubtitle,
                    ),
                    icon: Icons.terminal_rounded,
                    badge:
                        lanBadge(linked: ollamaLinked, matches: ollamaServers),
                    modelCount: ollamaLinked
                        ? _modelCounts[OnboardingProviderKind.ollama]
                        : null,
                    scanning: _scanning,
                    connected: ollamaLinked,
                    onTap: () => _openProvider(OnboardingProviderKind.ollama),
                  ),
                  const SizedBox(height: 10),
                  _ProviderCard(
                    title: 'oMLX',
                    subtitle:
                        _linkedProviders.contains(OnboardingProviderKind.omlx)
                            ? l10n.welcomeWizardConnected
                            : l10n.welcomeWizardOmlxSubtitle,
                    icon: Icons.memory_outlined,
                    badge: null,
                    modelCount:
                        _linkedProviders.contains(OnboardingProviderKind.omlx)
                            ? _modelCounts[OnboardingProviderKind.omlx]
                            : null,
                    scanning: false,
                    connected:
                        _linkedProviders.contains(OnboardingProviderKind.omlx),
                    onTap: () => _openProvider(OnboardingProviderKind.omlx),
                  ),
                  const SizedBox(height: 10),
                  _ProviderCard(
                    title: 'JAN AI',
                    subtitle:
                        _linkedProviders.contains(OnboardingProviderKind.jan)
                            ? l10n.welcomeWizardConnected
                            : l10n.welcomeWizardJanSubtitle,
                    icon: Icons.bolt_outlined,
                    badge: null,
                    modelCount:
                        _linkedProviders.contains(OnboardingProviderKind.jan)
                            ? _modelCounts[OnboardingProviderKind.jan]
                            : null,
                    scanning: false,
                    connected:
                        _linkedProviders.contains(OnboardingProviderKind.jan),
                    onTap: () => _openProvider(OnboardingProviderKind.jan),
                  ),
                  const SizedBox(height: 10),
                  _ProviderCard(
                    title: 'Unsloth',
                    subtitle: lanSubtitle(
                      linked: unslothLinked,
                      matches: unslothServers,
                      idle: l10n.welcomeWizardUnslothSubtitle,
                    ),
                    icon: Icons.science_outlined,
                    badge: lanBadge(
                        linked: unslothLinked, matches: unslothServers),
                    modelCount: unslothLinked
                        ? _modelCounts[OnboardingProviderKind.unsloth]
                        : null,
                    scanning: _scanning,
                    connected: unslothLinked,
                    onTap: () => _openProvider(OnboardingProviderKind.unsloth),
                  ),
                ],
              ),
            ),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Center(
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(minWidth: 168, maxWidth: 220),
                  child: FilledButton(
                    onPressed: _next,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(168, 52),
                      elevation: 6,
                      shadowColor: Colors.black.withValues(alpha: 0.35),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(l10n.welcomeWizardContinue),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOnDevicePicks(
    BuildContext context,
    OnboardingModelPicks picks,
    AppLocalizations l10n,
  ) {
    final visible = _visibleOnDevicePicks(picks);
    final collapse = _collapseOnDeviceSection(visible);

    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: Column(
        children: [
          for (final item in visible)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Builder(
                builder: (_) {
                  final entry = _downloads.entryById(item.spec.id);
                  final status = entry?.status;
                  final blurb = switch (item.label) {
                    'Faster' => l10n.welcomeWizardModelFasterBlurb,
                    'Best' => l10n.welcomeWizardModelBestBlurb,
                    _ => l10n.welcomeWizardModelBalancedBlurb,
                  };
                  String? footer;
                  if (status == LocalModelStatus.downloading) {
                    footer = l10n.welcomeWizardDownloadKeepsGoing;
                  } else if (status == LocalModelStatus.failed) {
                    final err = entry?.errorMessage?.trim();
                    footer = (err != null && err.isNotEmpty)
                        ? err
                        : l10n.welcomeWizardDownloadFailed;
                  }
                  return _ModelPickCard(
                    label: item.label,
                    blurb: blurb,
                    spec: item.spec,
                    entry: entry,
                    highlighted: collapse,
                    footer: footer,
                    onTap: () => _onPickOnDevice(item),
                    onStop: status == LocalModelStatus.downloading
                        ? () => unawaited(_stopOnDeviceDownload(item.spec))
                        : null,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  // ── Page 2: Look & feel ──────────────────────────────────────────

  Widget _buildLookPage(BuildContext context) {
    final settingsProvider = context.watch<SettingsProvider>();
    final settings = settingsProvider.settings;
    final l10n = AppLocalizations.of(context);

    final follow = _followOnDeviceDownload;
    final bottomPad = follow != null ? 200.0 : 108.0;
    final fullWidth = _fullWidthChoice ?? settings.fullWidthAssistant;

    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.fromLTRB(24, 12, 24, bottomPad),
          children: [
            Text(
              l10n.welcomeWizardThemeTitle,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: _fg,
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.welcomeWizardThemeSubtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _fgMuted,
                  ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _ThemeTile(
                    icon: Icons.light_mode_rounded,
                    label: l10n.themeLight,
                    selected: settings.themeMode == ThemeMode.light,
                    onTap: () =>
                        settingsProvider.updateThemeMode(ThemeMode.light),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ThemeTile(
                    icon: Icons.dark_mode_rounded,
                    label: l10n.themeDark,
                    selected: settings.themeMode == ThemeMode.dark,
                    onTap: () =>
                        settingsProvider.updateThemeMode(ThemeMode.dark),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            _ThemeTile(
              icon: Icons.brightness_auto_rounded,
              label: l10n.themeSystem,
              selected: settings.themeMode == ThemeMode.system,
              onTap: () => settingsProvider.updateThemeMode(ThemeMode.system),
              wide: true,
            ),
            const SizedBox(height: 28),
            Text(
              l10n.welcomeWizardAppearanceTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 12),
            _FrostPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _fg.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.welcomeWizardAppearancePreviewMessage,
                            style: TextStyle(
                              fontSize: settings.chatFontSize,
                              color: _fg.withValues(alpha: 0.9),
                              height: 1.35,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.thumb_up_alt_outlined,
                          size: settings.chatIconSize,
                          color: _fg.withValues(alpha: 0.7),
                        ),
                        const SizedBox(width: 6),
                        Icon(
                          Icons.content_copy_rounded,
                          size: settings.chatIconSize,
                          color: _fg.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    l10n.fontSizeLabel,
                    style: TextStyle(
                      color: _fg.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Slider(
                    value: settings.chatFontSize.clamp(10, 24),
                    min: 10,
                    max: 24,
                    divisions: 14,
                    label: settings.chatFontSize.round().toString(),
                    onChanged: settingsProvider.updateChatFontSize,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.iconSizeLabel,
                    style: TextStyle(
                      color: _fg.withValues(alpha: 0.75),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Slider(
                    value: settings.chatIconSize.clamp(10, 24),
                    min: 10,
                    max: 24,
                    divisions: 14,
                    label: settings.chatIconSize.round().toString(),
                    onChanged: settingsProvider.updateChatIconSize,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              l10n.onboardingChatStyleTitle,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _fg,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _ChatStyleTile(
                    fullWidth: true,
                    selected: fullWidth,
                    title: l10n.onboardingChatStyleFullWidth,
                    subtitle: l10n.onboardingChatStyleFullWidthHint,
                    onTap: () => _pickChatStyle(true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ChatStyleTile(
                    fullWidth: false,
                    selected: !fullWidth,
                    title: l10n.onboardingChatStyleBubbles,
                    subtitle: l10n.onboardingChatStyleBubblesHint,
                    onTap: () => _pickChatStyle(false),
                  ),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: SizedBox(
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Tooltip(
                        message: l10n.reset,
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _resetLookAndFeel,
                            customBorder: const CircleBorder(),
                            child: Ink(
                              width: 44,
                              height: 44,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _fg.withValues(alpha: 0.08),
                                border: Border.all(
                                  color: _fg.withValues(alpha: 0.14),
                                ),
                              ),
                              child: Icon(
                                Icons.restart_alt_rounded,
                                size: 22,
                                color: _fg.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints:
                          const BoxConstraints(minWidth: 168, maxWidth: 220),
                      child: FilledButton(
                        onPressed: _next,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(168, 52),
                          elevation: 6,
                          shadowColor: Colors.black.withValues(alpha: 0.35),
                          shape: const StadiumBorder(),
                        ),
                        child: Text(l10n.welcomeWizardFinish),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        _followOnDeviceDownloadOverlay(
          l10n: l10n,
          bottom: 12 + 52 + 12 + MediaQuery.paddingOf(context).bottom,
        ),
      ],
    );
  }

  void _pickChatStyle(bool fullWidth) {
    setState(() => _fullWidthChoice = fullWidth);
    final settings = context.read<SettingsProvider>();
    settings.updateFullWidthAssistant(fullWidth);
    // Chose a look here, so skip the later "try full-width" prompt.
    settings.markFullWidthAssistantNudgeShown();
  }
}

// ── Shared UI bits ─────────────────────────────────────────────────

class _WizardTone extends InheritedWidget {
  final Color fg;
  final bool light;

  const _WizardTone({
    required this.fg,
    required this.light,
    required super.child,
  });

  static _WizardTone of(BuildContext context) {
    final tone = context.dependOnInheritedWidgetOfExactType<_WizardTone>();
    assert(tone != null, 'WizardTone missing');
    return tone!;
  }

  Color get muted => fg.withValues(alpha: light ? 0.55 : 0.65);

  Color fill([double dark = 0.08, double lightA = 0.05]) =>
      fg.withValues(alpha: light ? lightA : dark);

  Color border([double dark = 0.12, double lightA = 0.1]) =>
      fg.withValues(alpha: light ? lightA : dark);

  @override
  bool updateShouldNotify(_WizardTone oldWidget) =>
      fg != oldWidget.fg || light != oldWidget.light;
}

class _ProgressDots extends StatelessWidget {
  final int current;
  final int total;
  final Color color;

  const _ProgressDots({
    required this.current,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(total, (i) {
          final on = i == current;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            margin: const EdgeInsets.symmetric(horizontal: 3),
            width: on ? 22 : 7,
            height: 7,
            decoration: BoxDecoration(
              color: on ? color : color.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(4),
            ),
          );
        }),
      ),
    );
  }
}

class _FrostPanel extends StatelessWidget {
  final Widget child;

  const _FrostPanel({required this.child});

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: GlassBlur(
        sigmaX: 28,
        sigmaY: 28,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tone.fill(),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tone.border()),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _ModelPickCard extends StatefulWidget {
  final String label;
  final String blurb;
  final LocalModelSpec spec;
  final LocalModelEntry? entry;
  final bool highlighted;
  final String? footer;
  final VoidCallback onTap;
  final VoidCallback? onStop;

  const _ModelPickCard({
    required this.label,
    required this.blurb,
    required this.spec,
    required this.entry,
    required this.highlighted,
    required this.onTap,
    this.footer,
    this.onStop,
  });

  @override
  State<_ModelPickCard> createState() => _ModelPickCardState();
}

class _ModelPickCardState extends State<_ModelPickCard> {
  int? _heldSpeed;
  DateTime _heldAt = DateTime.fromMillisecondsSinceEpoch(0);

  String? _stableSpeed(int bytesPerSecond) {
    final now = DateTime.now();
    if (bytesPerSecond > 0) {
      _heldSpeed = bytesPerSecond;
      _heldAt = now;
      return _wizardCompactSpeed(bytesPerSecond);
    }
    if (_heldSpeed != null &&
        now.difference(_heldAt) < const Duration(seconds: 2)) {
      return _wizardCompactSpeed(_heldSpeed!);
    }
    _heldSpeed = null;
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    final spec = widget.spec;
    final entry = widget.entry;
    final status = entry?.status;
    final progress = entry?.progress ?? 0.0;
    final downloading = status == LocalModelStatus.downloading;
    final ready = status == LocalModelStatus.ready;
    final failed = status == LocalModelStatus.failed;

    final l10n = AppLocalizations.of(context);
    String trailing;
    if (ready) {
      trailing = l10n.welcomeWizardModelReady;
    } else if (failed) {
      trailing = l10n.retry;
    } else if (downloading) {
      final pct = '${(progress * 100).clamp(0, 100).round()}%';
      final speed = _stableSpeed(entry?.bytesPerSecond ?? 0);
      trailing = speed != null ? '$pct · $speed' : pct;
    } else {
      trailing =
          '~${spec.sizeMb >= 1000 ? '${(spec.sizeMb / 1000).toStringAsFixed(1)} GB' : '${spec.sizeMb} MB'}';
    }

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: BoxDecoration(
            color: tone.fill(
              widget.highlighted ? 0.14 : 0.07,
              widget.highlighted ? 0.08 : 0.04,
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: widget.highlighted
                  ? tone.border(0.5, 0.35)
                  : tone.border(0.1, 0.08),
            ),
          ),
          child: Padding(
            padding: downloading
                ? const EdgeInsets.fromLTRB(14, 10, 8, 10)
                : const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (downloading)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          spec.displayName
                              .replaceAll(' (MLX)', '')
                              .replaceAll(' Instruct', ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: tone.fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        trailing,
                        style: TextStyle(
                          color: tone.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (widget.onStop != null)
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                            tooltip: l10n.cancel,
                            onPressed: widget.onStop,
                            icon: Icon(
                              Icons.stop_circle_outlined,
                              size: 20,
                              color: tone.muted,
                            ),
                          ),
                        ),
                    ],
                  )
                else ...[
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: tone.fill(0.12, 0.07),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            color: tone.fg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        trailing,
                        style: TextStyle(
                          color: ready
                              ? const Color(0xFF00B894)
                              : failed
                                  ? Theme.of(context).colorScheme.error
                                  : tone.muted,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    spec.displayName
                        .replaceAll(' (MLX)', '')
                        .replaceAll(' Instruct', ''),
                    style: TextStyle(
                      color: tone.fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.blurb,
                    style: TextStyle(
                      color: tone.muted,
                      fontSize: 13,
                    ),
                  ),
                ],
                if (downloading) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress > 0 ? progress : null,
                      minHeight: 3,
                      backgroundColor: tone.fill(0.12, 0.08),
                    ),
                  ),
                ],
                if (widget.footer != null && widget.footer!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.footer!,
                    style: TextStyle(
                      color: failed
                          ? Theme.of(context).colorScheme.error
                          : tone.muted,
                      fontSize: 11,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final String? badge;
  final int? modelCount;
  final bool scanning;
  final bool connected;
  final VoidCallback onTap;

  const _ProviderCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.badge,
    required this.modelCount,
    required this.scanning,
    required this.connected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    final scheme = Theme.of(context).colorScheme;
    // Assistant chat-bubble shape (tail on bottom-left).
    const radius = BorderRadius.only(
      topLeft: Radius.circular(18),
      topRight: Radius.circular(18),
      bottomLeft: Radius.circular(4),
      bottomRight: Radius.circular(18),
    );
    final bubbleFill = tone.light
        ? scheme.surfaceContainerHighest.withValues(alpha: 0.85)
        : scheme.surfaceContainerHigh.withValues(alpha: 0.9);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: radius,
        child: Ink(
          decoration: BoxDecoration(
            color: bubbleFill,
            borderRadius: radius,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                // Soft avatar-style circle like chat bubbles.
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.secondary.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 22, color: scheme.secondary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: ChatFontHelper.apply(
                                null,
                                TextStyle(
                                  color: tone.fg,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  height: 1.25,
                                ),
                              ),
                            ),
                          ),
                          if (badge != null && badge!.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            _StatusBadge(label: badge!, warning: true),
                          ] else if (scanning) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: tone.muted,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        connected
                            ? AppLocalizations.of(context)
                                .welcomeWizardConnected
                            : subtitle,
                        style: ChatFontHelper.apply(
                          null,
                          TextStyle(
                            color: connected
                                ? const Color(0xFF00B894)
                                : tone.muted,
                            fontSize: 13,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (connected && modelCount != null) ...[
                      _StatusBadge(
                        label: AppLocalizations.of(context)
                            .welcomeWizardModelsFound(modelCount!),
                        warning: false,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Icon(
                      connected
                          ? Icons.check_circle_rounded
                          : Icons.arrow_forward_ios_rounded,
                      size: connected ? 20 : 14,
                      color: connected ? const Color(0xFF00B894) : tone.muted,
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
}

/// Setup page choice ("Download a model", "Connect your computer"): one tap
/// target with a short status line; tapping opens its list underneath.
class _SetupChoiceCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String? status;
  final Color? statusColor;
  final bool busy;
  final bool expanded;
  final VoidCallback onTap;
  final Widget child;

  const _SetupChoiceCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.status,
    this.statusColor,
    this.busy = false,
    required this.expanded,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    final scheme = Theme.of(context).colorScheme;
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: GlassBlur(
        sigmaX: 28,
        sigmaY: 28,
        child: Container(
          decoration: BoxDecoration(
            color: tone.fill(),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tone.border()),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: scheme.primary.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(icon, size: 22, color: scheme.primary),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  color: tone.fg,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: TextStyle(
                                  color: tone.muted,
                                  fontSize: 13,
                                  height: 1.3,
                                ),
                              ),
                              if (status != null) ...[
                                const SizedBox(height: 4),
                                Text(
                                  status!,
                                  style: TextStyle(
                                    color: statusColor ?? tone.fg,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (busy)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: tone.muted,
                            ),
                          )
                        else
                          AnimatedRotation(
                            turns: expanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 200),
                            child: Icon(
                              Icons.keyboard_arrow_down_rounded,
                              color: tone.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeInOut,
                alignment: Alignment.topCenter,
                child: expanded
                    ? Padding(
                        padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                        child: child,
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Name page: a tiny picture of one chat look (full-width replies or
/// texting-style bubbles) that the user taps to choose.
class _ChatStyleTile extends StatelessWidget {
  final bool fullWidth;
  final bool selected;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ChatStyleTile({
    required this.fullWidth,
    required this.selected,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    final scheme = Theme.of(context).colorScheme;
    final textLine = tone.fg.withValues(alpha: tone.light ? 0.28 : 0.4);
    final assistantBubble = tone.fg.withValues(alpha: tone.light ? 0.08 : 0.14);

    Widget line(double widthFactor, Color color) => FractionallySizedBox(
          widthFactor: widthFactor,
          alignment: Alignment.centerLeft,
          child: Container(
            height: 6,
            margin: const EdgeInsets.only(bottom: 5),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        );

    final userBubble = Align(
      alignment: Alignment.centerRight,
      child: Container(
        width: 56,
        height: 18,
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(9),
        ),
      ),
    );

    final reply = fullWidth
        ? Column(
            children: [
              line(1, textLine),
              line(1, textLine),
              line(0.95, textLine),
              line(0.6, textLine),
            ],
          )
        : Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: 0.78,
              child: Container(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 3),
                decoration: BoxDecoration(
                  color: assistantBubble,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(12),
                    topRight: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                    bottomLeft: Radius.circular(3),
                  ),
                ),
                child: Column(
                  children: [
                    line(1, textLine),
                    line(1, textLine),
                    line(0.55, textLine),
                  ],
                ),
              ),
            ),
          );

    return Semantics(
      button: true,
      selected: selected,
      label: '$title, $subtitle',
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: tone.fill(),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? scheme.primary : tone.border(),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 92,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    userBubble,
                    const SizedBox(height: 10),
                    reply,
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        color: tone.fg,
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Icon(
                    selected
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    size: 18,
                    color: selected ? scheme.primary : tone.muted,
                  ),
                ],
              ),
              Text(
                subtitle,
                style: TextStyle(color: tone.muted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final bool warning;

  const _StatusBadge({required this.label, this.warning = false});

  @override
  Widget build(BuildContext context) {
    final color = warning ? const Color(0xFFE17055) : const Color(0xFF00B894);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: 0.45),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ThemeTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool wide;

  const _ThemeTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final tone = _WizardTone.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          decoration: BoxDecoration(
            color: tone.fill(
              selected ? 0.16 : 0.07,
              selected ? 0.1 : 0.04,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? tone.border(0.5, 0.4) : tone.border(0.1, 0.08),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 16,
              vertical: wide ? 14 : 20,
            ),
            child: Row(
              mainAxisAlignment:
                  wide ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(icon, color: tone.fg),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: tone.fg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (selected && wide) ...[
                  const Spacer(),
                  Icon(Icons.check_circle, color: tone.fg, size: 20),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocalNetworkAccessDialog extends StatelessWidget {
  const _LocalNetworkAccessDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: GlassBlur(
          sigmaX: 28,
          sigmaY: 28,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [
                          Colors.white.withValues(alpha: 0.12),
                          Colors.white.withValues(alpha: 0.05),
                        ]
                      : [
                          Colors.white.withValues(alpha: 0.94),
                          Colors.white.withValues(alpha: 0.80),
                        ],
                ),
                border: Border.all(
                  color: Colors.white.withValues(alpha: isDark ? 0.22 : 0.55),
                ),
              ),
              child: Material(
                color: Colors.transparent,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(22, 24, 22, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Container(
                        width: 56,
                        height: 56,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.primary.withValues(alpha: 0.14),
                        ),
                        child: Icon(
                          Icons.wifi_rounded,
                          size: 28,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.welcomeWizardLocalNetworkTitle,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        l10n.welcomeWizardLocalNetworkBody,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.onSurface.withValues(alpha: 0.62),
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(l10n.welcomeWizardLocalNetworkAllow),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String? _wizardCompactSpeed(int bytesPerSec) {
  if (bytesPerSec <= 0) return null;
  if (bytesPerSec < 1024) return '$bytesPerSec B/s';
  if (bytesPerSec < 1024 * 1024) {
    return '${(bytesPerSec / 1024).round()} KB/s';
  }
  final mb = (bytesPerSec / (1024 * 1024) * 10).round() / 10;
  return '${mb.toStringAsFixed(1)} MB/s';
}

const _wizardLanguages = <({String code, String name})>[
  (code: 'en', name: 'English'),
  (code: 'es', name: 'Español'),
  (code: 'de', name: 'Deutsch'),
  (code: 'fr', name: 'Français'),
  (code: 'ru', name: 'Русский'),
  (code: 'zh', name: '中文'),
];

String _wizardLanguageName(String code) {
  for (final lang in _wizardLanguages) {
    if (lang.code == code) return lang.name;
  }
  return 'English';
}

class _WizardLanguageSheet extends StatelessWidget {
  final String selectedCode;

  const _WizardLanguageSheet({required this.selectedCode});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final l10n = AppLocalizations.of(context);
    final fg = isDark ? Colors.white : Colors.black.withValues(alpha: 0.88);
    final canvas = isDark ? const Color(0xFF12151C) : const Color(0xFFF4F6FA);

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: GlassBlur(
        sigmaX: 28,
        sigmaY: 28,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: canvas.withValues(alpha: 0.94),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: fg.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      l10n.language,
                      style: TextStyle(
                        color: fg.withValues(alpha: 0.45),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  for (final lang in _wizardLanguages)
                    ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      title: Text(
                        lang.name,
                        style: TextStyle(
                          color: fg,
                          fontWeight: lang.code == selectedCode
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                      trailing: lang.code == selectedCode
                          ? Icon(
                              Icons.check_rounded,
                              color: theme.colorScheme.primary,
                              size: 20,
                            )
                          : null,
                      onTap: () => Navigator.pop(context, lang.code),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
