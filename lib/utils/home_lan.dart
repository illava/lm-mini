/// Pure helpers for the direct Wi‑Fi (LAN) path between the phone and
/// LM Mini Home on the Mac.
///
/// The Mac serves HTTPS with a self-signed certificate and advertises its
/// private IPv4 endpoints plus the certificate's SHA-256 fingerprint over the
/// authenticated channel (pairing link / QR / `host-status` via the relay).
/// The phone only talks to an advertised endpoint whose certificate matches
/// that fingerprint, and keeps sending the same `X-LM-Mini-Token`.
library;

import 'package:crypto/crypto.dart';

/// Pairing-link fragment keys (`#t=…&lan=…&lfp=…`).
const String kLanLinkParam = 'lan';
const String kLanFingerprintLinkParam = 'lfp';

/// JSON keys in the QR payload and `/lm-mini/host-status`.
const String kLanJsonKey = 'lan';
const String kLanFingerprintJsonKey = 'lanFingerprint';

/// Ports the Mac tries, in order, for the direct Wi‑Fi server.
const int kLanFirstPort = 8743;
const int kLanLastPort = 8760;

/// Parses a dotted IPv4 address into its four octets, or null.
List<int>? parseIPv4(String raw) {
  final parts = raw.trim().split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

/// RFC 1918 private IPv4: 10/8, 172.16/12, 192.168/16. Loopback, link-local
/// (169.254/16), CGNAT (100.64/10, e.g. Tailscale) and public are false.
bool isPrivateIPv4(String raw) {
  final o = parseIPv4(raw);
  if (o == null) return false;
  if (o[0] == 10) return true;
  if (o[0] == 172 && o[1] >= 16 && o[1] <= 31) return true;
  if (o[0] == 192 && o[1] == 168) return true;
  return false;
}

/// Peers the Mac's direct Wi‑Fi server answers: private LAN addresses and
/// loopback. Anything else (a public address through port forwarding, a VPN
/// carrier range) is refused before the token is even checked.
bool isLanPeerAddress(String raw) {
  var ip = raw.trim();
  // IPv4-mapped IPv6 (`::ffff:192.168.1.5`).
  if (ip.toLowerCase().startsWith('::ffff:')) ip = ip.substring(7);
  if (isPrivateIPv4(ip)) return true;
  final o = parseIPv4(ip);
  return o != null && o[0] == 127;
}

/// Interface name prefixes that are never the shared home network: VPN /
/// tunnels, AirDrop / low-latency WLAN, VM and container bridges, loopback.
const List<String> _skippedInterfacePrefixes = [
  'lo',
  'utun',
  'tun',
  'tap',
  'ppp',
  'ipsec',
  'gif',
  'stf',
  'awdl',
  'llw',
  'anpi',
  'bridge',
  'vmnet',
  'vboxnet',
  'docker',
  'veth',
  'virbr',
  'zt', // ZeroTier
  'wg', // WireGuard
  'tailscale',
];

/// True when [interfaceName] looks like a VPN / tunnel / virtual interface.
bool isSkippedLanInterface(String interfaceName) {
  final name = interfaceName.trim().toLowerCase();
  if (name.isEmpty) return false;
  for (final prefix in _skippedInterfacePrefixes) {
    if (name.startsWith(prefix)) return true;
  }
  return false;
}

/// One IPv4 address on a named interface (pure input for
/// [advertisableLanAddresses]).
class LanInterfaceAddress {
  const LanInterfaceAddress(this.interfaceName, this.address);
  final String interfaceName;
  final String address;
}

/// Private IPv4 addresses the Mac should advertise, physical interfaces
/// (`en*`) first, without duplicates. VPN tunnels and virtual bridges are
/// skipped even when they carry a private address.
List<String> advertisableLanAddresses(Iterable<LanInterfaceAddress> all) {
  final preferred = <String>[];
  final other = <String>[];
  for (final a in all) {
    if (isSkippedLanInterface(a.interfaceName)) continue;
    final ip = a.address.trim();
    if (!isPrivateIPv4(ip)) continue;
    if (preferred.contains(ip) || other.contains(ip)) continue;
    if (a.interfaceName.toLowerCase().startsWith('en')) {
      preferred.add(ip);
    } else {
      other.add(ip);
    }
  }
  return [...preferred, ...other];
}

/// `https://ip:port` for each address.
List<String> lanUrlsFor(List<String> addresses, int port) =>
    [for (final a in addresses) 'https://$a:$port'];

/// A validated direct Wi‑Fi endpoint: `https`, private IPv4 host, explicit
/// port, no path / query / user info. Null otherwise.
Uri? parseLanEndpoint(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null) return null;
  if (!uri.isScheme('https')) return null;
  if (!uri.hasPort || uri.port <= 0 || uri.port > 65535) return null;
  if (!isPrivateIPv4(uri.host)) return null;
  if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) return null;
  if (uri.path.isNotEmpty && uri.path != '/') return null;
  return Uri(scheme: 'https', host: uri.host, port: uri.port);
}

