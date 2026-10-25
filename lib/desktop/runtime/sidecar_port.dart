/// Parse OS tool output for PIDs listening on the desktop llama-server port.
abstract final class SidecarPort {
  /// `lsof -nP -iTCP:PORT -sTCP:LISTEN -t` stdout.
  static Set<int> parseLsofPids(String stdout) {
    final pids = <int>{};
    for (final line in stdout.split(RegExp(r'\s+'))) {
      final pid = int.tryParse(line.trim());
      if (pid != null && pid > 1) pids.add(pid);
    }
    return pids;
  }

  /// `netstat -ano -p TCP` (Windows) stdout — only LISTENING rows for [port].
  static Set<int> parseNetstatListeningPids(String stdout, int port) {
    final pids = <int>{};
    final needle = ':$port';
    for (final raw in stdout.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final upper = line.toUpperCase();
      if (!upper.contains('LISTENING')) continue;
      if (!line.contains(needle)) continue;
      // Avoid matching :87410 when looking for :8741.
      if (!_localAddressHasPort(line, port)) continue;
      final parts = line.split(RegExp(r'\s+'));
      final pid = int.tryParse(parts.last);
      if (pid != null && pid > 1) pids.add(pid);
    }
    return pids;
  }

  /// Whether `ps -p PID -o comm=` (macOS/Linux: full executable path) or a
  /// `tasklist /FO CSV /NH` row (Windows) names the bundled `llama-server`.
  ///
  /// Used before killing whatever listens on the sidecar port: another app
  /// (or the user's own server) may own it, and that must never be killed.
  static bool commandIsLlamaServer(String? raw) {
    if (raw == null) return false;
    var text = raw.trim();
    if (text.isEmpty) return false;
    // Windows CSV: "llama-server.exe","1234","Console","1","12,345 K"
    if (text.startsWith('"')) {
      final end = text.indexOf('"', 1);
      text = end > 1 ? text.substring(1, end) : text.substring(1);
    }
    text = text.split('\n').first.trim();
    final slash = text.lastIndexOf(RegExp(r'[\\/]'));
    var name = (slash >= 0 ? text.substring(slash + 1) : text).toLowerCase();
    if (name.endsWith('.exe')) name = name.substring(0, name.length - 4);
    return name == 'llama-server';
  }

  static bool _localAddressHasPort(String line, int port) {
    // "TCP 127.0.0.1:8741 0.0.0.0:0 LISTENING 1234"
    final match = RegExp(
      r'(?:\[::\]|\[::1\]|\d+\.\d+\.\d+\.\d+|\*):' '$port' r'(?:\s|$)',
    ).firstMatch(line);
    return match != null;
  }
}
