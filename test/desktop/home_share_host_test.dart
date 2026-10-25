import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/desktop/host/desktop_host_capabilities.dart';
import 'package:lm_mini/desktop/host/desktop_host_service.dart';
import 'package:lm_mini/desktop/host/desktop_relay_client.dart';
import 'package:lm_mini/desktop/host/desktop_request_proxy.dart';
import 'package:lm_mini/desktop/runtime/desktop_runtime_manager.dart';
import 'package:lm_mini/desktop/runtime/sidecar_load_timing.dart';
import 'package:lm_mini/desktop/runtime/sidecar_port.dart';

const _gib = 1024 * 1024 * 1024;

void main() {
  group('SidecarLoadTiming', () {
    test('scales 45 s + 20 s per GiB', () {
      expect(SidecarLoadTiming.timeoutForModelBytes(null),
          const Duration(seconds: 45));
      expect(SidecarLoadTiming.timeoutForModelBytes(0),
          const Duration(seconds: 45));
      expect(SidecarLoadTiming.timeoutForModelBytes(1 * _gib),
          const Duration(seconds: 65));
      expect(SidecarLoadTiming.timeoutForModelBytes(5 * _gib),
          const Duration(seconds: 145));
    });

    test('caps at 6 minutes', () {
      expect(SidecarLoadTiming.timeoutForModelBytes(40 * _gib),
          const Duration(minutes: 6));
    });

    test('keeps waiting past the timeout only while the server logs', () {
      const timeout = Duration(seconds: 60);
      expect(
        SidecarLoadTiming.shouldKeepWaiting(
            elapsed: const Duration(seconds: 30), timeout: timeout),
        isTrue,
      );
      expect(
        SidecarLoadTiming.shouldKeepWaiting(
          elapsed: const Duration(seconds: 90),
          timeout: timeout,
          sinceLastLog: const Duration(seconds: 3),
        ),
        isTrue,
      );
      expect(
        SidecarLoadTiming.shouldKeepWaiting(
          elapsed: const Duration(seconds: 90),
          timeout: timeout,
          sinceLastLog: const Duration(seconds: 45),
        ),
        isFalse,
      );
      expect(
        SidecarLoadTiming.shouldKeepWaiting(
            elapsed: const Duration(seconds: 90), timeout: timeout),
        isFalse,
      );
      expect(
        SidecarLoadTiming.shouldKeepWaiting(
          elapsed: const Duration(minutes: 11),
          timeout: timeout,
          sinceLastLog: Duration.zero,
        ),
        isFalse,
      );
    });
  });

  group('SidecarPort.commandIsLlamaServer', () {
    test('matches the bundled binary on macOS (ps comm= is a full path)', () {
      expect(
        SidecarPort.commandIsLlamaServer(
            '/Applications/LM Mini.app/Contents/Resources/runtime/llama-server\n'),
        isTrue,
      );
      expect(SidecarPort.commandIsLlamaServer('llama-server'), isTrue);
      expect(
          SidecarPort.commandIsLlamaServer('/opt/homebrew/bin/llama-server'),
          isTrue);
    });

    test('matches the Windows tasklist CSV row', () {
      expect(
        SidecarPort.commandIsLlamaServer(
            '"llama-server.exe","4242","Console","1","1,234 K"'),
        isTrue,
      );
      expect(
        SidecarPort.commandIsLlamaServer(
            '"node.exe","4242","Console","1","1,234 K"'),
        isFalse,
      );
    });

    test('rejects other processes on the port', () {
      expect(SidecarPort.commandIsLlamaServer(null), isFalse);
      expect(SidecarPort.commandIsLlamaServer(''), isFalse);
      expect(SidecarPort.commandIsLlamaServer('/usr/bin/python3'), isFalse);
      expect(
        SidecarPort.commandIsLlamaServer('/usr/local/bin/llama-server-proxy'),
        isFalse,
      );
      expect(SidecarPort.commandIsLlamaServer('node'), isFalse);
    });
  });

  test('context size keeps 8k on 8 GB Macs, 16k otherwise', () {
    expect(DesktopRuntimeManager.contextSizeForRam(null), 16384);
    expect(DesktopRuntimeManager.contextSizeForRam(8 * _gib), 8192);
    expect(DesktopRuntimeManager.contextSizeForRam(16 * _gib), 16384);
    expect(DesktopRuntimeManager.contextSizeForRam(64 * _gib), 16384);
  });

  group('model list', () {
    const loaded = '/m/qwen3-8b-q4_k_m.gguf';
    const other = '/m/gemma-3-4b-q4_0.gguf';

    test('merges downloaded GGUFs after the loaded one, without duplicates',
        () {
      final merged = DesktopRequestProxy.mergeDownloadedModels({
        'object': 'list',
        'data': [
          {'id': loaded, 'object': 'model', 'owned_by': 'llamacpp'},
        ],
      }, [loaded, other]);
      final data = merged['data'] as List;
      expect(data.map((e) => (e as Map)['id']), [loaded, other]);
      expect((data[1] as Map)['status'], {'value': 'unloaded'});
      expect((data[0] as Map).containsKey('status'), isFalse);
    });

    test('LM Studio V1 shape marks only the loaded model as loaded', () {
      final v1 = DesktopRequestProxy.openaiModelsToLmStudioV1(
        DesktopRequestProxy.mergeDownloadedModels({
          'data': [
            {'id': loaded, 'object': 'model', 'owned_by': 'llamacpp'},
          ],
        }, [other]),
        visionFromProps: true,
      );
      final models = (v1['models'] as List).cast<Map>();
      expect(models.map((m) => m['key']), [loaded, other]);
      expect(models[0]['loaded_instances'], isNotEmpty);
      expect(models[0]['type'], 'vlm');
      expect(models[1]['loaded_instances'], isEmpty);
      expect(models[1]['type'], 'llm');
    });

    test('cold probe lists the model about to load plus the rest', () {
      final v1 = DesktopRequestProxy.syntheticProbeBody(
        '/api/v1/models',
        modelId: loaded,
        otherModelIds: [loaded, other],
      );
      final keys = (v1['models'] as List).map((m) => (m as Map)['key']);
      expect(keys, [loaded, other]);

      final openai = DesktopRequestProxy.syntheticProbeBody(
        '/v1/models',
        otherModelIds: [other],
      );
      expect((openai['data'] as List).single['id'], other);

      expect(
        DesktopRequestProxy.syntheticProbeBody('/api/v1/models'),
        {'models': <dynamic>[]},
      );
    });

    test('matches requested ids by path, then by file name', () {
      expect(DesktopRequestProxy.matchDownloadedModel(other, [loaded, other]),
          other);
      expect(
        DesktopRequestProxy.matchDownloadedModel(
            'gemma-3-4b-q4_0.gguf', [loaded, other]),
        other,
      );
      expect(DesktopRequestProxy.matchDownloadedModel('gpt-4o', [loaded]),
          isNull);
      expect(DesktopRequestProxy.matchDownloadedModel(null, [loaded]), isNull);
    });

    test('switches only to a different downloaded model when not busy', () {
      String? target({String? requested, String? current, bool busy = false}) =>
          DesktopRequestProxy.modelSwitchTarget(
            requested: requested,
            loaded: current,
            available: const [loaded, other],
            otherBusy: busy,
          );
      expect(target(requested: other, current: loaded), other);
      expect(target(requested: loaded, current: loaded), isNull);
      expect(target(requested: other, current: loaded, busy: true), isNull);
      expect(target(requested: 'local', current: loaded), isNull);
      expect(target(requested: null, current: loaded), isNull);
      // Cold runtime: start straight with the requested model.
      expect(target(requested: other, current: null), other);
    });

    test('reads model from plain and base64 JSON bodies', () {
      final json = jsonEncode({'model': other, 'messages': []});
      expect(DesktopRequestProxy.requestedModelOf(json, null), other);
      expect(
        DesktopRequestProxy.requestedModelOf(
            base64Encode(utf8.encode(json)), 'base64'),
        other,
      );
      expect(DesktopRequestProxy.requestedModelOf('not json', null), isNull);
      expect(DesktopRequestProxy.requestedModelOf(null, null), isNull);
      expect(
          DesktopRequestProxy.requestedModelOf('{"model": ""}', null), isNull);
    });
  });

  group('host status', () {
    test('advertises version 2.1.0 and capabilities', () {
      final payload = DesktopRequestProxy.hostStatusPayload(
        const DesktopRelayBackends(reachable: {'lmMiniDesktop': true}),
      );
      expect(payload['connectVersion'], '2.1.0');
      expect(DesktopHostService.hostVersion, desktopHostVersion);
      expect(payload['capabilities'],
          containsAll(['cancel', 'utf8Stream', 'modelSwitch', 'syncManifest']));
    });

    test('builtin is not reachable unless the host says it can serve', () {
      final payload = DesktopRequestProxy.hostStatusPayload(
        const DesktopRelayBackends(advertiseBuiltin: true),
      );
      expect((payload['reachable'] as Map)['lmMiniDesktop'], isFalse);
    });

    test('builtinReachable needs a model and the runtime, or a running one',
        () {
      bool r(bool running, bool model, bool binary) =>
          DesktopHostService.builtinReachable(
              running: running, hasModel: model, binaryReady: binary);
      expect(r(false, false, true), isFalse);
      expect(r(false, true, false), isFalse);
      expect(r(false, true, true), isTrue);
      expect(r(true, false, false), isTrue);
    });
  });
}
