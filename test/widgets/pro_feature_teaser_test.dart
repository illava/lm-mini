import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/l10n/app_localizations.dart';
import 'package:lm_mini/models/paywall_feature.dart';
import 'package:lm_mini/widgets/pro_feature_teaser.dart';

void main() {
  const animated = [
    PaywallFeature.webSearch,
    PaywallFeature.codeSandbox,
    PaywallFeature.export,
    PaywallFeature.groupChat,
    PaywallFeature.remoteAccess,
    PaywallFeature.liveActivity,
    PaywallFeature.compactChat,
    PaywallFeature.appLock,
    PaywallFeature.branching,
    PaywallFeature.analytics,
    PaywallFeature.cloudBackup,
    PaywallFeature.huggingFace,
    PaywallFeature.memory,
  ];

  for (final feature in animated) {
    for (final width in [320.0, 430.0]) {
      testWidgets('${feature.name} scene fits a ${width.toInt()}px stage',
          (tester) async {
        await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                child: proFeatureAnimation(feature)!,
              ),
            ),
          ),
        ));
        // Step through the whole loop; any overflow throws here.
        for (var i = 0; i < 14; i++) {
          await tester.pump(const Duration(milliseconds: 400));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  test('features without a scene return null', () {
    expect(proFeatureAnimation(PaywallFeature.urlReader), isNull);
  });
}
