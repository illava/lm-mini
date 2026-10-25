import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../desktop_platform.dart';
import 'sidecar_load_timing.dart';
import 'sidecar_port.dart';

/// Manages the desktop llama.cpp `llama-server` sidecar process.
///
/// Phone builds never call this.
///
/// **Mac:** ships inside the app bundle at `Contents/Resources/runtime/llama-server`.
/// **Windows:** ships next to the exe at `runtime/llama-server.exe` (Vulkan).
///
/// Discovery order:
/// 1. Explicit [configuredBinaryPath] (dev override)
/// 2. Bundled runtime (production)
/// 3. Application Support copy (optional update channel later)
/// 4. Homebrew / PATH — **debug builds only**
class DesktopRuntimeManager extends ChangeNotifier {
  DesktopRuntimeManager._();
  static final DesktopRuntimeManager instance = DesktopRuntimeManager._();

  static const int defaultPort = 8741;
  static const String defaultHost = '127.0.0.1';

  static const _trayChannel = MethodChannel('lm_mini/desktop_tray');

  Process? _process;
  String? _binaryPath;
  String? _loadedModelPath;
  String? _lastError;
  int _port = defaultPort;
  final StringBuffer _stderrBuf = StringBuffer();
  DateTime? _lastLogAt;

  /// Optional user/override path to `llama-server` (dev only).
  String? configuredBinaryPath;

  /// Resolves the GGUF model path to load when a remote/USB phone asks for the
  /// builtin backend but the runtime isn't running yet. Set by
  /// [DesktopHostService]. Returns `null` when no GGUF model is available.
  Future<String?> Function()? builtinModelResolver;

  /// Every downloaded GGUF (full paths — the id llama-server reports) a phone
  /// may switch to. Set by [DesktopHostService].
  Future<List<String>> Function()? builtinModelLister;

  /// True while a phone request is being served through the host proxy. A
  /// model switch must not kill that generation. Set by the proxy.
  bool Function()? isBusy;

  /// How long a Mac-side switch to another model waits for a phone request
  /// to finish before giving up (the caller then falls back).
  static const Duration busyWait = Duration(seconds: 60);

  /// The one start in progress, whoever asked (Mac chat, phone, warm-up).
  Future<bool>? _startInFlight;
  String? _startInFlightModel;
  Future<bool>? _ensureBuiltinInFlight;
  int? _ramBytes;
  bool _ramProbed = false;

  bool get isRunning => _process != null;
  bool get isStarting => _startInFlight != null;

  /// Model the in-progress start is loading (null when idle).
  String? get startingModelPath => _startInFlightModel;
  String? get binaryPath => _binaryPath;
  String? get loadedModelPath => _loadedModelPath;
  String? get lastError => _lastError;
  int get port => _port;
  String get baseUrl => 'http://$defaultHost:$_port';

  int _localStreams = 0;

  /// [DesktopSidecarClient] brackets each Mac-side chat stream with this so a
  /// phone's model switch doesn't kill the Mac's own answer either.
  void markLocalStream(bool active) {
    _localStreams += active ? 1 : -1;
    if (_localStreams < 0) _localStreams = 0;
  }

  /// A phone (via the proxy) or the Mac itself is mid-answer on the sidecar.
  bool get isServing => _busy;

