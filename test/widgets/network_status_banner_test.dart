import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/l10n/app_localizations.dart';
import 'package:lm_mini/providers/chat_provider.dart';
import 'package:lm_mini/providers/settings_provider.dart';
import 'package:lm_mini/providers/theme_provider.dart';
import 'package:lm_mini/utils/connection_issue.dart';
import 'package:lm_mini/widgets/network_status_banner.dart';
import 'package:provider/provider.dart';

Widget _host(ConnectionIssue? issue) => MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: NetworkStatusBanner(issue: issue)),
      ),
    );

const _needsWifi = ConnectionIssue(
  ConnectionIssueKind.needsWifi,
  source: ConnectionIssueSource.connection,
  provider: 'LM Studio',
  host: '192.168.1.5',
);
const _needsWifiAfterSend = ConnectionIssue(
  ConnectionIssueKind.needsWifi,
  source: ConnectionIssueSource.chat,
  provider: 'LM Studio',
  host: '192.168.1.5',
);
const _offline = ConnectionIssue(
  ConnectionIssueKind.offline,
  source: ConnectionIssueSource.chat,
);

void main() {
  setUp(() => NetworkStatusBanner.closedThisSession = false);

  testWidgets('shows a closable banner for a failed connection',
      (tester) async {
    await tester.pumpWidget(_host(_needsWifi));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('once closed it stays hidden for the session, even after '
      'another failed send or a different issue', (tester) async {
    await tester.pumpWidget(_host(_needsWifi));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.pumpWidget(_host(_needsWifiAfterSend));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);

    await tester.pumpWidget(_host(_offline));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.close), findsNothing);
    expect(NetworkStatusBanner.closedThisSession, isTrue);
  });

  testWidgets('no issue, no banner', (tester) async {
    await tester.pumpWidget(_host(null));
    await tester.pump();
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
