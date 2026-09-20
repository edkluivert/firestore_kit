import 'dart:convert';
import 'dart:io';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:test/test.dart';

const _plist = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>API_KEY</key>
	<string>AIzaSy-plist-key</string>
	<key>GCM_SENDER_ID</key>
	<string>123456789</string>
	<key>PLIST_VERSION</key>
	<string>1</string>
	<key>BUNDLE_ID</key>
	<string>com.example.app</string>
	<key>PROJECT_ID</key>
	<string>plist-project</string>
	<key>STORAGE_BUCKET</key>
	<string>plist-project.appspot.com</string>
	<key>IS_ADS_ENABLED</key>
	<false/>
	<key>GOOGLE_APP_ID</key>
	<string>1:123456789:ios:abcdef</string>
</dict>
</plist>
''';

final _googleServices = {
  'project_info': {
    'project_number': '987654321',
    'project_id': 'json-project',
    'storage_bucket': 'json-project.appspot.com',
  },
  'client': [
    {
      'client_info': {'mobilesdk_app_id': '1:987654321:android:fedcba'},
      'api_key': [
        {'current_key': 'AIzaSy-json-key'}
      ],
    }
  ],
  'configuration_version': '1',
};

void main() {
  group('FirebaseOptions', () {
    test('parses GoogleService-Info.plist', () {
      final options = FirebaseOptions.fromPlist(_plist);
      expect(options.projectId, equals('plist-project'));
      expect(options.apiKey, equals('AIzaSy-plist-key'));
      expect(options.appId, equals('1:123456789:ios:abcdef'));
      expect(options.messagingSenderId, equals('123456789'));
      expect(options.storageBucket, equals('plist-project.appspot.com'));
      expect(options.databaseId, equals('(default)'));
      expect(() => FirebaseOptions.fromPlist('<plist><dict></dict></plist>'), throwsFormatException);
    });

    test('parses google-services.json', () {
      final options = FirebaseOptions.fromGoogleServicesJson(_googleServices);
      expect(options.projectId, equals('json-project'));
      expect(options.apiKey, equals('AIzaSy-json-key'));
      expect(options.appId, equals('1:987654321:android:fedcba'));
      expect(options.messagingSenderId, equals('987654321'));
      expect(() => FirebaseOptions.fromGoogleServicesJson({}), throwsFormatException);
    });

    test('reads environment variables including FIREBASE_CONFIG', () {
      expect(FirebaseOptions.fromEnvironment({}), isNull);
      expect(FirebaseOptions.fromEnvironment({'GOOGLE_CLOUD_PROJECT': 'gcp-proj'})!.projectId, 'gcp-proj');
      final fromConfig = FirebaseOptions.fromEnvironment({
        'FIREBASE_CONFIG': jsonEncode({'projectId': 'fn-proj', 'storageBucket': 'fn.appspot.com'}),
        'FIREBASE_API_KEY': 'k',
        'FIREBASE_DATABASE_ID': 'analytics',
      })!;
      expect(fromConfig.projectId, equals('fn-proj'));
      expect(fromConfig.storageBucket, equals('fn.appspot.com'));
      expect(fromConfig.apiKey, equals('k'));
      expect(fromConfig.databaseId, equals('analytics'));
      expect(fromConfig.source, equals('environment'));
    });

    test('finds config files in the usual project locations', () async {
      final dir = await Directory.systemTemp.createTemp('firestore_kit_options_');
      addTearDown(() => dir.delete(recursive: true));
      expect(FirebaseOptions.fromFiles(directory: dir), isNull);

      final json = File('${dir.path}/android/app/google-services.json')..createSync(recursive: true);
      json.writeAsStringSync(jsonEncode(_googleServices));
      expect(FirebaseOptions.fromFiles(directory: dir)!.projectId, equals('json-project'));

      final plist = File('${dir.path}/ios/Runner/GoogleService-Info.plist')..createSync(recursive: true);
      plist.writeAsStringSync(_plist);
      // iOS plist ranks above the Android json.
      final found = FirebaseOptions.fromFiles(directory: dir)!;
      expect(found.projectId, equals('plist-project'));
      expect(found.source, equals(plist.path));

      // Environment beats files during discovery.
      final discovered = FirebaseOptions.discover(
        environment: {'FIREBASE_PROJECT_ID': 'env-proj'},
        directory: dir,
      )!;
      expect(discovered.projectId, equals('env-proj'));
    });

    test('FirebaseFirestore.initialize(options:) configures the default instance', () {
      FirebaseFirestore.initialize(
        options: const FirebaseOptions(projectId: 'opts-project', apiKey: 'key-1', databaseId: 'db2'),
      );
      addTearDown(FirebaseFirestore.resetDefaultConfiguration);

      final db = FirebaseFirestore.instance;
      expect(db.projectId, equals('opts-project'));
      expect(db.databaseId, equals('db2'));
      expect(db.apiKey, equals('key-1'));
      expect(db.options, equals(FirebaseFirestore.defaultOptions));
      expect(identical(db, FirebaseFirestore.instance), isTrue);

      // The token provider can be attached after the fact (e.g. once auth is ready).
      db.tokenProvider = () async => 'fresh-token';
      expect(db.client.tokenProvider, isNotNull);
    });

    test('FirebaseFirestore.instance explains itself when nothing is configured', () {
      FirebaseFirestore.resetDefaultConfiguration();
      final discoverable = FirebaseOptions.discover();
      if (discoverable != null) {
        // This machine has Firebase config in scope; instance() just works.
        expect(FirebaseFirestore.instance.projectId, equals(discoverable.projectId));
        return;
      }
      expect(
        () => FirebaseFirestore.instance,
        throwsA(isA<FirebaseFirestoreException>()
            .having((e) => e.code, 'code', 'failed-precondition')
            .having((e) => e.message, 'message', contains('FIREBASE_PROJECT_ID'))),
      );
    }, skip: false);
  });
}
