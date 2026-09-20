@Tags(['emulator'])
library;

import 'dart:io';

import 'package:async/async.dart';
import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

/// End-to-end checks against a real Firestore emulator. Skipped unless
/// `FIRESTORE_EMULATOR_HOST=host:port` is set (as the Firebase CLI does).
void main() {
  final hostPort = Platform.environment['FIRESTORE_EMULATOR_HOST'];
  final skip = hostPort == null ? 'FIRESTORE_EMULATOR_HOST not set' : false;
  final host = hostPort?.split(':').first ?? '127.0.0.1';
  final port = int.tryParse(hostPort?.split(':').last ?? '') ?? 8080;
  // The emulator only serves the (default) database; isolate runs by collection name.
  final run = DateTime.now().microsecondsSinceEpoch;

  group('Firestore emulator (live)', () {
    late FirebaseFirestore db;
    late Directory cacheDir;

    setUp(() async {
      cacheDir = await Directory.systemTemp.createTemp('firestore_kit_live_');
      db = FirebaseFirestore.instanceFor(
        projectId: 'demo-firestore-kit',
        cacheAdapter: FileCacheAdapter(cacheDirectory: cacheDir),
        useGrpcStreaming: true,
        grpcOptions: const GrpcTransportOptions(fallbackToPolling: false, maxReconnectAttempts: 3),
      )..useFirestoreEmulator(host, port);
    });

    tearDown(() async {
      await db.terminate();
      await cacheDir.delete(recursive: true);
    });

    test('CRUD, field transforms, queries, aggregation and transactions', () async {
      final col = db.collection('live_$run');
      final a = col.doc('a');
      await a.set({
        'name': 'Alice',
        'score': 10,
        'tags': ['x'],
        'geo': const GeoPoint(1.5, 2.5),
        'when': const Timestamp(1700000000, 500000), // Firestore keeps microsecond precision
        'nested': {'k': 'v'},
        'createdAt': FieldValue.serverTimestamp(),
      });
      await a.update({
        'score': FieldValue.increment(5),
        'tags': FieldValue.arrayUnion(['y']),
        'nested.k2': 'v2',
        'name': FieldValue.delete(),
      });
      await col.doc('b').set({'score': 1});
      await col.doc('c').set({'score': 30});

      final snap = await a.get(const GetOptions(source: Source.server));
      expect(snap.exists, isTrue);
      expect(snap.metadata.isFromCache, isFalse);
      expect(snap.get('score'), equals(15));
      expect(snap.get('tags'), equals(['x', 'y']));
      expect(snap.get('nested'), equals({'k': 'v', 'k2': 'v2'}));
      expect(snap.containsField('name'), isFalse);
      expect(snap.get('geo'), equals(const GeoPoint(1.5, 2.5)));
      expect(snap.get('when'), equals(const Timestamp(1700000000, 500000)));
      expect(snap.get('createdAt'), isA<Timestamp>());

      // Server writes were mirrored into the disk cache.
      final cached = await a.get(const GetOptions(source: Source.cache));
      expect(cached.get('score'), equals(15));

      final q = await col.where('score', isGreaterThan: 5).orderBy('score', descending: true).get();
      expect(q.docs.map((d) => d.id), equals(['c', 'a']));

      final page = await col.orderBy('score').startAfterDocument(q.docs.last).get();
      expect(page.docs.map((d) => d.id), equals(['c']));

      final last = await col.orderBy('score').limitToLast(2).get();
      expect(last.docs.map((d) => d.id), equals(['a', 'c']));

      final group = await db.collectionGroup('live_$run').where('score', isEqualTo: 1).get();
      expect(group.docs.single.id, equals('b'));

      final agg = await col.aggregate(count(), sum('score'), average('score')).get();
      expect(agg.count, equals(3));
      expect(agg.getSum('score'), equals(46));
      expect(agg.getAverage('score'), closeTo(46 / 3, 0.001));

      final result = await db.runTransaction((tx) async {
        final current = await tx.get(a);
        tx.update(a, {'score': (current.get('score') as int) + 100});
        return current.get('score');
      });
      expect(result, equals(15));
      expect((await a.get()).get('score'), equals(115));

      final batch = db.batch()
        ..delete(col.doc('b'))
        ..set(col.doc('d'), {'score': 7});
      await batch.commit();
      expect((await col.doc('b').get()).exists, isFalse);
      expect((await col.doc('d').get()).get('score'), equals(7));
    });

    test('gRPC Listen delivers realtime document and query updates', () async {
      final col = db.collection('watch_$run');
      final docQueue = StreamQueue(col.doc('d1').snapshots());
      final queryQueue = StreamQueue(col.orderBy('n').snapshots());

      final first = await docQueue.next.timeout(const Duration(seconds: 10));
      expect(first.exists, isFalse);
      final firstQuery = await queryQueue.next.timeout(const Duration(seconds: 10));
      expect(firstQuery.size, equals(0));

      await col.doc('d1').set({'n': 2});
      final afterSet = await docQueue.next.timeout(const Duration(seconds: 10));
      expect(afterSet.get('n'), equals(2));
      final q1 = await queryQueue.next.timeout(const Duration(seconds: 10));
      expect(q1.docChanges.single.type, equals(DocumentChangeType.added));

      await col.doc('d0').set({'n': 1});
      final q2 = await queryQueue.next.timeout(const Duration(seconds: 10));
      expect(q2.docs.map((d) => d.id), equals(['d0', 'd1']));
      expect(q2.docChanges.map((c) => c.doc.id), contains('d0'));

      await col.doc('d1').delete();
      final afterDelete = await docQueue.next.timeout(const Duration(seconds: 10));
      expect(afterDelete.exists, isFalse);
      final q3 = await queryQueue.next.timeout(const Duration(seconds: 10));
      expect(q3.docs.map((d) => d.id), equals(['d0']));
      expect(q3.docChanges.single.type, equals(DocumentChangeType.removed));

      await docQueue.cancel();
      await queryQueue.cancel();
    });

    test('offline queue replays into the emulator after enableNetwork()', () async {
      final col = db.collection('offline_$run');
      await db.disableNetwork();
      await col.doc('q1').set({'v': 1, 'ts': FieldValue.serverTimestamp()});
      await col.doc('q1').update({'v': FieldValue.increment(1)});
      expect(await db.pendingWriteCount, equals(2));

      await db.enableNetwork();
      await db.waitForPendingWrites(timeout: const Duration(seconds: 10));
      final snap = await col.doc('q1').get(const GetOptions(source: Source.server));
      expect(snap.get('v'), equals(2));
      expect(snap.get('ts'), isA<Timestamp>());
    });
  }, skip: skip);
}
