// Run against the Firestore emulator:
//   firebase emulators:start --only firestore --project demo-firestore-kit
//   FIRESTORE_EMULATOR_HOST=127.0.0.1:8080 dart run example/main.dart
import 'dart:io';

import 'package:firestore_kit/firestore_kit.dart';

Future<void> main() async {
  FirebaseFirestore.initialize(
    projectId: 'demo-firestore-kit',
    cacheAdapter: FileCacheAdapter(cacheDirectory: Directory('.firestore_cache')),
    useGrpcStreaming: true,
    logger: FirestoreLogger(level: LogLevel.info),
  );
  final emulator = Platform.environment['FIRESTORE_EMULATOR_HOST'] ?? '127.0.0.1:8080';
  final db = FirebaseFirestore.instance
    ..useFirestoreEmulator(emulator.split(':').first, int.parse(emulator.split(':').last));

  final todos = db.collection('todos');
  final subscription = todos.orderBy('createdAt').snapshots().listen((snapshot) {
    for (final change in snapshot.docChanges) {
      stdout.writeln('${change.type.name}: ${change.doc.id} => ${change.doc.data()}');
    }
  });

  final ref = await todos.add({
    'title': 'Ship firestore_kit',
    'done': false,
    'createdAt': FieldValue.serverTimestamp(),
  });
  await ref.update({'done': true, 'tags': FieldValue.arrayUnion(['release'])});

  final count = await todos.count().get();
  stdout.writeln('todos: ${count.count}');

  await db.waitForPendingWrites();
  await subscription.cancel();
  await db.terminate();
}
