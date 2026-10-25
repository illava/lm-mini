import 'package:flutter_test/flutter_test.dart';
import 'package:lm_mini/models/chat_message.dart';
import 'package:lm_mini/models/file_attachment.dart';
import 'package:lm_mini/models/system_prompt.dart';
import 'package:lm_mini/services/home_sync_snapshot.dart';

const _mb = 1024 * 1024;

SystemPrompt _persona(String id, DateTime at) => SystemPrompt(
      id: id,
      name: id,
      content: 'hi',
      createdAt: at,
      updatedAt: at,
    );

Map<String, dynamic> _memory(String content, DateTime at) => {
      'content': content,
      'scope': 'private',
      'personaId': 'p',
      'category': 'general',
      'updatedAt': at.toIso8601String(),
    };

void main() {
  group('HomeSyncFiles.sanitize', () {
    test('accepts plain relative paths in chat folders', () {
      expect(HomeSyncFiles.sanitize('images/1.jpg'), 'images/1.jpg');
      expect(HomeSyncFiles.sanitize(' generated_images/a_1.png '),
          'generated_images/a_1.png');
      expect(HomeSyncFiles.sanitize('attachments/sub/x.pdf'),
          'attachments/sub/x.pdf');
    });

    test('rejects traversal, absolute paths and odd input', () {
      for (final bad in [
        null,
        '',
        '../images/x.jpg',
        'images/../../etc/passwd',
        'images/./x.jpg',
        'images//x.jpg',
        '/images/x.jpg',
        '~/images/x.jpg',
        r'images\x.jpg',
        'C:/images/x.jpg',
        'images/x\u0000.jpg',
        'images',
        'chat.db',
        'Library/Preferences/x.plist',
        'images/${'a' * 500}',
      ]) {
        expect(HomeSyncFiles.sanitize(bad), isNull, reason: '$bad');
      }
    });

    test('wire paths: relative kept, docs-absolute made relative, URLs skipped',
        () {
      const docs = '/var/mobile/Containers/Data/Application/U/Documents';
      expect(HomeSyncFiles.wirePath('images/1.jpg', docsDir: docs),
          'images/1.jpg');
      expect(
        HomeSyncFiles.wirePath('$docs/generated_images/g.png', docsDir: docs),
        'generated_images/g.png',
      );
      // Another device's container: relative part after /Documents/.
      expect(
        HomeSyncFiles.wirePath(
          '/Users/me/Library/Containers/x/Data/Documents/attachments/a.pdf',
          docsDir: docs,
        ),
        'attachments/a.pdf',
      );
      expect(HomeSyncFiles.wirePath('https://x.com/a.png'), isNull);
      expect(HomeSyncFiles.wirePath('data:image/png;base64,AAAA'), isNull);
      expect(HomeSyncFiles.wirePath('/tmp/a.png', docsDir: docs), isNull);
      expect(HomeSyncFiles.wirePath('$docs/../x/images/a.png', docsDir: docs),
          isNull);
    });

    test('collects image, generated and attachment paths from messages', () {
      final at = DateTime(2026);
      final paths = HomeSyncFiles.referencedPaths([
        ChatMessage(
          id: 'm',
          content: '',
          role: 'user',
          timestamp: at,
          imageUrls: const ['images/a.jpg', 'https://x/y.png'],
          generatedImagePaths: const ['/x/Documents/generated_images/g.png'],
          fileAttachments: [
            FileAttachment(
              id: 'f',
              fileName: 'a.pdf',
              filePath: '/y/Documents/attachments/1_a.pdf',
              type: FileAttachmentType.pdf,
              fileSize: 1,
              createdAt: at,
            ),
          ],
        ),
      ]);
      expect(paths, {
        'images/a.jpg',
        'generated_images/g.png',
        'attachments/1_a.pdf',
      });
    });
  });

  group('HomeSyncFiles.plan', () {
    test('skips files over the per-file cap and empty files', () {
      final plan = HomeSyncFiles.plan([
        (path: 'images/big.jpg', size: 9 * _mb),
        (path: 'images/empty.jpg', size: 0),
        (path: 'images/ok.jpg', size: 1 * _mb),
      ]);
      expect(plan.send, ['images/ok.jpg']);
      expect(plan.tooBig, ['images/big.jpg', 'images/empty.jpg']);
      expect(plan.deferred, isEmpty);
    });

    test('defers what does not fit the body budget (base64 counted)', () {
      final plan = HomeSyncFiles.plan([
        for (var i = 0; i < 8; i++) (path: 'images/$i.jpg', size: 6 * _mb),
      ]);
      // 6 MB is 8 MB once encoded: five fit in 40 MB.
      expect(plan.send, [for (var i = 0; i < 5; i++) 'images/$i.jpg']);
      expect(plan.deferred, [for (var i = 5; i < 8; i++) 'images/$i.jpg']);
      // A small file still fits after the big ones are deferred.
      final withSmall = HomeSyncFiles.plan([
        (path: 'images/a.jpg', size: 7 * _mb),
        (path: 'images/b.jpg', size: 7 * _mb),
        (path: 'images/small.jpg', size: 100),
      ], budget: 10 * _mb);
      expect(withSmall.send, ['images/a.jpg', 'images/small.jpg']);
      expect(withSmall.deferred, ['images/b.jpg']);
    });

    test('duplicates are planned once and encoded length matches base64', () {
      final plan = HomeSyncFiles.plan([
        (path: 'images/a.jpg', size: 10),
        (path: 'images/a.jpg', size: 10),
      ]);
      expect(plan.send, ['images/a.jpg']);
      expect(HomeSyncFiles.encodedLength(1), 4);
      expect(HomeSyncFiles.encodedLength(3), 4);
      expect(HomeSyncFiles.encodedLength(4), 8);
    });
  });

  group('JSON', () {
    test('file and memory-tombstone fields round-trip', () {
      final at = DateTime.utc(2026, 1, 2);
      final snap = HomeSyncSnapshot(
        deletedMemories: [HomeSyncTombstone(id: 'private|p|x', deletedAt: at)],
        files: const [HomeSyncFile(path: 'images/a.jpg', data: 'AAEC')],
        wantFiles: const ['images/b.jpg'],
        unavailableFiles: const ['images/c.jpg'],
        fileSync: true,
      );
      final back = HomeSyncSnapshot.fromJson(snap.toJson());
      expect(back.deletedMemories.single.id, 'private|p|x');
      expect(back.deletedMemories.single.deletedAt, at);
      expect(back.files.single.path, 'images/a.jpg');
      expect(back.files.single.data, 'AAEC');
      expect(back.wantFiles, ['images/b.jpg']);
      expect(back.unavailableFiles, ['images/c.jpg']);
      expect(back.fileSync, isTrue);
    });

    test('older payloads have none of the new fields, and none are written',
        () {
      final json = const HomeSyncSnapshot().toJson();
      for (final key in [
        'deletedMemories',
        'files',
        'wantFiles',
        'unavailableFiles',
        'fileSync',
      ]) {
        expect(json.containsKey(key), isFalse, reason: key);
      }
      final back = HomeSyncSnapshot.fromJson({
        'folders': [],
        'conversations': [],
        'files': [
          {'path': 'images/a.jpg'}, // no data: dropped
          'junk',
        ],
      });
      expect(back.files, isEmpty);
      expect(back.deletedMemories, isEmpty);
      expect(back.fileSync, isFalse);
    });

    test('withConversations keeps memory tombstones but drops file bytes', () {
      final snap = HomeSyncSnapshot(
        deletedMemories: [
          HomeSyncTombstone(id: 'k', deletedAt: DateTime.utc(2026)),
        ],
        files: const [HomeSyncFile(path: 'images/a.jpg', data: 'AA==')],
        fileSync: true,
      ).withConversations(const []);
      expect(snap.deletedMemories, hasLength(1));
      expect(snap.files, isEmpty);
      expect(snap.fileSync, isTrue);
    });
  });

  group('memory tombstones', () {
    final older = DateTime.utc(2026, 1, 1);
    final deleted = DateTime.utc(2026, 1, 2);
    final newer = DateTime.utc(2026, 1, 3);

    test('merge drops memories not updated after their tombstone', () {
      final tomb = HomeSyncTombstone(
        id: HomeSyncMerge.memoryKey(_memory('Likes Tea', older)),
        deletedAt: deleted,
      );
      final phone = HomeSyncSnapshot(
        personasEnabled: true,
        syncPersonaIds: const ['p'],
        personasUpdatedAt: older,
        personas: [
          HomeSyncPersona(
            prompt: _persona('p', older),
            memories: [_memory('lives in KL', older)],
          ),
        ],
        deletedMemories: [tomb],
      );
      // The Mac still has the deleted memory (and an older host sends it
      // back on every round).
      final mac = HomeSyncSnapshot(
        personasEnabled: true,
        syncPersonaIds: const ['p'],
        personasUpdatedAt: older,
        personas: [
          HomeSyncPersona(
            prompt: _persona('p', older),
            memories: [
              _memory('likes tea ', older),
              _memory('re-added later', newer),
            ],
          ),
        ],
      );
      final merged = HomeSyncMerge.merge(phone, mac);
      expect(
        merged.personas.single.memories.map((m) => m['content']).toSet(),
        {'lives in KL', 're-added later'},
      );
      expect(merged.deletedMemories.single.id, tomb.id);

      // Re-added after the delete: kept.
      final readded = HomeSyncMerge.merge(
        phone,
        HomeSyncSnapshot(
          personasEnabled: true,
          syncPersonaIds: const ['p'],
          personasUpdatedAt: older,
          personas: [
            HomeSyncPersona(
              prompt: _persona('p', older),
              memories: [_memory('likes tea', newer)],
            ),
          ],
        ),
      );
      expect(
        readded.personas.single.memories.map((m) => m['content']),
        contains('likes tea'),
      );
    });

    test('memory key ignores ids and case, separates scope and persona', () {
      final a = HomeSyncMerge.memoryKey(
          {'id': '1', 'content': 'Tea', 'scope': 'private', 'personaId': 'p'});
      final b = HomeSyncMerge.memoryKey(
          {'id': '9', 'content': ' tea', 'scope': 'private', 'personaId': 'p'});
      expect(a, b);
      expect(
        HomeSyncMerge.memoryKey(
            {'content': 'tea', 'scope': 'lore', 'personaId': 'p'}),
        isNot(a),
      );
      expect(
        HomeSyncMerge.memoryKey(
            {'content': 'tea', 'scope': 'private', 'personaId': 'q'}),
        isNot(a),
      );
      // Same key from MemoryService's recorded form (snake or camel case).
      expect(
        HomeSyncMerge.memoryKey(
            {'content': 'tea', 'scope': 'private', 'persona_id': 'p'}),
        a,
      );
    });
  });
}