  bool get _busy {
    if (_localStreams > 0) return true;
    try {
      return isBusy?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Context window when the caller does not ask for one.
  ///
  /// 16k fits the multi-turn chats phones send without truncating, and with
  /// `--parallel 1` costs ~2 GiB of KV cache on an 8B GQA model (f16 KV,
  /// ~128 KiB/token) — fine next to the weights on a 16 GB Mac. 8 GB Macs keep
  /// the old 8k so the KV cache doesn't push a 4–5 GB model into swap.
  static int contextSizeForRam(int? totalRamBytes) {
    if (totalRamBytes == null || totalRamBytes <= 0) return 16384;
    final gib = totalRamBytes / (1024 * 1024 * 1024);
    return gib <= 8.5 ? 8192 : 16384;
  }

  Future<int> defaultContextSize() async {
    if (!_ramProbed) {
      _ramProbed = true;
      try {
        if (Platform.isMacOS) {
          final r = await Process.run('sysctl', ['-n', 'hw.memsize']);
          if (r.exitCode == 0) {
            _ramBytes = int.tryParse((r.stdout as String).trim());
          }
        }
      } catch (_) {}
    }
    return contextSizeForRam(_ramBytes);
  }

  /// Whether a `llama-server` binary can be found for this build.
  Future<bool> get isBinaryAvailable async =>
      (await resolveBinaryPath()) != null;

  /// Path to the embedded runtime binary, if present.
  String? bundledBinaryPath() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      if (Platform.isWindows) {
        return p.join(exeDir.path, 'runtime', 'llama-server.exe');
      }
      if (Platform.isMacOS) {
        // .../LM Mini.app/Contents/MacOS/<executable>
        return p.join(
            exeDir.parent.path, 'Resources', 'runtime', 'llama-server');
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> resolveBinaryPath() async {
    if (!DesktopPlatform.supportsSidecarRuntime) return null;

    final configured = configuredBinaryPath?.trim();
    if (configured != null &&
        configured.isNotEmpty &&
        await File(configured).exists()) {
      return configured;
    }

    // 1) Shipped with the app (Mac bundle / Windows exe dir)
    final bundled = bundledBinaryPath();
    if (bundled != null && await File(bundled).exists()) {
      return bundled;
    }

    // 2) Application Support (future in-app runtime updates — optional)
    try {
      final support = await getApplicationSupportDirectory();
      final name = Platform.isWindows ? 'llama-server.exe' : 'llama-server';
      final local = File(p.join(support.path, 'runtime', name));
      if (await local.exists()) return local.path;
    } catch (_) {}

    // 3) Dev machines only — never required for store users
    if (kDebugMode) {
      if (Platform.isWindows) {
        try {
          final result = await Process.run('where', ['llama-server.exe']);
          if (result.exitCode == 0) {
            final path =
                (result.stdout as String).trim().split('\n').first.trim();
            if (path.isNotEmpty && await File(path).exists()) return path;
          }
        } catch (_) {}
      } else {
        const candidates = <String>[
          '/opt/homebrew/bin/llama-server',
          '/usr/local/bin/llama-server',
          '/opt/homebrew/opt/llama.cpp/bin/llama-server',
          '/usr/local/opt/llama.cpp/bin/llama-server',
        ];
        for (final path in candidates) {
          if (await File(path).exists()) return path;
        }
        try {
          final result = await Process.run('which', ['llama-server']);
          if (result.exitCode == 0) {
            final path = (result.stdout as String).trim().split('\n').first;
            if (path.isNotEmpty && await File(path).exists()) return path;
          }
        } catch (_) {}
      }
    }

    return null;
  }

  /// Start (or restart) the sidecar with [modelPath] loaded.
  ///
  /// Every start path (Mac chat, phone request, warm-up, model switch) goes
  /// through one in-flight future: a second caller for the same model joins
  /// it; a caller for a different model waits for it, then switches.
  ///
  /// A switch to a different model waits up to [busyWait] for an in-flight
  /// phone request to finish unless [ignoreBusy] (the proxy already checked).
  Future<bool> ensureStarted({
    required String modelPath,
    int? port,
    int? contextSize,
    bool ignoreBusy = false,
  }) async {
    if (!DesktopPlatform.supportsSidecarRuntime) {
      _lastError = 'Desktop runtime is only available on Mac/Windows.';
      notifyListeners();
      return false;
    }
    while (true) {
      final pending = _startInFlight;
      if (pending == null) break;
      if (_startInFlightModel == modelPath) return pending;
      await pending;
    }
    // No await between the check above and claiming the slot.
    final future = _start(
      modelPath: modelPath,
      port: port,
      contextSize: contextSize,
      ignoreBusy: ignoreBusy,
    );
    _startInFlight = future;
    _startInFlightModel = modelPath;
    notifyListeners();
    try {
      return await future;
    } finally {
      if (identical(_startInFlight, future)) {
        _startInFlight = null;
        _startInFlightModel = null;
      }
      notifyListeners();
    }
  }

  Future<bool> _waitUntilIdle() async {
    final deadline = DateTime.now().add(busyWait);
    while (_busy) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return true;
  }

  Future<bool> _start({
    required String modelPath,
    int? port,
    int? contextSize,
    required bool ignoreBusy,
  }) async {
    final modelFile = File(modelPath);
    if (!await modelFile.exists()) {
      _lastError = 'Model file not found: $modelPath';
      return false;
    }

    if (isRunning && _loadedModelPath == modelPath) {
      // Mid-generation a /health probe can time out; never restart the model
      // a phone is streaming from.
      if (_busy || await _healthOk()) return true;
    }

    if (isRunning && _loadedModelPath != modelPath && !ignoreBusy) {
      if (!await _waitUntilIdle()) {
        _lastError = '${DesktopPlatform.thisMachine} is answering a phone '
            'request with another model. Try again when it finishes.';
        return false;
      }
    }

    await stop();

    final binary = await resolveBinaryPath();
    if (binary == null) {
      _lastError = Platform.isWindows
          ? 'Desktop runtime is missing from this app build. '
              'Reinstall LM Mini Home.'
          : 'Desktop runtime is missing from this app build. '
              'Update LM Mini from the Mac App Store, or reinstall the app.';
      return false;
    }

    // Ensure execute bit (sometimes lost when copying resources).
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['+x', binary]);
      } catch (_) {}
    }

    _lastError = null;
    final chosenPort = await _choosePort(port ?? defaultPort);
    if (chosenPort == null) {
      _lastError = 'Ports ${port ?? defaultPort}–${(port ?? defaultPort) + 19} '
          'are all in use by other apps. Quit one and try again.';
      return false;
    }
    _port = chosenPort;
    _binaryPath = binary;
    final ctx = contextSize ?? await defaultContextSize();
    notifyListeners();

    try {
      final args = <String>[
        '--host',
        defaultHost,
        '--port',
        '$_port',
        '-m',
        modelPath,
        '-c',
        '$ctx',
        '-ngl',
        '99',
        '--parallel',
        '1',
        // Hybrid Qwen 3.x templates: per-request enable_thinking / budget.
        '--reasoning',
        'auto',
      ];
      final mmproj = _siblingMmproj(modelPath);
      if (mmproj != null) {
        args.addAll(['--mmproj', mmproj]);
      }

      debugPrint('🖥️ DesktopRuntime: starting $binary ${args.join(' ')}');
      final binDir = File(binary).parent.path;
      _stderrBuf.clear();
      _lastLogAt = DateTime.now();
      final proc = await Process.start(
        binary,
        args,
        runInShell: false,
        workingDirectory: binDir,
        mode: ProcessStartMode.normal,
      );
      _process = proc;
      _loadedModelPath = modelPath;
      await _rememberPid(proc.pid);
      await _notifyNativeSidecarPid(proc.pid);

      void onLog(String prefix, String data) {
        final text = data.trim();
        if (text.isEmpty) return;
        _lastLogAt = DateTime.now();
        debugPrint('$prefix $text');
      }

      proc.stdout.transform(utf8.decoder).listen((data) {
        onLog('llama-server:', data);
      });
      proc.stderr.transform(utf8.decoder).listen((data) {
        onLog('llama-server err:', data);
        if (_stderrBuf.length < 4000) _stderrBuf.write(data);
      });
      unawaited(proc.exitCode.then((code) async {
        debugPrint('🖥️ DesktopRuntime: llama-server exited ($code)');
        if (identical(_process, proc)) {
          _process = null;
          _loadedModelPath = null;
          if (code != 0 && _lastError == null) {
            _lastError = _formatExitError(code);
          }
          notifyListeners();
          await _notifyNativeSidecarPid(0);
        }
      }));

      int? bytes;
      try {
        bytes = await modelFile.length();
      } catch (_) {}
      final ready = await _waitForHealth(
        proc,
        timeout: SidecarLoadTiming.timeoutForModelBytes(bytes),
      );
      if (!ready) {
        // Let stderr drain into the buffer before composing the UI error.
        await Future<void>.delayed(const Duration(milliseconds: 80));
        _lastError ??= _formatExitError(null) ??
            'Desktop runtime failed to start. Please try again.';
        await stop();
        return false;
      }
      return true;
    } catch (e) {
      _lastError = 'Could not start desktop runtime.';
      debugPrint('🖥️ DesktopRuntime start error: $e');
      await stop();
      return false;
    }
  }

