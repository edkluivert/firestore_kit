import 'package:firestore_kit/src/codec/firestore_codec.dart';
import 'package:test/test.dart';

void main() {
  group('Dot Path Expansion', () {
    test('expandDotPaths expands flat dot-separated map keys into nested maps', () {
      final input = {
        'user.name': 'Alice',
        'user.profile.age': 30,
        'active': true,
      };

      final expanded = FirestoreCodec.expandDotPaths(input);

      expect(expanded['user'], isA<Map<String, dynamic>>());
      expect(expanded['user']['name'], equals('Alice'));
      expect(expanded['user']['profile'], isA<Map<String, dynamic>>());
      expect(expanded['user']['profile']['age'], equals(30));
      expect(expanded['active'], isTrue);
    });

    test('encodeDocument converts expanded dot-paths into nested MapValue proto fields', () {
      final input = {
        'settings.theme': 'dark',
        'settings.notifications.email': true,
      };

      final docProto = FirestoreCodec.encodeDocument(input);
      expect(docProto.fields, isNotNull);
      expect(docProto.fields!.containsKey('settings'), isTrue);

      final settingsValue = docProto.fields!['settings']!;
      expect(settingsValue.mapValue, isNotNull);
      expect(settingsValue.mapValue!.fields!['theme']!.stringValue, equals('dark'));

      final notifValue = settingsValue.mapValue!.fields!['notifications']!;
      expect(notifValue.mapValue!.fields!['email']!.booleanValue, isTrue);
    });
  });
}
