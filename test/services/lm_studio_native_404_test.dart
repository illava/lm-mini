import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/services/lm_studio_service.dart';

void main() {
  test('404 from LM Studio chat API on a non-LM Studio server explains why',
      () {
    expect(LMStudioService.nativeChatErrorMessage(404, '404: Not Found'),
        LMStudioService.notLmStudioApiMessage);
  });

  test('other statuses keep their usual messages', () {
    expect(
      LMStudioService.nativeChatErrorMessage(503, ''),
      isNot(LMStudioService.notLmStudioApiMessage),
    );
  });
}
