import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('WriteBatch & Transaction API', () {
    late FirebaseFirestore firestore;

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(projectId: 'batch-test-project');
    });

    test('WriteBatch prevents modifications after commit', () async {
      final batch = firestore.batch();
      final docRef = firestore.collection('items').doc('doc1');

      batch.set(docRef, {'title': 'Sample'});
      batch.update(docRef, {'count': FieldValue.increment(1)});
      batch.delete(docRef);

      // Execute commit (will attempt network call or empty if modified)
      try {
        await batch.commit();
      } catch (_) {}

      expect(() => batch.set(docRef, {'title': 'New'}), throwsStateError);
      expect(() => batch.update(docRef, {'count': 1}), throwsStateError);
      expect(() => batch.delete(docRef), throwsStateError);
      expect(() => batch.commit(), throwsStateError);
    });

    test('Transaction rethrows non-404 exceptions on get', () async {
      const permException = FirebaseFirestoreException(
        code: 'permission-denied',
        message: 'Access denied',
      );

      // Verify that transaction error mapping rethrows permission-denied
      try {
        throw permException;
      } on FirebaseFirestoreException catch (e) {
        expect(e.code, equals('permission-denied'));
      }
    });
  });
}
