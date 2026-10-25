/// What this desktop host advertises to phones in `/lm-mini/host-status`.
///
/// Phones compare [desktopHostVersion] (sent as `connectVersion`) and check
/// [desktopHostCapabilities] to tell old hosts apart before relying on a
/// feature. Add a capability only once the host side is shipped.
library;

/// Bumped from 2.0.0 when capabilities were first advertised.
const String desktopHostVersion = '2.1.0';

/// - `cancel`: a phone `cancel` frame aborts the in-flight generation.
/// - `utf8Stream`: streamed text is decoded across chunk boundaries (no
///   split emoji / CJK).
/// - `modelSwitch`: the model list includes every downloaded GGUF and a chat
///   (or `POST /api/v1/models/load`) naming one loads it.
/// - `syncManifest`: Home Sync accepts the `known` manifest (send only what
///   changed, edits and deletions).
const List<String> desktopHostCapabilities = [
  'cancel',
  'utf8Stream',
  'modelSwitch',
  'syncManifest',
];
