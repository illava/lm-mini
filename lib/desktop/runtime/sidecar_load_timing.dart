/// How long to wait for `llama-server` to become healthy after launch.
///
/// Loading is mostly reading the GGUF into (unified) memory, so the wait
/// scales with the file size instead of a flat 45 s that killed big models
/// mid-load.
abstract final class SidecarLoadTiming {
  /// Floor for tiny models and process start-up / Metal init.
  static const Duration base = Duration(seconds: 45);

  /// Extra wait per GiB of model file.
  static const Duration perGiB = Duration(seconds: 20);

  /// Upper bound of the size-based wait.
  static const Duration sizeCap = Duration(minutes: 6);

  /// Absolute ceiling, even while the process keeps logging progress.
  static const Duration hardCap = Duration(minutes: 10);

  /// A log line within this window counts as "still loading".
  static const Duration activityWindow = Duration(seconds: 20);

  /// `45 s + 20 s per GiB`, capped at [sizeCap].
  static Duration timeoutForModelBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return base;
    final gib = bytes / (1024 * 1024 * 1024);
    final ms = base.inMilliseconds + (perGiB.inMilliseconds * gib).round();
    final capped = ms > sizeCap.inMilliseconds ? sizeCap.inMilliseconds : ms;
    return Duration(milliseconds: capped);
  }

  /// Whether to keep polling `/health`. The process exiting is handled by the
  /// caller (fail fast); this only decides the time budget.
  ///
  /// Past [timeout], keep waiting while the server still logs (load progress)
  /// within [activityWindow], up to [hardCap].
  static bool shouldKeepWaiting({
    required Duration elapsed,
    required Duration timeout,
    Duration? sinceLastLog,
  }) {
    if (elapsed < timeout) return true;
    if (elapsed >= hardCap) return false;
    return sinceLastLog != null && sinceLastLog < activityWindow;
  }
}
