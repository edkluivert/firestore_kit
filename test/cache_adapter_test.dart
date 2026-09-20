import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

class CustomStorageAdapter implements FirestoreCacheAdapter {
  final Map<String, Map<String, dynamic>> db = {};

  @override
  Future<Map<String, dynamic>?> getDocument(String documentPath) async => db[documentPath];

  @override
  Future<void> putDocument(String documentPath, Map<String, dynamic> data) async {
    db[documentPath] = data;
  }

  @override
  Future<void> deleteDocument(String documentPath) async {
    db.remove(documentPath);
  }

  @override
  Future<void> clear() async {
    db.clear();
  }
}

void main() {
  group('Pluggable FirestoreCacheAdapter', () {
    test('MemoryCacheAdapter stores and retrieves document cache', () async {
      final cache = MemoryCacheAdapter();
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'cache-test-proj',
        cacheAdapter: cache,
      );

      final docRef = firestore.collection('users').doc('user_99');

      // Populate cache manually or via offline operation
      await cache.putDocument(docRef.path, {'name': 'Cached Alice', 'role': 'tester'});

      // Fetch with GetOptions(source: Source.cache)
      final snap = await docRef.get(const GetOptions(source: Source.cache));
      expect(snap.exists, isTrue);
      expect(snap.metadata.isFromCache, isTrue);
      expect(snap.get('name'), equals('Cached Alice'));
    });

    test('CustomStorageAdapter handles pluggable storage engines', () async {
      final customStorage = CustomStorageAdapter();
      final firestore = FirebaseFirestore.instanceFor(
        projectId: 'custom-cache-proj',
        cacheAdapter: customStorage,
      );

      final docRef = firestore.collection('posts').doc('post_1');
      await customStorage.putDocument(docRef.path, {'title': 'Hive / SharedPreferences Plugged In'});

      final snap = await docRef.get(const GetOptions(source: Source.cache));
      expect(snap.get('title'), equals('Hive / SharedPreferences Plugged In'));
    });
  });
}
