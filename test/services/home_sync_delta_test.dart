import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_conversation.dart';
import 'package:lm_mini/services/home_sync_service.dart';
import 'package:lm_mini/services/home_sync_snapshot.dart';

ChatConversation _c({
  String title = 'Trip',
  String? folderId,
  Map<String, dynamic> settings = const {},
  int at = 1000,
}) =>
    ChatConversation(
      id: 'c1',
      title: title,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(at),
      messageIds: const [],
      settings: settings,
      folderId: folderId,
    );

void main() {
  test('polls every minute, backs off to 10 minutes when the Mac is away',
      () {
    expect(HomeSyncService.nextPollDelay(0), const Duration(seconds: 60));
    expect(HomeSyncService.nextPollDelay(1), const Duration(minutes: 2));
    expect(HomeSyncService.nextPollDelay(3), const Duration(minutes: 8));
    expect(HomeSyncService.nextPollDelay(9), const Duration(minutes: 10));
  });

  test('manifest entry changes with the chat, its folder and its messages',
      () {
    final base = HomeSyncManifest.entry(_c(), '3|100|42|0|0|0|0');
    expect(HomeSyncManifest.entry(_c(), '3|100|42|0|0|0|0'), base);
    expect(HomeSyncManifest.entry(_c(), '3|100|50|0|0|0|0'), isNot(base));
    expect(HomeSyncManifest.entry(_c(folderId: 'work'), '3|100|42|0|0|0|0'),
        isNot(base));
    expect(HomeSyncManifest.entry(_c(at: 2000), '3|100|42|0|0|0|0'),
        isNot(base));
  });

  test('untouched New Chats are never synced', () {
    final draft = _c(settings: const {'isDraft': true});
    expect(HomeSyncManifest.isEmptyDraft(draft, 0), isTrue);
    expect(HomeSyncManifest.isEmptyDraft(draft, 1), isFalse);
    expect(HomeSyncManifest.isEmptyDraft(_c(), 0), isFalse);
    expect(HomeSyncManifest.messageCount('5|1|2|0|0|0|0'), 5);
    expect(HomeSyncManifest.messageCount(null), 0);
  });

  test('known manifest round-trips and older payloads have none', () {
    const snap = HomeSyncSnapshot(known: {'c1': 'x'});
    expect(HomeSyncSnapshot.fromJson(snap.toJson()).known, {'c1': 'x'});
    expect(HomeSyncSnapshot.fromJson(const HomeSyncSnapshot().toJson()).known,
        isNull);
  });
}
