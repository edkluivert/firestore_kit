import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('Filter', () {
    late FirebaseFirestore firestore;

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(projectId: 'filter-test-project');
    });

    test('Filter field condition factory', () {
      final filter = Filter('age', isGreaterThanOrEqualTo: 18);
      final query = firestore.collection('users').where(filter);

      final structured = query.buildStructuredQuery();
      expect(structured.where, isNotNull);
      expect(structured.where!.fieldFilter, isNotNull);
      expect(structured.where!.fieldFilter!.field!.fieldPath, equals('age'));
      expect(structured.where!.fieldFilter!.op, equals('GREATER_THAN_OR_EQUAL'));
      expect(structured.where!.fieldFilter!.value!.integerValue, equals('18'));
    });

    test('Filter.or combines conditions with OR composite filter', () {
      final filter = Filter.or(
        Filter('status', isEqualTo: 'active'),
        Filter('role', isEqualTo: 'admin'),
      );
      final query = firestore.collection('users').where(filter);

      final structured = query.buildStructuredQuery();
      expect(structured.where, isNotNull);
      expect(structured.where!.compositeFilter, isNotNull);
      expect(structured.where!.compositeFilter!.op, equals('OR'));
      expect(structured.where!.compositeFilter!.filters!.length, equals(2));
    });

    test('Filter.and combines conditions with AND composite filter', () {
      final filter = Filter.and(
        Filter('age', isGreaterThan: 21),
        Filter('country', isEqualTo: 'US'),
      );
      final query = firestore.collection('users').where(filter);

      final structured = query.buildStructuredQuery();
      expect(structured.where, isNotNull);
      expect(structured.where!.compositeFilter, isNotNull);
      expect(structured.where!.compositeFilter!.op, equals('AND'));
      expect(structured.where!.compositeFilter!.filters!.length, equals(2));
    });

    test('Complex nested Filter combinations (AND of ORs)', () {
      final filter = Filter.and(
        Filter('active', isEqualTo: true),
        Filter.or(
          Filter('role', isEqualTo: 'admin'),
          Filter('permissions', arrayContains: 'all'),
        ),
      );
      final query = firestore.collection('users').where(filter);

      final structured = query.buildStructuredQuery();
      expect(structured.where, isNotNull);
      expect(structured.where!.compositeFilter, isNotNull);
      expect(structured.where!.compositeFilter!.op, equals('AND'));

      final subFilters = structured.where!.compositeFilter!.filters!;
      expect(subFilters.length, equals(2));
      expect(subFilters[0].fieldFilter, isNotNull);
      expect(subFilters[1].compositeFilter, isNotNull);
      expect(subFilters[1].compositeFilter!.op, equals('OR'));
    });
  });
}
