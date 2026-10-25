import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/image_generation_service.dart';

void main() {
  final samplers = [
    SDSampler(name: 'Euler a', aliases: ['k_euler_a']),
    SDSampler(name: 'DPM++ 2M', aliases: ['k_dpmpp_2m']),
  ];
  final schedulers = [SDScheduler(name: 'karras', label: 'Karras')];

  test('ComfyUI 64-bit seed is folded into A1111 range', () {
    final out = ImageGenerationService.sanitizeForA1111(
        {'seed': 653398668424168});
    expect(out['seed'], 653398668424168 % 0x100000000);
    expect(out['seed'], lessThanOrEqualTo(0xFFFFFFFF));
    expect(ImageGenerationService.sanitizeForA1111({'seed': -1})['seed'], -1);
    expect(ImageGenerationService.sanitizeForA1111({'seed': 42})['seed'], 42);
  });

  test('unknown sampler / scheduler is dropped, known ones kept', () {
    final out = ImageGenerationService.sanitizeForA1111(
      {'sampler_name': 'res_multistep', 'scheduler': 'beta57'},
      samplers: samplers,
      schedulers: schedulers,
    );
    expect(out.containsKey('sampler_name'), isFalse);
    expect(out.containsKey('scheduler'), isFalse);

    final kept = ImageGenerationService.sanitizeForA1111(
      {'sampler_name': 'euler a', 'scheduler': 'Karras'},
      samplers: samplers,
      schedulers: schedulers,
    );
    expect(kept['sampler_name'], 'euler a');
    expect(kept['scheduler'], 'Karras');
  });

  test('without the server lists, names are left alone', () {
    final out = ImageGenerationService.sanitizeForA1111(
        {'sampler_name': 'res_multistep'});
    expect(out['sampler_name'], 'res_multistep');
  });
}
