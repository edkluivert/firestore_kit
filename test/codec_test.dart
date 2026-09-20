import 'dart:convert';
import 'dart:typed_data';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:firestore_kit/src/codec/firestore_codec.dart';
import 'package:test/test.dart';

void main() {
  group('FirestoreCodec', () {
    test('encodes and decodes primitive types', () {
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue(null)), isNull);
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue(true)), isTrue);
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue(false)), isFalse);
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue(42)), equals(42));
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue(3.14)), equals(3.14));
      expect(FirestoreCodec.decodeValue(FirestoreCodec.encodeValue('hello')), equals('hello'));
    });

    test('encodes and decodes Timestamp', () {
      final now = Timestamp.now();
      final encoded = FirestoreCodec.encodeValue(now);
      expect(encoded.timestampValue, isNotNull);

      final decoded = FirestoreCodec.decodeValue(encoded) as Timestamp;
      expect(decoded.seconds, equals(now.seconds));
    });

    test('encodes and decodes GeoPoint', () {
      const geo = GeoPoint(37.7749, -122.4194);
      final encoded = FirestoreCodec.encodeValue(geo);
      expect(encoded.geoPointValue, isNotNull);
      expect(encoded.geoPointValue!.latitude, equals(37.7749));
      expect(encoded.geoPointValue!.longitude, equals(-122.4194));

      final decoded = FirestoreCodec.decodeValue(encoded) as GeoPoint;
      expect(decoded.latitude, equals(37.7749));
      expect(decoded.longitude, equals(-122.4194));
    });

    test('encodes and decodes binary bytes', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final encoded = FirestoreCodec.encodeValue(bytes);
      expect(encoded.bytesValue, equals(base64.encode(bytes)));

      final decoded = FirestoreCodec.decodeValue(encoded) as Uint8List;
      expect(decoded, equals(bytes));
    });

    test('encodes and decodes nested maps and lists', () {
      final map = {
        'name': 'DartNative',
        'tags': ['flutter', 'native', 'pure-dart'],
        'details': {
          'active': true,
          'version': 1,
          'score': 99.5,
        },
      };

      final docProto = FirestoreCodec.encodeDocument(map);
      expect(docProto.fields, isNotNull);

      final decoded = FirestoreCodec.decodeDocument(docProto);
      expect(decoded['name'], equals('DartNative'));
      expect(decoded['tags'], equals(['flutter', 'native', 'pure-dart']));
      expect(decoded['details']['active'], isTrue);
      expect(decoded['details']['version'], equals(1));
      expect(decoded['details']['score'], equals(99.5));
    });

    test('extracts FieldValue transforms', () {
      final data = {
        'count': FieldValue.increment(5),
        'timestamp': FieldValue.serverTimestamp(),
        'items': FieldValue.arrayUnion(['item1', 'item2']),
        'tags': FieldValue.arrayRemove(['old_tag']),
        'nested': {
          'hits': FieldValue.increment(1),
        },
      };

      final transforms = FirestoreCodec.extractFieldTransforms(data);
      expect(transforms.length, equals(5));

      final fields = transforms.map((t) => t.fieldPath).toList();
      expect(fields, contains('count'));
      expect(fields, contains('timestamp'));
      expect(fields, contains('items'));
      expect(fields, contains('tags'));
      expect(fields, contains('nested.hits'));
    });

    test('extracts delete paths', () {
      final data = {
        'active': true,
        'deletedField': FieldValue.delete(),
        'nested': {
          'removeMe': FieldValue.delete(),
        },
      };

      final deletePaths = FirestoreCodec.extractDeletePaths(data);
      expect(deletePaths, contains('deletedField'));
      expect(deletePaths, contains('nested.removeMe'));
    });
  });
}
