import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

void main() {
  group('DocumentReference & CollectionReference', () {
    late FirebaseFirestore firestore;

    setUp(() {
      firestore = FirebaseFirestore.instanceFor(projectId: 'test-project');
    });

    test('auto-generates 20-character document IDs', () {
      final doc1 = firestore.collection('items').doc();
      final doc2 = firestore.collection('items').doc();

      expect(doc1.id.length, equals(20));
      expect(doc2.id.length, equals(20));
      expect(doc1.id, isNot(equals(doc2.id)));
    });

    test('resolves hierarchical paths and subcollections', () {
      final usersCol = firestore.collection('users');
      expect(usersCol.path, equals('users'));
      expect(usersCol.id, equals('users'));
      expect(usersCol.parent, isNull);

      final userDoc = usersCol.doc('user_123');
      expect(userDoc.path, equals('users/user_123'));
      expect(userDoc.id, equals('user_123'));
      expect(userDoc.parent.path, equals('users'));

      final postsCol = userDoc.collection('posts');
      expect(postsCol.path, equals('users/user_123/posts'));
      expect(postsCol.id, equals('posts'));
      expect(postsCol.parent!.path, equals('users/user_123'));

      final postDoc = postsCol.doc('post_456');
      expect(postDoc.path, equals('users/user_123/posts/post_456'));
      expect(postDoc.id, equals('post_456'));
    });

    test('DocumentSnapshot field access via string and FieldPath', () {
      final docRef = firestore.collection('users').doc('user_1');
      final snapshot = DocumentSnapshot<Map<String, dynamic>>(
        id: 'user_1',
        reference: docRef,
        metadata: const SnapshotMetadata(hasPendingWrites: false, isFromCache: false),
        exists: true,
        rawData: {
          'name': 'Alice',
          'profile': {
            'email': 'alice@example.com',
            'details': {
              'age': 30,
            },
          },
        },
        convertedData: {
          'name': 'Alice',
        },
      );

      expect(snapshot.exists, isTrue);
      expect(snapshot.get('name'), equals('Alice'));
      expect(snapshot.get('profile.email'), equals('alice@example.com'));
      expect(snapshot.get(FieldPath(const ['profile', 'details', 'age'])), equals(30));
      expect(snapshot['profile.email'], equals('alice@example.com'));
      expect(snapshot.get('unknown.field'), isNull);
    });

    test('DocumentReference withConverter supports custom domain types', () {
      final userDoc = firestore.collection('users').doc('123').withConverter<User>(
        fromFirestore: (snapshot, _) => User(name: snapshot.get('name') as String),
        toFirestore: (user, _) => {'name': user.name},
      );

      expect(userDoc.path, equals('users/123'));
      expect(userDoc.id, equals('123'));
    });
  });
}

class User {
  const User({required this.name});
  final String name;
}