  /// [preferred] unless another app (not our llama-server — that was reaped)
  /// already listens there; then the next free port above it.
  Future<int?> _choosePort(int preferred) async {
    for (var p = preferred; p < preferred + 20; p++) {
      if (!await _portInUse(p)) return p;
      if (p == preferred) {
        debugPrint('🖥️ DesktopRuntime: :$p is taken by another app — '
            'using the next free port');
      }
    }
    return null;
  }

  Future<bool> _portInUse(int port) async {
    Socket? s;
    try {
      s = await Socket.connect(defaultHost, port,
          timeout: const Duration(milliseconds: 400));
      return true;
    } catch (_) {
      return false;
    } finally {
      s?.destroy();
    }
  }

  /// Ensure the builtin sidecar is running so a phone's builtin-backend request
  /// can be proxied. Any model already loaded (or loading — e.g. started from
  /// the Mac's own chat) is used as-is; only an idle runtime starts with the
  /// model from [builtinModelResolver]. Joins any in-flight start so a phone
  /// probe never restarts a load in progress.
  ///
  /// Returns `false` (with [lastError] set) when no GGUF model is available or
  /// the runtime could not start — the proxy turns this into a clear 503.
  Future<bool> ensureBuiltinRunning({int? contextSize}) async {
    if (!DesktopPlatform.supportsSidecarRuntime) return false;
    final pending = _startInFlight;
    if (pending != null) return pending;
    if (isRunning && (_busy || await _healthOk())) return true;

    // Coalesce concurrent callers (relay delivers requests in parallel).
    final inFlight = _ensureBuiltinInFlight;
    if (inFlight != null) return inFlight;

    final future = () async {
      final started = _startInFlight;
      if (started != null) return started;
      final loaded = _loadedModelPath;
      if (isRunning && loaded != null) {
        // Running but unhealthy: restart the same model, never a different one.
        return ensureStarted(modelPath: loaded, contextSize: contextSize);
      }
      final resolver = builtinModelResolver;
      if (resolver == null) {
        _lastError =
            'No on-device model is selected on ${DesktopPlatform.thisMachine}. '
            'Open LM Mini Home and pick a model to share.';
        notifyListeners();
        return false;
      }
      final modelPath = await resolver();
      if (modelPath == null || modelPath.isEmpty) {
        _lastError = 'No downloaded GGUF model to share. '
            'Download an on-device model in LM Mini Home first.';
        notifyListeners();
        return false;
      }
      return ensureStarted(modelPath: modelPath, contextSize: contextSize);
    }();

    _ensureBuiltinInFlight = future;
    try {
      return await future;
    } finally {
      _ensureBuiltinInFlight = null;
    }
  }

