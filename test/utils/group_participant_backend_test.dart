import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/local_model_spec.dart';
import 'package:lm_mini/utils/group_participant_backend.dart';

void main() {
  test('stored kind wins over later global Settings', () {
    expect(
      GroupParticipantBackend.resolve(
        storedKind: 'lmStudio',
        globalKind: 'onDeviceGguf',
        modelId: 'local-qwen',
        isLocalGguf: (_) => true,
      ),
      'lmStudio',
    );
  });

  test('persona default fills a missing stored kind', () {
    expect(
      GroupParticipantBackend.resolve(
        personaKind: 'lmStudio',
        globalKind: 'onDeviceGguf',
        modelId: 'qwen-27b',
      ),
      'lmStudio',
    );
  });

  test('infers on-device from model id instead of global LM Studio', () {
    expect(
      GroupParticipantBackend.resolve(
        globalKind: 'lmStudio',
        modelId: 'qwen3-4b',
        isLocalGguf: (id) => id == 'qwen3-4b',
        isLmStudioModel: (_) => true,
      ),
      'onDeviceGguf',
    );
  });

  test('infers LM Studio from model id instead of global llama.cpp', () {
    expect(
      GroupParticipantBackend.resolve(
        globalKind: 'onDeviceGguf',
        modelId: 'Qwen3.6-27B-NEO-CODE',
        isLocalGguf: (_) => false,
        isLmStudioModel: (id) => id.contains('Qwen3.6'),
      ),
      'lmStudio',
    );
  });

  test('cloud provider id is stronger than global', () {
    expect(
      GroupParticipantBackend.resolve(
        cloudProviderKind: 'ollama',
        globalKind: 'onDeviceGguf',
        modelId: 'llama3.2',
      ),
      'ollama',
    );
  });

  test('unknown stored kind is ignored in favor of persona', () {
    expect(
      GroupParticipantBackend.resolve(
        storedKind: 'legacyFoo',
        personaKind: 'lmStudio',
        globalKind: 'onDeviceGguf',
      ),
      'lmStudio',
    );
  });

  group('configError', () {
    test('Apple Intelligence is valid unless the OS says no', () {
      expect(
        GroupParticipantBackend.configError(
          kind: 'appleIntelligence',
          displayName: 'Apple',
          modelId: 'Apple Intelligence',
          appleIntelligenceAvailable: true,
        ),
        isNull,
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'appleIntelligence',
          displayName: 'Apple',
          modelId: '',
        ),
        isNull,
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'appleIntelligence',
          displayName: 'Apple',
          modelId: 'Apple Intelligence',
          appleIntelligenceAvailable: false,
        ),
        contains('not available'),
      );
    });

    test('LM Mini Home is validated like LM Studio, not "unknown"', () {
      expect(
        GroupParticipantBackend.configError(
          kind: 'lmMiniDesktop',
          displayName: 'Home',
          modelId: 'qwen3-8b',
        ),
        isNull,
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'lmMiniDesktop',
          displayName: 'Home',
          modelId: '',
        ),
        contains('pick a model'),
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'lmMiniDesktop',
          displayName: 'Home',
          modelId: 'gone',
          homeModelKnown: (_) => false,
        ),
        contains('not available on Home'),
      );
    });

    test('on-device engine must match the provider', () {
      expect(
        GroupParticipantBackend.configError(
          kind: 'onDeviceMlx',
          displayName: 'M',
          modelId: 'gemma',
          readyLocalEngine: (_) => LocalEngine.fllama,
        ),
        contains('engine'),
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'onDeviceGguf',
          displayName: 'G',
          modelId: 'gemma',
          readyLocalEngine: (_) => null,
        ),
        contains('not downloaded'),
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'onDeviceGguf',
          displayName: 'G',
          modelId: 'gemma',
          readyLocalEngine: (_) => LocalEngine.fllama,
        ),
        isNull,
      );
    });

    test('LM Studio model must be in a loaded catalog', () {
      expect(
        GroupParticipantBackend.configError(
          kind: 'lmStudio',
          displayName: 'L',
          modelId: 'x',
          lmStudioModelKnown: (_) => false,
        ),
        contains('not available on LM Studio'),
      );
      expect(
        GroupParticipantBackend.configError(
          kind: 'lmStudio',
          displayName: 'L',
          modelId: 'x',
        ),
        isNull,
      );
    });

    test('unknown kinds are rejected', () {
      expect(
        GroupParticipantBackend.configError(
          kind: 'mystery',
          displayName: 'X',
          modelId: 'y',
        ),
        contains('unknown provider'),
      );
    });
  });
}
