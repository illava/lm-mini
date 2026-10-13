import 'package:lm_mini_premium/lm_mini_premium.dart';

/// Base URL for an LM Studio server as the app stores it.
///
/// Same rules as [normalizeCloudBaseUrl] (https for public hosts when no
/// scheme is typed, trailing slashes dropped), plus a pasted API path is cut
/// back to the server root: requests add `/api/v1/…` or `/v1/…` themselves,
/// so `http://host:1234/v1` used to become `/v1/v1/models` (404).
String normalizeLmStudioBaseUrl(String raw) {
  final base = normalizeCloudBaseUrl(raw).replaceFirst(
    RegExp(r'/api/v[01](/models|/chat)?$', caseSensitive: false),
    '',
  );
  return normalizeCloudBaseUrl(base, stripVersionSuffix: true);
}
