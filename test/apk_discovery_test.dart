import 'dart:io';

import 'package:firestore_kit/firestore_kit.dart';
import 'package:firestore_kit/src/types/apk_resources.dart';
import 'package:test/test.dart';

void main() {
  final gradleApk = File('test/fixtures/google_services.apk');
  final assetApk = File('test/fixtures/google_services_asset.apk');

  group('ZipReader', () {
    test('lists entries and inflates deflated data', () {
      final zip = ZipReader.open(assetApk);
      addTearDown(zip.close);
      expect(zip.entries.map((e) => e.name),
          contains('assets/flutter_assets/android/app/google-services.json'));
      final json = String.fromCharCodes(
          zip.read(zip.find('assets/flutter_assets/android/app/google-services.json')!));
      expect(json, contains('"project_id": "demo-asset"'));
      final dex = zip.read(zip.find('classes.dex')!);
      expect(dex.length, 4096);
    });

    test('rejects non-zip files', () {
      final file = File('${Directory.systemTemp.path}/not-a-zip.bin')
        ..writeAsBytesSync(List.filled(100, 7));
      addTearDown(file.deleteSync);
      expect(() => ZipReader.open(file), throwsFormatException);
    });
  });

  group('resources.arsc', () {
    test('parses the Google Services string resources aapt2 compiled', () {
      final zip = ZipReader.open(gradleApk);
      addTearDown(zip.close);
      final strings = parseArscStrings(zip.read(zip.find('resources.arsc')!));
      expect(strings['project_id'], 'demo-arsc');
      expect(strings['google_api_key'], 'AIzaSyArscTestKey0000000000000000000000');
      expect(strings['google_app_id'], '1:123456789:android:0123456789abcdef');
      expect(strings['gcm_defaultSenderId'], '123456789');
      expect(strings['google_storage_bucket'], 'demo-arsc.appspot.com');
      expect(strings['firebase_database_url'], 'https://demo-arsc.firebaseio.com');
      expect(strings['app_name'], 'Arsc Test');
      expect(strings['hello'], 'Hello', reason: 'default config wins over values-fr');
    });
  });

  group('FirebaseOptions from an APK', () {
    test('Gradle plugin resources', () {
      final options = FirebaseOptions.fromApk(gradleApk.path);
      expect(options, isNotNull);
      expect(options!.projectId, 'demo-arsc');
      expect(options.apiKey, 'AIzaSyArscTestKey0000000000000000000000');
      expect(options.appId, '1:123456789:android:0123456789abcdef');
      expect(options.messagingSenderId, '123456789');
      expect(options.storageBucket, 'demo-arsc.appspot.com');
      expect(options.databaseId, '(default)');
      expect(options.source, endsWith('!resources.arsc'));
    });

    test('bundled google-services.json asset', () {
      final options = FirebaseOptions.fromApk(assetApk.path);
      expect(options, isNotNull);
      expect(options!.projectId, 'demo-asset');
      expect(options.apiKey, 'AIzaSyAssetKey00000000000000000000000000');
      expect(options.appId, '1:987654321:android:fedcba');
      expect(options.messagingSenderId, '987654321');
      expect(options.source, contains('google-services.json'));
    });

    test('APK without Firebase configuration yields null', () {
      final file = File('${Directory.systemTemp.path}/plain.zip');
      addTearDown(file.deleteSync);
      // A valid empty zip: just an end-of-central-directory record.
      file.writeAsBytesSync([0x50, 0x4b, 0x05, 0x06, ...List.filled(18, 0)]);
      expect(FirebaseOptions.fromApk(file.path), isNull);
      expect(FirebaseOptions.fromApk('/nowhere/base.apk'), isNull);
    });

    test('currentApkPath is null off Android', () {
      expect(currentApkPath(), Platform.isAndroid ? isNotNull : isNull);
    });
  });

  group('bundled assets on desktop / iOS layout', () {
    test('finds a plist under flutter_assets next to a fake executable', () {
      // fromBundledAssets walks next to Platform.resolvedExecutable, which we
      // cannot relocate in a test; exercise the parser path through fromFiles
      // with a directory instead.
      final dir = Directory.systemTemp.createTempSync('fak-bundle');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/GoogleService-Info.plist').writeAsStringSync('''
<plist version="1.0"><dict>
<key>API_KEY</key><string>AIzaBundle</string>
<key>GOOGLE_APP_ID</key><string>1:1:ios:1</string>
<key>GCM_SENDER_ID</key><string>1</string>
<key>PROJECT_ID</key><string>bundle-project</string>
</dict></plist>''');
      expect(FirebaseOptions.fromFiles(directory: dir)?.projectId, 'bundle-project');
    });
  });
}
