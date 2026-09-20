import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

import 'helpers/fake_rest_server.dart';

void main() {
  group('Automatic offline sync', () {
    var counter = 0;
    late FirebaseFirestore firestore;
    late List<String> logs;

    setUp(() {
      logs = [];
      firestore = FirebaseFirestore.instanceFor(
        projectId: 'offline-sync-${counter++}',
        cacheAdapter: MemoryCacheAdapter(),
        logger: FirestoreLogger(
          level: LogLevel.debug,
          printer: (level, msg, [err, st]) => logs.add('${level.name}: $msg'),
        ),
      );
    });

    tearDown(() => firestore.terminate());

    test('queues writes when the backend is unreachable and mirrors them to the cache', () async {
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());
      final ref = firestore.collection('users').doc('u1');

      await ref.set({'name': 'Alice', 'score': 1, 'tags': ['a']});
      await ref.update({
        'score': FieldValue.increment(4),
        'tags': FieldValue.arrayUnion(['b']),
        'profile.city': 'Lagos',
        'lastSeen': FieldValue.serverTimestamp(),
      });

      expect(await firestore.pendingWriteCount, equals(2));
      expect(logs.where((l) => l.contains('queued')), hasLength(2));

      final cached = await ref.get(const GetOptions(source: Source.cache));
      expect(cached.exists, isTrue);
      expect(cached.metadata.isFromCache, isTrue);
      expect(cached.metadata.hasPendingWrites, isTrue);
      expect(cached.get('score'), equals(5));
      expect(cached.get('tags'), equals(['a', 'b']));
      expect(cached.get('profile.city'), equals('Lagos'));
      expect(cached.get('lastSeen'), isA<Timestamp>());

      // serverAndCache reads fall back to the cached, locally-applied data.
      final fallback = await ref.get();
      expect(fallback.metadata.isFromCache, isTrue);
      expect(fallback.get('score'), equals(5));
    });

    test('flushPendingWrites() replays queued Write protos once the backend is reachable', () async {
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());
      final ref = firestore.collection('users').doc('u1');
      await ref.set({'name': 'Alice', 'createdAt': FieldValue.serverTimestamp()});
      await ref.delete();
      expect(await firestore.pendingWriteCount, equals(2));

      final server = await FakeRestServer.start();
      addTearDown(server.close);
      firestore.useFirestoreEmulator(server.host, server.port);

      expect(await firestore.flushPendingWrites(), equals(2));
      expect(await firestore.pendingWriteCount, equals(0));
      expect(server.commits, hasLength(2));

      final firstWrites = server.commits.first['writes'] as List;
      expect(firstWrites, hasLength(2)); // update + transform
      expect((firstWrites.first as Map)['update']['name'], endsWith('/documents/users/u1'));
      expect((firstWrites.last as Map)['transform']['fieldTransforms'].first['setToServerValue'],
          equals('REQUEST_TIME'));
      expect((server.commits.last['writes'] as List).first['delete'], endsWith('/users/u1'));
    });

    test('disableNetwork() queues batches and enableNetwork() syncs them', () async {
      final server = await FakeRestServer.start();
      addTearDown(server.close);
      firestore.useFirestoreEmulator(server.host, server.port);

      await firestore.disableNetwork();
      expect(firestore.networkEnabled, isFalse);

      final batch = firestore.batch()
        ..set(firestore.doc('users/a'), {'n': 1})
        ..update(firestore.doc('users/b'), {'n': 2})
        ..delete(firestore.doc('users/c'));
      await batch.commit();

      expect(server.commits, isEmpty);
      expect(await firestore.pendingWriteCount, equals(1));
      expect(await firestore.hasPendingWritesFor('users/b'), isTrue);
      expect(await firestore.hasPendingWritesFor('users/zzz'), isFalse);

      // Reads while offline come from the cache without hitting the server.
      final a = await firestore.doc('users/a').get();
      expect(a.metadata.isFromCache, isTrue);
      expect(a.get('n'), equals(1));
      expect(server.getCount, equals(0));

      await firestore.enableNetwork();
      expect(await firestore.pendingWriteCount, equals(0));
      expect(server.commits, hasLength(1));
      expect(server.commits.single['writes'], hasLength(3));
    });

    test('waitForPendingWrites() times out while offline and completes when online', () async {
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());
      await firestore.doc('users/w').set({'x': 1});

      await expectLater(
        firestore.waitForPendingWrites(timeout: const Duration(milliseconds: 300)),
        throwsA(isA<FirebaseFirestoreException>()
            .having((e) => e.code, 'code', 'deadline-exceeded')),
      );

      final server = await FakeRestServer.start();
      addTearDown(server.close);
      firestore.useFirestoreEmulator(server.host, server.port);

      await firestore.waitForPendingWrites(timeout: const Duration(seconds: 5));
      expect(await firestore.pendingWriteCount, equals(0));
      expect(server.commits, hasLength(1));
    });

    test('writes rejected by the backend are dropped instead of blocking the queue', () async {
      firestore.useFirestoreEmulator('127.0.0.1', await closedPort());
      await firestore.doc('users/bad').set({'x': 1});

      final server = await FakeRestServer.start()..failCommitsWithStatus = 403;
      addTearDown(server.close);
      firestore.useFirestoreEmulator(server.host, server.port);

      expect(await firestore.flushPendingWrites(), equals(0));
      expect(await firestore.pendingWriteCount, equals(0));
      expect(logs.any((l) => l.startsWith('error:') && l.contains('Dropping queued write')), isTrue);
    });

    test('autoQueueOfflineWrites: false surfaces the network error', () async {
      final strict = FirebaseFirestore.instanceFor(
        projectId: 'offline-strict-${counter++}',
        cacheAdapter: MemoryCacheAdapter(),
        autoQueueOfflineWrites: false,
      );
      addTearDown(strict.terminate);
      strict.useFirestoreEmulator('127.0.0.1', await closedPort());

      await expectLater(
        strict.doc('users/u1').set({'a': 1}),
        throwsA(isA<FirebaseFirestoreException>().having((e) => e.isOffline, 'isOffline', isTrue)),
      );
      expect(await strict.pendingWriteCount, equals(0));
    });

    test('successful writes still update the cache and are not queued', () async {
      final server = await FakeRestServer.start();
      addTearDown(server.close);
      firestore.useFirestoreEmulator(server.host, server.port);

      final ref = firestore.doc('users/ok');
      await ref.set({'a': 1});
      await ref.update({'b': FieldValue.increment(2)});

      expect(server.commits, hasLength(2));
      expect(await firestore.pendingWriteCount, equals(0));
      final cached = await ref.get(const GetOptions(source: Source.cache));
      expect(cached.metadata.hasPendingWrites, isFalse);
      expect(cached.data(), equals({'a': 1, 'b': 2}));
    });
  });
}
