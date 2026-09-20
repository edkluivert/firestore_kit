import 'dart:async';

import 'package:async/async.dart';
import 'package:firestore_kit/firestore_kit.dart';
import 'package:grpc/grpc.dart';
import 'package:test/test.dart';

import 'helpers/fake_grpc_server.dart';

void main() {
  group('gRPC Listen (Firestore Watch)', () {
    late FakeFirestoreService service;
    late Server server;
    late FirebaseFirestore firestore;
    var counter = 0;
    late String db;
    late List<String> logs;

    String docName(String path) => '$db/documents/$path';

    setUp(() async {
      logs = [];
      service = FakeFirestoreService();
      server = await startFakeGrpcServer(service);
      final projectId = 'grpc-listen-${counter++}';
      db = 'projects/$projectId/databases/(default)';
      firestore = FirebaseFirestore.instanceFor(
        projectId: projectId,
        tokenProvider: () async => 'test-token',
        cacheAdapter: MemoryCacheAdapter(),
        logger: FirestoreLogger(
          level: LogLevel.debug,
          printer: (level, msg, [err, st]) => logs.add('${level.name}: $msg'),
        ),
        useGrpcStreaming: true,
        grpcOptions: GrpcTransportOptions(
          host: 'localhost',
          port: server.port!,
          useTls: false,
          maxReconnectAttempts: 2,
          initialBackoff: const Duration(milliseconds: 20),
          fallbackToPolling: false,
        ),
      );
    });

    tearDown(() async {
      await firestore.terminate();
      await server.shutdown();
    });

    test('document snapshots() streams live updates from a Listen stream', () async {
      final ref = firestore.collection('rooms').doc('r1');
      final snapshots = StreamQueue(ref.snapshots());
      final firstSnapshot = snapshots.next;

      final conn = await service.nextConnection();
      final first = await conn.nextRequest();
      expect(first.database, equals(db));
      expect(first.addTarget.targetId, equals(1));
      expect(first.addTarget.documents.documents, equals([docName('rooms/r1')]));
      expect(first.addTarget.resumeToken, isEmpty);
      expect(conn.metadata?['authorization'], equals('Bearer test-token'));
      expect(conn.metadata?['google-cloud-resource-prefix'], equals(db));

      conn.send(added());
      conn.send(documentChange(document(docName('rooms/r1'), {'title': str('hello'), 'n': integer(1)})));
      conn.send(current(resumeToken: [1, 2, 3]));
      conn.send(noChange());

      final s1 = await firstSnapshot;
      expect(s1.exists, isTrue);
      expect(s1.data(), equals({'title': 'hello', 'n': 1}));
      expect(s1.metadata.isFromCache, isFalse);
      expect(s1.metadata.hasPendingWrites, isFalse);

      // The server-delivered document is mirrored into the cache adapter.
      final cached = await ref.get(const GetOptions(source: Source.cache));
      expect(cached.data(), equals({'title': 'hello', 'n': 1}));

      conn.send(documentChange(document(docName('rooms/r1'), {'title': str('updated'), 'n': integer(2)}, version: 2)));
      conn.send(noChange());
      final s2 = await snapshots.next;
      expect(s2.data(), equals({'title': 'updated', 'n': 2}));

      conn.send(documentDelete(docName('rooms/r1')));
      conn.send(noChange());
      final s3 = await snapshots.next;
      expect(s3.exists, isFalse);
      expect(s3.data(), isNull);
      expect((await ref.get(const GetOptions(source: Source.cache))).exists, isFalse);

      await snapshots.cancel();
      await conn.clientClosed.future;
    });

    test('query snapshots() orders results locally and reports docChanges', () async {
      final query = firestore.collection('scores').orderBy('score', descending: true).limit(2);
      final snapshots = StreamQueue(query.snapshots());
      final firstSnapshot = snapshots.next;

      final conn = await service.nextConnection();
      final req = await conn.nextRequest();
      final target = req.addTarget.query;
      expect(target.parent, equals('$db/documents'));
      expect(target.structuredQuery.from.first.collectionId, equals('scores'));
      expect(target.structuredQuery.orderBy.first.field_1.fieldPath, equals('score'));
      expect(target.structuredQuery.limit.value, equals(2));

      conn.send(added());
      conn.send(documentChange(document(docName('scores/a'), {'score': integer(5)})));
      conn.send(documentChange(document(docName('scores/b'), {'score': integer(9)})));
      conn.send(documentChange(document(docName('scores/c'), {'score': integer(7)})));
      conn.send(current());
      conn.send(noChange());

      final s1 = await firstSnapshot;
      expect(s1.docs.map((d) => d.id), equals(['b', 'c']));
      expect(s1.docChanges.map((c) => c.type), everyElement(DocumentChangeType.added));

      conn.send(documentChange(document(docName('scores/d'), {'score': integer(10)})));
      conn.send(documentRemove(docName('scores/c')));
      conn.send(noChange());

      final s2 = await snapshots.next;
      expect(s2.docs.map((d) => d.id), equals(['d', 'b']));
      final byId = {for (final c in s2.docChanges) c.doc.id: c};
      expect(byId['c']!.type, equals(DocumentChangeType.removed));
      expect(byId['c']!.oldIndex, equals(1));
      expect(byId['d']!.type, equals(DocumentChangeType.added));
      expect(byId['d']!.newIndex, equals(0));
      expect(byId['b']!.type, equals(DocumentChangeType.modified));
      expect(byId['b']!.oldIndex, equals(0));
      expect(byId['b']!.newIndex, equals(1));

      await snapshots.cancel();
    });

    test('reconnects with the last resume token after a transient failure', () async {
      final ref = firestore.collection('rooms').doc('r1');
      final snapshots = StreamQueue(ref.snapshots());
      final firstSnapshot = snapshots.next;

      final conn1 = await service.nextConnection();
      await conn1.nextRequest();
      conn1.send(added());
      conn1.send(documentChange(document(docName('rooms/r1'), {'v': integer(1)})));
      conn1.send(current(resumeToken: [9, 9]));
      conn1.send(noChange());
      expect((await firstSnapshot).get('v'), equals(1));

      conn1.fail(const GrpcError.unavailable('gone'));

      final conn2 = await service.nextConnection();
      final req2 = await conn2.nextRequest();
      expect(req2.addTarget.resumeToken, equals([9, 9]));

      conn2.send(documentChange(document(docName('rooms/r1'), {'v': integer(2)}, version: 2)));
      conn2.send(current(resumeToken: [9, 10]));
      conn2.send(noChange());
      expect((await snapshots.next).get('v'), equals(2));

      await snapshots.cancel();
    });

    test('a permanent error is surfaced once without reconnecting', () async {
      final ref = firestore.collection('secret').doc('x');
      final errors = <Object>[];
      final done = Completer<void>();
      ref.snapshots().listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );

      final conn = await service.nextConnection();
      await conn.nextRequest();
      conn.fail(const GrpcError.permissionDenied('nope'));

      await done.future.timeout(const Duration(seconds: 5));
      expect(errors, hasLength(1));
      expect(errors.first, isA<FirebaseFirestoreException>());
      expect((errors.first as FirebaseFirestoreException).code, equals('permission-denied'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.connections, hasLength(1));
    });

    test('gives up after maxReconnectAttempts with the last error', () async {
      final ref = firestore.collection('rooms').doc('flaky');
      final errors = <Object>[];
      final done = Completer<void>();
      ref.snapshots().listen((_) {}, onError: errors.add, onDone: done.complete);

      for (var i = 0; i < 3; i++) {
        final conn = await service.nextConnection();
        await conn.nextRequest();
        conn.fail(const GrpcError.unavailable('down'));
      }

      await done.future.timeout(const Duration(seconds: 5));
      expect(service.connections, hasLength(3));
      expect(errors, hasLength(1));
      expect((errors.first as FirebaseFirestoreException).code, equals('unavailable'));
      expect(logs.where((l) => l.startsWith('warning: Listen stream error')), hasLength(2));
      expect(logs.any((l) => l.startsWith('error: Listen stream exhausted')), isTrue);
    });

    test('an existence filter mismatch triggers a full resync of the target', () async {
      final query = firestore.collection('items');
      final snapshots = StreamQueue(query.snapshots());
      final firstSnapshot = snapshots.next;

      final conn = await service.nextConnection();
      await conn.nextRequest();
      conn.send(added());
      conn.send(documentChange(document(docName('items/i1'), {'k': str('a')})));
      conn.send(current(resumeToken: [4]));
      conn.send(noChange());
      expect((await firstSnapshot).size, equals(1));

      conn.send(existenceFilter(2));
      final remove = await conn.nextRequest();
      expect(remove.removeTarget, equals(1));
      final readd = await conn.nextRequest();
      expect(readd.addTarget.targetId, equals(1));
      expect(readd.addTarget.resumeToken, isEmpty);

      conn.send(documentChange(document(docName('items/i1'), {'k': str('a')})));
      conn.send(documentChange(document(docName('items/i2'), {'k': str('b')})));
      conn.send(current());
      conn.send(noChange());
      final s2 = await snapshots.next;
      expect(s2.docs.map((d) => d.id), equals(['i1', 'i2']));

      await snapshots.cancel();
    });

    test('disableNetwork() suspends the stream and enableNetwork() resumes it', () async {
      final ref = firestore.collection('rooms').doc('r1');
      final snapshots = StreamQueue(ref.snapshots());
      final firstSnapshot = snapshots.next;

      final conn1 = await service.nextConnection();
      await conn1.nextRequest();
      conn1.send(added());
      conn1.send(documentChange(document(docName('rooms/r1'), {'v': integer(1)})));
      conn1.send(current(resumeToken: [7]));
      conn1.send(noChange());
      expect((await firstSnapshot).get('v'), equals(1));

      await firestore.disableNetwork();
      await conn1.clientClosed.future.timeout(const Duration(seconds: 5));
      expect(service.connections, hasLength(1));

      await firestore.enableNetwork();
      final conn2 = await service.nextConnection();
      final req = await conn2.nextRequest();
      expect(req.addTarget.resumeToken, equals([7]));

      await snapshots.cancel();
    });

    test('snapshotsInSync() fires after each consistent snapshot', () async {
      final ref = firestore.collection('rooms').doc('r1');
      final inSync = StreamQueue(firestore.snapshotsInSync());
      await inSync.next; // fires immediately: no listeners yet
      final snapshots = StreamQueue(ref.snapshots());
      final firstSnapshot = snapshots.next;

      final conn = await service.nextConnection();
      await conn.nextRequest();
      conn.send(added());
      conn.send(documentChange(document(docName('rooms/r1'), {'v': integer(1)})));
      conn.send(current());
      conn.send(noChange());
      await firstSnapshot;
      await inSync.next.timeout(const Duration(seconds: 5));

      await snapshots.cancel();
      await inSync.cancel();
    });
  });

  test('WatchTarget encodes structured queries into protobuf targets', () {
    final firestore = FirebaseFirestore.instanceFor(projectId: 'watch-target');
    final query = firestore
        .collection('users')
        .where('age', isGreaterThan: 18)
        .orderBy('age')
        .startAt([21]);
    final target = WatchTarget.query(
      parent: firestore.client.queryParent(query.path),
      structuredQuery: query.buildStructuredQuery(),
    ).toProto(5, resumeToken: [1]);

    expect(target.targetId, equals(5));
    expect(target.resumeToken, equals([1]));
    final sq = target.query.structuredQuery;
    expect(sq.where.fieldFilter.field_1.fieldPath, equals('age'));
    expect(sq.where.fieldFilter.value.integerValue.toInt(), equals(18));
    expect(sq.startAt.before, isTrue);
    expect(sq.startAt.values.first.integerValue.toInt(), equals(21));
  });
}