/// Splits a comma list (link param) or takes a JSON list, keeps only valid
/// endpoints ([parseLanEndpoint]) in their canonical `https://ip:port` form.
List<String> parseLanUrls(Object? raw) {
  final items = <String>[];
  if (raw is String) {
    items.addAll(raw.split(','));
  } else if (raw is List) {
    for (final e in raw) {
      if (e is String) items.add(e);
    }
  }
  final out = <String>[];
  for (final item in items) {
    final uri = parseLanEndpoint(item);
    if (uri == null) continue;
    final s = uri.toString();
    if (!out.contains(s)) out.add(s);
  }
  return out;
}

/// Lowercase 64-char hex SHA-256 fingerprint, or null when [raw] is not one.
/// Colons and spaces (`AB:CD:…`) are accepted.
String? normalizeFingerprint(String? raw) {
  if (raw == null) return null;
  final hex = raw.replaceAll(RegExp(r'[\s:]'), '').toLowerCase();
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) return null;
  return hex;
}

/// SHA-256 of a DER-encoded certificate as lowercase hex.
String certificateFingerprint(List<int> der) => sha256.convert(der).toString();

/// Compares two strings without an early exit on the first difference.
bool constantTimeEquals(String a, String b) {
  final x = a.codeUnits;
  final y = b.codeUnits;
  var diff = x.length ^ y.length;
  final n = x.length < y.length ? x.length : y.length;
  for (var i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// True when the certificate [der] hashes to the [pinned] fingerprint.
/// A missing / malformed pin never matches.
bool certificateMatchesPin(List<int> der, String? pinned) {
  final pin = normalizeFingerprint(pinned);
  if (pin == null || der.isEmpty) return false;
  return constantTimeEquals(certificateFingerprint(der), pin);
}

/// Maps a request under the paired relay URL ([relayBase], e.g.
/// `https://relay.lmmini.com/s/{session}`) onto the direct endpoint
/// [lanBase]: `…/s/{session}/v1/models?x=1` → `https://ip:port/v1/models?x=1`.
/// Null when [request] is not under [relayBase].
Uri? lanUriForRelayRequest(Uri request, String? relayBase, Uri lanBase) {
  final relay = Uri.tryParse(relayBase?.trim() ?? '');
  if (relay == null || !relay.hasScheme || relay.host.isEmpty) return null;
  if (request.scheme.toLowerCase() != relay.scheme.toLowerCase()) return null;
  if (request.host.toLowerCase() != relay.host.toLowerCase()) return null;
  if (request.port != relay.port) return null;
  final base = relay.path.replaceAll(RegExp(r'/+$'), '');
  final path = request.path;
  String rest;
  if (base.isEmpty) {
    rest = path;
  } else if (path == base) {
    rest = '';
  } else if (path.startsWith('$base/')) {
    rest = path.substring(base.length);
  } else {
    return null;
  }
  if (rest.isEmpty) rest = '/';
  // `path` / `query` are already percent-encoded: parse, don't re-encode.
  final query = request.hasQuery ? '?${request.query}' : '';
  return Uri.parse('https://${lanBase.host}:${lanBase.port}$rest$query');
}
