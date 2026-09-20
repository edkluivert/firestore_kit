import 'dart:io';
import 'dart:typed_data';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('FileCacheAdapter', () {
    late Directory dir;
    late FileCacheAdapter adapter;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('firestore_kit_cache_');
      adapter = FileCacheAdapter(cacheDirectory: Directory('${dir.path}/nested/cache'));
    });

    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('round-trips Firestore value types through JSON on disk', () async {
      final firestore = FirebaseFirestore.instanceFor(projectId: 'file-cache-types');
      final data = <String, dynamic>{
        'name': 'Alice',
        'age': 30,
        'ratio': 0.5,
        'active': true,
        'nothing': null,
        'when': const Timestamp(1700000000, 123456789),
        'born': DateTime.utc(1990, 5, 17, 8, 30),
        'where': const GeoPoint(6.5244, 3.3792),
        'blob': Uint8List.fromList([1, 2, 3, 255]),
        'friend': firestore.doc('users/bob'),
        'tags': ['x', 1, const Timestamp(1, 2)],
        'nested': {
          'deep': {'ts': const Timestamp(5, 6)},
        },
      };

      await adapter.putDocument('users/alice', data);
      final loaded = await adapter.getDocument('users/alice');

      expect(loaded, isNotNull);
      expect(loaded!['name'], equals('Alice'));
      expect(loaded['age'], equals(30));
      expect(loaded['ratio'], equals(0.5));
      expect(loaded['active'], isTrue);
      expect(loaded.containsKey('nothing'), isTrue);
      expect(loaded['nothing'], isNull);
      expect(loaded['when'], equals(const Timestamp(1700000000, 123456789)));
      expect(loaded['born'], equals(DateTime.utc(1990, 5, 17, 8, 30)));
      expect(loaded['where'], equals(const GeoPoint(6.5244, 3.3792)));
      expect(loaded['blob'], equals(Uint8List.fromList([1, 2, 3, 255])));
      expect(loaded['friend'], equals('users/bob'));
      expect(loaded['tags'], equals(['x', 1, const Timestamp(1, 2)]));
      expect((loaded['nested'] as Map)['deep']['ts'], equals(const Timestamp(5, 6)));
    });

    test('CacheJsonCodec decode can resolve references', () {
      final firestore = FirebaseFirestore.instanceFor(projectId: 'file-cache-refs');
      final encoded = CacheJsonCodec.encode({'ref': firestore.doc('a/b')});
      final decoded = CacheJsonCodec.decode(encoded, refResolver: firestore.doc);
      expect(decoded['ref'], isA<DocumentReference<Map<String, dynamic>>>());
      expect((decoded['ref'] as DocumentReference<Map<String, dynamic>>).path, equals('a/b'));
    });

    test('persists the offline write queue across adapter instances', () async {
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'file-cache-queue',
        cacheAdapter: adapter,
      );
      await firestore.offlineQueue.enqueueWrite(PendingWrite(
        id: 'w1',
        type: 'set',
        path: 'todos/t1',
        data: {'title': 'persist me'},
      ));

      final reopened = FileCacheAdapter(cacheDirectory: adapter.cacheDirectory);
      final queue = OfflineWriteQueueManager(cacheAdapter: reopened);
      final pending = await queue.getPendingWrites();
      expect(pending, hasLength(1));
      expect(pending.single.id, equals('w1'));
      expect(pending.single.data, equals({'title': 'persist me'}));
      expect(pending.single.touchedPaths, equals(['todos/t1']));
    });

    test('keys(), deleteDocument() and clear() manage files on disk', () async {
      await adapter.putDocument('a/1', {'v': 1});
      await adapter.putDocument('a/2', {'v': 2});
      await adapter.putDocument('deep/x/y/z', {'v': 3});
      expect((await adapter.keys())..sort(), equals(['a/1', 'a/2', 'deep/x/y/z']));

      await adapter.deleteDocument('a/1');
      expect(await adapter.getDocument('a/1'), isNull);
      expect((await adapter.keys()).length, equals(2));

      await adapter.clear();
      expect(await adapter.keys(), isEmpty);
      expect(adapter.cacheDirectory.existsSync(), isTrue);

      // Writing after clear() works again.
      await adapter.putDocument('a/1', {'v': 1});
      expect((await adapter.getDocument('a/1'))!['v'], equals(1));
    });

    test('a corrupted cache file reads as a miss instead of throwing', () async {
      await adapter.putDocument('a/1', {'v': 1});
      final file = adapter.cacheDirectory.listSync().whereType<File>().single;
      await file.writeAsString('{not json');
      expect(await adapter.getDocument('a/1'), isNull);
    });

    test('is used by DocumentReference reads with Source.cache', () async {
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'file-cache-reads',
        cacheAdapter: adapter,
      );
      await adapter.putDocument('users/u', {'name': 'Disk', 'ts': const Timestamp(3, 0)});
      final snap = await firestore.doc('users/u').get(const GetOptions(source: Source.cache));
      expect(snap.exists, isTrue);
      expect(snap.metadata.isFromCache, isTrue);
      expect(snap.get('ts'), equals(const Timestamp(3, 0)));
    });
  });
}
