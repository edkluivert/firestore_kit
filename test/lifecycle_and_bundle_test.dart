import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:async/async.dart';
import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

import 'helpers/fake_rest_server.dart';

Uint8List buildBundle(List<Map<String, dynamic>> elements) {
  final buffer = StringBuffer();
  for (final element in elements) {
    final json = jsonEncode(element);
    buffer.write(utf8.encode(json).length);
    buffer.write(json);
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

void main() {
  group('Snapshot-based cursors', () {
    late FirebaseFirestore firestore;

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(projectId: 'cursor-project');
    });

    DocumentSnapshot<Map<String, dynamic>> snapshotFor(String path, Map<String, dynamic> data) {
      final ref = firestore.doc(path);
      return ref.buildSnapshotSync(data, exists: true, isFromCache: false);
    }

    test('startAfterDocument uses orderBy values plus the document name', () {
      final snap = snapshotFor('scores/s1', {'score': 42, 'name': 'x'});
      final query = firestore.collection('scores').orderBy('score', descending: true).startAfterDocument(snap);
      final sq = query.buildStructuredQuery();

      expect(sq.orderBy!.map((o) => o.field!.fieldPath), equals(['score', '__name__']));
      expect(sq.orderBy!.map((o) => o.direction), equals(['DESCENDING', 'DESCENDING']));
      expect(sq.startAt!.before, isFalse);
      expect(sq.startAt!.values!.first.integerValue, equals('42'));
      expect(sq.startAt!.values!.last.referenceValue,
          equals('projects/cursor-project/databases/(default)/documents/scores/s1'));
    });

    test('startAtDocument / endAtDocument / endBeforeDocument set cursor bounds', () {
      final snap = snapshotFor('scores/s2', {'score': 7});
      final base = firestore.collection('scores').orderBy('score');

      expect(base.startAtDocument(snap).buildStructuredQuery().startAt!.before, isTrue);
      expect(base.endAtDocument(snap).buildStructuredQuery().endAt!.before, isFalse);
      expect(base.endBeforeDocument(snap).buildStructuredQuery().endAt!.before, isTrue);

      // Without orderBy the cursor is the document name alone.
      final byName = firestore.collection('scores').startAtDocument(snap).buildStructuredQuery();
      expect(byName.orderBy!.single.field!.fieldPath, equals('__name__'));
      expect(byName.startAt!.values!.single.referenceValue, endsWith('/scores/s2'));
    });

    test('rejects missing documents and missing orderBy fields', () {
      final missing = firestore.doc('scores/none').buildSnapshotSync(null, exists: false, isFromCache: false);
      expect(() => firestore.collection('scores').startAtDocument(missing), throwsArgumentError);

      final noField = snapshotFor('scores/s3', {'other': 1});
      expect(() => firestore.collection('scores').orderBy('score').startAtDocument(noField),
          throwsArgumentError);
    });

    test('limitToLast reverses orderBy directions and swaps cursors', () {
      final query = firestore.collection('msgs').orderBy('ts').startAt([5]).limitToLast(3);
      final sq = query.buildStructuredQuery();
      expect(sq.orderBy!.single.direction, equals('DESCENDING'));
      expect(sq.limit, equals(3));
      expect(sq.startAt, isNull);
      expect(sq.endAt!.values!.single.integerValue, equals('5'));
      expect(() => firestore.collection('msgs').limitToLast(1).buildStructuredQuery(),
          throwsA(isA<FirebaseFirestoreException>()));
    });
  });

  group('Firestore bundles', () {
    late FirebaseFirestore firestore;
    const db = 'projects/bundle-project/databases/(default)';

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(
        projectId: 'bundle-project',
        cacheAdapter: MemoryCacheAdapter(),
      );
    });

    Uint8List sampleBundle() => buildBundle([
          {
            'metadata': {
              'id': 'b1',
              'createTime': '2024-01-01T00:00:00Z',
              'version': 1,
              'totalDocuments': 2,
              'totalBytes': 999,
            }
          },
          {
            'namedQuery': {
              'name': 'top-users',
              'bundledQuery': {
                'parent': '$db/documents',
                'structuredQuery': {
                  'from': [
                    {'collectionId': 'users'}
                  ],
                  'orderBy': [
                    {
                      'field': {'fieldPath': 'score'},
                      'direction': 'DESCENDING'
                    }
                  ],
                },
                'limitType': 'FIRST',
              },
              'readTime': '2024-01-01T00:00:00Z',
            }
          },
          {
            'documentMetadata': {
              'name': '$db/documents/users/low',
              'readTime': '2024-01-01T00:00:00Z',
              'exists': true,
              'queries': ['top-users'],
            }
          },
          {
            'document': {
              'name': '$db/documents/users/low',
              'fields': {
                'score': {'integerValue': '5'},
                'joined': {'timestampValue': '2024-01-01T00:00:00Z'},
              },
              'createTime': '2024-01-01T00:00:00Z',
              'updateTime': '2024-01-01T00:00:00Z',
            }
          },
          {
            'documentMetadata': {
              'name': '$db/documents/users/high',
              'readTime': '2024-01-01T00:00:00Z',
              'exists': true,
              'queries': ['top-users'],
            }
          },
          {
            'document': {
              'name': '$db/documents/users/high',
              'fields': {
                'score': {'integerValue': '50'},
                'name': {'stringValue': 'Ünïcode ✓'},
              },
              'createTime': '2024-01-01T00:00:00Z',
              'updateTime': '2024-01-01T00:00:00Z',
            }
          },
        ]);

    test('loadBundle reports progress and namedQueryGet serves ordered cached docs', () async {
      final task = firestore.loadBundle(sampleBundle());
      final progress = await task.stream.toList();

      expect(progress.first.taskState, equals(LoadBundleTaskState.running));
      expect(progress.last.taskState, equals(LoadBundleTaskState.success));
      expect(progress.last.documentsLoaded, equals(2));
      expect(progress.last.totalDocuments, equals(2));
      expect(progress.last.bytesLoaded, equals(progress.last.totalBytes));

      final snapshot = await firestore.namedQueryGet('top-users',
          options: const GetOptions(source: Source.cache));
      expect(snapshot.docs.map((d) => d.id), equals(['high', 'low']));
      expect(snapshot.metadata.isFromCache, isTrue);
      expect(snapshot.docs.first.get('name'), equals('Ünïcode ✓'));
      expect(snapshot.docs.last.get('joined'), isA<Timestamp>());
      expect(snapshot.docs.last.get('score'), equals(5));

      // Documents are also available through the cache adapter.
      final cached = await firestore.doc('users/high').get(const GetOptions(source: Source.cache));
      expect(cached.get('score'), equals(50));
    });

    test('namedQueryGet falls back to bundled data when the backend is unreachable', () async {
      await firestore.loadBundle(sampleBundle()).future;
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());

      final fallback = await firestore.namedQueryGet('top-users');
      expect(fallback.metadata.isFromCache, isTrue);
      expect(fallback.size, equals(2));

      await expectLater(
        firestore.namedQueryGet('top-users', options: const GetOptions(source: Source.server)),
        throwsA(isA<FirebaseFirestoreException>().having((e) => e.isOffline, 'isOffline', isTrue)),
      );
      await expectLater(
        firestore.namedQueryGet('missing'),
        throwsA(isA<FirebaseFirestoreException>().having((e) => e.code, 'code', 'not-found')),
      );
    });

    test('namedQueryGet runs the bundled query against a reachable backend', () async {
      await firestore.loadBundle(sampleBundle()).future;
      final server = await FakeRestServer.start();
      addTearDown(server.close);
      server.seed('$db/documents/users/fresh', {
        'score': {'integerValue': '99'}
      });
      firestore.useFirestoreEmulator(server.host, server.port);

      final live = await firestore.namedQueryGet('top-users');
      expect(live.metadata.isFromCache, isFalse);
      expect(live.docs.map((d) => d.id), equals(['fresh']));

      final typed = await firestore.namedQueryWithConverterGet<int>(
        'top-users',
        fromFirestore: (snap, _) => snap.get('score') as int,
        toFirestore: (score, _) => {'score': score},
      );
      expect(typed.docs.single.data(), equals(99));
    });

    test('a malformed bundle yields an error snapshot and throws', () async {
      final task = firestore.loadBundle(Uint8List.fromList(utf8.encode('19{"metadata":oops}')));
      await expectLater(task.future, throwsA(isA<FirebaseFirestoreException>()));
      // Nothing was loaded.
      await expectLater(firestore.namedQueryGet('x'), throwsA(isA<FirebaseFirestoreException>()));
    });
  });

  group('Persistence & lifecycle', () {
    var counter = 0;

    test('enablePersistence installs a FileCacheAdapter and migrates queued writes', () async {
      final dir = await Directory.systemTemp.createTemp('firestore_kit_persist_');
      addTearDown(() => dir.delete(recursive: true));
      final firestore = FirebaseFirestore.instanceFor(projectId: 'persist-${counter++}');
      addTearDown(firestore.terminate);

      expect(firestore.persistenceEnabled, isFalse);
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());
      await firestore.doc('todos/t1').set({'title': 'queued in memory'});
      expect(await firestore.pendingWriteCount, equals(1));

      await firestore.enablePersistence(PersistenceSettings(cacheDirectory: dir));
      expect(firestore.persistenceEnabled, isTrue);
      expect(firestore.cacheAdapter, isA<FileCacheAdapter>());
      expect(firestore.settings.persistenceEnabled, isTrue);

      // The in-memory queue moved to disk.
      final reopened = OfflineWriteQueueManager(cacheAdapter: FileCacheAdapter(cacheDirectory: dir));
      expect(await reopened.getPendingWrites(), hasLength(1));

      await firestore.doc('todos/t2').set({'title': 'on disk'});
      final cached = await firestore.doc('todos/t2').get(const GetOptions(source: Source.cache));
      expect(cached.get('title'), equals('on disk'));

      await firestore.clearPersistence();
      expect(await firestore.pendingWriteCount, equals(0));
      expect((await firestore.doc('todos/t2').get(const GetOptions(source: Source.cache))).exists, isFalse);
    });

    test('settings setter routes to an emulator host and enables persistence', () async {
      final dir = await Directory.systemTemp.createTemp('firestore_kit_settings_');
      addTearDown(() => dir.delete(recursive: true));
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'settings-${counter++}',
        cacheAdapter: FileCacheAdapter(cacheDirectory: dir),
      );
      addTearDown(firestore.terminate);
      final server = await FakeRestServer.start();
      addTearDown(server.close);

      firestore.settings = Settings(
        host: '${server.host}:${server.port}',
        sslEnabled: false,
        persistenceEnabled: true,
      );
      expect(firestore.client.isEmulator, isTrue);
      expect(firestore.client.emulatorPort, equals(server.port));
      expect(firestore.settings.persistenceEnabled, isTrue);

      await firestore.doc('ping/1').set({'ok': true});
      expect(server.commits, hasLength(1));
    });

    test('terminate() cancels listeners, blocks further use and releases the instance', () async {
      final server = await FakeRestServer.start();
      addTearDown(server.close);
      final projectId = 'terminate-${counter++}';
      final firestore = FirebaseFirestore.instanceFor(projectId: projectId);
      firestore.useFirestoreEmulator(server.host, server.port);
      server.seed('projects/$projectId/databases/(default)/documents/live/1', {
        'v': {'integerValue': '1'}
      });

      final done = Completer<void>();
      final sub = firestore
          .doc('live/1')
          .snapshots(pollInterval: const Duration(milliseconds: 50))
          .listen((_) {}, onDone: done.complete);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(firestore.listenerRegistry.length, equals(1));

      await firestore.terminate();
      await done.future.timeout(const Duration(seconds: 2));
      expect(firestore.isTerminated, isTrue);
      expect(firestore.listenerRegistry.length, equals(0));
      await sub.cancel();

      await expectLater(
        firestore.doc('live/1').get(),
        throwsA(isA<FirebaseFirestoreException>().having((e) => e.code, 'code', 'failed-precondition')),
      );
      await expectLater(firestore.waitForPendingWrites(), throwsA(isA<FirebaseFirestoreException>()));
      expect(() => firestore.loadBundle(Uint8List(0)), throwsA(isA<FirebaseFirestoreException>()));

      final fresh = FirebaseFirestore.instanceFor(projectId: projectId);
      addTearDown(fresh.terminate);
      expect(identical(fresh, firestore), isFalse);
      expect(fresh.isTerminated, isFalse);
      await firestore.terminate(); // idempotent
    });

    test('snapshotsInSync() fires immediately without listeners and after polling syncs', () async {
      final server = await FakeRestServer.start();
      addTearDown(server.close);
      final projectId = 'insync-${counter++}';
      final firestore = FirebaseFirestore.instanceFor(projectId: projectId);
      addTearDown(firestore.terminate);
      firestore.useFirestoreEmulator(server.host, server.port);
      server.seed('projects/$projectId/databases/(default)/documents/sync/1', {
        'v': {'integerValue': '1'}
      });

      final idle = StreamQueue(firestore.snapshotsInSync());
      await idle.next.timeout(const Duration(seconds: 1));
      await idle.cancel();

      final inSync = StreamQueue(firestore.snapshotsInSync());
      final snapshots = StreamQueue(
          firestore.doc('sync/1').snapshots(pollInterval: const Duration(milliseconds: 50)));
      final first = await snapshots.next.timeout(const Duration(seconds: 2));
      expect(first.get('v'), equals(1));
      await inSync.next.timeout(const Duration(seconds: 2));

      // While the network is disabled polling stops without erroring.
      await firestore.disableNetwork();
      final before = server.getCount;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(server.getCount, equals(before));
      await firestore.enableNetwork();

      await snapshots.cancel();
      await inSync.cancel();
    });
  });
}
