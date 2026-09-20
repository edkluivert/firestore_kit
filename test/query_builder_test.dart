import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('Query Builder', () {
    late FirebaseFirestore firestore;

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(projectId: 'test-project');
    });

    test('builds collection query with filters and sorting', () {
      final query = firestore
          .collection('users')
          .where('age', isGreaterThanOrEqualTo: 18)
          .where('active', isEqualTo: true)
          .orderBy('age', descending: true)
          .limit(10);

      final structured = query.buildStructuredQuery();

      expect(structured.from, isNotNull);
      expect(structured.from!.first.collectionId, equals('users'));
      expect(structured.from!.first.allDescendants, isFalse);

      expect(structured.where, isNotNull);
      expect(structured.where!.compositeFilter, isNotNull);
      expect(structured.where!.compositeFilter!.filters!.length, equals(2));

      expect(structured.orderBy, isNotNull);
      expect(structured.orderBy!.first.field!.fieldPath, equals('age'));
      expect(structured.orderBy!.first.direction, equals('DESCENDING'));

      expect(structured.limit, equals(10));
    });

    test('builds collectionGroup query', () {
      final query = firestore
          .collectionGroup('messages')
          .where('unread', isEqualTo: true);

      final structured = query.buildStructuredQuery();
      expect(structured.from!.first.collectionId, equals('messages'));
      expect(structured.from!.first.allDescendants, isTrue);
    });

    test('builds cursors (startAt, endBefore)', () {
      final query = firestore
          .collection('scores')
          .orderBy('score')
          .startAt([100])
          .endBefore([500]);

      final structured = query.buildStructuredQuery();
      expect(structured.startAt, isNotNull);
      expect(structured.startAt!.before, isTrue);
      expect(structured.startAt!.values!.first.integerValue, equals('100'));

      expect(structured.endAt, isNotNull);
      expect(structured.endAt!.before, isTrue);
      expect(structured.endAt!.values!.first.integerValue, equals('500'));
    });

    test('handles null filter conditions', () {
      final query = firestore
          .collection('profiles')
          .where('deletedAt', isNull: true);

      final structured = query.buildStructuredQuery();
      expect(structured.where!.unaryFilter, isNotNull);
      expect(structured.where!.unaryFilter!.op, equals('IS_NULL'));
    });
  });
}