  /// Kill leftover `llama-server` on the sidecar port from a previous app
  /// session (Cmd-Q / crash often reparents the child to launchd).
  ///
  /// Only processes whose executable is `llama-server` are killed — another
  /// app listening on the port is left alone ([ensureStarted] then picks a
  /// free port). Does not touch other ports (LM Studio, etc.).
  Future<void> reapStaleSidecar({int? exceptPid}) async {
    if (!DesktopPlatform.supportsSidecarRuntime) return;
    final skip = exceptPid ?? _process?.pid;
    final candidates = <int>{...await _pidsListeningOnPort(_port)};
    final stored = await _readStoredPid();
    if (stored != null) candidates.add(stored);
    final pids = <int>{};
    for (final pid in candidates) {
      if (skip != null && pid == skip) continue;
      if (SidecarPort.commandIsLlamaServer(await _pidCommandName(pid))) {
        pids.add(pid);
      } else if (pid != stored) {
        debugPrint('🖥️ DesktopRuntime: :$_port is held by pid=$pid '
            '(not llama-server) — leaving it alone');
      }
    }
    for (final pid in pids) {
      debugPrint(
          '🖥️ DesktopRuntime: reaping stale sidecar pid=$pid on :$_port');
      Process.killPid(pid, ProcessSignal.sigterm);
    }
    if (pids.isEmpty) {
      if (skip == null) await _clearPidFile();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 400));
    for (final pid in pids) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    if (skip == null) await _clearPidFile();
  }

  Future<String?> _pidCommandName(int pid) async {
    if (pid <= 1) return null;
    try {
      if (Platform.isWindows) {
        final result = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        final out = (result.stdout as String).trim().toLowerCase();
        if (out.isEmpty || out.contains('no tasks')) return null;
        return out;
      }
      final result = await Process.run('ps', ['-p', '$pid', '-o', 'comm=']);
      if (result.exitCode != 0) return null;
      final name = (result.stdout as String).trim().toLowerCase();
      return name.isEmpty ? null : name;
    } catch (_) {
      return null;
    }
  }

  Future<void> _notifyNativeSidecarPid(int pid) async {
    try {
      await _trayChannel
          .invokeMethod('setSidecarPid', {'pid': pid, 'port': _port});
    } catch (_) {}
  }

  Future<File> _pidFile() async {
    final support = await getApplicationSupportDirectory();
    return File(p.join(support.path, 'llama-server.pid'));
  }

  Future<void> _rememberPid(int pid) async {
    try {
      await (await _pidFile()).writeAsString('$pid');
    } catch (e) {
      debugPrint('🖥️ DesktopRuntime: could not write pid file: $e');
    }
  }

  Future<int?> _readStoredPid() async {
    try {
      final f = await _pidFile();
      if (!await f.exists()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearPidFile() async {
    try {
      final f = await _pidFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<Set<int>> _pidsListeningOnPort(int port) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('netstat', ['-ano', '-p', 'TCP']);
        if (result.exitCode != 0) return {};
        return SidecarPort.parseNetstatListeningPids(
          result.stdout as String,
          port,
        );
      }
      final result = await Process.run('lsof', [
        '-nP',
        '-iTCP:$port',
        '-sTCP:LISTEN',
        '-t',
      ]);
      if (result.exitCode != 0 && result.exitCode != 1) return {};
      return SidecarPort.parseLsofPids(result.stdout as String);
    } catch (e) {
      debugPrint('🖥️ DesktopRuntime: port scan failed: $e');
      return {};
    }
  }

  Future<void> stop() async {
    final proc = _process;
    _process = null;
    _loadedModelPath = null;
    if (proc != null) {
      proc.kill(ProcessSignal.sigterm);
      try {
        await proc.exitCode.timeout(const Duration(seconds: 3));
      } catch (_) {
        proc.kill(ProcessSignal.sigkill);
      }
    }
    await _notifyNativeSidecarPid(0);
    await reapStaleSidecar();
    notifyListeners();
  }

  /// Polls `/health` until ready. Fails fast when [proc] exits; otherwise
  /// waits [timeout] (scaled to the model size) and keeps going while the
  /// server still logs load progress, up to [SidecarLoadTiming.hardCap].
  Future<bool> _waitForHealth(Process proc, {required Duration timeout}) async {
    final started = DateTime.now();
    while (true) {
      if (!identical(_process, proc)) return false;
      if (await _healthOk()) return true;
      if (!identical(_process, proc)) return false;
      final now = DateTime.now();
      final last = _lastLogAt;
      if (!SidecarLoadTiming.shouldKeepWaiting(
        elapsed: now.difference(started),
        timeout: timeout,
        sinceLastLog: last == null ? null : now.difference(last),
      )) {
        debugPrint('🖥️ DesktopRuntime: not healthy after '
            '${now.difference(started).inSeconds}s — giving up');
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }

  String? _siblingMmproj(String modelPath) {
    final dir = File(modelPath).parent;
    try {
      final matches = dir.listSync().whereType<File>().where((f) {
        final name = f.path.split(Platform.pathSeparator).last.toLowerCase();
        return name.contains('mmproj') && name.endsWith('.gguf');
      }).toList();
      if (matches.isEmpty) return null;
      return matches.first.path;
    } catch (_) {
      return null;
    }
  }

  String? _formatExitError(int? code) {
    final detail = _stderrBuf.toString().trim();
    if (detail.isEmpty) {
      return code == null
          ? null
          : 'Desktop runtime exited unexpectedly (code $code).';
    }
    final lines = detail
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .where((l) {
      final lower = l.toLowerCase();
      if (lower.startsWith('warning:')) return false;
      if (lower.contains('ggml_print_backtrace')) return false;
      if (RegExp(r'^\d+\s+\S+\s+0x').hasMatch(l)) return false;
      return true;
    }).toList();
    final errors = lines.where((l) {
      final lower = l.toLowerCase();
      return lower.contains('failed') ||
          lower.contains('no backends') ||
          lower.contains('filesystem error') ||
          lower.contains('terminating') ||
          lower.contains('error') ||
          RegExp(r'\sE\s').hasMatch(l);
    }).toList();
    final compact = (errors.isNotEmpty ? errors : lines).take(3).join(' ');
    final clipped =
        compact.length > 280 ? '${compact.substring(0, 277)}…' : compact;
    return code == null ? clipped : '$clipped (code $code)';
  }

  Future<bool> _healthOk() async {
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 2);
      final req = await client.getUrl(Uri.parse('$baseUrl/health'));
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      client.close(force: true);
      return res.statusCode == 200;
    } catch (_) {
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 2);
        final req = await client.getUrl(Uri.parse('$baseUrl/v1/models'));
        final res = await req.close().timeout(const Duration(seconds: 2));
        await res.drain<void>();
        client.close(force: true);
        return res.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
  }
}
